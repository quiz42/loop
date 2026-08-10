#!/usr/bin/env python3
"""Locate the first review marker in a review log, for Loop's Stop hook.

The hook must decide two things about a `codex review` log: what the findings
tail is, so it can extract it, and whether the log contains any marker at all,
so it knows whether it may record the review as clean. Both questions have one
correct answer -- the one `proof/core.py` gives, because that module is what
later reads the recorded result.

With `--extract`, the findings tail itself is printed, cut from the very text
that was scanned. A line number is printed otherwise, but it must never be
used to re-locate the marker in the file through a second reader: `sed` and
`wc` count raw `\n` bytes while this scanner counts lines of the decoded text,
and the difference once moved an extraction past the marker it was extracting
-- publishing a marker-free record that read as a clean review.

The hook used to answer them itself, in awk. The two implementations drifted
three times: on whether a marker had to fit inside the first ten columns or
merely start there, on byte offsets versus character offsets once a line
carried non-ASCII text, and on a token spanning a line break. Every divergence
had the same shape and the same cost -- the hook wrote "no finding was
reported" about a review the Proof layer reads as reporting one, and that
record then resolves every finding still open in the Run. So the grammar lives
in one place and this script is how the shell reaches it.

Exit codes are the interface, and the third one matters most:

    0  a marker was found; its 1-based line number is on stdout
    1  the text was scanned and holds no marker
    2  the text could not be scanned

`2` is never `1`. Issue #28 records what happens when a hook treats "the
checker did not run" as "the checker found nothing": on a host with no
`python3` the exit status is 127, and a gate that only tests for its own
failure codes passes silently. A caller that cannot tell those apart cannot
fail closed, so this keeps them apart and lets the caller decide.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    from proof.core import first_review_marker
except Exception as error:  # pragma: no cover - import failure path
    print(f"review-markers: cannot load the marker grammar: {error}", file=sys.stderr)
    raise SystemExit(2)


EXIT_FOUND = 0
EXIT_NONE = 1
EXIT_UNSCANNABLE = 2


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("path", help="review log or recorded review result")
    parser.add_argument(
        "--canonical",
        action="store_true",
        help="only an actionable [P0]-[P9] finding line counts",
    )
    parser.add_argument(
        "--tail",
        type=int,
        default=0,
        metavar="N",
        help="search only the last N lines; line numbers stay absolute",
    )
    parser.add_argument(
        "--extract",
        action="store_true",
        help="print the text from the marker's line to the end, not a line number",
    )
    args = parser.parse_args(argv)
    if args.extract and not args.canonical:
        # Only an actionable finding starts an extraction; a malformed token
        # withholds the clean record but extracts nothing.
        parser.error("--extract requires --canonical")

    try:
        text = Path(args.path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        # Undecodable is not clean. `proof/core.py` reads a review it cannot
        # decode as unparseable, never as free of findings, and this has to
        # agree with it.
        print(f"review-markers: cannot read {args.path}: {error}", file=sys.stderr)
        return EXIT_UNSCANNABLE

    # The tail window is sliced on "\n" alone, matching how the grammar numbers
    # lines (`first_review_marker` counts "\n" before the match). str.splitlines
    # is the wrong knife: it also cuts on form feed, NEL, U+2028 and friends,
    # which no "\n"-counting reader recognizes, so one such byte early in a log
    # shifted the window arithmetic relative to the marker's own line number.
    offset = 0
    if args.tail > 0:
        parts = text.split("\n")
        line_count = len(parts) - 1 if parts and parts[-1] == "" else len(parts)
        if line_count > args.tail:
            offset = line_count - args.tail
            text = "\n".join(parts[offset:])

    found = first_review_marker(text, canonical_only=args.canonical)
    if found is None:
        return EXIT_NONE
    if args.extract:
        # The suffix comes out of the exact text that was scanned, so what is
        # published is what the grammar read -- there is no second reader to
        # disagree with. Encoding is pinned because the record has one, whatever
        # locale the calling hook inherited.
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stdout.write(text[found["offset"]:])
        return EXIT_FOUND
    print(found["line"] + offset)
    return EXIT_FOUND


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as error:  # pragma: no cover - unexpected failure path
        # An unexpected failure is "could not scan", never "nothing found".
        print(f"review-markers: scan failed: {error}", file=sys.stderr)
        raise SystemExit(EXIT_UNSCANNABLE)
