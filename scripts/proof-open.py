#!/usr/bin/env python3
"""Open a generated Proof Explorer without requiring a network service."""

from __future__ import annotations

import argparse
import functools
import http.server
import platform
import subprocess
import sys
from http import HTTPStatus
from pathlib import Path
from typing import Optional, Sequence, Tuple


EXIT_USAGE = 1


class _ArgumentParser(argparse.ArgumentParser):
    """Make argparse usage errors use Proof's documented exit code (1)."""

    def error(self, message: str) -> None:  # pragma: no cover - argparse edge
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        prog="loop proof open",
        description="Open a Proof Bundle's offline Explorer.",
    )
    parser.add_argument(
        "--server",
        action="store_true",
        help="serve the Explorer on 127.0.0.1 using an ephemeral port",
    )
    parser.add_argument("bundle", metavar="BUNDLE_DIR")
    return parser


def _bundle_and_index(value: str) -> Tuple[Path, Path]:
    """Resolve a Bundle directory and require its packaged Explorer entry point."""
    supplied = Path(value).expanduser().resolve()
    bundle = (
        supplied.parent
        if supplied.is_file() and supplied.name == "proof.json"
        else supplied
    )
    index = bundle / "index.html"
    if not bundle.is_dir():
        raise ValueError(f"Proof Bundle directory does not exist: {bundle}")
    try:
        resolved_index = index.resolve()
        resolved_index.relative_to(bundle)
    except (OSError, ValueError):
        raise ValueError(
            f"Proof Bundle Explorer index.html must remain inside the Bundle: {bundle}"
        ) from None
    if not index.is_file():
        raise ValueError(
            f"Proof Bundle has no packaged Explorer index.html: {bundle}. "
            "Re-export the Run with a current Loop version."
        )
    try:
        for candidate in bundle.rglob("*"):
            if not candidate.is_symlink():
                continue
            candidate.resolve().relative_to(bundle)
    except (OSError, RuntimeError, ValueError):
        raise ValueError(
            f"Proof Bundle paths must remain inside the Bundle: {bundle}"
        ) from None
    return bundle, index


def _launcher() -> Optional[str]:
    """Return the native URL opener required by the supported platforms."""
    system = platform.system()
    if system == "Darwin":
        return "open"
    if system == "Linux":
        return "xdg-open"
    return None


def _open_url(url: str) -> bool:
    """Ask the operating system to open a URL without adding a web dependency."""
    launcher = _launcher()
    if launcher is None:
        print(
            f"Error: loop proof open supports macOS and Linux; open this URL manually: {url}",
            file=sys.stderr,
        )
        return False
    try:
        result = subprocess.run([launcher, url], check=False)
    except OSError as error:
        print(
            f"Error: could not launch {launcher}; open this URL manually: {url} ({error})",
            file=sys.stderr,
        )
        return False
    if result.returncode != 0:
        print(
            f"Error: {launcher} failed; open this URL manually: {url}",
            file=sys.stderr,
        )
        return False
    return True


class _ProofBundleRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Serve only resolved paths that remain inside the requested Bundle."""

    def __init__(self, *args: object, directory: Optional[str] = None, **kwargs: object) -> None:
        self._bundle_root = Path(directory or ".").resolve()
        super().__init__(*args, directory=str(self._bundle_root), **kwargs)

    def _is_inside_bundle(self, path: Path) -> bool:
        try:
            path.resolve().relative_to(self._bundle_root)
        except (OSError, ValueError):
            return False
        return True

    def send_head(self) -> Optional[object]:
        candidate = Path(super().translate_path(self.path))
        if not self._is_inside_bundle(candidate):
            self.send_error(
                HTTPStatus.NOT_FOUND,
                "Requested path is outside this Proof Bundle.",
            )
            return None
        if candidate.is_dir():
            for name in ("index.html", "index.htm"):
                index = candidate / name
                if index.exists() and not self._is_inside_bundle(index):
                    self.send_error(
                        HTTPStatus.NOT_FOUND,
                        "Bundle index is outside this Proof Bundle.",
                    )
                    return None
        return super().send_head()


def _serve(bundle: Path) -> int:
    """Serve a Bundle locally until interrupted, then close the listening socket."""
    handler = functools.partial(
        _ProofBundleRequestHandler, directory=str(bundle)
    )
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        url = f"http://127.0.0.1:{server.server_port}/"
        print(f"Serving Proof Explorer at {url}", flush=True)
        print("Press Ctrl-C to stop the local server.", flush=True)
        # A browser-launch failure should not make a useful local server vanish.
        _open_url(url)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped local Proof Explorer server.")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _parser()
    try:
        args = parser.parse_args(argv)
        bundle, index = _bundle_and_index(args.bundle)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        parser.print_usage(sys.stderr)
        return EXIT_USAGE

    if args.server:
        return _serve(bundle)
    return 0 if _open_url(index.as_uri()) else EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
