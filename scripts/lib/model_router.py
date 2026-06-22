#!/usr/bin/env python3
"""Model routing helpers for humanize-loop."""

from __future__ import annotations

import argparse
import shutil
import sys
from typing import Literal

Provider = Literal["codex", "claude"]
_ALLOWED_EFFORTS = {"xhigh", "high", "medium", "low"}


class ModelRoutingError(ValueError):
    """Raised when a model or provider cannot be routed."""


def detect_provider(model_name: str) -> Provider:
    name = model_name.strip()
    lower_name = name.lower()
    if not name:
        raise ModelRoutingError("Model name must be non-empty.")
    if lower_name.startswith("gpt-") or (
        lower_name.startswith("o") and len(lower_name) > 1 and lower_name[1].isdigit()
    ):
        return "codex"
    if (
        lower_name.startswith("claude-")
        or "haiku" in lower_name
        or "sonnet" in lower_name
        or "opus" in lower_name
    ):
        return "claude"
    raise ModelRoutingError(
        f"Unknown model name '{model_name}'. Expected gpt-*/o[N]-* or Claude family names."
    )


def check_provider_dependency(provider: str) -> bool:
    if provider not in {"codex", "claude"}:
        raise ModelRoutingError(f"Unknown provider '{provider}'. Expected 'codex' or 'claude'.")
    if shutil.which(provider):
        return True
    raise ModelRoutingError(
        f"Required binary '{provider}' was not found in PATH for provider '{provider}'."
    )


def map_effort(effort: str, target_provider: str) -> str:
    if target_provider not in {"codex", "claude"}:
        raise ModelRoutingError(
            f"Unknown target provider '{target_provider}'. Expected 'codex' or 'claude'."
        )
    if effort not in _ALLOWED_EFFORTS:
        raise ModelRoutingError(
            f"Unknown effort '{effort}'. Expected one of: xhigh, high, medium, low."
        )
    if target_provider == "claude" and effort == "xhigh":
        return "high"
    return effort


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Route models to supported providers.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    detect_parser = subparsers.add_parser("detect-provider")
    detect_parser.add_argument("model_name")

    dependency_parser = subparsers.add_parser("check-provider-dependency")
    dependency_parser.add_argument("provider")

    effort_parser = subparsers.add_parser("map-effort")
    effort_parser.add_argument("effort")
    effort_parser.add_argument("target_provider")

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        if args.command == "detect-provider":
            print(detect_provider(args.model_name))
        elif args.command == "check-provider-dependency":
            check_provider_dependency(args.provider)
        elif args.command == "map-effort":
            print(map_effort(args.effort, args.target_provider))
    except ModelRoutingError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
