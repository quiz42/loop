#!/usr/bin/env python3
"""Verify a Proof Bundle using the repository's offline validator."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

EXIT_USAGE = 1


class _ArgumentParser(argparse.ArgumentParser):
    """Make argparse usage errors use the documented environment code (1)."""

    def error(self, message: str) -> None:  # pragma: no cover - argparse edge
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        prog="loop proof verify",
        description="Verify a Proof Bundle offline.",
    )
    parser.add_argument("bundle", metavar="BUNDLE_DIR_OR_PROOF_JSON")
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the machine-readable validation report",
    )
    return parser


def _print_human(report: object) -> None:
    status = getattr(report, "status", "invalid")
    print(f"status: {status}")
    reasons = getattr(report, "reasons", []) or []
    warnings = getattr(report, "warnings", []) or []
    for problem in reasons:
        reason = problem.get("reason", "unknown")
        target = problem.get("target", "")
        detail = problem.get("detail", "")
        suffix = f": {detail}" if detail else ""
        print(f"{reason}: {target}{suffix}")
    for warning in warnings:
        reason = warning.get("reason") or "schema-warning"
        target = warning.get("target", "")
        detail = warning.get("detail", "")
        suffix = f": {detail}" if detail else ""
        print(f"warning {reason}: {target}{suffix}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    if sys.version_info < (3, 9):
        print(
            "Error: loop proof verify requires Python 3.9 or newer. "
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
        from proof.validator import validate_bundle

        report = validate_bundle(Path(args.bundle).expanduser())
    except Exception as error:  # validator should be offline and traceback-free
        if args.json:
            print(
                json.dumps(
                    {
                        "status": "invalid",
                        "reasons": [
                            {
                                "reason": "environment-error",
                                "target": args.bundle,
                                "detail": str(error),
                            }
                        ],
                        "warnings": [],
                    },
                    ensure_ascii=False,
                    sort_keys=True,
                )
            )
        else:
            print(f"Error: {error}", file=sys.stderr)
        return EXIT_USAGE

    if args.json:
        print(json.dumps(report.as_dict(), ensure_ascii=False, sort_keys=True))
    else:
        _print_human(report)
    return report.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
