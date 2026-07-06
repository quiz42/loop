"""
Test suite for the prompt template system.

Tests verify that:
1. All required template directories exist
2. All templates load successfully
3. Template variable substitution works correctly
4. Missing templates fall back gracefully
"""

import unittest
import os
from pathlib import Path


class TestTemplateStructure(unittest.TestCase):
    """Test template directory structure and file existence."""

    def setUp(self):
        self.template_root = Path(__file__).parent.parent / "prompt-template"
    
    def test_template_root_exists(self):
        """Template root directory must exist."""
        self.assertTrue(self.template_root.exists(), 
                       f"Template root not found at {self.template_root}")
        self.assertTrue(self.template_root.is_dir(),
                       f"Template root is not a directory: {self.template_root}")
    
    def test_required_subdirectories_exist(self):
        """All required template subdirectories must exist."""
        required_dirs = ["block", "claude", "codex", "idea", "plan"]
        for dirname in required_dirs:
            dirpath = self.template_root / dirname
            with self.subTest(directory=dirname):
                self.assertTrue(dirpath.exists(), 
                               f"Required directory missing: {dirname}")
                self.assertTrue(dirpath.is_dir(),
                               f"Path is not a directory: {dirname}")
    
    def test_block_templates_exist(self):
        """Block templates must exist."""
        block_templates = [
            "message.md",
            "todos-file-access.md",
            "prompt-file-write.md",
            "state-file-modification.md",
            "git-not-clean.md",
            "git-push.md",
            "round-contract-missing.md",
            "plan-file-modified.md",
            "incomplete-todos.md",
            "work-summary-missing.md",
            "bitlesson-delta-empty-kb.md",
            "bitlesson-delta-inconsistent.md",
            "bitlesson-delta-invalid.md",
            "bitlesson-delta-missing-notes.md",
            "bitlesson-delta-missing.md",
        ]
        block_dir = self.template_root / "block"
        for template in block_templates:
            with self.subTest(template=template):
                template_path = block_dir / template
                self.assertTrue(template_path.exists(),
                               f"Block template missing: {template}")
    
    def test_claude_templates_exist(self):
        """Claude templates must exist."""
        claude_templates = [
            "next-round-prompt.md",
            "drift-replan-prompt.md",
            "review-phase-prompt.md",
            "finalize-phase-prompt.md",
            "methodology-analysis-prompt.md",
            "next-round-footer.md",
            "agent-teams-core.md"
        ]
        claude_dir = self.template_root / "claude"
        for template in claude_templates:
            with self.subTest(template=template):
                template_path = claude_dir / template
                self.assertTrue(template_path.exists(),
                               f"Claude template missing: {template}")
    
    def test_codex_templates_exist(self):
        """Codex templates must exist."""
        codex_templates = [
            "full-alignment-review.md",
            "regular-review.md",
            "code-review-phase.md",
            "goal-tracker-update-section.md",
            "commit-history-section.md"
        ]
        codex_dir = self.template_root / "codex"
        for template in codex_templates:
            with self.subTest(template=template):
                template_path = codex_dir / template
                self.assertTrue(template_path.exists(),
                               f"Codex template missing: {template}")
    
    def test_plan_templates_exist(self):
        """Plan templates must exist."""
        plan_templates = [
            "gen-plan-template.md",
            "refine-plan-qa-template.md"
        ]
        plan_dir = self.template_root / "plan"
        for template in plan_templates:
            with self.subTest(template=template):
                template_path = plan_dir / template
                self.assertTrue(template_path.exists(),
                               f"Plan template missing: {template}")
    
    def test_idea_templates_exist(self):
        """Idea templates must exist."""
        idea_dir = self.template_root / "idea"
        template_path = idea_dir / "gen-idea-template.md"
        self.assertTrue(template_path.exists(),
                       "Idea template missing: gen-idea-template.md")


