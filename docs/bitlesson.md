# Bitter Lesson Workflow

The Bitter Lesson workflow tracks small, concrete lessons learned during iterative development. It is named after Richard Sutton's essay arguing that general methods beat hand-crafted ones over time. The workflow encourages you to record surprises and failures so they inform the next iteration rather than being forgotten.

## Files

| Path | Description |
|------|-------------|
| `.humanize/bitlesson/lessons.md` | The running log of lesson entries |
| `.humanize/bitlesson/state.json` | Workflow state (current lesson index, last validated delta) |
| `templates/bitlesson.md` | Blank template to start a new log |

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/bitlesson-init.sh` | Creates the `.humanize/bitlesson/` directory and initial files |
| `scripts/bitlesson-select.sh` | Interactively selects or filters a lesson from the log |
| `scripts/bitlesson-validate-delta.sh` | Validates that new entries conform to the expected format |

## Python API

`bitlesson.py` exposes three functions:

```python
from bitlesson import init_workflow, select_lesson, validate_delta
```

### init_workflow(root)

Initializes the Bitter Lesson workflow at `root`. Creates `.humanize/bitlesson/lessons.md` from `templates/bitlesson.md` and writes an empty `state.json`.

```python
init_workflow("/path/to/project")
```

### select_lesson(root, query=None)

Returns a lesson entry from the log. If `query` is provided, performs a fuzzy search and returns the best match. If `query` is `None`, returns the most recent entry.

```python
lesson = select_lesson("/path/to/project", query="dependency injection")
print(lesson)
```

### validate_delta(root, delta)

Validates `delta` (a string containing one or more new lesson entries) against the expected format. Returns `True` if valid, raises `ValueError` with a descriptive message if not.

```python
validate_delta("/path/to/project", new_entries_text)
```

## Getting started

### 1. Initialize the workflow

```bash
bash scripts/bitlesson-init.sh
```

This creates `.humanize/bitlesson/lessons.md` and `.humanize/bitlesson/state.json` in your current directory.

### 2. Add your first lesson

Open `.humanize/bitlesson/lessons.md` and add an entry under `## Entries`:

```
### 2026-06-25: Mocking external HTTP calls in tests

**What happened:** Tests hit the live API and failed in CI due to missing credentials.
**Why:** No mock was set up for the HTTP client.
**Lesson:** Always patch external HTTP clients in unit tests using unittest.mock.
```

### 3. Validate new entries

Before committing, run:

```bash
bash scripts/bitlesson-validate-delta.sh
```

The script reads new entries since the last validated state and reports any format errors.

### 4. Select a relevant lesson before starting a loop

Before running `/start-rlcr-loop`, retrieve a relevant past lesson to keep context in mind:

```bash
bash scripts/bitlesson-select.sh "async error handling"
```

Or from Python:

```python
lesson = select_lesson(".", query="async error handling")
```

## Entry format

Each entry must follow this structure exactly for `validate_delta` to pass:

```
### YYYY-MM-DD: Short title

**What happened:** ...
**Why:** ...
**Lesson:** ...
```

- The date must be in `YYYY-MM-DD` format.
- All three fields (`What happened`, `Why`, `Lesson`) are required.
- Entries are separated by a blank line.

## Integration with the RLCR loop

When `bitlesson_model` is set in `config/default_config.json`, the loop automatically summarizes the Bitter Lesson log at the start of each iteration and injects the most relevant lesson into the review prompt. This helps Codex (or Kimi) avoid known pitfalls from earlier iterations.

To disable this behavior, set `bitlesson_model` to `null` in the config.
