#!/usr/bin/env bash
#
# shell-timeout.sh - wall-clock timeout using only shell builtins.
#
# Sourced by scripts/portable-timeout.sh (as the last link of its
# gtimeout -> timeout -> shell chain) and by tests/portable-helpers.sh (which
# exposes it as portable_run_with_timeout). One implementation, because a
# timeout primitive that has to get process groups and signal ordering right
# is the last thing that should exist twice.
#
# GNU coreutils `timeout` is not on the macOS runner image and macOS has
# shipped no system python3 since 12.3, so a chain that ends in Python either
# reaches for a dependency ADR-0003 reserves for the Proof layer or gives up
# and runs the command unbounded.
#
# WHAT IS GUARANTEED
#
#   * The function always returns within the limit plus one second (the
#     granularity of the SECONDS builtin the wait loop measures with) plus
#     LOOP_PORTABLE_KILL_GRACE_MS, with status 124 on expiry, and never returns
#     early. This holds no matter what the command spawns, because the wait loop
#     and the kill are the function's own; TERM alone would not, since it can be
#     trapped or ignored, so KILL follows the grace period.
#
#   * A command that traps TERM gets the full grace period to run its handler
#     before KILL arrives, matching GNU timeout.
#
#   * The exit status is the command's own, or 124 on expiry, regardless of the
#     caller's `set -e` (the wrapper runs with errexit off; see `set +e` below).
#
#   * At expiry the command, its process group, and every descendant that exists
#     at that moment are signalled. `set -m` puts the command in its own group so
#     `kill -- -PID` catches later arrivals into that group; the pre-signal
#     descendant walk catches descendants that already left the group (a child
#     that ran its own `set -m`). Signalling only the group left such a child
#     alive.
#
# WHAT IS NOT GUARANTEED, and why a stronger promise is not possible in shell
#
#   * A process that leaves the tracked tree *after* the snapshot cannot be
#     reached. Two ways to do that: a TERM handler that starts its own process
#     group (`trap 'set -m; sleep & wait' TERM`), or a double-fork / setsid
#     daemon. In both cases the group leader dies to the signal and the survivor
#     is reparented to init, so no parent link remains for `pgrep -P` to follow --
#     re-snapshotting after the grace period does not help, as the anchor is
#     already gone. GNU timeout has the same limitation; closing it needs cgroups
#     or job objects, not a shell, which is tracked separately as production
#     descendant supervision (issue #20's handoff note).
#
#   * The consequence is scoped to output liveness: if such an escapee inherited
#     the caller's stdout and that stdout is a pipe, the pipe stays open until the
#     escapee exits, even though the function itself already returned 124. This
#     covers both a command substitution `out=$(shell_run_with_timeout ...)`
#     and a pipeline `shell_run_with_timeout ... | consumer` -- they have the
#     same liveness property. A call whose stdout is a terminal or a regular file
#     is unaffected. No call site in this repo runs a command that does this.
#
# The command inherits the caller's stdin, stdout and stderr unchanged, so output
# interleaving under 2>&1 is real, piped stdin arrives, a closed stderr stays
# closed, and no auxiliary descriptor is reserved. An earlier version routed the
# command's stderr through fd 3 so the subshell's own stderr could be silenced,
# which broke a caller whose stderr was closed and clobbered a caller's fd 3.
#
# Job control makes Bash announce jobs on the owning shell's stderr, which would
# land in a captured stream. Redirecting a single builtin does not help, because
# Bash 3.2 reports a finished job at whichever command boundary it notices, so the
# job is disowned as soon as it starts and its exit status is passed back through a
# small status file instead of `wait`. Only the status goes through that file.
#
# The wait loop runs in the caller rather than in a background watchdog: a
# `( sleep N; kill ... ) &` watchdog inherits the caller's stdout too, which once
# turned a 4-second suite into 112 seconds.
#
# Caveat, shared with GNU timeout: the command runs in a background process group,
# so one that reads from a terminal gets SIGTTIN rather than the terminal. Callers
# here always redirect or pipe stdin.
#
# Exit status: the command's own status, or 124 when the timeout fired, matching
# GNU timeout so callers can tell the two apart.
#
# Usage: shell_run_with_timeout 30 bash script.sh arg
#

