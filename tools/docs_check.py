#!/usr/bin/env python3
"""Offline checks for Markdown links, instruction routing, and the ADR index.

Checks inline links and reference links, ATX/setext heading anchors, and source
line anchors. Code fences, inline code, remote links and archived HTML contents
are excluded. This is a repository check, not a complete Markdown renderer.
"""

import argparse
from collections import Counter
import html
import os
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SKILLS = ("coordinator", "worker", "lander")
SKIP = {".git", ".build", ".swiftpm", "__pycache__", ".pytest_cache", "node_modules", "references", "DerivedData"}
ADR_NAME = re.compile(r"^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
INLINE_LINK = re.compile(r'!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()\s]*\))+)(?:\s+["\'][^\n]*?["\'])?\s*\)')


def prose(text):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            run = marker[1]
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append("" if fence else line)
    return "\n".join(lines)


def anchors(text):
    found = set()
    previous = ""
    for line in prose(text).splitlines():
        match = re.match(r"^\s{0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*$", line)
        heading = match[1] if match else previous if re.fullmatch(r"\s{0,3}(?:=+|-+)\s*", line) else None
        if heading:
            heading = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", heading)
            heading = html.unescape(re.sub(r"<[^>]+>", "", heading)).strip().lower()
            slug = re.sub(r"[^\w -]", "", heading).replace(" ", "-")
            candidate = slug
            suffix = 0
            while candidate in found:
                suffix += 1
                candidate = f"{slug}-{suffix}"
            found.add(candidate)
        previous = line.strip()
    return found


def link_targets(text):
    """Return destination strings and unresolved full-reference labels."""
    text = re.sub(r"(`+).*?\1", "", prose(text))
    definitions = {}
    for match in re.finditer(r"(?m)^\s{0,3}\[([^\]]+)\]:\s*(<[^>]+>|\S+)", text):
        definitions[" ".join(match[1].lower().split())] = match[2].strip("<>")
    targets = [match[1].strip("<>") for match in INLINE_LINK.finditer(text)]
    missing = []
    for match in re.finditer(r"!?\[([^\]\n]+)\]\[([^\]\n]*)\]", text):
        key = " ".join((match[2] or match[1]).lower().split())
        if key in definitions:
            targets.append(definitions[key])
        else:
            missing.append(key)
    # Shortcut references use only an existing definition; ordinary [text] is prose.
    without_links = INLINE_LINK.sub("", text)
    for match in re.finditer(r"(?<!!)\[([^\]\n]+)\](?![\[(:])", without_links):
        key = " ".join(match[1].lower().split())
        if key in definitions:
            targets.append(definitions[key])
    return targets, missing


def markdown_files(root):
    for directory, names, files in os.walk(root, followlinks=False):
        names[:] = sorted(name for name in names if name not in SKIP and not (Path(directory) / name).is_symlink())
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix.lower() == ".md":
                yield path


def link_problems(root, documents):
    problems = []
    for source, text in documents.items():
        targets, missing = link_targets(text)
        relative = source.relative_to(root)
        problems.extend(f"{relative}: undefined link reference [{key}]" for key in missing)
        for raw in targets:
            url = urlsplit(raw)
            if url.scheme or url.netloc:
                continue
            path = unquote(url.path)
            destination = (root / path.lstrip("/") if path.startswith("/") else source.parent / path) if path else source
            destination = destination.resolve()
            if not destination.is_relative_to(root):
                problems.append(f"{relative}: link escapes repository: {raw}")
            elif not destination.exists():
                problems.append(f"{relative}: missing destination: {raw}")
            elif url.fragment and destination.is_file():
                fragment = unquote(url.fragment)
                line = re.fullmatch(r"L([1-9]\d*)(?:-L([1-9]\d*))?", fragment)
                if line:
                    total = len(destination.read_text(encoding="utf-8").splitlines())
                    start, end = int(line[1]), int(line[2] or line[1])
                    if not 1 <= start <= end <= total:
                        problems.append(f"{relative}: invalid source line anchor: {raw}")
                elif destination.suffix.lower() == ".md":
                    target = documents.get(destination)
                    if target is None:
                        target = destination.read_text(encoding="utf-8")
                    if fragment not in anchors(target):
                        problems.append(f"{relative}: missing heading: {raw}")
    return problems


def adr_problems(root):
    directory = root / "adr"
    if not directory.is_dir():
        return ["adr/: missing decision records directory"]
    records = []
    problems = []
    for path in sorted(directory.glob("*.md")):
        if path.name in {"README.md", "template.md"}:
            continue
        if not ADR_NAME.fullmatch(path.name):
            problems.append(f"adr/: invalid record filename {path.name}")
            continue
        records.append(path.name)
        text = prose(path.read_text(encoding="utf-8"))
        if not re.search(r"(?im)^\s*(?:[-*+]\s+)?(?:\*\*)?Status:(?:\*\*)?\s*(?:Proposed|Accepted|Rejected|Deprecated|Superseded)\b", text):
            problems.append(f"adr/{path.name}: missing or invalid Status line")
    for number, count in Counter(name[:4] for name in records).items():
        if count > 1:
            problems.append(f"adr/: duplicate record number {number}")
    index = directory / "README.md"
    if not index.is_file():
        return problems + ["adr/README.md: missing index"]
    rows = []
    for line in prose(index.read_text(encoding="utf-8")).splitlines():
        if re.match(r"^\s*\|\s*\[", line):
            match = re.match(r"^\s*\|\s*\[(\d{4})\]\(([^)]+)\)\s*\|", line)
            if not match or not ADR_NAME.fullmatch(match[2]) or match[1] != match[2][:4]:
                problems.append(f"adr/README.md: invalid index row: {line}")
            else:
                rows.append(match[2])
    if rows != records:
        problems.append("adr/README.md: index must list every record exactly once in number order")
    if not records:
        problems.append("adr/: no numbered decision records")
    return problems


def routing_problems(root):
    problems = []
    agents = root / "AGENTS.md"
    claude = root / "CLAUDE.md"
    if not agents.is_file():
        problems.append("AGENTS.md: missing instructions")
    if not claude.is_file():
        problems.append("CLAUDE.md: missing instruction routing")
    elif claude.resolve() != agents.resolve():
        text = prose(claude.read_text(encoding="utf-8"))
        targets, _ = link_targets(text)
        if "@AGENTS.md" not in text and not any(target.split("#")[0] in {"AGENTS.md", "./AGENTS.md"} for target in targets):
            problems.append("CLAUDE.md: must route to AGENTS.md using @AGENTS.md or a Markdown link")
    skills = root / ".agents" / "skills"
    alias = root / ".claude" / "skills"
    if not alias.is_symlink() or alias.resolve() != skills.resolve():
        problems.append(".claude/skills: must be a symlink to .agents/skills")
    for name in SKILLS:
        if not (skills / name / "SKILL.md").is_file():
            problems.append(f".agents/skills/{name}/SKILL.md: missing role skill")
    return problems


def check(root):
    root = root.resolve()
    documents = {path: path.read_text(encoding="utf-8") for path in markdown_files(root)}
    return link_problems(root, documents) + adr_problems(root) + routing_problems(root), len(documents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository directory, defaults to this checkout")
    args = parser.parse_args()
    try:
        problems, count = check(args.root)
        for problem in problems:
            print(f"FAIL: {problem}")
        print(f"docs check: {count} Markdown files; {len(problems)} problems")
        return int(bool(problems))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"docs check: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
