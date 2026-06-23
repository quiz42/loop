#!/usr/bin/env bash
# Render a compact humanize-loop terminal status line.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/statusline.py" "$@"