# Guard against repeated sourcing: both portable-timeout.sh and
# portable-helpers.sh may load this in the same shell.
if [ -n "${LOOP_SHELL_TIMEOUT_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
LOOP_SHELL_TIMEOUT_LOADED=1

LOOP_PORTABLE_KILL_GRACE_MS=500

shell_run_with_timeout() {
    local seconds="${1:-0}"
    shift

    # Strip leading zeros before any arithmetic. Callers validate with
    # ^[0-9]+$, which accepts "08", and shell arithmetic reads a leading zero
    # as octal: "08" is an error ("value too great for base") that returned 1
    # without running the command at all, and "010" silently meant eight
    # seconds. GNU timeout treats both as decimal, so this keeps the fallback
    # answering the same way as the rungs above it.
    while [ -n "${seconds#0}" ] && [ "${seconds#0}" != "$seconds" ]; do
        seconds="${seconds#0}"
    done
    case "$seconds" in
        '' | *[!0-9]*) seconds=0 ;;
    esac

    # A subshell keeps `set -m` local. No fd juggling: the command gets the
    # caller's descriptors as they are.
    (
        # Job control is what makes the command a process-group leader, so
        # `kill -- -PID` reaches processes that join the group after the
        # descendant snapshot.
        #
        # Only Bash can have it here. zsh cannot enable MONITOR inside a
        # subshell at all: `set -m` is a fatal error that kills the subshell
        # outright (redirecting it or appending `|| true` does not help), and
        # `setopt monitor` is accepted but silently leaves the option off. The
        # branch is on ZSH_VERSION rather than on a probe for that reason.
        # scripts/loop.sh is sourced by zsh users, so this path is real; there
        # the negative-PID kill simply fails and the direct-PID kill plus the
        # descendant walk below do the work. Every guarantee except "later
        # arrivals into the group" survives.
        if [ -z "${ZSH_VERSION:-}" ]; then
            set -m
        fi
        # Disable errexit inside the wrapper regardless of the caller's setting.
        # The helper does its own explicit status handling, so an inherited
        # `set -e` must not abort the status-file write when the command exits
        # non-zero -- that would turn a real exit 7 into an empty file, reported
        # as 1.
        #
        # This helper is for external commands (`bash ...`, a script, a binary),
        # which run as their own process and keep their own errexit. A Bash
        # function or builtin passed as "$@" would run in THIS subshell after the
        # `set +e` and so would not see its own errexit -- do not pass one.
        set +e

        # The job is removed from the job table immediately, because Bash 3.2
        # emits "[1]+ Done" at whichever command boundary it happens to notice the
        # exit -- somewhere inside the poll loop, not reliably at `wait` -- so
        # redirecting any single builtin does not suppress it. Without a job to
        # wait on, the exit status comes from a status file. Only the status is
        # written there; the command's own output still goes straight to the
        # caller, so stream ordering and stdin are unaffected.
        status_file=$(mktemp) || exit 1
        # The <&0 goes on the group, not on the command inside it: Bash gives a
        # background command /dev/null for stdin unless it is redirected
        # explicitly, and redirecting inside the group would only re-duplicate that
        # /dev/null.
        { "$@"; printf '%s\n' "$?" > "$status_file"; } <&0 &
        command_pid=$!
        disown %1 2>/dev/null || disown "$command_pid" 2>/dev/null || true

        # Poll in tenths of a second, but measure elapsed time against the
        # SECONDS builtin rather than by counting iterations. Each iteration
        # costs its 0.1s sleep plus the fork that runs it, so a counter drifts
        # by roughly 17% -- 11.7s for a 10s limit here, and about fifteen
        # minutes at the 5400s codex timeout this now guards. SECONDS costs no
        # fork and both Bash and zsh advance it inside a subshell.
        #
        # The comparison is strictly greater so the firing time is never early:
        # SECONDS has one-second granularity and the two reads sample it at an
        # arbitrary phase, so `-ge` could expire a 1s timeout a millisecond in.
        # Expiry therefore lands between `seconds` and `seconds + 1`.
        started_at=$SECONDS
        timed_out=0
        while kill -0 "$command_pid" 2>/dev/null; do
            if [ $((SECONDS - started_at)) -gt "$seconds" ]; then
                timed_out=1
                break
            fi
            sleep 0.1
        done

        if [ "$timed_out" -eq 1 ]; then
            # Snapshot the tree first: killing a parent reparents its children and
            # loses the chain that identifies them.
            descendants=$(_portable_descendants "$command_pid")
            _portable_terminate_tree "$command_pid" "$descendants"
            rm -f "$status_file"
            exit 124
        fi

        # The wrapper writes the status before it exits, so by the time kill -0
        # fails the file is complete. Named cmd_status, not status: `status` is
        # a read-only parameter in zsh (its spelling of `$?`), and assigning to
        # it aborts the subshell.
        cmd_status=$(cat "$status_file" 2>/dev/null)
        rm -f "$status_file"
        case "$cmd_status" in
            '' | *[!0-9]*) cmd_status=1 ;;
        esac
        exit "$cmd_status"
    )
}

