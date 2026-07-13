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
    def make_repo(self, root: Path) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=root, check=True, capture_output=True, text=True)
        subprocess.run(["git", "config", "user.email", "dev@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Dev User"], cwd=root, check=True)
        (root / "README.md").write_text("# Test repo\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "initial"], cwd=root, check=True, capture_output=True, text=True)

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
            self.assertIn("## Goal Description", plan)
            self.assertIn("## Path Boundaries", plan)
            self.assertIn("## Task Breakdown", plan)
            self.assertIn("## Claude-Codex Deliberation", plan)
            self.assertIn("## Pending User Decisions", plan)
            self.assertIn("python3 -m unittest discover -s tests", plan)

    def test_gen_idea_defaults_to_loop_ideas_and_records_requested_directions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result = subprocess.run(
                [
                    "python3",
                    str(PROJECT_ROOT / "scripts" / "loop.py"),
                    "gen-idea",
                    "Improve",
                    "the",
                    "planning",
                    "workflow",
                    "--n",
                    "3",
                ],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )

            self.assertIn(".loop/ideas/", result.stdout)
            idea_files = list((root / ".loop" / "ideas").glob("*.md"))
            self.assertEqual(len(idea_files), 1)
            content = idea_files[0].read_text(encoding="utf-8")
            self.assertIn("## Directed Exploration", content)
            self.assertIn("- Requested directions: 3", content)
            self.assertIn("### Alt-2:", content)

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
            self.make_repo(root)
            plan = root / "docs" / "plan.md"
            plan.parent.mkdir()
            plan.write_text(
                "# Plan\n\n"
                "## Goal\nShip the main CLI RLCR setup path.\n\n"
                "## Acceptance Criteria\n- AC-1: Creates loop files.\n- AC-2: Preserves review settings.\n\n"
                "## Steps\nBuild and test the implementation.\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "docs/plan.md"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "add plan"], cwd=root, check=True, capture_output=True, text=True)

            start = subprocess.run(
                [
                    "python3",
                    str(PROJECT_ROOT / "scripts/loop.py"),
                    "start-rlcr-loop",
                    str(plan),
                    "--codex-model",
                    "gpt-test",
                    "--codex-effort",
                    "medium",
                    "--max-iterations",
                    "7",
                ],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("RLCR loop initialized.", start.stdout)
            session_dirs = list((root / ".loop" / "rlcr").glob("*"))
            self.assertEqual(len(session_dirs), 1)
            session = session_dirs[0]
            self.assertTrue((session / "goal-tracker.md").is_file())
            self.assertTrue((session / "round-0-prompt.md").is_file())
            self.assertTrue((root / ".loop" / ".pending-session-id").is_file())
            state = (session / "state.md").read_text(encoding="utf-8")
            self.assertIn("max_iterations: 7", state)
            self.assertIn("codex_model: gpt-test", state)
            self.assertIn("codex_effort: medium", state)

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
            self.assertIn("CANCELLED", cancel.stdout)
            self.assertIn("No longer needed.", cancel.stdout)
            self.assertTrue((session / "cancel-state.md").is_file())
            self.assertFalse((session / "state.md").exists())

    def test_start_rlcr_loop_rejects_dirty_tree_and_untracked_plan_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_repo(root)
            tracked_plan = root / "plan.md"
            tracked_plan.write_text(
                "# Plan\n\n## Goal\nKeep setup safe.\n\n## Acceptance Criteria\n- AC-1: Reject unsafe starts.\n\n## Steps\nValidate.\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "plan.md"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "add plan"], cwd=root, check=True, capture_output=True, text=True)
            (root / "dirty.txt").write_text("dirty", encoding="utf-8")

            dirty = subprocess.run(
                ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "start-rlcr-loop", str(tracked_plan)],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("Git working tree is not clean", dirty.stderr)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_repo(root)
            untracked_plan = root / "plan.md"
            untracked_plan.write_text(
                "# Plan\n\n## Goal\nTrack plan input.\n\n## Acceptance Criteria\n- AC-1: Reject untracked plan.\n\n## Steps\nValidate.\n",
                encoding="utf-8",
            )

            untracked = subprocess.run(
                [
                    "python3",
                    str(PROJECT_ROOT / "scripts" / "loop.py"),
                    "start-rlcr-loop",
                    str(untracked_plan),
                    "--track-plan-file",
                ],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(untracked.returncode, 0)
            self.assertIn("--track-plan-file requires the plan file to be tracked in git", untracked.stderr)

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
        self.assertIn("refine-plan", result.stdout)
        self.assertIn("ask-codex", result.stdout)
        self.assertIn("ask-gemini", result.stdout)

    def test_ask_commands_expose_provider_help(self):
        cases = [
            ("ask-codex", "--codex-model"),
            ("ask-gemini", "--gemini-model"),
        ]
        for command, expected_option in cases:
            with self.subTest(command=command):
                result = subprocess.run(
                    ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), command, "--help"],
                    cwd=PROJECT_ROOT,
                    text=True,
                    capture_output=True,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected_option, result.stdout)

    def test_bitlesson_command_exposes_help_and_validate_delta(self):
        top_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "bitlesson", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(top_help.returncode, 0, top_help.stderr)
        self.assertIn("validate-delta", top_help.stdout)

        init_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "bitlesson", "init", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(init_help.returncode, 0, init_help.stderr)
        self.assertIn("--force", init_help.stdout)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            delta = root / "delta.md"
            delta.write_text("## Problem\nA\n## Change\nB\n## Lesson\nC\n", encoding="utf-8")
            result = subprocess.run(
                ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "bitlesson", "validate-delta", str(delta)],
                cwd=root,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Delta is valid.", result.stdout)

    def test_install_command_exposes_helper_subcommands(self):
        top_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "install", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(top_help.returncode, 0, top_help.stderr)
        self.assertIn("codex-hooks", top_help.stdout)
        self.assertIn("skills-codex", top_help.stdout)
        self.assertIn("skills-kimi", top_help.stdout)

        codex_hooks_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "install", "codex-hooks", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(codex_hooks_help.returncode, 0, codex_hooks_help.stderr)
        self.assertIn("--target-dir", codex_hooks_help.stdout)

        skill_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "install", "skill", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(skill_help.returncode, 0, skill_help.stderr)
        self.assertIn("--destination", skill_help.stdout)

    def test_validate_command_exposes_io_validation_subcommands(self):
        top_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "validate", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(top_help.returncode, 0, top_help.stderr)
        self.assertIn("gen-idea", top_help.stdout)
        self.assertIn("gen-plan", top_help.stdout)
        self.assertIn("refine-plan", top_help.stdout)

        gen_plan_help = subprocess.run(
            ["python3", str(PROJECT_ROOT / "scripts" / "loop.py"), "validate", "gen-plan", "--help"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(gen_plan_help.returncode, 0, gen_plan_help.stderr)
        self.assertIn("--input", gen_plan_help.stdout)
        self.assertIn("--output", gen_plan_help.stdout)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            idea = root / "idea.md"
            output = root / "plan.md"
            idea.write_text("# Title\n\n## Idea\nBuild a useful validation command.\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(PROJECT_ROOT / "scripts" / "loop.py"),
                    "validate",
                    "gen-plan",
                    "--input",
                    str(idea),
                    "--output",
                    str(output),
                ],
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("IO validation passed.", result.stdout)

    def test_refine_plan_direct_mode_writes_refined_plan_and_qa_ledger(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plan = root / "docs" / "plan.md"
            plan.parent.mkdir()
            plan.write_text(
                """# Demo Plan

## Implementation Steps
1. Add the first behavior.
CMT:
Clarify the first task.
ENDCMT

## Acceptance Criteria
- AC-1: Ship the first behavior. <cmt>Need a failure-path assertion.</cmt>
""",
                encoding="utf-8",
            )
            output = root / "docs" / "plan.refined.md"
            qa_dir = root / ".loop" / "plan_qa"

            result = subprocess.run(
                [
                    "python3",
                    str(PROJECT_ROOT / "scripts/loop.py"),
                    "refine-plan",
                    "--input",
                    str(plan),
                    "--output",
                    str(output),
                    "--qa-dir",
                    str(qa_dir),
                    "--direct",
                ],
                cwd=root,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Wrote refined plan", result.stdout)
            self.assertIn("Wrote QA ledger", result.stdout)
            self.assertTrue(output.is_file())
            self.assertTrue((qa_dir / "plan-qa.md").is_file())
            refined = output.read_text(encoding="utf-8")
            qa = (qa_dir / "plan-qa.md").read_text(encoding="utf-8")
            self.assertNotIn("CMT:", refined)
            self.assertNotIn("<cmt>", refined)
            self.assertIn("Clarify the first task.", qa)
            self.assertIn("Need a failure-path assertion.", qa)


if __name__ == "__main__":
    unittest.main()
