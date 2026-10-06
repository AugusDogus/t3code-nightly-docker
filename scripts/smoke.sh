#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
expected_version="${2:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
container="t3code-smoke-${RANDOM}"
volume="${container}-data"
engine="${CONTAINER_ENGINE:-docker}"
current_image="${MIGRATE_FROM_IMAGE:-$image}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  "$engine" rm -f "$container" >/dev/null 2>&1 || true
  "$engine" volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$engine" volume create "$volume" >/dev/null
"$engine" run --rm --user 0 --entrypoint sh -v "$volume:/data" "$image" \
  -c 'mkdir -p /data/workspace && chown -R 99:100 /data && git init -q /data/workspace/repository'

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
    "$current_image" >/dev/null
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
  git --version
  git lfs version
  python3 --version
  cc --version
  fd --version
  bash -lc "command -v codex claude opencode"
  printf "persistent\n" > /data/workspace/smoke-marker
'
if [[ "$initial_version" != "$expected_version" ]]; then
  "$engine" exec -i "$container" node --input-type=module - "$expected_version" "$initial_version" \
    < "$script_dir/check-runtime.mjs"
else
  "$engine" exec -i "$container" node --input-type=module - "$expected_version" \
    < "$script_dir/check-runtime.mjs"
fi

# Native settings and profile data must survive replacing the old base image.
"$engine" exec -i "$container" python3 - <<'PY'
import json
from pathlib import Path
path = Path('/data/t3/userdata/settings.json')
settings = json.loads(path.read_text())
settings['providerInstances']['codex']['displayName'] = 'Personal smoke profile'
settings['providerInstances']['claudeAgent_work'] = {
    'driver': 'claudeAgent', 'displayName': 'Work smoke profile', 'enabled': False,
    'environment': [], 'config': {'binaryPath': 'claude', 'homePath': '/data/claude-work'},
}
path.write_text(json.dumps(settings))
home = Path('/data/claude-work')
home.mkdir(exist_ok=True)
(home / 'smoke-marker').write_text('preserved')
PY

# Recreate the container, retaining data. The selected runtime and provider
# installs must survive, even when the image's bootstrap version is older.
"$engine" rm -f "$container" >/dev/null
current_image="$image"
start
ready
# shellcheck disable=SC2016 # Read the marker inside the replacement container.
"$engine" exec "$container" sh -c 'test "$(cat /data/workspace/smoke-marker)" = persistent'
"$engine" exec "$container" sh -c '
  set -eu
  test ! -e /opt/t3-docker
  /opt/t3-container/healthcheck.sh
  yarn --version
  git -C /data/workspace/repository status --porcelain
'
"$engine" exec -i "$container" python3 - <<'PY'
import json
from pathlib import Path
profiles = json.loads(Path('/data/t3/userdata/settings.json').read_text())['providerInstances']
assert profiles['codex']['displayName'] == 'Personal smoke profile'
assert profiles['claudeAgent_work']['config']['homePath'] == '/data/claude-work'
assert profiles['claudeAgent_work']['enabled'] is False
assert Path('/data/claude-work/smoke-marker').read_text() == 'preserved'
print('Personal/work profiles and provider homes preserved.')
PY
"$engine" exec -i -e TEST_ROLLBACK=1 "$container" node --input-type=module - "$expected_version" \
  < "$script_dir/check-runtime.mjs"
echo "Native updates, provider installations, UID 99, and container replacement passed."