# Print every process still descended from a pid, breadth first, space separated.
# Prints nothing when pgrep is unavailable, in which case the caller falls back to
# signalling the process group alone.
_portable_descendants() {
    local root="$1"
    command -v pgrep >/dev/null 2>&1 || return 0

    local queue="$root"
    local found=""
    local current children
    while [ -n "$queue" ]; do
        current="${queue%% *}"
        case "$queue" in
            *' '*) queue="${queue#* }" ;;
            *) queue="" ;;
        esac
        children=$(pgrep -P "$current" 2>/dev/null | tr '\n' ' ')
        if [ -n "$children" ]; then
            found="$found $children"
            queue="$queue $children"
        fi
    done

    printf '%s' "$found"
}

# Signal every pid in a space-separated list.
#
# Not `for pid in $list`: that relies on IFS word splitting, which zsh does not
# perform on an unquoted parameter (SH_WORD_SPLIT is off by default). There the
# whole list arrived as one word and every kill failed -- and since the zsh
# branch deliberately has no process group, this list is its ONLY descendant
# cleanup path, so a timed-out command was left running. Peeling words off with
# parameter expansion behaves identically in both shells, and is the same
# technique _portable_descendants already uses for its queue.
_portable_signal_list() {
    local sig="$1"
    local list="${2:-}"
    local pid

    while [ -n "$list" ]; do
        pid="${list%% *}"
        case "$list" in
            *' '*) list="${list#* }" ;;
            *) list="" ;;
        esac
        [ -n "$pid" ] || continue
        kill "-$sig" "$pid" 2>/dev/null || true
    done
}

# Is anything in the tracked tree still alive? Split the same way and for the
# same reason as _portable_signal_list.
_portable_tree_alive() {
    local target="$1"
    local list="${2:-}"
    local pid

    kill -0 "$target" 2>/dev/null && return 0
    while [ -n "$list" ]; do
        pid="${list%% *}"
        case "$list" in
            *' '*) list="${list#* }" ;;
            *) list="" ;;
        esac
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# TERM a command's process group and any listed descendants, then KILL whatever
# survived the grace period.
#
# The negative PID reaches the whole group, which the leader's own children join
# automatically. The explicit list covers processes that changed group -- a child
# running `set -m` gets its own group but is still a descendant -- and is collected
# before anything is signalled, while the parent links still exist.
_portable_terminate_tree() {
    local target="$1"
    local descendants="${2:-}"

    kill -TERM -"$target" 2>/dev/null || kill -TERM "$target" 2>/dev/null
    _portable_signal_list TERM "$descendants"

    # Wait on the whole tree, not on "$target" alone. $target is the brace-group
    # wrapper shell, which has no TERM trap and dies instantly, so waiting on it
    # ended the grace period at once and KILL landed on the real command a
    # moment after its TERM -- a command whose TERM handler flushes state got
    # the signal and then died mid-cleanup. GNU timeout gives that handler the
    # full grace period; this now does too.
    local grace=$((LOOP_PORTABLE_KILL_GRACE_MS / 100))
    [ "$grace" -lt 1 ] && grace=1
    local waited=0
    while _portable_tree_alive "$target" "$descendants" && [ "$waited" -lt "$grace" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    kill -KILL -"$target" 2>/dev/null || kill -KILL "$target" 2>/dev/null
    _portable_signal_list KILL "$descendants"
}
