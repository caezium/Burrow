import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_tap_permission_check_runs_before_the_release_build(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        require_credentials = workflow.index("- name: Require release credentials")
        verify_tap = workflow.index("- name: Verify Homebrew tap write access")
        build_release = workflow.index("- name: Build (Release)")

        self.assertLess(require_credentials, verify_tap)
        self.assertLess(verify_tap, build_release)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow[verify_tap:build_release],
        )

    def test_manual_tap_check_uses_the_same_isolated_verifier(self) -> None:
        workflow = (WORKFLOWS / "homebrew-tap-credential-check.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow,
        )
        self.assertIn("persist-credentials: false", workflow)

    def test_tap_verifier_pushes_and_removes_a_temporary_ref(self) -> None:
        verifier = (ROOT / "scripts" / "verify-homebrew-tap-access.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("burrow-release-access-probe-", verifier)
        self.assertIn('push --quiet origin "HEAD:$probe_ref"', verifier)
        self.assertIn('push --quiet origin ":$probe_ref"', verifier)
        self.assertNotIn('push --dry-run origin "HEAD:$probe_ref"', verifier)

    def test_release_does_not_leak_engine_credentials_into_tap_push(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
        tap_start = workflow.index(
            "- name: Bump Homebrew cask in caezium/homebrew-tap"
        )
        tap_step = workflow[tap_start:]

        # `persist-credentials: false` has to be on the CHECKOUT, not merely somewhere in the
        # file — a bare `assertIn` over the whole workflow passes even if the flag drifts onto
        # an unrelated step and the checkout starts leaving GITHUB_TOKEN in .git/config for the
        # tap push to reuse. Pin it to the one `actions/checkout` step this job runs.
        checkout_start = workflow.index("- uses: actions/checkout@")
        checkout_step = workflow[checkout_start : workflow.index("- name:", checkout_start)]
        self.assertIn("persist-credentials: false", checkout_step)
        self.assertEqual(
            workflow.count("- uses: actions/checkout@"),
            1,
            "a second checkout step would need its own persist-credentials assertion",
        )
        # The tap is `git clone`d rather than checked out, so it never inherits the runner's
        # credentials; what it must not do is install a global rewrite that would.
        self.assertNotIn("git config --global url.", workflow)
        self.assertNotIn("actions/checkout@", tap_step)

        # This used to assert `export GIT_CONFIG_COUNT=1` in the build step: a
        # process-scoped URL rewrite, so ENGINE_PAT could reach the private
        # burrow-engine crate during the conductor's cargo build without becoming
        # the credential the later Homebrew push used. The repoint deleted the
        # conductor, and burrow-engine's own Cargo.toml has no git dependencies,
        # so there is nothing left in the build that needs to authenticate to
        # GitHub. Not having the token in the step at all is strictly stronger
        # than scoping the rewrite, so that is what gets pinned now.
        build_start = workflow.index("- name: Build (Release)")
        build_end = workflow.index(
            "- name: Verify the bundled engine made it into the app"
        )
        build_step = workflow[build_start:build_end]
        self.assertNotIn(
            "ENGINE_PAT: ${{ secrets.ENGINE_PAT }}",
            build_step,
            "the release build must not receive the engine token at all",
        )
        self.assertNotIn("CARGO_NET_GIT_FETCH_WITH_CLI", build_step)

        # Neither the checkout nor the tap push may receive the engine token — INCLUDING by
        # inheritance, which a per-step search cannot see. A workflow- or job-level `env:` block
        # is handed to every step in the job, so ENGINE_PAT declared there would reach the tap
        # push while each step's own text stayed clean. Step-level `env:` sits at 8 spaces here;
        # anything shallower is an outer block.
        for name, step in (("checkout", checkout_step), ("tap push", tap_step)):
            self.assertNotIn(
                "ENGINE_PAT", step, f"the {name} step must not see the engine token"
            )
        self.assertEqual(
            workflow.count("ENGINE_PAT: ${{ secrets.ENGINE_PAT }}"),
            1,
            "the engine token belongs to the fetch step alone",
        )
        for line in workflow.splitlines():
            stripped = line.lstrip()
            if stripped == "env:":
                self.assertGreaterEqual(
                    len(line) - len(stripped),
                    8,
                    "workflow- or job-level `env:` is inherited by every step, including the "
                    f"tap push — keep env step-scoped: {line!r}",
                )

        # ENGINE_PAT survives only in the fetch step, where every use is scoped
        # to one `git -c` invocation that writes no config anywhere.
        for line in workflow.splitlines():
            if "insteadOf" in line:
                self.assertIn('git -c "url.', line)
        self.assertIn(
            'export GIT_CONFIG_GLOBAL="$RUNNER_TEMP/burrow-tap-gitconfig"',
            tap_step,
        )
        self.assertIn('(cd "$RUNNER_TEMP" && git clone', tap_step)
        self.assertIn('cd "$TAP_DIR"', tap_step)

    def test_release_notes_are_validated_before_sparkle_embeds_them(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        validate = workflow.index("scripts/validate-release-notes.py")
        embed = workflow.index('cp RELEASES.md "dist/Burrow-${VERSION}.md"')

        self.assertLess(validate, embed)

    def test_manual_notes_repair_is_narrow_and_fail_closed(self) -> None:
        workflow = (WORKFLOWS / "repair-sparkle-release-notes.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("group: release", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn('if [ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]', workflow)
        self.assertIn("scripts/validate-release-notes.py", workflow)
        self.assertIn("scripts/verify-sparkle-appcast.py", workflow)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", workflow)
        self.assertIn('gh release upload "$TAG" "$APPCAST"', workflow)
        self.assertIn("--clobber", workflow)
        self.assertIn('gh release edit "$TAG"', workflow)
        self.assertIn("--notes-file RELEASES.md", workflow)
        self.assertNotIn('gh release upload "$TAG" "$ZIP"', workflow)
        self.assertIn('sign_update" --verify', workflow)

        verify_start = workflow.index("- name: Verify the published repair")
        verify_step = workflow[verify_start:]
        self.assertIn(
            "ASSET_NAME: ${{ steps.target.outputs.asset_name }}", verify_step
        )
        self.assertIn(
            "EXPECTED_DIGEST: ${{ steps.target.outputs.asset_digest }}", verify_step
        )
        self.assertIn(
            'if [ "$PUBLISHED_DIGEST" != "$EXPECTED_DIGEST" ]', verify_step
        )

    def test_xcode_27_preview_lane_is_advisory_and_runs_the_full_suite(self) -> None:
        workflow = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        start = workflow.index("  xcode-27-compatibility:")
        end = workflow.index("  fclones-sidecar:", start)
        job = workflow[start:end]

        self.assertIn("runs-on: xcode-27", job)
        self.assertIn("continue-on-error: true", job)
        self.assertIn("bash ../scripts/fetch-sentry.sh", job)
        self.assertIn("bash ../scripts/fetch-sparkle.sh", job)
        self.assertIn("xcodegen generate", job)
        self.assertIn("xcodebuild test", job)


if __name__ == "__main__":
    unittest.main()
