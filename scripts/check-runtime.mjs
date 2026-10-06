// Runs inside an isolated smoke-test container. Credentials stay in memory.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";

const [expectedVersion, updateFrom] = process.argv.slice(2);
assert.ok(expectedVersion, "Expected T3 version is required");
const origin = "http://127.0.0.1:3773";
const baseDir = process.env.T3CODE_HOME || "/data/t3";

async function environment() {
  const response = await fetch(`${origin}/.well-known/t3/environment`, {
    signal: AbortSignal.timeout(2000),
  });
  assert.equal(response.status, 200, "Environment discovery failed");
  return response.json();
}

const before = await environment();
assert.equal(before.serverVersion, updateFrom || expectedVersion);
assert.equal(before.capabilities.serverSelfUpdate, "boot-service");
const token = execFileSync("t3", ["auth", "session", "issue", "--token-only", "--ttl", "10m"], {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "pipe"],
}).trim();

async function rpc(method, payload) {
  const ticketResponse = await fetch(`${origin}/api/auth/websocket-ticket`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(5000),
  });
  assert.equal(ticketResponse.status, 200, "Existing session could not authenticate");
  const { ticket } = await ticketResponse.json();
  const descriptor = await environment();
  const url = new URL("/ws", origin);
  url.protocol = "ws:";
  url.searchParams.set("orchestrationProtocol", descriptor.orchestrationProtocolVersion);
  url.searchParams.set("wsTicket", ticket);
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timeout = setTimeout(() => finish(new Error(`${method} timed out`)), 180_000);
    function finish(error, value) {
      clearTimeout(timeout);
      socket.onclose = null;
      socket.close();
      if (error) reject(error);
      else resolve(value);
    }
    socket.onopen = () => socket.send(JSON.stringify({
      _tag: "Request", id: "1", tag: method, payload, headers: [],
    }));
    socket.onerror = () => finish(new Error(`${method}: WebSocket failed`));
    socket.onclose = () => finish(new Error(`${method}: connection closed before acknowledgement`));
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message._tag !== "Exit") return;
      if (message.exit._tag === "Success") finish(null, message.exit.value);
      else finish(new Error(`${method} failed: ${JSON.stringify(message.exit.cause)}`));
    };
  });
}

async function checkProviders() {
  const config = await rpc("server.getConfig", {});
  assert.equal(config.settings.enableProviderUpdateChecks, true);
  const drivers = ["codex", "claudeAgent", "opencode"];
  let snapshot = await rpc("server.refreshProviders", {});
  // Maintenance advisories arrive after executable discovery, even after a
  // refresh RPC. Wait for that asynchronous phase without refreshing it again.
  for (let attempt = 0; attempt < 30; attempt++) {
    if (drivers.every((driver) => snapshot.providers.some((item) =>
      item.driver === driver && item.enabled && item.versionAdvisory !== undefined))) break;
    await delay(1000);
    snapshot = await rpc("server.getConfig", {});
  }
  for (const driver of drivers) {
    const provider = snapshot.providers.find((item) => item.driver === driver && item.enabled);
    assert.ok(provider?.installed, `${driver} was not detected`);
    assert.equal(provider.versionAdvisory?.canUpdate, true, `${driver} cannot update`);
    assert.ok(provider.versionAdvisory.updateCommand.includes("--prefix /data/providers "),
      `${driver} updater targets a nonpersistent installation`);
    assert.notEqual(provider.compatibilityAdvisory?.status, "broken", `${driver} is incompatible`);
    console.log(`${driver} ${provider.version}: persistent installation, updates enabled`);
  }
}

await checkProviders();
if (updateFrom) {
  const result = await rpc("server.updateServer", { targetVersion: expectedVersion });
  assert.equal(result.method, "boot-service");
  assert.ok(result.updateId, "Update was not acknowledged by the native launcher");
  let after;
  for (let attempt = 0; attempt < 120; attempt++) {
    await delay(1000);
    try {
      after = await environment();
      if (after.serverVersion === expectedVersion) break;
    } catch (error) {
      // The listener is intentionally unavailable during the native handoff.
      if (!(error instanceof TypeError || error.name === "TimeoutError")) throw error;
    }
  }
  assert.equal(after?.serverVersion, expectedVersion, "Server did not activate the requested update");
  assert.equal(after.environmentId, before.environmentId, "Environment identity changed");
  const state = JSON.parse(readFileSync(`${baseDir}/runtime/service-state.json`, "utf8"));
  assert.equal(state.update.id, result.updateId);
  assert.equal(state.update.status, "committed");
  await checkProviders(); // Reconnect using the pre-update credential.
  console.log(`Native update ${updateFrom} -> ${expectedVersion}: committed and reconnected`);
}

if (process.env.TEST_ROLLBACK === "1") {
  // A staged test executable passes preflight, alters SQLite, then fails its
  // trial startup. The real launcher must restore both runtime and database.
  const version = "999.0.0-nightly.99990101.1";
  const fixture = `${baseDir}/runtime/versions/${version}`;
  const database = `${baseDir}/userdata/statev2.sqlite`;
  const databaseVersion = () => execFileSync("sqlite3", [database, "PRAGMA user_version"], {
    encoding: "utf8",
  }).trim();
  const originalDatabaseVersion = databaseVersion();
  mkdirSync(fixture);
  writeFileSync(`${fixture}/.install-complete`, `${version}\n`);
  writeFileSync(`${fixture}/t3`, `#!/bin/sh
if [ "$1" = __service-preflight ]; then
  printf '%s\\n' '{"status":"ready","version":"${version}","launcherProtocol":3}'
  exit 0
fi
sqlite3 "$T3CODE_HOME/userdata/statev2.sqlite" 'PRAGMA user_version=987654'
exit 42
`, { mode: 0o755 });
  try {
    const result = await rpc("server.updateServer", { targetVersion: version });
    let state;
    for (let attempt = 0; attempt < 60; attempt++) {
      await delay(1000);
      state = JSON.parse(readFileSync(`${baseDir}/runtime/service-state.json`, "utf8"));
      if (state.update?.id !== result.updateId || state.update.status !== "rolled-back") continue;
      try {
        if ((await environment()).serverVersion === expectedVersion) break;
      } catch (error) {
        if (!(error instanceof TypeError || error.name === "TimeoutError")) throw error;
      }
    }
    assert.equal(state.update.id, result.updateId);
    assert.equal(state.update.status, "rolled-back");
    assert.equal(state.activeVersion, expectedVersion);
    assert.equal(databaseVersion(), originalDatabaseVersion, "Trial database changes were not restored");
    await rpc("server.getConfig", {});
    console.log("Failed update: previous runtime, database, and authenticated connection restored");
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
}
