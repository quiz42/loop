#!/usr/bin/env python3
"""Open a generated Proof Explorer without requiring a network service."""

from __future__ import annotations

import argparse
import functools
import hashlib
import http.server
import json
import platform
import re
import subprocess
import sys
from http import HTTPStatus
from pathlib import Path
from typing import Any, Dict, Mapping, NoReturn, Optional, Sequence, Tuple


# Running python scripts/proof-open.py puts scripts/ (rather than the
# checkout root) on sys.path.  Bootstrap the repository package explicitly so
# the command is independent of the caller's current working directory.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


EXIT_USAGE = 1
_EXPLORER_ASSET_NAMES = ("index.html", "app.js", "styles.css")
_ASSET_HASH_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
_REEXPORT_GUIDANCE = "Re-export the Run with a current Loop version."


class _ArgumentParser(argparse.ArgumentParser):
    """Make argparse usage errors use Proof's documented exit code (1)."""

    def error(self, message: str) -> NoReturn:  # pragma: no cover - argparse edge
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
            f"{_REEXPORT_GUIDANCE}"
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


def _read_manifest(bundle: Path) -> Dict[str, Any]:
    """Read the parsed canonical manifest after normal Bundle validation."""
    proof_path = bundle / "proof.json"
    try:
        manifest = json.loads(proof_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(
            f"Cannot read Proof Bundle manifest {proof_path}: {error}"
        ) from None
    if not isinstance(manifest, dict):
        raise ValueError(
            f"Proof Bundle manifest must be a JSON object: {proof_path}. "
            f"{_REEXPORT_GUIDANCE}"
        )
    return manifest


def _expected_proof_data(manifest: Mapping[str, Any]) -> bytes:
    """Render the exact deterministic display projection written by export."""
    return (
        "window.PROOF = "
        + json.dumps(
            manifest,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + ";\n"
    ).encode("utf-8")


def _declared_explorer_assets(manifest: Mapping[str, Any]) -> Mapping[str, str]:
    """Require current renderer attestations while preserving legacy validation."""
    explorer = manifest.get("explorer")
    assets = explorer.get("assets") if isinstance(explorer, Mapping) else None
    if not isinstance(assets, Mapping):
        raise ValueError(
            "Proof Bundle lacks explorer.assets renderer attestations and cannot be "
            f"opened through loop proof open. {_REEXPORT_GUIDANCE}"
        )

    declared: Dict[str, str] = {}
    for name in _EXPLORER_ASSET_NAMES:
        digest = assets.get(name)
        if not isinstance(digest, str) or _ASSET_HASH_PATTERN.fullmatch(digest) is None:
            raise ValueError(
                "Proof Bundle explorer.assets metadata is malformed for "
                f"{name}. {_REEXPORT_GUIDANCE}"
            )
        declared[name] = digest
    return declared


def _verify_renderer(bundle: Path, manifest: Mapping[str, Any]) -> None:
    """Ensure the launched Explorer matches the renderer bound into proof.json."""
    declared_assets = _declared_explorer_assets(manifest)
    for name in _EXPLORER_ASSET_NAMES:
        asset_path = bundle / name
        try:
            contents = asset_path.read_bytes()
        except OSError as error:
            raise ValueError(
                f"Cannot read packaged Explorer asset {name}: {error}. "
                f"{_REEXPORT_GUIDANCE}"
            ) from None
        actual_digest = "sha256:" + hashlib.sha256(contents).hexdigest()
        if actual_digest != declared_assets[name]:
            raise ValueError(
                f"Proof Bundle Explorer asset hash mismatch: {name}. "
                "Refusing to launch an unattested renderer. "
                f"{_REEXPORT_GUIDANCE}"
            )

    proof_data_path = bundle / "proof-data.js"
    try:
        actual_proof_data = proof_data_path.read_bytes()
    except OSError as error:
        raise ValueError(
            f"Cannot read packaged Explorer data proof-data.js: {error}. "
            f"{_REEXPORT_GUIDANCE}"
        ) from None
    if actual_proof_data != _expected_proof_data(manifest):
        raise ValueError(
            "Proof Bundle proof-data.js does not exactly match proof.json. "
            "Refusing to launch an unattested display projection. "
            f"{_REEXPORT_GUIDANCE}"
        )


def _preflight(bundle: Path) -> None:
    """Allow only a validated Bundle and its bound static renderer to launch."""
    try:
        from proof.validator import validate_bundle

        report = validate_bundle(bundle)
    except Exception as error:
        raise ValueError(f"Cannot validate Proof Bundle: {error}") from None

    if report.status not in {"valid", "incomplete"}:
        detail = ""
        if report.reasons:
            first_reason = report.reasons[0]
            reason = first_reason.get("reason", "invalid")
            target = first_reason.get("target", "")
            detail = f" First reason: {reason}{': ' + target if target else ''}."
        raise ValueError(
            "Proof Bundle validation is invalid; refusing to launch its Explorer. "
            f"Run loop proof verify {bundle} for details.{detail}"
        )

    _verify_renderer(bundle, _read_manifest(bundle))


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

    def _has_loopback_host_header(self) -> bool:
        """Accept only this server's two loopback Host header spellings.

        Binding the socket to 127.0.0.1 is not enough for browser clients: a
        hostile DNS rebinding response can still cause a browser to send an
        arbitrary Host header to the loopback listener. Requiring the exact
        loopback host and ephemeral port keeps this single-Bundle server local.
        """
        host_values = self.headers.get_all("Host") or []
        if len(host_values) != 1:
            return False
        port = getattr(self.server, "server_port", None)
        if not isinstance(port, int):
            return False
        host = host_values[0]
        return host == f"127.0.0.1:{port}" or host.lower() == f"localhost:{port}"

    def parse_request(self) -> bool:
        """Reject DNS-rebinding Host headers before resolving request paths."""
        if not super().parse_request():
            return False
        if self._has_loopback_host_header():
            return True
        self.send_error(
            HTTPStatus.BAD_REQUEST,
            "Host header must name this loopback Proof Explorer server.",
        )
        return False

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
        _preflight(bundle)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        parser.print_usage(sys.stderr)
        return EXIT_USAGE

    if args.server:
        return _serve(bundle)
    return 0 if _open_url(index.as_uri()) else EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
