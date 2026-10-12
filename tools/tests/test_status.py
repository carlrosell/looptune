import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import status


def issue(number, labels=("task", "p2"), assignees=(), body=""):
    return {"number": number, "title": f"Task {number}", "html_url": f"https://github.com/{status.REPO}/issues/{number}",
            "labels": [{"name": label} for label in labels], "assignees": [{"login": owner} for owner in assignees], "body": body}


def pr(number, claims=(), draft=False, body=""):
    return {"number": number, "title": f"PR {number}", "url": "https://github.com/example", "claims": list(claims),
            "labels": [], "isDraft": draft, "body": body}


class StatusTests(unittest.TestCase):
    def test_claims_are_repository_scoped_and_ignore_examples(self):
        body = """Closes #12. Fixes carlrosell/looptune#13.
Resolves https://github.com/carlrosell/looptune/issues/14
Fixes other/repo#99
<!-- Closes #98 -->
```
Closes #97
```
"""
        self.assertEqual(status.closing_numbers(body), {12, 13, 14})

    def test_reservations_require_explicit_lines_and_skip_fenced_examples(self):
        self.assertEqual(status.reserved_adrs("""Reserves: ADR 0012
Reserves: ADR 0020
ADR 0099 is just a reference.
```
Reserves: ADR 9999
```
"""), {12, 20})

    def test_longer_and_unclosed_fences_cannot_claim_work_or_reserve_adrs(self):
        for opener, closer in (("```text", "````"), ("~~~text", "~~~~~")):
            with self.subTest(opener=opener):
                body = f"{opener}\nReserves: ADR 9999\nCloses #97\n{closer}\nReserves: ADR 0003\nCloses #4"
                self.assertEqual(status.reserved_adrs(body), {3})
                self.assertEqual(status.closing_numbers(body), {4})
                self.assertEqual(status.summarize([issue(1, body=body)], [], {0, 1, 2})["next_adr"], "0004")
        unterminated = "Reserves: ADR 0003\nCloses #4\n```text\nReserves: ADR 9999\nCloses #97"
        self.assertEqual(status.reserved_adrs(unterminated), {3})
        self.assertEqual(status.closing_numbers(unterminated), {4})

    def test_fence_closers_require_matching_character_sufficient_length_and_no_text(self):
        body = """````text
```
Closes #91
~~~~
Closes #92
````text
Closes #93
````
Closes #4
"""
        self.assertEqual(status.closing_numbers(body), {4})

    def test_task_states_priorities_and_assignments(self):
        issues = [issue(1, assignees=("carlrosell",)), issue(2, ("task", "p1")), issue(3), issue(4),
                  issue(5, ("task", "needs-owner")), issue(6, ("task", "p2", "p3")), issue(7)]
        prs = [pr(10, (3,), True, "## Status\nState: complete\nDone: verified\n"), pr(11, (4,)), pr(12, (7,), True)]
        report = status.summarize(issues, prs, {0, 1})
        by_number = {task["number"]: task for task in report["tasks"]}
        self.assertEqual(by_number[1]["state"], "running (assigned)")
        self.assertEqual(by_number[2]["state"], "ready unclaimed")
        self.assertEqual(by_number[3]["state"], "draft complete waiting promotion")
        self.assertEqual(by_number[4]["state"], "ready review")
        self.assertEqual(by_number[5]["state"], "needs owner")
        self.assertEqual(by_number[7]["state"], "running")
        self.assertEqual(report["priority_problems"], [5, 6])
        self.assertEqual(report["tasks"][0]["number"], 2)

    def test_multiple_claims_are_visible_and_status_does_not_leak_sections(self):
        report = status.summarize([issue(1)], [pr(2, (1,)), pr(3, (1,))], set())
        self.assertEqual(report["tasks"][0]["state"], "conflicting PR claims")
        self.assertEqual(status.status_section("## Status\nState: running\n## Validation\nState: complete"), "State: running")

    def test_bulleted_completion_and_hold_precedence_match_workflow(self):
        issues = [issue(1), issue(2, ("task", "p2", "held"), ("carlrosell",)),
                  issue(3, ("task", "p2", "held", "needs-owner")), issue(4, ("task", "p2", "held"))]
        prs = [pr(10, (1,), True, "## Status\n- State: complete\n- Done: verified\n"),
               pr(11, (2,)), pr(12, (3,), True)]
        tasks = {task["number"]: task for task in status.summarize(issues, prs, set())["tasks"]}
        self.assertEqual(tasks[1]["state"], "draft complete waiting promotion")
        self.assertEqual(tasks[2]["state"], "held")
        self.assertEqual(tasks[3]["state"], "needs owner")
        self.assertEqual(tasks[4]["state"], "held")

    def test_only_task_issues_require_a_priority(self):
        issues = [issue(1, ("notice",)), issue(2, ()), issue(3, ("task",)), issue(4, ("task", "p1", "p2"))]
        report = status.summarize(issues, [], set())
        self.assertEqual(report["priority_problems"], [3, 4])

    def test_next_adr_includes_remote_local_and_live_reservations(self):
        report = status.summarize([issue(1, body="Reserves: ADR 0012")], [pr(2, body="Reserves: ADR 0015")], {0, 9}, {16})
        self.assertEqual(report["next_adr"], "0017")
        self.assertEqual(report["reserved_adrs"], [12, 15])

    def test_connection_reads_every_page_and_refuses_broken_cursors(self):
        def page(nodes, more, cursor):
            return {"data": {"items": {"nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": cursor}}}}
        with patch.object(status, "api", side_effect=[page([1], True, "a"), page([2], False, "b")]) as api:
            self.assertEqual(list(status.connection("query", ("items",))), [1, 2])
            self.assertIn("cursor=a", api.call_args.args)
        with patch.object(status, "api", return_value=page([], True, "a")):
            with self.assertRaisesRegex(RuntimeError, "pagination cursor"):
                list(status.connection("query", ("items",)))

    def test_wrong_account_and_api_failures_are_not_empty_success(self):
        with patch.object(status, "api", return_value={"login": "nullwrap"}) as api:
            with self.assertRaisesRegex(RuntimeError, "Expected GitHub user carlrosell"):
                status.fetch_github()
            self.assertEqual(api.call_count, 1)
        with patch.object(status, "command", return_value='{"errors":[{"message":"unavailable"}]}'):
            with self.assertRaisesRegex(RuntimeError, "GraphQL error"):
                status.api("graphql")
        with patch.object(status, "api", return_value={"message": "error"}):
            with self.assertRaisesRegex(RuntimeError, "Unexpected paginated response"):
                status.rest_pages("endpoint")

    def test_live_reader_preserves_canonical_claims_and_detects_truncated_tree(self):
        pull = {"number": 4, "title": "Change", "body": "Closes #3", "url": "https://github.com/example",
                "isDraft": False, "headRefName": "change", "closingIssuesReferences": {
                    "nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "more"}}}
        references = [{"number": 1, "repository": {"nameWithOwner": status.REPO}},
                      {"number": 99, "repository": {"nameWithOwner": "other/repository"}}]
        responses = [{"login": "carlrosell"}, {"default_branch": "main"},
                     {"truncated": False, "tree": [{"path": "adr/0002-verification.md"}]}]
        with patch.object(status, "api", side_effect=responses), \
                patch.object(status, "rest_pages", return_value=[issue(1)]), \
                patch.object(status, "connection", side_effect=[[pull], references]):
            _, prs, accepted = status.fetch_github()
            self.assertEqual(prs[0]["claims"], [1, 3])
            self.assertEqual(accepted, {2})
        with patch.object(status, "api", side_effect=[{"login": "carlrosell"}, {"default_branch": "main"}, {"truncated": True}]), \
                patch.object(status, "rest_pages", return_value=[]), \
                patch.object(status, "connection", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "truncated"):
                status.fetch_github()


if __name__ == "__main__":
    unittest.main()
