#!/usr/bin/env bash
#
# Deterministic project-root resolver for all loop hooks and scripts.
#
# Resolution priority:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code, stable across `cd` within a session)
#   2. git rev-parse --show-toplevel (nearest enclosing repo)
#   3. Non-zero return.
#
# pwd is intentionally NOT used as a fallback: it drifts with `cd`
# invocations during a session and silently causes state.md lookups
# under .loop/rlcr/ to miss the active loop directory.
#
# The resolved path is passed through realpath so symlinked prefixes
# (e.g. /Users/x vs /private/Users/x on macOS, or /var vs /private/var)
# do not diverge between setup-time and hook-time resolution.
#
# Path-comparison sites in validators must mirror this by canonicalizing
# the user-provided side as well; use the companion `canonicalize_path`
# helper below.
#

if [[ -n "${_LOOP_PROJECT_ROOT_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_LOOP_PROJECT_ROOT_SOURCED=1

# resolve_project_root
#
# Prints the resolved project root to stdout. Returns 0 on success,
# 1 when neither CLAUDE_PROJECT_DIR nor a git toplevel is available.
#
# Callers that must have a project root should handle the failure:
#
#   PROJECT_ROOT="$(resolve_project_root)" || exit 0   # hook: allow natural stop
#   PROJECT_ROOT="$(resolve_project_root)" || {        # setup: hard error
#       echo "Error: cannot determine loop project root" >&2
#       exit 1
#   }
#
resolve_project_root() {
    local root="${CLAUDE_PROJECT_DIR:-}"
    if [[ -z "$root" ]]; then
        root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -z "$root" ]]; then
        return 1
    fi

    local canonical
    canonical=$(canonicalize_path "$root")
    printf '%s\n' "${canonical:-$root}"
}

# _portable_resolved_dir
#
# Prints the fully symlink-resolved path of an existing directory, using
# shell builtins alone. `cd -P` resolves every component including the
# leaf, so this matches `realpath` for directories on hosts where realpath
# is not installed. Returns 1 when the argument is not a directory or the
# cd fails, so callers can chain it after their realpath attempt.
#
# CDPATH is cleared because a `cd` that consults it prints the resolved
# directory on stdout and may land somewhere else entirely.
#
_portable_resolved_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    ( CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P ) || return 1
}

