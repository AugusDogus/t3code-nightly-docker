#!/usr/bin/env bash
# Runs inside the disposable smoke container without registry dependencies.
set -euo pipefail

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/javascript/dependency" "$fixture/python"
cd "$fixture/javascript"
cat > package.json <<'JSON'
{"name":"container-smoke","private":true,"dependencies":{"smoke-dependency":"file:./dependency"}}
JSON
cat > dependency/package.json <<'JSON'
{"name":"smoke-dependency","version":"1.0.0","type":"module","exports":"./index.js"}
JSON
printf 'export const answer = 42;\n' > dependency/index.js
cat > dependency.test.js <<'JS'
import { expect, test } from "bun:test";
import { answer } from "smoke-dependency";

test("installed local package resolves", () => {
  expect(answer).toBe(42);
});
JS
bun install --ignore-scripts
bun install --frozen-lockfile --ignore-scripts
bun test

cd "$fixture/python"
cat > pyproject.toml <<'TOML'
[project]
name = "container-smoke"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = []
TOML
cat > check.py <<'PY'
from pathlib import Path
import sys

assert Path(sys.prefix) == Path(__file__).parent / ".venv", sys.prefix
PY
uv lock --offline --python python3 --no-python-downloads
uv sync --locked --offline --no-python-downloads
# Exercise uv 0.12's script-relative project discovery from another directory.
cd "$fixture"
uv run --locked --offline --no-python-downloads "$fixture/python/check.py"
