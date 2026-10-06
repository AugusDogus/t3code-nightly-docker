#!/usr/bin/env bash
set -euo pipefail

curl --fail --silent --show-error --max-time 3 \
  "http://127.0.0.1:${T3_SERVER_PORT:-${T3CODE_PORT:-3773}}/.well-known/t3/environment" \
  >/dev/null