# portable_abs_path
#
# Prints the absolute, symlink-resolved form of a path whose trailing
# components need not exist yet -- what GNU `realpath -m` does. BSD realpath
# has no -m and fails outright on a missing component, so callers that used
# `realpath -m ... || echo "$input"` silently reported the raw, often
# relative, input on macOS while reporting an absolute path on Linux.
#
# Method: an existing path is handed to the system resolver so the result is
# byte-identical to what `realpath -m` returns today on Linux. Otherwise the
# longest existing prefix is resolved and the not-yet-existing tail is
# reattached with `.` and `..` folded away lexically -- which is also how
# realpath -m treats a tail it cannot stat.
#
# Two deliberate differences from `realpath -m`, both of which behave the same
# way on Linux and macOS -- which is the property callers here need:
#
#   * A dangling symlink inside the path is left as written rather than
#     followed to its missing target: `cd -P` cannot enter it, and chasing it
#     by hand would mean a readlink loop with cycle detection for a path that
#     fails the caller's directory check either way.
#   * On a host with no usable realpath at all, a leaf that is a symlink to a
#     file stays unresolved, since `cd -P` only resolves directories. Every
#     platform Loop's CI targets ships realpath (macOS 13+, coreutils Linux),
#     so this is the fallback's fallback.
#
# Empty input prints nothing and returns 0.
#
# Usage: abs=$(portable_abs_path "$maybe_relative_and_missing")
portable_abs_path() {
    # Not named `path`: zsh ties that name to the PATH array, so `local path=`
    # replaces PATH for the body of the function and every external command
    # the function runs stops resolving. project-root.sh is sourced by
    # scripts/loop.sh, which zsh users source.
    local target_path="$1"
    if [[ -z "$target_path" ]]; then
        return 0
    fi

    local resolved=""
    if resolved=$(realpath "$target_path" 2>/dev/null) && [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    case "$target_path" in
        /*) ;;
        *) target_path="$(pwd -P)/$target_path" ;;
    esac

    # Peel components off the right until an existing directory remains --
    # `cd -P` is the builtin-only resolver and it only accepts directories, so
    # an existing file's own name belongs in the tail alongside the components
    # that do not exist yet.
    local head="$target_path" tail=""
    while [[ ! -d "$head" && "$head" != "/" ]]; do
        tail="${head##*/}${tail:+/}${tail}"
        head="${head%/*}"
        if [[ -z "$head" ]]; then
            head="/"
        fi
    done

    local head_real=""
    if ! { head_real=$(realpath "$head" 2>/dev/null) && [[ -n "$head_real" ]]; }; then
        head_real=$(_portable_resolved_dir "$head") || head_real=""
    fi
    if [[ -z "$head_real" ]]; then
        head_real="$head"
    fi

    # Fold "." and ".." out of the tail. ".." past the start of the tail walks
    # up out of the resolved prefix instead.
    local folded="" rest="$tail" component
    while [[ -n "$rest" ]]; do
        component="${rest%%/*}"
        if [[ "$component" == "$rest" ]]; then
            rest=""
        else
            rest="${rest#*/}"
        fi
        case "$component" in
            '' | '.')
                ;;
            '..')
                if [[ -n "$folded" ]]; then
                    if [[ "$folded" == */* ]]; then
                        folded="${folded%/*}"
                    else
                        folded=""
                    fi
                else
                    head_real="${head_real%/*}"
                    if [[ -z "$head_real" ]]; then
                        head_real="/"
                    fi
                fi
                ;;
            *)
                folded="${folded:+$folded/}$component"
                ;;
        esac
    done

    if [[ -z "$folded" ]]; then
        printf '%s\n' "$head_real"
    else
        printf '%s/%s\n' "${head_real%/}" "$folded"
    fi
}

# canonicalize_path_prefix
#
# Resolves symlinks ONLY in the parent directory and reattaches the
# original basename verbatim. This is the right helper for comparing
# user-supplied filenames against an expected path inside a known
# directory: a symlink at /tmp/alias pointing at /real/loop/state.md
# MUST NOT canonicalize to /real/loop/state.md for comparison purposes,
# because `mv` operates on the link path itself. Resolving only the
# parent still lets a symlinked project prefix (e.g. /var vs /private/var
# on macOS) match a canonical expected path.
#
# If realpath on the parent fails, falls back to returning the input
# path unchanged (prefix cannot be canonicalized -> caller's comparison
# will correctly fail against a canonical expected path).
#
# Empty input prints nothing and returns 0.
#
canonicalize_path_prefix() {
    # See portable_abs_path for why this is not called `path`.
    local target_path="$1"
    if [[ -z "$target_path" ]]; then
        return 0
    fi

    local parent base parent_real
    parent=$(dirname -- "$target_path")
    base=$(basename -- "$target_path")

    if parent_real=$(realpath "$parent" 2>/dev/null) && [[ -n "$parent_real" ]]; then
        printf '%s/%s\n' "${parent_real%/}" "$base"
        return 0
    fi

    # No realpath on this host: `cd -P` resolves the parent with builtins
    # alone. This replaced a python3 -c os.path.realpath fallback, which put
    # a Python dependency in the hook layer that ADR-0003 reserves for the
    # Proof layer.
    if parent_real=$(_portable_resolved_dir "$parent") && [[ -n "$parent_real" ]]; then
        printf '%s/%s\n' "${parent_real%/}" "$base"
        return 0
    fi

    printf '%s\n' "$target_path"
}

# canonicalize_path
#
# Prints the realpath of the input path. If the path itself does not
# exist yet (common for write validation before the file is created),
# canonicalizes the parent directory and reattaches the basename.
# If realpath is unavailable, `cd -P` resolves the directory instead; if
# neither can resolve it, prints the input path verbatim. Note that on a
# host with no realpath a leaf that is itself a symlink to a file is left
# unresolved, because `cd -P` can only resolve directories.
#
# SECURITY NOTE: This helper dereferences symlinks at the leaf when
# the leaf exists. Do NOT use it to authorize a user-supplied path
# against an expected filename -- use canonicalize_path_prefix instead,
# which only resolves the parent.
#
# Empty input prints nothing and returns 0.
#
canonicalize_path() {
    # See portable_abs_path for why this is not called `path`.
    local target_path="$1"
    if [[ -z "$target_path" ]]; then
        return 0
    fi

    local canonical=""

    if canonical=$(realpath "$target_path" 2>/dev/null) && [[ -n "$canonical" ]]; then
        printf '%s\n' "$canonical"
        return 0
    fi
    if canonical=$(_portable_resolved_dir "$target_path") && [[ -n "$canonical" ]]; then
        printf '%s\n' "$canonical"
        return 0
    fi

    # Path does not exist: canonicalize parent, reattach basename.
    local parent base
    parent=$(dirname -- "$target_path")
    base=$(basename -- "$target_path")
    if canonical=$(realpath "$parent" 2>/dev/null) && [[ -n "$canonical" ]]; then
        printf '%s/%s\n' "${canonical%/}" "$base"
        return 0
    fi

    # Builtin-only fallback, replacing a python3 -c os.path.realpath call:
    # ADR-0003 keeps the hook layer independent of Python.
    if canonical=$(_portable_resolved_dir "$parent") && [[ -n "$canonical" ]]; then
        printf '%s/%s\n' "${canonical%/}" "$base"
        return 0
    fi

    printf '%s\n' "$target_path"
}
