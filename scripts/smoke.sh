#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
expected_version="${2:?usage: smoke.sh IMAGE EXPECTED_T3_VERSION}"
container="t3code-smoke-${RANDOM}"
engine="${CONTAINER_ENGINE:-docker}"

cleanup() {
  "$engine" rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$engine" run --rm \
  --entrypoint sh \
  -e EXPECTED_T3_VERSION="$expected_version" \
  "$image" \
  -c '
    set -eu
    t3_version="$(t3 --version)"
    case "$t3_version" in
      *"$EXPECTED_T3_VERSION"*) ;;
      *)
        echo "expected T3 $EXPECTED_T3_VERSION, got $t3_version" >&2
        exit 1
        ;;
    esac
    test "$(id -u)" != "0"
    claude --version
    codex --version
    opencode --version
    cursor-agent --version
    grok --version
    pnpm --version
    bun --version
    uv --version
    gh --version
  '

"$engine" run --detach \
  --name "$container" \
  --publish 127.0.0.1::3773 \
  "$image" >/dev/null

host_port="$("$engine" port "$container" 3773/tcp | sed 's/.*://')"

for _ in $(seq 1 120); do
  if curl --fail --silent --max-time 2 \
    "http://127.0.0.1:${host_port}/.well-known/t3/environment" >/dev/null; then
    "$engine" logs "$container"
    exit 0
  fi

  if ! "$engine" inspect --format '{{.State.Running}}' "$container" | grep -qx true; then
    "$engine" logs "$container" >&2
    exit 1
  fi

  sleep 0.5
done

"$engine" logs "$container" >&2
echo "T3 Code did not become healthy" >&2
exit 1
