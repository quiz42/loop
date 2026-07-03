"""
Tests for project scaffold and plugin configuration.

Verifies that the project directory structure, configuration files,
plugin metadata, and documentation are correctly set up.
"""

import json
import os
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

REQUIRED_DIRECTORIES = [
    "agents",
    "commands",
    "config",
    "docs",
    "hooks",
    "prompt-template",
    "scripts",
    "skills",
    "templates",
    "tests",
]

REQUIRED_ROOT_FILES = [
    ".gitignore",
    "LICENSE",
    "README.md",
]

PLUGIN_FILE = ".claude-plugin/plugin.json"
MARKETPLACE_FILE = ".claude-plugin/marketplace.json"
CLAUDE_MD = ".claude/CLAUDE.md"

CONFIG_FILES = [
    "config/default_config.json",
    "config/codex-hooks.json",
]

WORKFLOW_FILES = [
    ".github/workflows/plan-file-test.yml",
    ".github/workflows/pr-target-check.yml",
    ".github/workflows/run-all-tests.yml",
    ".github/workflows/shell-syntax-check.yml",
    ".github/workflows/template-test.yml",
    ".github/workflows/version-bump-check.yml",
]


class TestProjectScaffold(unittest.TestCase):
    """Test that the project directory structure is properly scaffolded."""

    def test_required_directories_exist(self):
        """All required subdirectories must exist at the project root."""
        for directory in REQUIRED_DIRECTORIES:
            path = os.path.join(PROJECT_ROOT, directory)
            self.assertTrue(
                os.path.isdir(path),
                f"Required directory '{directory}' does not exist at {path}",
            )

    def test_gitkeep_files_in_subdirectories(self):
        """Directories without tracked content should have a .gitkeep file."""
        for directory in REQUIRED_DIRECTORIES:
            dir_path = os.path.join(PROJECT_ROOT, directory)
            dir_contents = os.listdir(dir_path)
            # Skip directories that already have non-.gitkeep files
            non_gitkeep = [f for f in dir_contents if f != ".gitkeep"]
            if non_gitkeep:
                continue
            gitkeep_path = os.path.join(
                PROJECT_ROOT, directory, ".gitkeep"
            )
            self.assertTrue(
                os.path.isfile(gitkeep_path),
                f"Missing .gitkeep in empty '{directory}' directory",
            )


class TestRootFiles(unittest.TestCase):
    """Test that required root-level files exist with correct content."""

    def test_gitignore_exists(self):
        """.gitignore must exist and contain essential entries."""
        gitignore_path = os.path.join(PROJECT_ROOT, ".gitignore")
        self.assertTrue(os.path.isfile(gitignore_path))

        with open(gitignore_path) as f:
            content = f.read()

        self.assertIn("__pycache__", content, ".gitignore missing __pycache__")
        self.assertIn(".loop/", content, ".gitignore missing .loop/")
        self.assertIn(".DS_Store", content, ".gitignore missing .DS_Store")

    def test_license_exists_and_is_mit(self):
        """LICENSE must exist and be the MIT license."""
        license_path = os.path.join(PROJECT_ROOT, "LICENSE")
        self.assertTrue(os.path.isfile(license_path))

        with open(license_path) as f:
            content = f.read()

        self.assertIn("MIT License", content, "LICENSE is not MIT")
        self.assertIn("Permission is hereby granted", content)

    def test_readme_exists(self):
        """README.md must exist with project overview."""
        readme_path = os.path.join(PROJECT_ROOT, "README.md")
        self.assertTrue(os.path.isfile(readme_path))

        with open(readme_path) as f:
            content = f.read()

        self.assertIn("loop", content, "README missing project name")
        self.assertIn("RLCR", content, "README missing RLCR reference")
        self.assertIn("MIT", content, "README missing license info")
        self.assertIn("## Quick Start", content, "README missing Quick Start section")
        self.assertIn("## License", content, "README missing License section")


