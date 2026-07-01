#!/usr/bin/env python3
"""Cross-platform timeout runner for loop."""

from __future__ import annotations

import argparse
import subprocess
import sys

TIMEOUT_EXIT_CODE = 124


def run_with_timeout(timeout_seconds: float, command: list[str]) -> int:
    """Run a command and return 124 when it exceeds the timeout."""
    if timeout_seconds <= 0:
        raise ValueError("Timeout must be greater than zero.")
    if not command:
        raise ValueError("Command must be non-empty.")
    try:
        completed = subprocess.run(command, timeout=timeout_seconds)
        return completed.returncode
    except subprocess.TimeoutExpired:
        return TIMEOUT_EXIT_CODE


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a command with a portable timeout.")
    parser.add_argument("timeout", type=float, help="Timeout in seconds.")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Command and arguments to run.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    try:
        return run_with_timeout(args.timeout, command)
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
