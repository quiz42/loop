---
name: loop-refine-plan
description: Refine and iterate on a plan using RLCR loop feedback
---

# Loop Refine-Plan

Refine an existing implementation plan by incorporating feedback from the RLCR loop, Codex review, or manual review. This is not a standalone CLI command — it is a workflow practice of editing the plan file and re-running the loop with the updated plan.

## Concept

The RLCR loop evaluates a plan file each iteration. When a round produces feedback indicating the plan needs adjustment — scope changes, missing steps, incorrect assumptions — you refine the plan file and continue the loop. Refinement is the human-in-the-loop step of the RLCR workflow.

## Workflow

1. Start or run the RLCR loop: `python3 scripts/loop.py start-rlcr-loop plan.md`
2. Review the loop output or monitor: `python3 scripts/loop.py monitor rlcr`
3. Cancel the loop if a plan-level change is needed: `python3 scripts/loop.py cancel-rlcr-loop --reason "Plan needs restructuring"`
4. Edit `plan.md` to address the feedback.
5. Re-run the loop with the refined plan.

## Plan Editing Guidelines

- Keep tasks atomic: each step should be independently verifiable.
- Add acceptance criteria to ambiguous tasks so Codex review has a clear target.
- Remove or reorder steps that caused repeated loop failures.
- Use `ask-codex` or `ask-gemini` to get targeted suggestions before editing:
  ```
  python3 scripts/ask_tool.py codex "Given this loop failure, how should I restructure the plan?"
  ```

## Iteration Strategy

| Situation | Action |
|---|---|
| Minor wording or scope issue | Edit plan in place, re-run loop |
| Structural issue across multiple steps | Cancel loop, reorganize plan, restart |
| Unclear requirements | Use `ask-gemini` to clarify before editing |
| Repeated Codex review failures on same step | Break the step into smaller sub-tasks |

## Notes

- The plan file passed to `start-rlcr-loop` is the source of truth for each run.
- Use `--track-plan-file` when starting the loop to have changes to the plan file reflected across iterations automatically.
- Frequent small refinements outperform large rewrites; change one thing at a time and observe the effect.
