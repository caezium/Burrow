import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "sentry-issues.yml"


class SentryIssuesWorkflowTests(unittest.TestCase):
    def test_app_hangs_are_aggregated_instead_of_silently_skipped(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertNotIn("Skipping App-Hang issue", workflow)
        self.assertIn("[Sentry] App-Hang digest", workflow)
        self.assertIn("gh issue edit", workflow)
        self.assertIn("sentry-id: ${shortId}", workflow)

    def test_hang_digests_are_bounded_and_roll_into_numbered_parts(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('MAX_HANG_GROUPS_PER_RUN: "20"', workflow)
        self.assertIn('MAX_HANG_TRACE_CHARS: "1200"', workflow)
        self.assertIn('MAX_ISSUE_BODY_BYTES: "60000"', workflow)
        self.assertIn('digest_title="${digest_base_title} — part ${digest_part}"', workflow)
        self.assertIn("existing_bytes + section_bytes", workflow)

    def test_sentry_issue_poll_follows_cursor_pagination(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('MAX_SENTRY_PAGES_PER_PROJECT: "100"', workflow)
        self.assertIn('-D "$headers" -o "$page"', workflow)
        self.assertIn("'rel=\"next\"'", workflow)
        self.assertIn("'results=\"true\"'", workflow)
        self.assertIn('done < "$response_rows"', workflow)

    def test_hang_digest_carries_bounded_release_and_launch_context(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('select(.key=="os_build")', workflow)
        self.assertIn('select(.key=="launch_phase")', workflow)
        self.assertIn('select(.key=="status_item_state")', workflow)
        self.assertIn(".release.version", workflow)

    def test_regular_issues_carry_the_same_launch_context(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(r'| **Release** | \`${release}\` |', workflow)
        self.assertIn(r'| **OS build** | \`${osBuild}\` |', workflow)
        self.assertIn(r'| **Launch phase** | \`${launchPhase}\` |', workflow)
        self.assertIn(r'| **Status item** | \`${statusItem}\` |', workflow)

    def test_release_shape_is_checked_before_reading_its_version(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('if (.release | type) == "object"', workflow)
        self.assertIn('elif (.release | type) == "string"', workflow)


if __name__ == "__main__":
    unittest.main()
