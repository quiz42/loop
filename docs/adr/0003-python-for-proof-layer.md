# The Proof layer uses the Python 3.9+ standard library, breaking the repository's pure-Bash convention

Loop's existing code is pure Bash + jq + git, but the Proof layer's Compiler and Validator need canonical JSON serialization, SHA-256 content addressing, and schema validation — implementing those in Bash is both painful and unreliable, and would directly threaten determinism (AC-2) and tamper detection (AC-3). Meanwhile macOS system Bash 3.2 is already a real source of failure (the full test runner cannot even start on it). So `proof export|verify` is implemented with the Python standard library, requiring Python 3.9+, with a version check at the `loop proof` subcommand entry point. Python 3 is a de facto standard on both macOS and Ubuntu CI, which is more realistic than asking users to upgrade Bash.

## Consequences

- Installation docs, the prerequisite dependency check, and the CI matrix each need a Python 3.9+ entry added; the Bash parts still do not depend on Python.
- The standard library has no JSON Schema validator: either hand-write a small validator covering the subset our own schemas use, or vendor a pure-Python implementation — that sub-choice is settled during implementation planning, but it must not introduce an external dependency requiring `pip install`.
