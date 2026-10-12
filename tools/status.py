#!/usr/bin/env python3
"""Read LoopTune's live task/PR state. Requires gh authenticated as carlrosell.

Nothing is fetched into git or changed on GitHub. ADR numbers are suggestions,
not atomic reservations; put `Reserves: ADR NNNN` in an issue or PR to claim one.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = "carlrosell/looptune"
PRIORITIES = ("p1", "p2", "p3")
ADR = re.compile(r"^adr/(\d{4})-[a-z0-9-]+\.md$")


def command(args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip() or result.returncode}")
    return result.stdout


def api(*args):
    data = json.loads(command(["gh", "api", *args]))
    if isinstance(data, dict) and data.get("errors"):
        raise RuntimeError(f"GitHub GraphQL error: {data['errors']}")
    return data


def rest_pages(endpoint):
    pages = api("--paginate", "--slurp", endpoint)
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise RuntimeError(f"Unexpected paginated response for {endpoint}")
    return [item for page in pages for item in page]


def connection(query, path):
    """Read every page, including nested connections that gh cannot paginate."""
    cursor = None
    seen = set()
    while True:
        args = ["graphql", "-f", f"query={query}"]
        if cursor:
            args += ["-f", f"cursor={cursor}"]
        data = api(*args)["data"]
        for key in path:
            data = data[key]
        yield from data["nodes"]
        page = data["pageInfo"]
        if not page["hasNextPage"]:
            return
        cursor = page["endCursor"]
        if not cursor or cursor in seen:
            raise RuntimeError("GitHub returned an invalid pagination cursor")
        seen.add(cursor)


def visible_text(body):
    """Ignore examples in fenced code and HTML comments when deriving state."""
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    lines = []
    fence = None
    for line in body.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if marker and fence is None:
            fence = marker[1]
            lines.append("")
        elif fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            lines.append("")
        else:
            lines.append(line)
    return "\n".join(lines)


def reserved_adrs(body):
    return {int(number) for number in re.findall(
        r"(?im)^\s*Reserves:\s*ADR\s+(\d{4})\s*$", visible_text(body)
    )}


def closing_numbers(body):
    reference = rf"(?:#(\d+)|{re.escape(REPO)}#(\d+)|https://github\.com/{re.escape(REPO)}/issues/(\d+))"
    matches = re.findall(rf"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+{reference}\b", visible_text(body))
    return {int(next(part for part in match if part)) for match in matches}


def status_section(body):
    match = re.search(r"(?ims)^##\s+Status\s*\n(.*?)(?=^#{1,2}\s|\Z)", visible_text(body))
    return match.group(1).strip() if match else ""


def fetch_github():
    user = api("user")["login"]
    if user != "carlrosell":
        raise RuntimeError(f"Expected GitHub user carlrosell, got {user}; select the correct account first")
    entries = rest_pages(f"repos/{REPO}/issues?state=open&per_page=100")
    issues = [item for item in entries if "pull_request" not in item]
    labels = {item["number"]: item["labels"] for item in entries}
    query = '''query($cursor: String) { repository(owner:"carlrosell", name:"looptune") {
      pullRequests(states:OPEN, first:100, after:$cursor) {
        nodes { number title body url isDraft headRefName
          closingIssuesReferences(first:100) {
            nodes { number repository { nameWithOwner } }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }}'''
    prs = list(connection(query, ("repository", "pullRequests")))
    for pr in prs:
        refs = pr.pop("closingIssuesReferences")
        if refs["pageInfo"]["hasNextPage"]:
            query = '''query($cursor: String) { repository(owner:"carlrosell", name:"looptune") {
              pullRequest(number:NUMBER) { closingIssuesReferences(first:100, after:$cursor) {
                nodes { number repository { nameWithOwner } }
                pageInfo { hasNextPage endCursor }
              }}
            }}'''.replace("NUMBER", str(pr["number"]))
            refs["nodes"] = list(connection(query, ("repository", "pullRequest", "closingIssuesReferences")))
        canonical = {ref["number"] for ref in refs["nodes"] if ref["repository"]["nameWithOwner"].lower() == REPO}
        pr["claims"] = sorted(canonical | closing_numbers(pr["body"]))
        pr["labels"] = labels.get(pr["number"], [])
    metadata = api(f"repos/{REPO}")
    tree = api(f"repos/{REPO}/git/trees/{metadata['default_branch']}?recursive=1")
    if tree.get("truncated"):
        raise RuntimeError("GitHub truncated the default-branch tree; ADR allocation is incomplete")
    accepted = {int(match[1]) for entry in tree["tree"] if (match := ADR.fullmatch(entry["path"]))}
    return issues, prs, accepted


def label_names(item):
    return {label["name"] for label in item.get("labels", [])}


def summarize(issues, prs, accepted, local_adrs=()):
    tasks = []
    for issue in issues:
        labels = label_names(issue)
        if "task" not in labels:
            continue
        claims = [pr for pr in prs if issue["number"] in pr["claims"]]
        owners = [owner["login"] for owner in issue.get("assignees", [])]
        if "needs-owner" in labels or any("needs-owner" in label_names(pr) for pr in claims):
            state = "needs owner"
        elif "held" in labels:
            state = "held"
        elif len(claims) > 1:
            state = "conflicting PR claims"
        elif claims:
            pr = claims[0]
            complete = re.search(r"(?im)^\s*(?:[-*+]\s+)?State:\s*complete\s*$", status_section(pr["body"]))
            state = "ready review" if not pr["isDraft"] else (
                "draft complete waiting promotion" if complete else "running"
            )
        else:
            state = "running (assigned)" if owners else "ready unclaimed"
        priorities = [p for p in PRIORITIES if p in labels]
        tasks.append({"number": issue["number"], "title": issue["title"], "url": issue["html_url"],
                      "priority": priorities[0] if len(priorities) == 1 else None,
                      "state": state, "assignees": owners, "prs": [pr["number"] for pr in claims]})
    tasks.sort(key=lambda item: (PRIORITIES.index(item["priority"]) if item["priority"] else 3, item["number"]))
    reservations = set().union(*(reserved_adrs(item.get("body")) for item in issues + prs))
    taken = set(accepted) | set(local_adrs) | reservations
    return {"repository": REPO, "tasks": tasks,
            "notices": [item["number"] for item in issues if "notice" in label_names(item)],
            "needs_owner": [{"number": item["number"], "kind": kind, "title": item["title"]}
                            for kind, items in (("issue", issues), ("PR", prs))
                            for item in items if "needs-owner" in label_names(item)],
            "priority_problems": [item["number"] for item in issues
                                  if "task" in label_names(item) and len(label_names(item) & set(PRIORITIES)) != 1],
            "pull_requests": [{"number": pr["number"], "title": pr["title"], "url": pr["url"],
                               "draft": pr["isDraft"], "claims": pr["claims"],
                               "status": status_section(pr["body"])} for pr in prs],
            "reserved_adrs": sorted(reservations), "next_adr": f"{max(taken, default=-1) + 1:04d}"}


def worktrees():
    records = []
    current = {}
    for field in command(["git", "worktree", "list", "--porcelain", "-z"]).split("\0"):
        if not field:
            if current:
                records.append(current)
                current = {}
        else:
            key, _, value = field.partition(" ")
            current[key] = value or True
    if current:
        records.append(current)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-local", action="store_true", help="omit local worktrees")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--next-adr", action="store_true", help="print the next available ADR number")
    output.add_argument("--json", action="store_true", help="emit structured status")
    args = parser.parse_args()
    try:
        issues, prs, accepted = fetch_github()
        local = {int(match[1]) for path in (ROOT / "adr").glob("*.md")
                 if (match := ADR.fullmatch(path.relative_to(ROOT).as_posix()))}
        report = summarize(issues, prs, accepted, local)
        if args.next_adr:
            print(report["next_adr"])
            return 0
        if not args.no_local:
            report["worktrees"] = worktrees()
        if args.json:
            print(json.dumps(report, indent=2))
            return 0
        print(REPO)
        for item in report["needs_owner"]:
            print(f"Needs owner: {item['kind']} #{item['number']} {item['title']}")
        for number in report["notices"]:
            print(f"Notice: https://github.com/{REPO}/issues/{number}")
        for task in report["tasks"]:
            print(f"{task['priority'] or '--'} #{task['number']} [{task['state']}] {task['title']}"
                  + (f"; PRs {task['prs']}" if task["prs"] else ""))
        for pr in report["pull_requests"]:
            print(f"PR #{pr['number']} {'draft' if pr['draft'] else 'ready'}: {pr['title']}; claims {pr['claims']}")
            for line in pr["status"].splitlines()[:4]:
                print(f"  {line}")
        if report["priority_problems"]:
            print(f"Missing or multiple priority labels: {report['priority_problems']}")
        print(f"Next ADR: {report['next_adr']} (reserve it in an issue or PR)")
        for tree in report.get("worktrees", []):
            print(f"Worktree: {tree['worktree']} ({tree.get('branch', 'detached')})")
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"status: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