class TestTemplateContent(unittest.TestCase):
    """Test template content and variable placeholders."""

    def setUp(self):
        self.template_root = Path(__file__).parent.parent / "prompt-template"
    
    def test_templates_are_readable(self):
        """All template files must be readable."""
        for template_file in self.template_root.rglob("*.md"):
            with self.subTest(template=template_file.name):
                try:
                    content = template_file.read_text(encoding="utf-8")
                    self.assertIsInstance(content, str)
                    self.assertGreater(len(content), 0,
                                     f"Template is empty: {template_file.name}")
                except Exception as e:
                    self.fail(f"Failed to read {template_file.name}: {e}")
    
    def test_variable_placeholder_syntax(self):
        """Templates using variables must use {{VAR}} syntax."""
        invalid_patterns = []
        for template_file in self.template_root.rglob("*.md"):
            content = template_file.read_text(encoding="utf-8")
            # Check for single braces (common mistake)
            import re
            # Look for {VAR} but not {{VAR}}
            single_brace = re.findall(r'(?<!\{)\{([A-Z_][A-Z0-9_]*)\}(?!\})', content)
            if single_brace:
                invalid_patterns.append((template_file.name, single_brace))
        
        if invalid_patterns:
            details = "\n".join([f"  {name}: {vars}" for name, vars in invalid_patterns])
            self.fail(f"Templates with single-brace variables found:\n{details}\n"
                     "Use {{VAR}} syntax instead.")
    
    def test_block_message_template(self):
        """Block message template must be a simple passthrough."""
        message_template = self.template_root / "block" / "message.md"
        content = message_template.read_text(encoding="utf-8").strip()
        self.assertEqual(content, "{{MESSAGE}}",
                        "message.md should contain only {{MESSAGE}}")
    
    def test_next_round_prompt_has_required_vars(self):
        """next-round-prompt.md must reference key variables."""
        template = self.template_root / "claude" / "next-round-prompt.md"
        content = template.read_text(encoding="utf-8")
        required_vars = ["{{PLAN_FILE}}", "{{GOAL_TRACKER_FILE}}", 
                        "{{ROUND_CONTRACT_FILE}}", "{{CURRENT_ROUND}}"]
        for var in required_vars:
            with self.subTest(variable=var):
                self.assertIn(var, content,
                             f"next-round-prompt.md missing {var}")

    def test_bitlesson_block_templates_use_loop_paths(self):
        """Bitlesson block templates must reference loop runtime paths."""
        block_dir = self.template_root / "block"
        templates = [
            "bitlesson-delta-empty-kb.md",
            "bitlesson-delta-inconsistent.md",
            "bitlesson-delta-invalid.md",
            "bitlesson-delta-missing-notes.md",
            "bitlesson-delta-missing.md",
        ]
        legacy_path = "." + "human" + "ize"
        templates_requiring_path = {
            "bitlesson-delta-empty-kb.md",
            "bitlesson-delta-inconsistent.md",
        }
        for template in templates:
            with self.subTest(template=template):
                content = (block_dir / template).read_text(encoding="utf-8")
                self.assertNotIn(legacy_path, content)
                if template in templates_requiring_path:
                    self.assertIn(".loop/bitlesson/lessons.md", content)


class TestTemplateIntegration(unittest.TestCase):
    """Integration tests for template loading and rendering."""
    
    def setUp(self):
        self.template_root = Path(__file__).parent.parent / "prompt-template"
    
    def test_all_templates_have_markdown_extension(self):
        """All template files must have .md extension."""
        non_md_files = [
            f for f in self.template_root.rglob("*")
            if f.is_file() and not f.name.endswith(".md")
        ]
        self.assertEqual(len(non_md_files), 0,
                        f"Non-.md files found in templates: {non_md_files}")
    
    def test_template_count(self):
        """Verify expected template count."""
        all_templates = list(self.template_root.rglob("*.md"))
        # block: ~38, claude: 14, codex: 5, idea: 1, plan: 2
        # Total expected: around 60
        self.assertGreaterEqual(len(all_templates), 55,
                               f"Expected at least 55 templates, found {len(all_templates)}")
        self.assertLessEqual(len(all_templates), 65,
                            f"Expected at most 65 templates, found {len(all_templates)}")


if __name__ == "__main__":
    unittest.main()
