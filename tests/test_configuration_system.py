"""Tests for the configuration system."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, PROJECT_ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {relative_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config_loader = load_module("config_loader", "scripts/lib/config_loader.py")
model_router = load_module("model_router", "scripts/lib/model_router.py")


class TestConfigurationFiles(unittest.TestCase):
    def test_default_config_matches_expected_defaults(self):
        data = json.loads((PROJECT_ROOT / "config/default_config.json").read_text())
        self.assertEqual(data["codex_model"], "gpt-5.5")
        self.assertEqual(data["codex_effort"], "high")
        self.assertEqual(data["bitlesson_model"], "haiku")
        self.assertFalse(data["agent_teams"])
        self.assertEqual(data["alternative_plan_language"], "")
        self.assertEqual(data["gen_plan_mode"], "discussion")

    def test_codex_hooks_config_has_stop_command(self):
        data = json.loads((PROJECT_ROOT / "config/codex-hooks.json").read_text())
        stop_hooks = data["hooks"]["Stop"]
        command_hook = stop_hooks[0]["hooks"][0]
        self.assertEqual(command_hook["type"], "command")
        self.assertEqual(
            command_hook["command"],
            "{{LOOP_RUNTIME_ROOT}}/hooks/loop-codex-stop-hook.sh",
        )
        self.assertEqual(command_hook["timeout"], 7200)


class TestConfigLoader(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.plugin_root = self.root / "plugin"
        self.project_root = self.root / "project"
        (self.plugin_root / "config").mkdir(parents=True)
        (self.project_root / ".loop").mkdir(parents=True)
        (self.root / "user" / "loop").mkdir(parents=True)
        (self.plugin_root / "config" / "default_config.json").write_text(
            json.dumps(
                {
                    "codex_model": "gpt-5.5",
                    "codex_effort": "high",
                    "nested": {"keep": "default", "override": "default"},
                    "list_value": ["default", None],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_load_merged_config_applies_hierarchy_and_strips_nulls(self):
        user_config = self.root / "user" / "loop" / "config.json"
        user_config.write_text(
            json.dumps(
                {
                    "codex_effort": "medium",
                    "nested": {"override": "user", "user_only": None},
                }
            ),
            encoding="utf-8",
        )
        project_config = self.project_root / ".loop" / "config.json"
        project_config.write_text(
            json.dumps(
                {
                    "codex_model": "o3-mini",
                    "nested": {"override": "project"},
                    "project_only": True,
                }
            ),
            encoding="utf-8",
        )

        config = config_loader.load_merged_config(
            self.plugin_root,
            self.project_root,
            env={"XDG_CONFIG_HOME": str(self.root / "user")},
        )

        self.assertEqual(config["codex_model"], "o3-mini")
        self.assertEqual(config["codex_effort"], "medium")
        self.assertEqual(config["nested"]["keep"], "default")
        self.assertEqual(config["nested"]["override"], "project")
        self.assertNotIn("user_only", config["nested"])
        self.assertEqual(config["list_value"], ["default"])
        self.assertTrue(config["project_only"])

    def test_loop_config_overrides_project_default_path(self):
        override_config = self.root / "override.json"
        override_config.write_text(json.dumps({"codex_model": "gpt-4o"}), encoding="utf-8")
        config = config_loader.load_merged_config(
            self.plugin_root,
            self.project_root,
            env={"LOOP_CONFIG": str(override_config)},
        )
        self.assertEqual(config["codex_model"], "gpt-4o")

    def test_malformed_optional_config_is_ignored(self):
        user_config = self.root / "user" / "loop" / "config.json"
        user_config.write_text("not json", encoding="utf-8")
        config = config_loader.load_merged_config(
            self.plugin_root,
            self.project_root,
            env={"XDG_CONFIG_HOME": str(self.root / "user")},
        )
        self.assertEqual(config["codex_model"], "gpt-5.5")

    def test_missing_required_default_config_raises_error(self):
        (self.plugin_root / "config" / "default_config.json").unlink()
        with self.assertRaises(config_loader.ConfigError):
            config_loader.load_merged_config(self.plugin_root, self.project_root, env={})

    def test_get_config_value_formats_shell_friendly_values(self):
        config = {"name": "loop", "enabled": False, "count": 3, "items": ["a"]}
        self.assertEqual(config_loader.get_config_value(config, "name"), "loop")
        self.assertEqual(config_loader.get_config_value(config, "enabled"), "false")
        self.assertEqual(config_loader.get_config_value(config, "count"), "3")
        self.assertEqual(config_loader.get_config_value(config, "items"), '["a"]')
        self.assertEqual(config_loader.get_config_value(config, "missing"), "")


class TestModelRouter(unittest.TestCase):
    def test_detect_provider_routes_supported_models(self):
        examples = {
            "gpt-5.5": "codex",
            "o3-mini": "codex",
            "claude-3-5-sonnet": "claude",
            "haiku": "claude",
            "OPUS": "claude",
        }
        for model_name, provider in examples.items():
            with self.subTest(model_name=model_name):
                self.assertEqual(model_router.detect_provider(model_name), provider)

    def test_detect_provider_rejects_unknown_model(self):
        with self.assertRaises(model_router.ModelRoutingError):
            model_router.detect_provider("unknown-model")

    def test_map_effort_preserves_codex_and_maps_claude_xhigh(self):
        self.assertEqual(model_router.map_effort("xhigh", "codex"), "xhigh")
        self.assertEqual(model_router.map_effort("xhigh", "claude"), "high")
        self.assertEqual(model_router.map_effort("medium", "claude"), "medium")

    def test_map_effort_rejects_unknown_values(self):
        with self.assertRaises(model_router.ModelRoutingError):
            model_router.map_effort("extreme", "codex")
        with self.assertRaises(model_router.ModelRoutingError):
            model_router.map_effort("high", "other")

    def test_check_provider_dependency_uses_path_lookup(self):
        with mock.patch("shutil.which", return_value="/usr/bin/codex"):
            self.assertTrue(model_router.check_provider_dependency("codex"))
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(model_router.ModelRoutingError):
                model_router.check_provider_dependency("claude")


class TestShellWrappers(unittest.TestCase):
    def test_config_loader_shell_wrapper_can_load_and_read_values(self):
        command = "source scripts/lib/config-loader.sh; config=$(load_merged_config . .); get_config_value \"$config\" codex_model"
        result = subprocess.run(
            ["bash", "-lc", command],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(result.stdout.strip(), "gpt-5.5")

    def test_model_router_shell_wrapper_routes_models(self):
        command = "source scripts/lib/model-router.sh; detect_provider gpt-5.5; map_effort xhigh claude"
        result = subprocess.run(
            ["bash", "-lc", command],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(result.stdout.splitlines(), ["codex", "high"])


if __name__ == "__main__":
    unittest.main()
