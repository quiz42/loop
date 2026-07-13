"""Tests for monitor dashboard utilities."""

from __future__ import annotations

import importlib.util
import json
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


monitor_common = load_module("monitor_common", "scripts/lib/monitor_common.py")
monitor_skill = load_module("monitor_skill", "scripts/lib/monitor_skill.py")
statusline = load_module("statusline", "scripts/statusline.py")
portable_timeout = load_module("portable_timeout", "scripts/portable_timeout.py")


class TestMonitorCommon(unittest.TestCase):
    def test_latest_session_and_state_file_detection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            older = root / "2026-06-22_10-00-00"
            newer = root / "2026-06-22_11-00-00-extra"
            ignored = root / "notes"
            older.mkdir()
            newer.mkdir()
            ignored.mkdir()
            (newer / "completed-state.md").write_text("done", encoding="utf-8")

            self.assertEqual(monitor_common.find_latest_session(root), newer)
            state_file, state = monitor_common.find_state_file(newer)

            self.assertEqual(state_file, newer / "completed-state.md")
            self.assertEqual(state, "completed")

    def test_frontmatter_timestamp_truncate_and_goal_tracker(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "metadata.md"
            path.write_text('---\nstatus: "success"\nmodel: gpt-5.5\n---\nBody\n', encoding="utf-8")
            self.assertEqual(monitor_common.yaml_value("status", path), "success")
            self.assertEqual(monitor_common.format_timestamp("2026-01-18T10:00:00Z"), "2026-01-18 10:00:00 UTC")
            self.assertEqual(monitor_common.truncate_string("abcdef", 5), "ab...")
            self.assertEqual(monitor_common.truncate_string("abcdef", 5, "start"), "...ef")

            tracker = Path(temp) / "goal-tracker.md"
            tracker.write_text(
                "### Ultimate Goal\nShip the monitor dashboard\n"
                "### Acceptance Criteria\n| ID | Text |\n| - | - |\n| AC-1 | Works |\n"
                "#### Active Tasks\n| Task | Owner | Status |\n| - | - | - |\n| Build | Dev | active |\n| Done | Dev | completed |\n"
                "### Completed and Verified\n| AC | Task |\n| - | - |\n| AC-1 | Build |\n"
                "### Explicitly Deferred\n| Task | Reason |\n| - | - |\n| Later | Scope |\n"
                "### Blocking Side Issues\n| ID | Text |\n| - | - |\n| B1 | Blocked |\n",
                encoding="utf-8",
            )
            self.assertEqual(monitor_common.parse_goal_tracker_issue_counts(tracker), (1, 0, 1))
            self.assertEqual(monitor_common.parse_goal_tracker(tracker), (1, 1, 1, 1, 1, 1, "Ship the monitor dashboard"))

    def test_latest_session_falls_back_when_newest_directory_is_deleted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            older = root / "2026-06-22_10-00-00"
            newer = root / "2026-06-22_11-00-00"
            older.mkdir()
            newer.mkdir()
            (older / "state.md").write_text("status: active\n", encoding="utf-8")
            (newer / "state.md").write_text("status: active\n", encoding="utf-8")

            self.assertEqual(monitor_common.find_latest_session(root), newer)
            for child in newer.iterdir():
                child.unlink()
            newer.rmdir()

            self.assertEqual(monitor_common.find_latest_session(root), older)


class TestMonitorSkill(unittest.TestCase):
    def test_skill_stats_best_file_and_once_rendering(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            skill_dir = root / ".loop" / "skill"
            first = skill_dir / "2026-06-22_10-00-00"
            second = skill_dir / "2026-06-22_11-00-00"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            first.joinpath("input.md").write_text("- Tool: codex\n- Model: gpt-5.5\n- Effort: high\n\n## Question\nHow should this work?\n", encoding="utf-8")
            first.joinpath("output.md").write_text("Use a monitor.\n", encoding="utf-8")
            first.joinpath("metadata.md").write_text("---\ntool: codex\nstatus: success\nmodel: gpt-5.5\neffort: high\nduration: 3s\nstarted_at: 2026-06-22T10:00:00Z\n---\n", encoding="utf-8")
            second.joinpath("input.md").write_text("- Tool: gemini\n- Model: gemini-pro\n\n## Question\nWhat is running?\n", encoding="utf-8")
            second.joinpath("cache").mkdir()
            second.joinpath("cache/gemini-run.log").write_text("still running\n", encoding="utf-8")

            self.assertEqual(monitor_skill.count_stats(skill_dir)["total"], 2)
            self.assertEqual(monitor_skill.count_stats(skill_dir)["success"], 1)
            self.assertEqual(monitor_skill.count_stats(skill_dir)["running"], 1)
            self.assertEqual(monitor_skill.count_stats(skill_dir, "codex")["total"], 1)
            best = monitor_skill.best_invocation(skill_dir, project_root=root)
            self.assertEqual(best.path, second)
            self.assertEqual(best.monitored_file, second / "cache/gemini-run.log")
            rendered = monitor_skill.render_once(skill_dir, project_root=root)
            self.assertIn("Loop Skill Monitor", rendered)
            self.assertIn("still running", rendered)

    def test_shell_wrapper_outputs_once_dashboard(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            invocation = root / ".loop" / "skill" / "2026-06-22_10-00-00"
            invocation.mkdir(parents=True)
            invocation.joinpath("input.md").write_text("- Tool: codex\n\n## Question\nHello?\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", "scripts/lib/monitor-skill.sh", "--once", "--skill-dir", str(root / ".loop" / "skill"), "--project-root", str(root)],
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("Total Invocations: 1", result.stdout)
            self.assertIn("Hello?", result.stdout)


class TestStatuslineAndTimeout(unittest.TestCase):
    def test_statusline_renders_json_context_and_truncates(self):
        payload = json.dumps({"cwd": str(PROJECT_ROOT), "CODEX_MODEL": "gpt-5.5", "LOOP_STATUS": "active"})
        line = statusline.render_from_json(payload, width=24)
        self.assertLessEqual(len(line), 24)
        self.assertIn("...", line)

    def test_portable_timeout_success_and_timeout_exit_codes(self):
        success = portable_timeout.run_with_timeout(2, ["python3", "-c", "print('ok')"])
        timed_out = portable_timeout.run_with_timeout(0.1, ["python3", "-c", "import time; time.sleep(1)"])
        self.assertEqual(success, 0)
        self.assertEqual(timed_out, 124)

    def test_shell_wrappers_are_executable_via_bash(self):
        timeout_result = subprocess.run(
            ["bash", "scripts/portable-timeout.sh", "2", "python3", "-c", "print('ok')"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        status_result = subprocess.run(
            ["bash", "scripts/statusline.sh", "--cwd", str(PROJECT_ROOT), "--width", "120"],
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertIn("ok", timeout_result.stdout)
        self.assertIn("loop", status_result.stdout)
        self.assertIn("model unset", status_result.stdout)


if __name__ == "__main__":
    unittest.main()
