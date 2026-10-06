"""Seed native T3 settings once; existing profiles belong to the user."""

import json
import os
from pathlib import Path
import tempfile


def initialize(base: Path) -> None:
    path = base / "userdata/settings.json"
    if path.exists():
        return
    profiles = {}
    for driver, binary, name, home in [
        ("codex", "codex", "Codex", "/data/codex"),
        ("claudeAgent", "claude", "Claude", "/data/claude-home"),
        ("opencode", "opencode", "OpenCode", None),
    ]:
        config = {"enabled": True, "binaryPath": f"/data/providers/bin/{binary}"}
        if home is not None:
            config["homePath"] = home
        profiles[driver] = {"driver": driver, "displayName": name, "enabled": True,
                            "environment": [], "config": config}
    settings = {"providerInstances": profiles,
                "providers": {driver: profile["config"] for driver, profile in profiles.items()}}
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent) as temporary:
        json.dump(settings, temporary)
        temporary.flush()
        os.fsync(temporary.fileno())
        try:
            os.link(temporary.name, path)
        except FileExistsError:
            pass  # A concurrent initializer already published settings.
