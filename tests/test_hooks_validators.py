from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from hooks import validators


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


TODO_CHECKER = load_module(ROOT / "hooks" / "check-todos-from-transcript.py", "check_todos_from_transcript")


class HookValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.loop_dir = self.root / ".humanize" / "rlcr" / "2026-01-01_00-00-00"
        self.loop_dir.mkdir(parents=True)
        (self.loop_dir / "state.md").write_text(
            "---\ncurrent_round: 2\nmax_iterations: 4\nreview_started: false\nbase_branch: main\nsession_id: sid\n---\n",
            encoding="utf-8",
        )
        (self.loop_dir / "goal-tracker.md").write_text(
            "## IMMUTABLE SECTION\nGoal\n---\n## MUTABLE SECTION\nCurrent\n",
            encoding="utf-8",
        )
        self.old_env = os.environ.copy()
        os.environ["CLAUDE_PROJECT_DIR"] = str(self.root)

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp_dir.cleanup()

    def payload(self, tool_name: str, **tool_input: object) -> dict[str, object]:
        return {"tool_name": tool_name, "tool_input": tool_input, "session_id": "sid"}

    def test_write_blocks_state_file(self) -> None:
        result = validators.validate_write(self.payload("Write", file_path=str(self.loop_dir / "state.md"), content="x"))
        self.assertFalse(result.allowed)
        self.assertEqual(result.exit_code, 2)
        self.assertIn("State File Blocked", result.message)

    def test_write_allows_current_round_summary(self) -> None:
        result = validators.validate_write(
            self.payload("Write", file_path=str(self.loop_dir / "round-2-summary.md"), content="summary")
        )
        self.assertTrue(result.allowed)

    def test_write_blocks_wrong_round_summary(self) -> None:
        result = validators.validate_write(
            self.payload("Write", file_path=str(self.loop_dir / "round-1-summary.md"), content="summary")
        )
        self.assertFalse(result.allowed)
        self.assertIn("round-2-summary.md", result.message)

    def test_edit_blocks_goal_tracker_immutable_change(self) -> None:
        result = validators.validate_edit(
            self.payload(
                "Edit",
                file_path=str(self.loop_dir / "goal-tracker.md"),
                old_string="Goal",
                new_string="Different",
            )
        )
        self.assertFalse(result.allowed)
        self.assertIn("immutable", result.message.lower())

    def test_edit_allows_goal_tracker_mutable_change(self) -> None:
        result = validators.validate_edit(
            self.payload(
                "Edit",
                file_path=str(self.loop_dir / "goal-tracker.md"),
                old_string="Current",
                new_string="Updated",
            )
        )
        self.assertTrue(result.allowed)

    def test_bash_blocks_redirection_to_summary(self) -> None:
        result = validators.validate_bash(
            self.payload("Bash", command=f"printf done > {self.loop_dir}/round-2-summary.md")
        )
        self.assertFalse(result.allowed)
        self.assertIn("Summary Bash Write Blocked", result.message)

    def test_bash_blocks_manual_stop_hook_execution(self) -> None:
        result = validators.validate_bash(self.payload("Bash", command="bash hooks/loop-codex-stop-hook.sh"))
        self.assertFalse(result.allowed)
        self.assertIn("Hook Execution Blocked", result.message)

    def test_methodology_phase_restricts_project_reads(self) -> None:
        (self.loop_dir / "state.md").rename(self.loop_dir / "methodology-analysis-state.md")
        project_file = self.root / "README.md"
        project_file.write_text("private", encoding="utf-8")
        result = validators.validate_read(self.payload("Read", file_path=str(project_file)))
        self.assertFalse(result.allowed)
        self.assertIn("Methodology Analysis", result.message)

    def test_wrapper_delegates_to_python_validator(self) -> None:
        script = ROOT / "hooks" / "loop-write-validator.sh"
        input_json = json.dumps(self.payload("Write", file_path=str(self.loop_dir / "state.md"), content="x"))
        result = subprocess.run([str(script)], input=input_json, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 2)
        self.assertIn("State File Blocked", result.stderr)


class TodoCheckerTests(unittest.TestCase):
    def test_latest_todowrite_blocks_incomplete_items(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            transcript = Path(temp_dir) / "transcript.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "name": "TodoWrite",
                                    "input": {
                                        "todos": [
                                            {"status": "completed", "content": "done"},
                                            {"status": "pending", "content": "[blocking] finish validation"},
                                            {"status": "pending", "content": "[queued] later"},
                                        ]
                                    },
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )
            items = TODO_CHECKER.find_incomplete_todos_from_transcript(transcript)
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["lane"], "blocking")

    def test_task_directory_blocks_incomplete_nonqueued_tasks(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            session = Path(temp_dir) / "sid"
            session.mkdir()
            (session / "1.json").write_text(json.dumps({"status": "in_progress", "subject": "[mainline] build"}), encoding="utf-8")
            (session / "2.json").write_text(json.dumps({"status": "pending", "subject": "[queued] later"}), encoding="utf-8")
            (session / "3.json").write_text(json.dumps({"status": "completed", "subject": "done"}), encoding="utf-8")
            items = TODO_CHECKER.find_incomplete_tasks_from_directory("sid", temp_dir)
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["task_id"], "1")

    def test_main_reports_parse_errors(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "hooks" / "check-todos-from-transcript.py")],
            input="not-json",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("PARSE_ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
