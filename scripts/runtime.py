"""Adapt T3's native service launcher (protocol 3) to a persistent container.

Only first boot creates service-state.json. Once present, that file belongs to
the upstream launcher, including pending updates and rollback recovery.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

import settings


VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?")


def active_runtime(base: Path, seed: Path) -> Path:
    state_path = base / "runtime/service-state.json"
    if not state_path.exists():
        return seed / "t3"
    state = json.loads(state_path.read_text())
    version = state.get("activeVersion") if isinstance(state, dict) else None
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError(f"Invalid activeVersion in {state_path}; restore the runtime from backup.")
    if state.get("protocol") != 3:
        raise ValueError(f"Unsupported launcher protocol in {state_path}; use a compatible container image.")
    runtime = base / "runtime/versions" / version
    if (runtime / ".install-complete").read_text().strip() != version:
        raise ValueError(f"Incomplete T3 runtime at {runtime}; restore it from backup.")
    if not os.access(runtime / "t3", os.X_OK):
        raise ValueError(f"T3 executable missing or not executable at {runtime}; restore it from backup.")
    return runtime / "t3"


def seed_directory(source: Path, destination: Path, version: str | None = None) -> None:
    """Publish a complete copy, never overlay an existing installation."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".container-seed-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "content"
        shutil.copytree(source, staged, symlinks=True)
        if version is not None:
            (staged / ".install-complete").write_text(version + "\n")
        staged.rename(destination)


def initialize(base: Path, seed: Path, provider_seed: Path, providers: Path, version: str) -> None:
    if not VERSION.fullmatch(version):
        raise ValueError("T3_IMAGE_T3_VERSION must contain an exact version.")
    runtime_dir = base / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    with (runtime_dir / ".container-init.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state_path = runtime_dir / "service-state.json"
        if not state_path.exists():
            destination = runtime_dir / "versions" / version
            if not destination.exists():
                seed_directory(seed, destination, version)
            # An interrupted initialization may already have copied the runtime.
            if (destination / ".install-complete").read_text().strip() != version:
                raise ValueError(f"Incomplete runtime at {destination}; restore it before starting.")
            if not os.access(destination / "t3", os.X_OK):
                raise ValueError(f"T3 executable missing or not executable at {destination}.")
            with tempfile.NamedTemporaryFile(mode="w", dir=runtime_dir, delete=False) as staging:
                staging.write(json.dumps({"protocol": 3, "activeVersion": version}) + "\n")
                staging.flush()
                os.fsync(staging.fileno())
            os.replace(staging.name, state_path)
            directory = os.open(runtime_dir, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        active_runtime(base, seed)
        if not providers.exists():
            seed_directory(provider_seed, providers)
        settings.initialize(base)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["initialize", "resolve", "launch"])
    parser.add_argument("--host")
    parser.add_argument("--port")
    parser.add_argument("--base-dir")
    parser.add_argument("cwd", nargs="?")
    args = parser.parse_intermixed_args()
    base = Path(args.base_dir or os.environ.get("T3CODE_HOME", "/data/t3"))
    seed = Path("/opt/t3-seed")
    if args.operation == "initialize":
        initialize(base, seed, Path("/opt/t3-provider-seed"), Path("/data/providers"),
                   os.environ.get("T3_IMAGE_T3_VERSION", ""))
    elif args.operation == "resolve":
        print(active_runtime(base, seed))
    else:
        active_runtime(base, seed)
        os.environ["T3CODE_HOME"] = str(base)
        os.environ["T3CODE_HOST"] = args.host or "0.0.0.0"
        os.environ["T3CODE_PORT"] = args.port or "3773"
        if args.cwd:
            os.chdir(args.cwd)
        # Keep the image's launcher stable while its children update themselves.
        os.execv(seed / "t3", [str(seed / "t3"), "__service-launcher"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"T3 container startup failed: {error} Existing data was not reset.", file=sys.stderr)
        sys.exit(1)
