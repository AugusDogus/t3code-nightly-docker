#!/usr/bin/env bash
set -euo pipefail

if (( $# > 0 )); then
  exec "$@"
fi

mkdir -p "$HOME" "$CODEX_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" \
  "$XDG_CACHE_HOME" "$NPM_CONFIG_CACHE" "$T3_WORKDIR" /data/claude-home
python3 /opt/t3-container/runtime.py initialize

# Trust repositories explicitly mounted as the coding workspace, not all paths.
while IFS= read -r -d '' marker; do
  repository="$(dirname -- "$marker")"
  if ! git config --global --get-all safe.directory | grep -Fx -- "$repository" >/dev/null; then
    git config --global --add safe.directory "$repository"
  fi
done < <(find "$T3_WORKDIR" -xdev -maxdepth 8 -name .git -print0 -prune)

# Retain the old image's host/port/bootstrap variable names for existing installs.
export T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD="${T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD:-${T3_AUTO_BOOTSTRAP_PROJECT_FROM_CWD:-1}}"
exec python3 /opt/t3-container/runtime.py launch \
  --host "${T3_SERVER_HOST:-${T3CODE_HOST:-0.0.0.0}}" \
  --port "${T3_SERVER_PORT:-${T3CODE_PORT:-3773}}" "$T3_WORKDIR"
