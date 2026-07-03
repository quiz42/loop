"""Parity checks for the public loop plugin surface."""

from __future__ import annotations

import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def public_markdown_files() -> list[Path]:
    roots = ["README.md", "commands", "docs", "skills", "agents"]
    files: list[Path] = []
    for root in roots:
        path = PROJECT_ROOT / root
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
    return files


def runtime_surface_files() -> list[Path]:
    roots = ["scripts", "hooks"]
    files: list[Path] = []
    for root in roots:
        files.extend(
            path
            for path in sorted((PROJECT_ROOT / root).rglob("*"))
            if path.is_file() and path.suffix in {".py", ".sh", ".json"}
        )
    files.append(PROJECT_ROOT / ".gitignore")
    return files


class TestLoopParitySurface(unittest.TestCase):
    def test_private_directory_is_ignored_for_local_planning(self) -> None:
        gitignore = read(".gitignore")
        self.assertIn("private/", gitignore)

    def test_refine_plan_command_is_documented(self) -> None:
        command = PROJECT_ROOT / "commands" / "refine-plan.md"
        self.assertTrue(command.is_file())
        content = command.read_text(encoding="utf-8")
        self.assertIn("# Command: /loop:refine-plan", content)
        self.assertIn("loop refine-plan", content)
        self.assertIn("--qa-dir", content)
        self.assertIn("--alt-language", content)

    def test_public_markdown_uses_loop_command_branding(self) -> None:
        offenders: list[str] = []
        for path in public_markdown_files():
            content = path.read_text(encoding="utf-8")
            legacy_name = "human" + "ize"
            for forbidden in (f"/{legacy_name}:", f" {legacy_name} ", f"`{legacy_name} ", f"[{legacy_name}]"):
                if forbidden in content:
                    offenders.append(f"{path.relative_to(PROJECT_ROOT)} contains {forbidden!r}")
        self.assertEqual([], offenders)

    def test_loop_skill_frontmatter_matches_plugin_name(self) -> None:
        skill = read("skills/loop/SKILL.md")
        self.assertIn("name: loop", skill)
        self.assertIn("Main loop plugin skill covering all loop commands", skill)

    def test_upstream_parity_agents_are_present(self) -> None:
        for agent in (
            "plan-understanding-quiz.md",
            "plan-compliance-checker.md",
            "draft-relevance-checker.md",
            "bitlesson-selector.md",
        ):
            with self.subTest(agent=agent):
                path = PROJECT_ROOT / "agents" / agent
                self.assertTrue(path.is_file())
                self.assertNotIn("." + "human" + "ize", path.read_text(encoding="utf-8"))

    def test_runtime_surface_uses_loop_only(self) -> None:
        forbidden_tokens = (
            "HUM" + "ANIZE",
            "Hum" + "anize",
            "human" + "ize",
            "." + "human" + "ize",
        )
        offenders: list[str] = []
        for path in runtime_surface_files():
            content = path.read_text(encoding="utf-8")
            for token in forbidden_tokens:
                if token in content:
                    offenders.append(f"{path.relative_to(PROJECT_ROOT)} contains legacy token")
        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
