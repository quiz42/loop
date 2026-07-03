#!/usr/bin/env python3
"""Configuration loading helpers for loop."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping


class ConfigError(ValueError):
    """Raised when a required configuration layer is missing or invalid."""


def _strip_nulls(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _strip_nulls(item)
            for key, item in value.items()
            if item is not None
        }
    if isinstance(value, list):
        return [_strip_nulls(item) for item in value if item is not None]
    return value


def _deep_merge(base: Mapping[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if (
            key in merged
            and isinstance(merged[key], dict)
            and isinstance(value, dict)
        ):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def _read_layer(path: Path, label: str, required: bool) -> dict[str, Any]:
    if not path.exists():
        if required:
            raise ConfigError(f"Missing required {label}: {path}")
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        if required:
            raise ConfigError(f"Malformed required {label}: {path}") from exc
        print(f"Warning: Ignoring malformed {label}: {path}", file=sys.stderr)
        return {}
    if not isinstance(data, dict):
        if required:
            raise ConfigError(f"Malformed required {label} (must be a JSON object): {path}")
        print(
            f"Warning: Ignoring malformed {label} (must be a JSON object): {path}",
            file=sys.stderr,
        )
        return {}
    return _strip_nulls(data)


def user_config_path(env: Mapping[str, str] | None = None) -> Path:
    values = os.environ if env is None else env
    if values.get("XDG_CONFIG_HOME"):
        return Path(values["XDG_CONFIG_HOME"]) / "loop" / "config.json"
    return Path(values.get("HOME", "")) / ".config" / "loop" / "config.json"


def project_config_path(project_root: str | Path, env: Mapping[str, str] | None = None) -> Path:
    values = os.environ if env is None else env
    if values.get("LOOP_CONFIG"):
        return Path(values["LOOP_CONFIG"])
    return Path(project_root) / ".loop" / "config.json"


def load_merged_config(
    plugin_root: str | Path,
    project_root: str | Path,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    plugin_root_path = Path(plugin_root)
    project_root_path = Path(project_root)
    layers = [
        _read_layer(
            plugin_root_path / "config" / "default_config.json",
            "default config",
            required=True,
        ),
        _read_layer(user_config_path(env), "user config", required=False),
        _read_layer(project_config_path(project_root_path, env), "project config", required=False),
    ]
    merged: dict[str, Any] = {}
    for layer in layers:
        merged = _deep_merge(merged, layer)
    return merged


def get_config_value(config: Mapping[str, Any], key: str) -> str:
    if not key:
        raise ConfigError("Configuration key must be non-empty.")
    if key not in config or config[key] is None:
        return ""
    value = config[key]
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value, separators=(",", ":")) if isinstance(value, (dict, list)) else str(value)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load loop configuration.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    load_parser = subparsers.add_parser("load", help="Print merged configuration JSON.")
    load_parser.add_argument("plugin_root")
    load_parser.add_argument("project_root")

    value_parser = subparsers.add_parser("get", help="Print one value from JSON on stdin.")
    value_parser.add_argument("key")

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        if args.command == "load":
            config = load_merged_config(args.plugin_root, args.project_root)
            print(json.dumps(config, indent=2, sort_keys=True))
        elif args.command == "get":
            config = json.load(sys.stdin)
            if not isinstance(config, dict):
                raise ConfigError("Input configuration must be a JSON object.")
            print(get_config_value(config, args.key))
    except (ConfigError, OSError, json.JSONDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
