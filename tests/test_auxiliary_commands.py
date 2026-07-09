"""Tests for auxiliary command scripts."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
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
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


auxiliary_commands = load_module("auxiliary_commands", "scripts/lib/auxiliary_commands.py")
bitlesson = load_module("bitlesson", "scripts/bitlesson.py")
validate_io = load_module("validate_io", "scripts/validate_io.py")
install_tools = load_module("install_tools", "scripts/install_tools.py")
ask_tool = load_module("ask_tool", "scripts/ask_tool.py")


class TestBitlessonWorkflow(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_init_creates_workflow_files_and_preserves_existing_log(self):
        path = bitlesson.init_workflow(self.root)
        self.assertTrue(path.exists())
        state = json.loads((self.root / ".loop/bitlesson/state.json").read_text())
        self.assertIsNone(state["active_lesson"])
        path.write_text("custom", encoding="utf-8")
        bitlesson.init_workflow(self.root)
        self.assertEqual(path.read_text(encoding="utf-8"), "custom")

    def test_select_lesson_matches_query_or_uses_latest(self):
        bitlesson.init_workflow(self.root)
        path = self.root / ".loop/bitlesson/lessons.md"
        path.write_text(
            "# Bitter Lesson Log\n\n## Entries\n\n### First\nUse tests.\n\n### Second\nPrefer small deltas.\n",
            encoding="utf-8",
        )
        self.assertEqual(bitlesson.select_lesson(self.root)[0], "Second")
        self.assertEqual(bitlesson.select_lesson(self.root, "tests")[0], "First")

    def test_validate_delta_requires_sections(self):
        delta = self.root / "delta.md"
        delta.write_text("## Problem\nA\n## Change\nB\n", encoding="utf-8")
        self.assertIn("## Lesson", bitlesson.validate_delta(delta)[0])
        delta.write_text("## Problem\nA\n## Change\nB\n## Lesson\nC\n", encoding="utf-8")
        self.assertEqual(bitlesson.validate_delta(delta), [])


class TestIOValidation(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_gen_plan_requires_idea_section_and_available_output(self):
        idea = self.root / "idea.md"
        output = self.root / "plan.md"
        idea.write_text("# Title\n\n## Idea\nBuild a useful command.\n", encoding="utf-8")
        args = validate_io.build_parser().parse_args(["gen-plan", "--input", str(idea), "--output", str(output)])
        validate_io.validate_mode(args)
        output.write_text("existing", encoding="utf-8")
        with self.assertRaises(validate_io.IOValidationError):
            validate_io.validate_mode(args)

    def test_refine_plan_requires_plan_sections(self):
        plan = self.root / "plan.md"
        plan.write_text("## Implementation Steps\n- One\n## Acceptance Criteria\n- Done\n", encoding="utf-8")
        args = validate_io.build_parser().parse_args(["refine-plan", "--input", str(plan), "--output", str(self.root / "next.md")])
        validate_io.validate_mode(args)


class TestInstallTools(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.plugin = self.root / "plugin"
        (self.plugin / "hooks").mkdir(parents=True)
        (self.plugin / "config").mkdir()
        (self.plugin / "skills" / "demo").mkdir(parents=True)
        (self.plugin / "hooks" / "hook.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (self.plugin / "config" / "codex-hooks.json").write_text("{}", encoding="utf-8")
        (self.plugin / "skills" / "demo" / "SKILL.md").write_text("# Demo\n", encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_install_codex_hooks_copies_hooks_and_config(self):
        target = self.root / "target"
        copied = install_tools.install_codex_hooks(self.plugin, target)
        self.assertIn(target / "hooks" / "hook.sh", copied)
        self.assertIn(target / "codex-hooks.json", copied)
        self.assertTrue((target / "codex-hooks.json").exists())

    def test_install_skills_writes_profile_manifest(self):
        destination = self.root / "installed-skills"
        copied = install_tools.install_skills(self.plugin, destination, "codex")
        self.assertTrue(destination / "demo" / "SKILL.md")
        manifest = destination / "loop-codex-skills.json"
        self.assertIn(manifest, copied)
        self.assertEqual(json.loads(manifest.read_text())["profile"], "codex")


class TestAskTool(unittest.TestCase):
    def test_codex_model_option_splits_effort(self):
        with mock.patch.object(ask_tool, "command_available", return_value=True), \
            mock.patch.object(ask_tool, "project_root", return_value=PROJECT_ROOT), \
            mock.patch.object(ask_tool, "ensure_project_storage") as storage, \
            mock.patch.object(ask_tool, "unique_id", return_value="unit"), \
            mock.patch.object(ask_tool, "run_command", return_value=0):
            with tempfile.TemporaryDirectory() as temp_dir:
                temp = Path(temp_dir)
                skill_dir = temp / "skill"
                cache_dir = temp / "cache"
                skill_dir.mkdir()
                cache_dir.mkdir()
                storage.return_value = (skill_dir, cache_dir)
                stdout_path = cache_dir / "codex-run.out"
                stdout_path.write_text("Answer\n", encoding="utf-8")
                args = ask_tool.build_parser().parse_args(["codex", "--codex-model", "gpt-test:medium", "Question?"])
                self.assertEqual(ask_tool.run_codex(args), 0)
                metadata = json.loads((skill_dir / "metadata.md").read_text())
                self.assertEqual(metadata["model"], "gpt-test")
                self.assertIn("model_reasoning_effort=medium", metadata["command"])


class TestShellWrappers(unittest.TestCase):
    def test_requested_wrappers_are_executable_and_show_help(self):
        wrappers = [
            "ask-codex.sh",
            "ask-gemini.sh",
            "bitlesson-init.sh",
            "bitlesson-select.sh",
            "bitlesson-validate-delta.sh",
            "validate-gen-idea-io.sh",
            "validate-gen-plan-io.sh",
            "validate-refine-plan-io.sh",
            "install-codex-hooks.sh",
            "install-skill.sh",
            "install-skills-codex.sh",
            "install-skills-kimi.sh",
        ]
        for wrapper in wrappers:
            with self.subTest(wrapper=wrapper):
                path = PROJECT_ROOT / "scripts" / wrapper
                self.assertTrue(path.exists())
                self.assertTrue(path.stat().st_mode & 0o111)
                result = subprocess.run([str(path), "--help"], text=True, capture_output=True)
                self.assertIn(result.returncode, {0, 1})
                self.assertTrue(result.stdout or result.stderr)


class TestShellTestAssets(unittest.TestCase):
    def test_template_loader_shell_regression_assets_exist(self):
        for relative in (
            "tests/test-helpers.sh",
            "tests/test-template-loader.sh",
            "tests/test-loop-escape.sh",
            "tests/test-bash-validator-patterns.sh",
        ):
            with self.subTest(relative=relative):
                path = PROJECT_ROOT / relative
                self.assertTrue(path.exists())
                self.assertTrue(path.stat().st_mode & 0o111)

    def test_run_all_tests_includes_shell_regression(self):
        content = (PROJECT_ROOT / "tests" / "run-all-tests.sh").read_text(encoding="utf-8")
        self.assertIn("test-template-loader.sh", content)
        self.assertIn("test-loop-escape.sh", content)
        self.assertIn("test-bash-validator-patterns.sh", content)


if __name__ == "__main__":
    unittest.main()
