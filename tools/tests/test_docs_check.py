from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import docs_check


class DocsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_relative_links_headings_references_and_source_lines(self):
        source = self.write("docs/page.md", """[Good](../README.md#same-1)
[Reference][intro]
[intro]: ../README.md#intro
[Source](../source.swift#L2)
[Absent](missing.md)
[Heading](../README.md#absent)
[Bad line](../source.swift#L3)
[Undefined][nope]
`[ignored](inline-missing.md)`
~~~text
[ignored](fenced-missing.md)
~~~
[Remote](https://example.invalid/unreachable)
""")
        target = self.write("README.md", "# Intro\n# Same\n# Same\n````\n# Hidden\n````\n")
        self.write("source.swift", "one\ntwo\n")
        problems = docs_check.link_problems(self.root, {source: source.read_text(), target: target.read_text()})
        self.assertEqual(len(problems), 4, problems)
        self.assertTrue(any("undefined link reference [nope]" in problem for problem in problems))
        self.assertTrue(any("missing destination: missing.md" in problem for problem in problems))
        self.assertTrue(any("missing heading:" in problem for problem in problems))
        self.assertTrue(any("invalid source line anchor:" in problem for problem in problems))

    def test_percent_encoded_paths_and_repository_escape(self):
        source = self.write("README.md", "[Space](docs/a%20b.md#hello)\n[Escape](../outside.md)")
        self.write("docs/a b.md", "# Hello")
        problems = docs_check.link_problems(self.root, {source: source.read_text()})
        self.assertEqual(len(problems), 1)
        self.assertIn("escapes repository", problems[0])

    def test_adr_index_requires_exact_coverage_unique_numbers_and_status(self):
        self.write("adr/0000-record-decisions.md", "# Record decisions\n\n- **Status:** Accepted\n")
        self.write("adr/README.md", "| # | Decision | Status |\n|---|---|---|\n| [0000](0000-record-decisions.md) | Record | Accepted |\n")
        self.assertEqual(docs_check.adr_problems(self.root), [])
        self.write("adr/0000-duplicate.md", "# Duplicate\n")
        problems = docs_check.adr_problems(self.root)
        self.assertTrue(any("duplicate record number" in problem for problem in problems))
        self.assertTrue(any("Status line" in problem for problem in problems))
        self.assertTrue(any("every record exactly once" in problem for problem in problems))

    def test_routing_and_skill_links_are_checked_without_traversing_alias(self):
        self.write("AGENTS.md", "# Agreements")
        self.write("CLAUDE.md", "@AGENTS.md\n")
        for name in docs_check.SKILLS:
            self.write(f".agents/skills/{name}/SKILL.md", "[Rules](../../../AGENTS.md)")
        (self.root / ".claude").mkdir()
        (self.root / ".claude/skills").symlink_to("../.agents/skills", target_is_directory=True)
        self.assertEqual(docs_check.routing_problems(self.root), [])
        documents = {path: path.read_text() for path in docs_check.markdown_files(self.root)}
        self.assertEqual(len(documents), 5)
        # A skill lives three directories below the root; the fixture is valid.
        self.assertEqual(docs_check.link_problems(self.root, documents), [])
        (self.root / ".claude/skills").unlink()
        self.assertTrue(any("symlink" in problem for problem in docs_check.routing_problems(self.root)))

    def test_runtime_directories_and_html_contents_are_not_scanned(self):
        self.write("README.md", "# Readme")
        self.write(".build/README.md", "[broken](missing.md)")
        self.write("docs/archive.html", '<a href="missing.md">ignored</a>')
        self.assertEqual([path.name for path in docs_check.markdown_files(self.root)], ["README.md"])


if __name__ == "__main__":
    unittest.main()
