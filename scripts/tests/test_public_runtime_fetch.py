import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIN = "1234567890abcdef1234567890abcdef12345678"
POWERSHELL = os.environ.get("BURROW_TEST_POWERSHELL") or shutil.which("pwsh") or shutil.which("powershell")


def workflow_script(filename: str, step_name: str) -> str:
    workflow = (ROOT / ".github" / "workflows" / filename).read_text(encoding="utf-8")
    step = workflow.split(f"      - name: {step_name}\n", 1)[1].split("      - name:", 1)[0]
    body = step.split("        run: |\n", 1)[1]
    lines = []
    for line in body.splitlines():
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines) + "\n"


def fixture_environment(root: Path, scenario: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in list(env):
        if key in {"ENGINE_PAT", "GH_TOKEN", "GITHUB_TOKEN"} or key.startswith("GIT_CONFIG_"):
            del env[key]
    env.update(
        RUNNER_TEMP=str(root / "runner temp"),
        GITHUB_ENV=str(root / "github-env"),
        GIT_TERMINAL_PROMPT="0",
        BURROW_FETCH_SCENARIO=scenario,
        BURROW_FETCH_LOG=str(root / "calls"),
        BURROW_FETCH_PIN=PIN,
    )
    Path(env["RUNNER_TEMP"]).mkdir()
    Path(env["GITHUB_ENV"]).touch()
    return env


class PublicRuntimeFetchTests(unittest.TestCase):
    def test_macos_fetch_executes_without_credentials_and_fails_closed(self) -> None:
        script = workflow_script("release.yml", "Fetch bundled burrow-engine (outside the work tree)")
        for scenario in ("success", "missing", "not-gitlink", "bad-hash", "ls-tree", "clone", "checkout"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="burrow fetch ") as directory:
                root = Path(directory)
                env = fixture_environment(root, scenario)
                fake_bin = root / "bin"
                fake_bin.mkdir()
                fake_git = fake_bin / "git"
                fake_git.write_text(textwrap.dedent("""\
                    #!/bin/bash
                    set -eu
                    printf '%s\\n' "$*" >> "$BURROW_FETCH_LOG"
                    case "$1" in
                      ls-tree)
                        case "$BURROW_FETCH_SCENARIO" in
                          missing) exit 0 ;;
                          not-gitlink) printf '100644 blob %s\\t%s\\n' "$BURROW_FETCH_PIN" "$3"; exit 0 ;;
                          bad-hash) printf '160000 commit invalid\\t%s\\n' "$3"; exit 0 ;;
                        esac
                        printf '160000 commit %s\\t%s\\n' "$BURROW_FETCH_PIN" "$3"
                        [ "$BURROW_FETCH_SCENARIO" != ls-tree ] || exit 21
                        ;;
                      clone)
                        [ "$BURROW_FETCH_SCENARIO" != clone ] || exit 22
                        mkdir -p "${!#}"
                        ;;
                      -C)
                        [ "$5" = checkout ] || exit 99
                        [ "$BURROW_FETCH_SCENARIO" != checkout ] || exit 23
                        ;;
                      *) exit 99 ;;
                    esac
                    """), encoding="utf-8")
                fake_git.chmod(0o755)
                env["PATH"] = str(fake_bin) + os.pathsep + env["PATH"]
                result = subprocess.run(["bash", "-c", script], cwd=root, env=env, text=True, capture_output=True, timeout=10)
                calls = Path(env["BURROW_FETCH_LOG"]).read_text().splitlines()
                succeeded = scenario == "success"
                self.assertEqual(result.returncode == 0, succeeded, result.stdout + result.stderr)
                exported = Path(env["GITHUB_ENV"]).read_text()
                self.assertEqual(bool(exported), succeeded, exported)
                if succeeded:
                    self.assertEqual(exported, f"BURROW_ENGINE_SRC={env['RUNNER_TEMP']}/burrow-engine\n")
                expected_calls = 1 if scenario in {"missing", "not-gitlink", "bad-hash", "ls-tree"} else 2 if scenario == "clone" else 3
                self.assertEqual(len(calls), expected_calls, calls)
                if len(calls) > 1:
                    self.assertEqual(calls[1], f"clone --quiet https://github.com/caezium/burrow-engine.git {env['RUNNER_TEMP']}/burrow-engine")
                if len(calls) > 2:
                    self.assertTrue(calls[2].endswith(f"checkout --quiet {PIN}"), calls)

    @unittest.skipUnless(POWERSHELL, "PowerShell is required to execute the Windows workflow block")
    def test_windows_fetch_build_and_stage_fail_closed_without_credentials(self) -> None:
        script = workflow_script("windows-release.yml", "Build + stage burrow conductor")
        # These fake native commands replace Git/Cargo before executing the exact
        # workflow block. Only fixture files are created; no build or network runs.
        prelude = r"""
function git {
    Add-Content -LiteralPath $env:BURROW_FETCH_LOG -Value ('git ' + ($args -join ' '))
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'ls-tree' {
            switch ($env:BURROW_FETCH_SCENARIO) {
                'missing' { return }
                'not-gitlink' { "100644 blob $env:BURROW_FETCH_PIN`t$($args[2])"; return }
                'bad-hash' { "160000 commit invalid`t$($args[2])"; return }
                'ls-tree' { $global:LASTEXITCODE = 21 }
            }
            "160000 commit $env:BURROW_FETCH_PIN`t$($args[2])"
        }
        'clone' {
            if ($env:BURROW_FETCH_SCENARIO -eq 'clone') { $global:LASTEXITCODE = 22; return }
            [IO.Directory]::CreateDirectory($args[-1]) | Out-Null
            Get-ChildItem -LiteralPath $env:BURROW_FETCH_SOURCE -Force | Copy-Item -Destination $args[-1] -Recurse
        }
        '-C' {
            if ($args[4] -ne 'checkout') { throw 'Unexpected Git command' }
            if ($env:BURROW_FETCH_SCENARIO -eq 'checkout') { $global:LASTEXITCODE = 23 }
        }
        default { throw 'Unexpected Git command' }
    }
}
function cargo {
    Add-Content -LiteralPath $env:BURROW_FETCH_LOG -Value ('cargo ' + ($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($env:BURROW_FETCH_SCENARIO -eq 'build') { $global:LASTEXITCODE = 24; return }
    if ($env:BURROW_FETCH_SCENARIO -eq 'missing-artifact') { return }
    $release = Join-Path $env:RUNNER_TEMP 'burrow-cli/target/release'
    [IO.Directory]::CreateDirectory($release) | Out-Null
    [IO.File]::WriteAllText((Join-Path $release 'burrow.exe'), 'fixture artifact')
}
"""
        notice_names = ("LICENSE.md", "NOTICE", "THIRD-PARTY-LICENSES.md",
                        "LICENSES/cargo-packages.json", "LICENSES/cargo/example-1.2.3/LICENSE-MIT")
        license_files = {name: f"fixture {name}" for name in notice_names}
        license_files["LICENSES/cargo-packages.json"] = json.dumps([
            {"name": "example", "version": "1.2.3", "texts": [{"file": notice_names[-1]}]}
        ])
        # Copy the full tree, including notices not individually named by the inventory.
        license_files["LICENSES/cargo/example-1.2.3/NOTICE"] = "additional fixture notice"
        scenarios = ("success", "missing", "not-gitlink", "bad-hash", "ls-tree", "clone", "checkout", "build", "missing-artifact")
        scenarios += tuple(f"{kind}:{name}" for kind in ("missing-notice", "empty-notice") for name in notice_names)
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="burrow fetch ") as directory:
                root = Path(directory)
                env = fixture_environment(root, scenario)
                fixture_source = root / "cli source"
                env["BURROW_FETCH_SOURCE"] = str(fixture_source)
                for name, contents in {**license_files, "private.p8": "fake fixture key", "main.rs": "// fixture source"}.items():
                    path = fixture_source / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    if scenario == f"missing-notice:{name}":
                        continue
                    path.write_text("" if scenario == f"empty-notice:{name}" else contents)
                (root / "windows" / "Assets").mkdir(parents=True)
                runner = root / "fetch.ps1"
                runner.write_text(prelude + script, encoding="utf-8")
                result = subprocess.run([POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(runner)], cwd=root, env=env, text=True, capture_output=True, timeout=20)
                calls = Path(env["BURROW_FETCH_LOG"]).read_text().splitlines()
                succeeded = scenario == "success"
                self.assertEqual(result.returncode == 0, succeeded, result.stdout + result.stderr)
                artifact = root / "windows" / "Assets" / "burrow.exe"
                self.assertEqual(artifact.exists(), succeeded, result.stdout + result.stderr)
                if succeeded:
                    self.assertEqual(artifact.read_text(), "fixture artifact")
                    notices = root / "windows/Assets/licenses/burrow-cli"
                    for name, contents in license_files.items():
                        self.assertEqual((notices / name).read_text(), contents)
                    packaged = {path.relative_to(artifact.parent).as_posix() for path in artifact.parent.rglob("*") if path.is_file()}
                    self.assertEqual(packaged, {"burrow.exe"} | {"licenses/burrow-cli/" + name for name in license_files})
                incomplete_notices = scenario.startswith(("missing-notice:", "empty-notice:"))
                if incomplete_notices:
                    self.assertIn("Required CLI license notice is missing or empty", result.stderr)
                expected_calls = 1 if scenario in {"missing", "not-gitlink", "bad-hash", "ls-tree"} else 2 if scenario == "clone" else 3 if scenario == "checkout" or incomplete_notices else 4
                self.assertEqual(len(calls), expected_calls, calls)
                if len(calls) > 1:
                    self.assertIn("git clone --quiet https://github.com/caezium/burrow-cli.git ", calls[1])
                if len(calls) > 2:
                    self.assertTrue(calls[2].endswith(f"checkout --quiet {PIN}"), calls)
                if len(calls) > 3:
                    self.assertIn("cargo build --release --manifest-path ", calls[3])

    def test_windows_publish_includes_extensionless_cli_notices(self) -> None:
        project = ET.parse(ROOT / "windows/BurrowWin.csproj")
        content = [node for node in project.findall(".//Content")
                   if node.get("Include") == r"Assets\licenses\burrow-cli\**\*"]
        self.assertEqual(len(content), 1)
        self.assertEqual(content[0].get("CopyToOutputDirectory"), "PreserveNewest")
        self.assertEqual(content[0].get("CopyToPublishDirectory"), "PreserveNewest")


if __name__ == "__main__":
    unittest.main()
