#!/usr/bin/env python3
"""Export a terminal Loop Run as an offline Proof Bundle.

This is intentionally a small command-line adapter around :mod:`proof.core`.
Keeping path discovery and presentation here means the compiler remains useful
to embedders while ``loop proof export`` works when ``scripts/loop.sh`` was
sourced from a different current working directory.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Optional, Sequence


# ``python scripts/proof-export.py`` puts ``scripts/`` (rather than the
# checkout root) on sys.path.  Bootstrap the repository package explicitly so
# the command is independent of the caller's working directory.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


EXIT_USAGE = 1
EXIT_ACTIVE_RUN = 2
EXIT_SECRET_SCAN = 3
EXIT_UNREADABLE_RUN = 4


class _ArgumentParser(argparse.ArgumentParser):
    """Make argparse usage errors use Proof's documented exit code (1)."""

    def error(self, message: str) -> None:  # pragma: no cover - argparse edge
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        prog="loop proof export",
        description="Export a terminal Loop Run as a Proof Bundle.",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--latest",
        action="store_true",
        help="export the newest Run with a terminal state",
    )
    source.add_argument(
        "--run",
        metavar="DIR",
        help="export the terminal Run at DIR",
    )
    parser.add_argument(
        "--profile",
        default="local-v0",
        metavar="NAME",
        help="verification profile (default: local-v0)",
    )
    parser.add_argument(
        "--out",
        dest="output",
        metavar="DIR",
        help="bundle output directory (default: .loop/proofs/<proof-id>/)",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    if sys.version_info < (3, 9):
        print(
            "Error: loop proof export requires Python 3.9 or newer. "
            "Install Python 3.9+ and ensure python3 is on PATH.",
            file=sys.stderr,
        )
        return EXIT_USAGE

    parser = _parser()
    try:
        args = parser.parse_args(argv)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        parser.print_usage(sys.stderr)
        return EXIT_USAGE

    try:
        from proof.adapter import ActiveRunError, RunUnreadableError
        from proof.compiler import SecretScanError, export_run, find_latest_terminal_run
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        return EXIT_USAGE

    project_root = Path.cwd().resolve()
    try:
        run_dir = (
            find_latest_terminal_run(project_root / ".loop" / "rlcr")
            if args.latest
            else Path(args.run).expanduser().resolve()
        )
        result = export_run(
            run_dir,
            output_dir=args.output,
            profile=args.profile,
            repo_root=project_root,
        )
    except ActiveRunError as error:
        print(f"Error: {error}", file=sys.stderr)
        return EXIT_ACTIVE_RUN
    except SecretScanError as error:
        print(f"Error: {error}", file=sys.stderr)
        return EXIT_SECRET_SCAN
    except RunUnreadableError as error:
        print(f"Error: {error}", file=sys.stderr)
        return EXIT_UNREADABLE_RUN
    except Exception as error:  # keep environment/write failures traceback-free
        print(f"Error: {error}", file=sys.stderr)
        return EXIT_USAGE

    # Keep the human output stable and useful in scripts without making export
    # itself a second JSON protocol.
    print(f"Exported Proof Bundle: {result.bundle_dir}")
    print(f"proof_id: {result.proof_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
