#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
expected_version="${2:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
container="t3code-smoke-${RANDOM}"
volume="${container}-data"
engine="${CONTAINER_ENGINE:-docker}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  "$engine" rm -f "$container" >/dev/null 2>&1 || true
  "$engine" volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$engine" volume create "$volume" >/dev/null
"$engine" run --rm --user 0 --entrypoint sh -v "$volume:/data" "$image" \
  -c 'chown -R 99:100 /data'

# Seed an older real release to exercise the same download and restart RPC as
# the UI. Omit UPDATE_FROM_VERSION for the smaller startup/persistence check.
initial_version="${UPDATE_FROM_VERSION:-$expected_version}"
if [[ "$initial_version" != "$expected_version" ]]; then
  "$engine" run --rm --user 99:100 --entrypoint /opt/t3-seed/t3 \
    -v "$volume:/data" "$image" update "$initial_version" \
    --base-dir /data/t3 --allow-downgrade
fi

start() {
  "$engine" run --detach --name "$container" --user 99:100 \
    --publish 127.0.0.1::3773 -v "$volume:/data" \
    -e T3_IMAGE_T3_VERSION="$initial_version" \
    -e T3_WORKDIR=/data/workspace \
    -e T3_PROVIDER_CURSOR=0 -e T3_PROVIDER_GROK=0 \
    -e T3_OPENCODE_CLOUDFLARE_MCP=0 -e T3_OPENCODE_MCP_PRESETS= \
    "$image" >/dev/null
}

ready() {
  local host_port
  host_port="$("$engine" port "$container" 3773/tcp | sed 's/.*://')"
  for _ in $(seq 1 120); do
    if curl --fail --silent --max-time 2 \
      "http://127.0.0.1:${host_port}/.well-known/t3/environment" >/dev/null; then
      return 0
    fi
    if [[ "$("$engine" inspect --format '{{.State.Running}}' "$container")" != true ]]; then
      break
    fi
    sleep 0.5
  done
  # Do not print pairing credentials or QR codes from startup logs.
  "$engine" logs "$container" 2>&1 | grep -Ei 'error|failed|denied|invalid|unsupported|usage:' >&2 || true
  echo "T3 Code did not become healthy. Inspect the smoke container startup error above." >&2
  return 1
}

start
ready
# shellcheck disable=SC2016 # These expressions run inside the container.
"$engine" exec "$container" sh -c '
  set -eu
  test "$(id -u)" = 99
  claude --version
  codex --version
  opencode --version
  pnpm --version
  bun --version
  uv --version
  gh --version
  printf "persistent\n" > /data/workspace/smoke-marker
'
if [[ "$initial_version" != "$expected_version" ]]; then
  "$engine" exec -i "$container" node --input-type=module - "$expected_version" "$initial_version" \
    < "$script_dir/check-runtime.mjs"
else
  "$engine" exec -i "$container" node --input-type=module - "$expected_version" \
    < "$script_dir/check-runtime.mjs"
fi

# Recreate the container, retaining data. The selected runtime and provider
# installs must survive, even when the image's bootstrap version is older.
"$engine" rm -f "$container" >/dev/null
start
ready
# shellcheck disable=SC2016 # Read the marker inside the replacement container.
"$engine" exec "$container" sh -c 'test "$(cat /data/workspace/smoke-marker)" = persistent'
"$engine" exec -i -e TEST_ROLLBACK=1 "$container" node --input-type=module - "$expected_version" \
  < "$script_dir/check-runtime.mjs"
echo "Native updates, provider installations, UID 99, and container replacement passed."
