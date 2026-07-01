"""Tests for the main loop command line entry point."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, PROJECT_ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {relative_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


loop = load_module("loop_cli", "scripts/loop.py")


class TestLoopCli(unittest.TestCase):
    def test_gen_idea_and_gen_plan_write_markdown_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            idea_file = root / "idea.md"
            plan_file = root / "plan.md"

            idea_code = loop.main(["gen-idea", "Add", "a", "monitor", "dashboard", "--output", str(idea_file)])
            plan_code = loop.main(["gen-plan", "--input", str(idea_file), "--output", str(plan_file)])

            self.assertEqual(idea_code, 0)
            self.assertEqual(plan_code, 0)
            self.assertIn("# Add a monitor dashboard", idea_file.read_text(encoding="utf-8"))
            plan = plan_file.read_text(encoding="utf-8")
            self.assertIn("Implementation Plan", plan)
            self.assertIn("python3 -m unittest discover -s tests", plan)

    def test_gen_idea_protects_existing_files_without_force(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "idea.md"
            output.write_text("keep me", encoding="utf-8")

            code = loop.main(["gen-idea", "new idea", "--output", str(output)])

            self.assertEqual(code, 1)
            self.assertEqual(output.read_text(encoding="utf-8"), "keep me")

    def test_monitor_skill_filters_through_main_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            codex = root / ".loop" / "skill" / "2026-06-22_10-00-00"
            gemini = root / ".loop" / "skill" / "2026-06-22_11-00-00"
            codex.mkdir(parents=True)
            gemini.mkdir(parents=True)
            codex.joinpath("input.md").write_text("- Tool: codex\n\n## Question\nReview this?\n", encoding="utf-8")
            gemini.joinpath("input.md").write_text("- Tool: gemini\n\n## Question\nPlan this?\n", encoding="utf-8")

            result = subprocess.run(
                [
                    "bash",
                    "scripts/loop.sh",
                    "monitor",
                    "codex",
                    "--once",
                    "--skill-dir",
                    str(root / ".loop" / "skill"),
                    "--project-root",
                    str(root),
                ],
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
                check=True,
            )

            self.assertIn("Loop Skill Monitor [codex]", result.stdout)
            self.assertIn("Review this?", result.stdout)
            self.assertNotIn("Plan this?", result.stdout)

    def test_start_cancel_and_monitor_rlcr_session(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plan = root / "docs" / "plan.md"
            plan.parent.mkdir()
            plan.write_text("# Plan\n", encoding="utf-8")

            start = subprocess.run(
                ["python3", str(PROJECT_ROOT / "scripts/loop.py"), "start-rlcr-loop", str(plan)],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("Created RLCR session", start.stdout)

            monitor = subprocess.run(
                ["python3", str(PROJECT_ROOT / "scripts/loop.py"), "monitor", "rlcr", "--once"],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("Loop RLCR Monitor", monitor.stdout)
            self.assertIn("Status:  active", monitor.stdout)

            cancel = subprocess.run(
                ["python3", str(PROJECT_ROOT / "scripts/loop.py"), "cancel-rlcr-loop", "--reason", "No longer needed."],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("Cancelled RLCR session", cancel.stdout)
            self.assertTrue(any((root / ".loop" / "rlcr").glob("*/cancelled-state.md")))

    def test_help_includes_top_level_commands(self):
        result = subprocess.run(
            ["bash", "scripts/loop.sh", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertIn("gen-idea", result.stdout)
        self.assertIn("gen-plan", result.stdout)
        self.assertIn("monitor", result.stdout)


if __name__ == "__main__":
    unittest.main()
