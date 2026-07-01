#!/usr/bin/env bash
# Compatibility wrapper for Python methodology analysis helpers.

_LOOP_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

complete_methodology_analysis() {
    python3 "$_LOOP_HOOK_LIB_DIR/methodology_analysis.py" complete "$LOOP_DIR"
}

block_methodology_analysis_incomplete() {
    python3 "$_LOOP_HOOK_LIB_DIR/methodology_analysis.py" block-incomplete "$LOOP_DIR"
}