class TestPluginConfiguration(unittest.TestCase):
    """Test Claude Code plugin configuration files."""

    def test_plugin_json_exists_and_valid(self):
        """plugin.json must be valid JSON with required fields."""
        plugin_path = os.path.join(PROJECT_ROOT, PLUGIN_FILE)
        self.assertTrue(os.path.isfile(plugin_path))

        with open(plugin_path) as f:
            data = json.load(f)

        self.assertEqual(data["name"], "loop")
        self.assertEqual(data["license"], "MIT")
        self.assertIn("version", data)
        self.assertIn("description", data)
        self.assertIn("repository", data)
        self.assertIn("keywords", data)
        self.assertIsInstance(data["keywords"], list)
        self.assertGreater(len(data["keywords"]), 0)

    def test_marketplace_json_exists_and_valid(self):
        """marketplace.json must be valid JSON with correct structure."""
        marketplace_path = os.path.join(PROJECT_ROOT, MARKETPLACE_FILE)
        self.assertTrue(os.path.isfile(marketplace_path))

        with open(marketplace_path) as f:
            data = json.load(f)

        self.assertEqual(data["name"], "FrankDan77")
        self.assertIn("plugins", data)
        self.assertIsInstance(data["plugins"], list)
        self.assertGreater(len(data["plugins"]), 0)

        plugin = data["plugins"][0]
        self.assertEqual(plugin["name"], "loop")
        self.assertEqual(plugin["source"], "./")
        self.assertIn("version", plugin)
        self.assertIn("description", plugin)

    def test_claude_md_exists(self):
        """CLAUDE.md must exist with project rules."""
        claude_path = os.path.join(PROJECT_ROOT, CLAUDE_MD)
        self.assertTrue(os.path.isfile(claude_path))

        with open(claude_path) as f:
            content = f.read()

        self.assertIn(
            "loop", content, "CLAUDE.md missing project name"
        )
        self.assertIn("version bump", content.lower())

    def test_plugin_and_marketplace_versions_match(self):
        """Version in plugin.json and marketplace.json should match."""
        plugin_path = os.path.join(PROJECT_ROOT, PLUGIN_FILE)
        marketplace_path = os.path.join(PROJECT_ROOT, MARKETPLACE_FILE)

        with open(plugin_path) as f:
            plugin_data = json.load(f)
        with open(marketplace_path) as f:
            marketplace_data = json.load(f)

        plugin_version = plugin_data["version"]
        marketplace_version = marketplace_data["plugins"][0]["version"]

        self.assertEqual(
            plugin_version,
            marketplace_version,
            f"Version mismatch: plugin.json={plugin_version}, marketplace.json={marketplace_version}",
        )


class TestConfigurationFiles(unittest.TestCase):
    """Test configuration files."""

    def test_config_files_exist_and_valid_json(self):
        """All config files must exist and be valid JSON."""
        for config_file in CONFIG_FILES:
            config_path = os.path.join(PROJECT_ROOT, config_file)
            self.assertTrue(
                os.path.isfile(config_path),
                f"Config file '{config_file}' does not exist",
            )

            with open(config_path) as f:
                data = json.load(f)

            self.assertIsInstance(data, dict)

    def test_default_config_has_expected_keys(self):
        """default_config.json must have expected configuration keys."""
        config_path = os.path.join(PROJECT_ROOT, "config/default_config.json")

        with open(config_path) as f:
            data = json.load(f)

        expected_keys = [
            "codex_model",
            "codex_effort",
            "bitlesson_model",
            "agent_teams",
            "alternative_plan_language",
            "gen_plan_mode",
        ]
        for key in expected_keys:
            self.assertIn(key, data, f"Missing config key: {key}")


class TestGitHubWorkflows(unittest.TestCase):
    """Test GitHub Actions workflow parity."""

    def test_workflow_files_exist_and_use_loop_branding(self):
        legacy_name = "human" + "ize"
        for workflow_file in WORKFLOW_FILES:
            workflow_path = os.path.join(PROJECT_ROOT, workflow_file)
            self.assertTrue(
                os.path.isfile(workflow_path),
                f"Workflow file '{workflow_file}' does not exist",
            )
            with open(workflow_path) as f:
                content = f.read()
            self.assertIn("name:", content)
            self.assertNotIn(legacy_name, content)


class TestReadmeVersionConsistency(unittest.TestCase):
    """Test version consistency between README and plugin.json."""

    def test_version_in_readme_matches_plugin_json(self):
        """Version in README's header should match plugin.json."""
        readme_path = os.path.join(PROJECT_ROOT, "README.md")
        plugin_path = os.path.join(PROJECT_ROOT, PLUGIN_FILE)

        with open(readme_path) as f:
            readme_content = f.read()
        with open(plugin_path) as f:
            plugin_data = json.load(f)

        plugin_version = plugin_data["version"]
        # README has: **Version: X.Y.Z**
        self.assertIn(
            f"**Version: {plugin_version}**",
            readme_content,
            f"README version does not match plugin.json version ({plugin_version})",
        )


if __name__ == "__main__":
    unittest.main()
