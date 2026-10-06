"""Regression coverage with no network, sudo, or host systemd operations."""

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
COMMAND_FIXTURE = Path(__file__).with_name("fake_command.py")


class RunnerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="runner-lifecycle-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.home = self.root / "home"
        self.bin = self.root / "commands"
        for directory in (self.repo, self.home, self.bin, self.root / "systemd", self.root / "tmp"):
            directory.mkdir()
        for source in REPOSITORY.glob("*.sh"):
            shutil.copy2(source, self.repo / source.name)
        shutil.copy2(REPOSITORY / "github-runner.service.template", self.repo)
        self.mock = self.root / "fake_command.py"
        self.mock.write_text("#!" + sys.executable + "\n" + COMMAND_FIXTURE.read_text())
        self.mock.chmod(0o755)
        for name in ("sudo", "systemctl", "curl", "uname", "id", "stat", "rm", "mkdir"):
            (self.bin / name).symlink_to(self.mock)
        self.state = {"units": {}}
        self.save_state()
        self.config_script = '#!/bin/bash\nexec "$TEST_PYTHON" "$TEST_COMMAND" --mock-command config "$@"\n'
        package = self.root / "package.tar.gz"
        with tarfile.open(package, "w:gz") as archive:
            for name, contents in {"config.sh": self.config_script, "bin/runsvc.sh": "#!/bin/bash\nexit 0\n", "run.sh": "#!/bin/bash\nexit 0\n"}.items():
                encoded = contents.encode()
                member = tarfile.TarInfo(name)
                member.size = len(encoded)
                member.mode = 0o755
                archive.addfile(member, io.BytesIO(encoded))
        self.checksum = hashlib.sha256(package.read_bytes()).hexdigest()
        self.write_env()
        (self.repo / "repos.txt").write_text("demo/project\n")
        self.env = os.environ.copy()
        self.env.update({"HOME": str(self.home), "TMPDIR": str(self.root / "tmp"), "PATH": str(self.bin) + os.pathsep + os.environ["PATH"], "TEST_ROOT": str(self.root), "TEST_COMMAND": str(self.mock), "TEST_PYTHON": sys.executable})

    def save_state(self):
        (self.root / "state.json").write_text(json.dumps(self.state))

    def write_env(self, **overrides):
        values = {"GITHUB_PAT": "fixture-only-token", "RUNNER_VERSION": "9.9.9", "ARCH": "arm64", "LABELS": "self-hosted,test", "RUNNER_SHA256": self.checksum}
        values.update(overrides)
        (self.repo / ".env").write_text("".join(name + "=" + shlex.quote(value) + "\n" for name, value in values.items()))

    def run_script(self, name, *args):
        # A different working directory catches accidental relative config paths.
        return subprocess.run(["bash", str(self.repo / name), *args], cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20)

    def run_helper(self, body):
        script = 'set -euo pipefail; SCRIPT_DIR="$1"; source "$SCRIPT_DIR/utils.sh"; ' + body
        return subprocess.run(["bash", "-c", script, "fixture", str(self.repo)], cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20)

    def calls(self, command=None):
        path = self.root / "commands.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if command is None or call["command"] == command]

    def mutations(self):
        return [call for call in self.calls() if call["command"] in {"sudo", "config", "install", "rm", "mkdir"} or call["command"] == "curl" or call["command"] == "systemctl" and call["args"][0] in {"stop", "disable", "start", "enable", "daemon-reload"}]

    def assert_succeeded(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def add_runner(self, repo="demo/project", *, marker=True, active=False, foreign=False, url=True):
        name = repo.replace("/", "_")
        directory = self.home / "github-runners" / name
        directory.mkdir(parents=True)
        (directory / "config.sh").write_text(self.config_script)
        (directory / "config.sh").chmod(0o755)
        (directory / "bin").mkdir()
        (directory / "bin" / "runsvc.sh").write_text("#!/bin/bash\nexit 0\n")
        (directory / ".runner").write_text(json.dumps({"gitHubUrl": "https://github.com/" + repo} if url else {}))
        (directory / ".credentials").write_text("fixture credentials\n")
        if marker:
            (directory / ".pi-runner-repo").write_text(repo + "\n")
        self.state["units"]["github-runner@" + name + ".service"] = {"LoadState": "loaded", "User": "another-user" if foreign else "runner-test", "WorkingDirectory": str(directory), "FragmentPath": "/etc/systemd/system/github-runner@" + name + ".service", "active": active}
        self.save_state()
        return directory

    def test_missing_repository_list_does_not_mutate(self):
        directory = self.add_runner("demo/old")
        for command in ("register_all.sh", "sync.sh"):
            with self.subTest(command=command):
                (self.repo / "repos.txt").unlink(missing_ok=True)
                result = self.run_script(command)
                self.assert_failed(result)
                self.assertTrue((directory / ".runner").exists())
                self.assertEqual(self.mutations(), [])

    def test_parser_handles_comments_crlf_duplicates_and_final_line(self):
        (self.repo / "repos.txt").write_bytes(b"# ignored\r\n \r\n demo/first \r\ndemo/first\r\ndemo/last_repo")
        result = self.run_helper('init_config; load_repos; printf "%s\\n" "${REPOSITORIES[@]}"')
        self.assert_succeeded(result)
        self.assertEqual(result.stdout.splitlines(), ["demo/first", "demo/last_repo"])
        self.assertEqual(self.mutations(), [])

    def test_malformed_input_is_rejected_before_any_mutation(self):
        directory = self.add_runner("demo/old")
        (self.repo / "repos.txt").write_text("demo/project\ninvalid/repo/extra\n")
        for command in ("register_all.sh", "sync.sh"):
            with self.subTest(command=command):
                self.assert_failed(self.run_script(command))
                self.assertTrue(directory.exists())
                self.assertEqual(self.mutations(), [])

    def test_api_error_responses_are_failures(self):
        for helper in ("get_runner_token", "get_removal_token"):
            for failure in ("http", "transport", "null", "missing", "invalid_json"):
                with self.subTest(helper=helper, failure=failure):
                    self.state["api_failure"] = failure
                    self.save_state()
                    result = self.run_helper('init_config; ' + helper + ' demo/project')
                    self.assert_failed(result)
                    self.assertNotIn("fixture-only-token", result.stdout + result.stderr)

    def test_removal_token_uses_removal_endpoint(self):
        result = self.run_helper('init_config; get_removal_token demo/project')
        self.assert_succeeded(result)
        self.assertEqual(result.stdout.strip(), "removal-token")
        self.assertTrue(self.calls("curl")[-1]["args"][-1].endswith("/actions/runners/remove-token"))

    def test_failed_download_never_installs_service(self):
        self.state["download_failure"] = True
        self.save_state()
        self.assert_failed(self.run_script("install_runner.sh", "demo/project", "registration-token"))
        self.assertEqual(self.calls("sudo"), [])
        self.assertEqual(self.calls("config"), [])

    def test_unregister_cleans_marker_only_failed_download_without_api(self):
        self.state["download_failure"] = True
        self.save_state()
        self.assert_failed(self.run_script("install_runner.sh", "demo/project", "registration-token"))
        directory = self.home / "github-runners" / "demo_project"
        self.assertEqual((directory / ".pi-runner-repo").read_text().strip(), "demo/project")
        self.assertFalse((directory / ".runner").exists())
        self.assertFalse((directory / "config.sh").exists())
        (self.root / "commands.jsonl").write_text("")
        self.assert_succeeded(self.run_script("unregister_all.sh"))
        self.assertFalse(directory.exists())
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.calls("config"), [])

    def test_installer_preserves_existing_unmanaged_destination(self):
        directory = self.home / "github-runners" / "demo_project"
        directory.mkdir(parents=True)
        unrelated = directory / "personal-notes.txt"
        unrelated.write_text("keep this user data\n")
        self.assert_failed(self.run_script("install_runner.sh", "demo/project", "registration-token"))
        self.assertEqual(unrelated.read_text(), "keep this user data\n")
        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["personal-notes.txt"])
        self.assertEqual(self.mutations(), [])

    def test_checksum_mismatch_never_configures_or_installs(self):
        self.write_env(RUNNER_SHA256="0" * 64)
        self.assert_failed(self.run_script("install_runner.sh", "demo/project", "registration-token"))
        self.assertEqual(self.calls("config"), [])
        self.assertEqual(self.calls("sudo"), [])

    def test_failed_registration_never_installs_service(self):
        self.state["config_failure"] = True
        self.save_state()
        self.assert_failed(self.run_script("install_runner.sh", "demo/project", "registration-token"))
        self.assertEqual(len(self.calls("config")), 1)
        self.assertEqual(self.calls("sudo"), [])

    def test_failed_service_start_preserves_configured_runner_and_reports_failure(self):
        self.state["start_failure"] = True
        self.save_state()
        result = self.run_script("install_runner.sh", "demo/project", "registration-token")
        self.assert_failed(result)
        directory = self.home / "github-runners" / "demo_project"
        self.assertEqual(json.loads((directory / ".runner").read_text())["gitHubUrl"], "https://github.com/demo/project")
        self.assertTrue((directory / ".credentials").is_file())
        self.assertTrue((directory / ".pi-runner-repo").is_file())
        self.assertNotIn("configured and its service is started", result.stdout + result.stderr)

    def test_amd64_downloads_x64_and_installs_service_entry_point(self):
        self.write_env(ARCH="amd64")
        result = self.run_script("install_runner.sh", "demo/project", "registration-token")
        self.assert_succeeded(result)
        url = self.calls("curl")[0]["args"][-1]
        self.assertIn("actions-runner-linux-x64-9.9.9.tar.gz", url)
        directory = self.home / "github-runners" / "demo_project"
        self.assertTrue((directory / "runsvc.sh").is_file())
        self.assertEqual((directory / ".pi-runner-repo").read_text().strip(), "demo/project")
        unit = (self.root / "systemd" / "github-runner@demo_project.service").read_text()
        self.assertIn('ExecStart="' + str(directory) + '/runsvc.sh"', unit)

    def test_inactive_configured_runner_restarts_without_api(self):
        directory = self.add_runner(active=False)
        self.state["api_failure"] = "http"
        self.save_state()
        result = self.run_script("register_all.sh")
        self.assert_succeeded(result)
        self.assertTrue(directory.exists())
        self.assertEqual(self.calls("curl"), [])
        self.assertTrue(any("start" in call["args"] for call in self.calls("systemctl")))

    def test_unregister_finds_runner_absent_from_desired_list(self):
        directory = self.add_runner("demo/removed_from_list")
        result = self.run_script("unregister_all.sh")
        self.assert_succeeded(result)
        self.assertFalse(directory.exists())
        self.assertTrue(self.calls("curl")[0]["args"][-1].endswith("/repos/demo/removed_from_list/actions/runners/remove-token"))

    def test_legacy_name_preserves_repository_underscores(self):
        directory = self.add_runner("demo/repo_with_underscores", marker=False, url=False)
        result = self.run_script("sync.sh")
        self.assert_succeeded(result)
        self.assertFalse(directory.exists())
        urls = [call["args"][-1] for call in self.calls("curl")]
        self.assertTrue(any(url.endswith("/repos/demo/repo_with_underscores/actions/runners/remove-token") for url in urls))

    def test_failed_stop_preserves_registration_and_files(self):
        directory = self.add_runner()
        self.state["stop_failure"] = True
        self.save_state()
        self.assert_failed(self.run_script("unregister_all.sh"))
        self.assertTrue((directory / ".runner").exists())
        self.assertTrue((directory / ".credentials").exists())
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.calls("config"), [])
        self.assertEqual(self.calls("rm"), [])

    def test_failed_deregistration_preserves_local_recovery_state(self):
        directory = self.add_runner()
        self.state["remove_failure"] = True
        self.save_state()
        self.assert_failed(self.run_script("unregister_all.sh"))
        self.assertTrue((directory / ".runner").exists())
        self.assertTrue((directory / ".credentials").exists())
        self.assertTrue((directory / ".pi-runner-repo").exists())
        self.assertEqual(self.calls("rm"), [])
        self.assertFalse(any("disable" in call["args"] for call in self.calls("systemctl")))

    def test_failed_removal_token_preserves_local_recovery_state(self):
        directory = self.add_runner()
        self.state["api_failure"] = "http"
        self.save_state()
        self.assert_failed(self.run_script("unregister_all.sh"))
        self.assertTrue((directory / ".runner").exists())
        self.assertTrue((directory / ".credentials").exists())
        self.assertEqual(self.calls("config"), [])
        self.assertEqual(self.calls("rm"), [])

    def test_empty_desired_list_removes_inactive_runner(self):
        directory = self.add_runner(active=False)
        (self.repo / "repos.txt").write_text("# intentionally empty\n")
        self.assert_succeeded(self.run_script("sync.sh"))
        self.assertFalse(directory.exists())
        self.assertEqual(len(self.calls("config")), 1)

    def test_unregister_preserves_unmanaged_and_symlinked_directories(self):
        runners = self.home / "github-runners"
        runners.mkdir()
        unmanaged = runners / "notes"
        unmanaged.mkdir()
        (unmanaged / "keep.txt").write_text("unrelated user data\n")
        external = self.root / "other-data"
        external.mkdir()
        (external / "keep.txt").write_text("outside managed directory\n")
        (runners / "demo_symlink").symlink_to(external, target_is_directory=True)
        self.assert_succeeded(self.run_script("unregister_all.sh"))
        self.assertTrue((unmanaged / "keep.txt").exists())
        self.assertTrue((external / "keep.txt").exists())
        self.assertTrue((runners / "demo_symlink").is_symlink())
        self.assertEqual(self.mutations(), [])

    def test_foreign_unit_is_preserved(self):
        directory = self.add_runner(foreign=True)
        for command in ("unregister_all.sh", "register_all.sh"):
            with self.subTest(command=command):
                self.assert_failed(self.run_script(command))
                self.assertTrue((directory / ".runner").exists())
                self.assertEqual(self.mutations(), [])

    def test_symlinked_runner_configuration_is_rejected_before_mutation(self):
        directory = self.add_runner()
        external = self.root / "external-runner.json"
        contents = (directory / ".runner").read_text()
        external.write_text(contents)
        (directory / ".runner").unlink()
        (directory / ".runner").symlink_to(external)
        for command, args in (("install_runner.sh", ("demo/project", "registration-token")), ("unregister_all.sh", ())):
            with self.subTest(command=command):
                self.assert_failed(self.run_script(command, *args))
                self.assertTrue((directory / ".runner").is_symlink())
                self.assertEqual(external.read_text(), contents)
                self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
