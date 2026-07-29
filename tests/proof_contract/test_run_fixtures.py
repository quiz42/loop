"""Contract checks for the committed Proof Run fixture corpus."""

import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_FIXTURES = PROJECT_ROOT / "tests" / "fixtures" / "proof" / "runs"
TERMINAL_STATE_FILENAMES = {
    "complete": "complete-state.md",
    "stop": "stop-state.md",
    "cancel": "cancel-state.md",
    "maxiter": "maxiter-state.md",
    "unexpected": "unexpected-state.md",
}
D17_FIELDS = {
    "reviewed_commit",
    "reviewed_at",
    "reviewed_base",
    "head_commit",
    "ended_at",
}


def read_frontmatter(path):
    """Read Markdown frontmatter while allowing a legacy file-header comment."""
    lines = path.read_text(encoding="utf-8").splitlines()
    start = lines.index("---")
    end = lines.index("---", start + 1)
    return {
        key.strip(): value.strip()
        for line in lines[start + 1 : end]
        if ":" in line
        for key, value in [line.split(":", 1)]
    }


class RunFixtureTests(unittest.TestCase):
    """Golden and derived fixtures retain the Run facts later CLI tests need."""

    def test_real_runs_have_whole_evidence_and_d17_recorder_facts(self):
        real_runs = {
            "clean-complete": "complete",
            "complete-after-rework": "complete",
            "cancel-after-review": "cancel",
        }

        for fixture_name, terminal_state in real_runs.items():
            with self.subTest(fixture=fixture_name):
                run = RUN_FIXTURES / fixture_name
                state_path = run / TERMINAL_STATE_FILENAMES[terminal_state]
                fields = read_frontmatter(state_path)

                self.assertTrue((run / "plan.md").is_file())
                self.assertTrue((run / "goal-tracker.md").is_file())
                self.assertTrue(list(run.glob("round-*-summary.md")))
                self.assertTrue(list(run.glob("round-*-review-result.md")))
                self.assertEqual(
                    {path.name for path in run.glob("*-state.md")},
                    {TERMINAL_STATE_FILENAMES[terminal_state]},
                )
                self.assertTrue(D17_FIELDS.issubset(fields))
                self.assertTrue(all(fields[field] for field in D17_FIELDS))

    def test_rework_run_preserves_the_review_feedback_and_follow_up_round(self):
        run = RUN_FIXTURES / "complete-after-rework"

        self.assertTrue((run / "round-1-prompt.md").is_file())
        self.assertTrue((run / "round-1-summary.md").is_file())
        review_result = (run / "round-1-review-result.md").read_text(encoding="utf-8")
        self.assertIn("[P1]", review_result)
        self.assertIn("[P2]", review_result)

    def test_cancel_run_records_the_explicit_post_review_cancellation(self):
        run = RUN_FIXTURES / "cancel-after-review"

        self.assertTrue((run / ".cancel-requested").is_file())
        self.assertTrue((run / "round-1-review-result.md").is_file())

    def test_derived_runs_complete_the_terminal_state_matrix(self):
        expected = {
            "maxiter-derived": "maxiter",
            "stop-derived": "stop",
            "unexpected-derived": "unexpected",
        }

        for fixture_name, terminal_state in expected.items():
            with self.subTest(fixture=fixture_name):
                run = RUN_FIXTURES / fixture_name
                self.assertEqual(
                    {path.name for path in run.glob("*-state.md")},
                    {TERMINAL_STATE_FILENAMES[terminal_state]},
                )

        maxiter_fields = read_frontmatter(
            RUN_FIXTURES / "maxiter-derived" / "maxiter-state.md"
        )
        self.assertEqual(maxiter_fields["current_round"], maxiter_fields["max_iterations"])
        self.assertEqual(maxiter_fields["mainline_stall_count"], "0")
        self.assertEqual(maxiter_fields["last_mainline_verdict"], "unknown")

        stop_fields = read_frontmatter(
            RUN_FIXTURES / "stop-derived" / "stop-state.md"
        )
        self.assertEqual(stop_fields["mainline_stall_count"], "3")
        self.assertEqual(stop_fields["last_mainline_verdict"], "stalled")
        self.assertEqual(stop_fields["drift_status"], "replan_required")

    def test_legacy_run_names_its_recorder_gap_and_removes_all_d17_fields(self):
        state_path = RUN_FIXTURES / "legacy-pre-d17" / "complete-state.md"
        contents = state_path.read_text(encoding="utf-8")

        self.assertTrue(
            contents.startswith("<!-- Simulates the pre-D17 Run Recorder version gap:")
        )
        self.assertFalse(D17_FIELDS.intersection(read_frontmatter(state_path)))


if __name__ == "__main__":
    unittest.main()
