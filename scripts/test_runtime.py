import json
from pathlib import Path
import tempfile
import unittest

from runtime import active_runtime, initialize, seed_directory


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = self.root / "data/t3"
        self.providers = self.root / "data/providers"
        self.seed = self.root / "seed"
        self.provider_seed = self.root / "provider-seed"
        self.seed.mkdir()
        (self.seed / "t3").write_text("#!/bin/sh\nexit 0\n")
        (self.seed / "t3").chmod(0o755)
        self.provider_seed.mkdir()
        (self.provider_seed / "version").write_text("original")
        self.state = self.base / "runtime/service-state.json"

    def initialize(self, version="0.0.46-nightly.20261005.2676"):
        initialize(self.base, self.seed, self.provider_seed, self.providers, version)

    def test_first_boot_creates_complete_writable_installation(self):
        self.initialize()
        executable = active_runtime(self.base, self.seed)
        self.assertEqual(executable.read_bytes(), (self.seed / "t3").read_bytes())
        self.assertEqual(json.loads(self.state.read_text())["protocol"], 3)
        (self.providers / "version").write_text("updated")

    def test_image_replacement_preserves_selected_version_and_providers(self):
        self.initialize()
        original = self.state.read_bytes()
        (self.providers / "version").write_text("user update")
        self.initialize("0.0.46-nightly.20261005.2702")
        self.assertEqual(self.state.read_bytes(), original)
        self.assertEqual((self.providers / "version").read_text(), "user update")

    def test_fresh_settings_use_persistent_provider_homes(self):
        self.initialize()
        settings = json.loads((self.base / "userdata/settings.json").read_text())
        profiles = settings["providerInstances"]
        self.assertEqual(profiles["codex"]["config"]["homePath"], "/data/codex")
        self.assertEqual(profiles["claudeAgent"]["config"]["homePath"], "/data/claude-home")
        for driver, binary in [("codex", "codex"), ("claudeAgent", "claude"), ("opencode", "opencode")]:
            self.assertTrue(profiles[driver]["enabled"])
            self.assertEqual(profiles[driver]["config"]["binaryPath"], f"/data/providers/bin/{binary}")

    def test_existing_personal_and_work_profiles_are_not_rewritten(self):
        path = self.base / "userdata/settings.json"
        path.parent.mkdir(parents=True)
        original = json.dumps({"providerInstances": {
            "personal": {"driver": "claudeAgent", "config": {"homePath": "/data/claude-home"}},
            "work": {"driver": "claudeAgent", "config": {"homePath": "/data/claude-work"}},
        }, "enableProviderUpdateChecks": False}) + "\n"
        path.write_text(original)
        self.initialize()
        self.assertEqual(path.read_text(), original)

    def test_pending_update_is_left_for_upstream_rollback_recovery(self):
        self.initialize()
        state = json.loads(self.state.read_text())
        state["update"] = {"status": "pending", "fromVersion": state["activeVersion"],
                           "targetVersion": "0.0.46-nightly.20261005.2702",
                           "id": "test-update", "dbPath": str(self.base / "userdata/statev2.sqlite")}
        self.state.write_text(json.dumps(state))
        original = self.state.read_bytes()
        self.initialize()
        self.assertEqual(self.state.read_bytes(), original)

    def test_invalid_existing_state_is_not_reset(self):
        self.initialize()
        self.state.write_text('{"protocol":3,"activeVersion":"../../outside"}')
        with self.assertRaisesRegex(ValueError, "Invalid activeVersion"):
            self.initialize()
        self.assertIn("../../outside", self.state.read_text())

    def test_unknown_protocol_requires_compatible_image(self):
        self.initialize()
        state = json.loads(self.state.read_text())
        state["protocol"] = 4
        self.state.write_text(json.dumps(state))
        with self.assertRaisesRegex(ValueError, "Unsupported launcher protocol"):
            self.initialize()

    def test_incomplete_seed_never_publishes_service_state(self):
        (self.seed / "t3").unlink()
        with self.assertRaisesRegex(ValueError, "executable"):
            self.initialize()
        self.assertFalse(self.state.exists())

    def test_provider_seed_preserves_launcher_symlinks(self):
        (self.provider_seed / "dangling").symlink_to("missing")
        seed_directory(self.provider_seed, self.providers)
        self.assertTrue((self.providers / "dangling").is_symlink())


if __name__ == "__main__":
    unittest.main()
