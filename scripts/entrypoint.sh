#!/usr/bin/env bash
set -euo pipefail

python3 /opt/t3-container/runtime.py initialize

# Keep the upstream configuration, authentication, and provider setup. Its final
# `t3 serve` is intercepted by our shim to start the native update supervisor.
export T3_CONTAINER_STARTUP=1
export T3_AUTO_UPDATE=0 T3_UPDATE_T3=0
export NPM_CONFIG_PREFIX=/data/providers npm_config_prefix=/data/providers
export PATH="/data/providers/bin:/usr/local/bin:$PATH"

# Project creation must happen inside the managed server, after the launcher's
# database snapshot, rather than before a pending update/rollback is recovered.
export T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD="${T3_AUTO_BOOTSTRAP_PROJECT_FROM_CWD:-1}"
export T3_AUTO_BOOTSTRAP_PROJECT_FROM_CWD=0
exec /opt/t3-docker/entrypoint.sh
