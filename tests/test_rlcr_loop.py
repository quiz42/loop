"""Tests for RLCR loop orchestration commands."""

from __future__ import annotations

import importlib.util
import json
import os
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


rlcr_loop = load_module("rlcr_loop", "scripts/rlcr_loop.py")


class TestRLCRLoopSetup(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=root, check=True, capture_output=True, text=True)
        subprocess.run(["git", "config", "user.email", "dev@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Dev User"], cwd=root, check=True)
        (root / "README.md").write_text("# Test repo\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "initial"], cwd=root, check=True, capture_output=True, text=True)

    def test_setup_creates_state_prompt_goal_tracker_and_pending_session_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_repo(root)
            plan = root / "plan.md"
            plan.write_text(
                "# Plan\n\n"
                "## Goal\nShip the RLCR loop.\n\n"
                "## Acceptance Criteria\n- AC-1: Creates loop files.\n- AC-2: Preserves review settings.\n\n"
                "## Steps\nBuild and test the implementation.\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "plan.md"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "add plan"], cwd=root, check=True, capture_output=True, text=True)
            options = rlcr_loop.RLCRSetupOptions(
                project_root=root,
                plan_file=plan,
                max_iterations=7,
                codex_model="gpt-test",
                codex_effort="medium",
                codex_timeout=120,
                push_every_round=True,
                track_plan_file=True,
            )

            session = rlcr_loop.setup_rlcr_loop(options)

            state = rlcr_loop.parse_state(session.state_file)
            self.assertEqual(state["current_round"], "0")
            self.assertEqual(state["max_iterations"], "7")
            self.assertEqual(state["codex_model"], "gpt-test")
            self.assertEqual(state["codex_effort"], "medium")
            self.assertEqual(state["push_every_round"], "true")
            self.assertEqual(state["base_branch"], "main")
            self.assertIn("Ship the RLCR loop.", session.goal_tracker_file.read_text(encoding="utf-8"))
            self.assertIn("AC-1: Creates loop files", session.goal_tracker_file.read_text(encoding="utf-8"))
            self.assertIn("RLCR Round 0 Prompt", session.prompt_file.read_text(encoding="utf-8"))
            self.assertTrue((root / ".loop" / ".pending-session-id").is_file())
            self.assertEqual(
                rlcr_loop.find_active_loop(root / ".loop" / "rlcr").resolve(),
                session.loop_dir.resolve(),
            )

    def test_skip_impl_setup_does_not_require_plan(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_repo(root)
            options = rlcr_loop.RLCRSetupOptions(project_root=root, plan_file=None, skip_impl=True)

            session = rlcr_loop.setup_rlcr_loop(options)

            state = rlcr_loop.parse_state(session.state_file)
            self.assertEqual(state["review_started"], "true")
            self.assertEqual(state["skip_impl"], "true")
            self.assertTrue((session.loop_dir / ".review-phase-started").is_file())
            self.assertIn("Code Review Only", session.prompt_file.read_text(encoding="utf-8"))


class TestRLCRCancellation(unittest.TestCase):
    def make_loop(self, root: Path, state_name: str = "state.md") -> Path:
        loop_dir = root / ".loop" / "rlcr" / "2026-06-24_05-00-00"
        loop_dir.mkdir(parents=True)
        (loop_dir / state_name).write_text("current_round: 3\nmax_iterations: 9\n", encoding="utf-8")
        (root / ".loop" / ".pending-session-id").write_text("pending\n", encoding="utf-8")
        return loop_dir

    def test_cancel_active_loop_moves_state_and_cleans_pending_signal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            loop_dir = self.make_loop(root)

            code, message = rlcr_loop.cancel_rlcr_loop(root)

            self.assertEqual(code, 0)
            self.assertIn("CANCELLED", message)
            self.assertTrue((loop_dir / ".cancel-requested").is_file())
            self.assertTrue((loop_dir / "cancel-state.md").is_file())
            self.assertFalse((loop_dir / "state.md").exists())
            self.assertFalse((root / ".loop" / ".pending-session-id").exists())

    def test_finalize_phase_requires_force(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            loop_dir = self.make_loop(root, "finalize-state.md")

            code, message = rlcr_loop.cancel_rlcr_loop(root)
            forced_code, forced_message = rlcr_loop.cancel_rlcr_loop(root, force=True)

            self.assertEqual(code, 2)
            self.assertIn("FINALIZE_PHASE_DETECTED", message)
            self.assertEqual(forced_code, 0)
            self.assertIn("CANCELLED_FINALIZE", forced_message)
            self.assertTrue((loop_dir / "cancel-state.md").is_file())


class TestRLCRStopGate(unittest.TestCase):
    def write_hook(self, root: Path, output: str, exit_code: int = 0) -> None:
        hook = root / "hooks" / "loop-codex-stop-hook.sh"
        hook.parent.mkdir(parents=True)
        hook.write_text(
            "#!/usr/bin/env bash\n"
            "cat > hook-input.json\n"
            f"printf '%s' {json.dumps(output)}\n"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        hook.chmod(0o755)

    def test_stop_gate_allows_empty_hook_output_and_forwards_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_hook(root, "")

            code, stdout, stderr = rlcr_loop.run_stop_gate(root, session_id="session-1", transcript_path="transcript.jsonl")

            self.assertEqual(code, 0)
            self.assertEqual(stdout, "ALLOW: stop gate passed.")
            self.assertEqual(stderr, "")
            payload = json.loads((root / "hook-input.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["hook_event_name"], "Stop")
            self.assertEqual(payload["session_id"], "session-1")
            self.assertEqual(payload["transcript_path"], "transcript.jsonl")

    def test_stop_gate_maps_block_json_to_exit_one(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_hook(root, '{"decision":"block","reason":"round summary is missing"}')

            code, stdout, stderr = rlcr_loop.run_stop_gate(root)

            self.assertEqual(code, 1)
            self.assertIn("BLOCK: round summary is missing", stdout)
            self.assertEqual(stderr, "")

    def test_shell_wrappers_are_invokable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            loop_dir = self.make_loop_fixture(root)
            result = subprocess.run(
                ["bash", "scripts/cancel-rlcr-loop.sh", "--project-root", str(root)],
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("CANCELLED", result.stdout)
            self.assertTrue((loop_dir / "cancel-state.md").is_file())

    def make_loop_fixture(self, root: Path) -> Path:
        loop_dir = root / ".loop" / "rlcr" / "2026-06-24_06-00-00"
        loop_dir.mkdir(parents=True)
        (loop_dir / "state.md").write_text("current_round: 1\nmax_iterations: 2\n", encoding="utf-8")
        return loop_dir


if __name__ == "__main__":
    unittest.main()
