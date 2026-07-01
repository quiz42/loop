from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from hooks.lib import project_root, template_loader
from hooks.lib import loop_bg_tasks, loop_common, methodology_analysis


class ProjectRootTests(unittest.TestCase):
    def test_resolve_project_root_prefers_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "project"
            root.mkdir()
            resolved = project_root.resolve_project_root(env={"CLAUDE_PROJECT_DIR": str(root)})
            self.assertEqual(resolved, root.resolve())

    def test_canonicalize_path_prefix_keeps_leaf_symlink_text(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            parent = Path(temp_dir) / "parent"
            parent.mkdir()
            target = parent / "missing.txt"
            self.assertEqual(
                project_root.canonicalize_path_prefix(target),
                str(parent.resolve(strict=True) / target.name),
            )


class TemplateLoaderTests(unittest.TestCase):
    def test_render_template_is_single_pass(self) -> None:
        rendered = template_loader.render_template(
            "Plan {{PLAN}} keeps {{UNKNOWN}}",
            {"PLAN": "{{UNKNOWN}}"},
        )
        self.assertEqual(rendered, "Plan {{UNKNOWN}} keeps {{UNKNOWN}}")

    def test_load_and_render_safe_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            rendered = template_loader.load_and_render_safe(
                temp_dir,
                "missing.md",
                "Hello {{NAME}}",
                {"NAME": "developer"},
            )
            self.assertEqual(rendered, "Hello developer")

    def test_shell_wrapper_renders_template(self) -> None:
        script = ROOT / "hooks" / "lib" / "template-loader.sh"
        command = f"source {script}; render_template 'Hi {{{{NAME}}}}' NAME=Sam"
        result = subprocess.run(["bash", "-lc", command], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        self.assertEqual(result.stdout, "Hi Sam")


class LoopCommonTests(unittest.TestCase):
    def test_parse_state_file_defaults_and_strict_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state = Path(temp_dir) / "state.md"
            state.write_text(
                "---\ncurrent_round: 3\nmax_iterations: 8\nreview_started: true\nbase_branch: main\nsession_id: abc\n---\nbody\n",
                encoding="utf-8",
            )
            parsed = loop_common.parse_state_file(state, strict=True)
            self.assertEqual(parsed.current_round, 3)
            self.assertEqual(parsed.max_iterations, 8)
            self.assertEqual(parsed.get("privacy_mode"), "true")

    def test_find_active_loop_respects_session_terminal_newest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir)
            older = base / "2026-01-01_00-00-00"
            newer = base / "2026-01-02_00-00-00"
            older.mkdir()
            newer.mkdir()
            older.joinpath("state.md").write_text("---\nsession_id: sid\ncurrent_round: 1\nmax_iterations: 2\n---\n", encoding="utf-8")
            newer.joinpath("complete-state.md").write_text("---\nsession_id: sid\ncurrent_round: 2\nmax_iterations: 2\n---\n", encoding="utf-8")
            self.assertIsNone(loop_common.find_active_loop(base, "sid"))

    def test_goal_tracker_immutable_must_be_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            tracker = Path(temp_dir) / "goal-tracker.md"
            original = "## IMMUTABLE SECTION\nGoal\n---\n## MUTABLE SECTION\nOld\n"
            tracker.write_text(original, encoding="utf-8")
            allowed = "## IMMUTABLE SECTION\nGoal\n---\n## MUTABLE SECTION\nNew\n"
            blocked = "## IMMUTABLE SECTION\nChanged\n---\n## MUTABLE SECTION\nNew\n"
            self.assertTrue(loop_common.goal_tracker_mutable_update_allowed(tracker, allowed))
            self.assertFalse(loop_common.goal_tracker_mutable_update_allowed(tracker, blocked))

    def test_review_verdict_rejects_ambiguous_line(self) -> None:
        content = "Mainline Progress Verdict: ADVANCED or STALLED"
        self.assertEqual(loop_common.extract_mainline_progress_verdict(content), "unknown")


class BackgroundTaskTests(unittest.TestCase):
    def test_extract_transcript_path_expands_tilde(self) -> None:
        payload = json.dumps({"transcript_path": "~/session.jsonl"})
        self.assertEqual(loop_bg_tasks.extract_transcript_path(payload), f"{os.environ.get('HOME', '')}/session.jsonl")

    def test_pending_background_tasks_from_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            transcript = Path(temp_dir) / "session.jsonl"
            events = [
                {"timestamp": "2026-01-01T00:00:00.000Z", "toolUseResult": {"isAsync": True, "agentId": "agent-1"}},
                {"timestamp": "2026-01-01T00:00:01.000Z", "toolUseResult": {"backgroundTaskId": "bash-1"}},
                {"type": "system", "subtype": "task_notification", "task_id": "agent-1"},
            ]
            transcript.write_text("\n".join(json.dumps(event) for event in events), encoding="utf-8")
            self.assertEqual(loop_bg_tasks.list_pending_background_task_ids(transcript, prune_dead=False), ["bash-1"])


class MethodologyAnalysisTests(unittest.TestCase):
    def test_methodology_completion_renames_state_and_removes_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            loop_dir = Path(temp_dir)
            (loop_dir / "methodology-analysis-state.md").write_text("state", encoding="utf-8")
            (loop_dir / "methodology-analysis-done.md").write_text("done", encoding="utf-8")
            (loop_dir / "methodology-analysis-report.md").write_text("report", encoding="utf-8")
            (loop_dir / ".methodology-exit-reason").write_text("complete", encoding="utf-8")
            target = methodology_analysis.complete_methodology_analysis(loop_dir)
            self.assertEqual(target, loop_dir / "complete-state.md")
            self.assertTrue((loop_dir / "complete-state.md").is_file())
            self.assertFalse((loop_dir / ".methodology-exit-reason").exists())


if __name__ == "__main__":
    unittest.main()
