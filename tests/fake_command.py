#!/usr/bin/env python3
"""Hermetic command substitutes; privileged writes stay inside the test fixture."""

import json
import os
from pathlib import Path
import shutil
import sys


ROOT = Path(os.environ["TEST_ROOT"]).resolve()
STATE_FILE = ROOT / "state.json"
LOG_FILE = ROOT / "commands.jsonl"
STATE = json.loads(STATE_FILE.read_text())


def save():
    STATE_FILE.write_text(json.dumps(STATE))


def log(command, args):
    with LOG_FILE.open("a") as handle:
        handle.write(json.dumps({"command": command, "args": args, "cwd": os.getcwd()}) + "\n")


def guarded_path(value):
    path = Path(value)
    if str(path).startswith("/etc/systemd/system/"):
        if path.parent != Path("/etc/systemd/system") or not path.name.startswith("github-runner@"):
            raise RuntimeError("unexpected systemd target: " + value)
        path = ROOT / "systemd" / path.name
    path = path.absolute()
    if ROOT not in path.resolve().parents:
        raise RuntimeError("refusing write outside fixture: " + value)
    return path


def option(args, *names):
    for index, arg in enumerate(args):
        if arg in names:
            return args[index + 1]
        for name in names:
            if arg.startswith(name + "="):
                return arg.split("=", 1)[1]
    return None


def unit_properties(unit):
    unit = unit if unit.endswith(".service") else unit + ".service"
    values = {"LoadState": "not-found", "User": "", "WorkingDirectory": "", "FragmentPath": ""}
    values.update(STATE.get("units", {}).get(unit, {}))
    unit_file = ROOT / "systemd" / unit
    if unit_file.exists():
        values["LoadState"] = "loaded"
        values["FragmentPath"] = "/etc/systemd/system/" + unit
        for line in unit_file.read_text().splitlines():
            if line.startswith(("User=", "WorkingDirectory=")):
                key, value = line.split("=", 1)
                values[key] = value.strip('"')
    return unit, values


def dispatch(command, args):
    log(command, args)
    if command == "sudo":
        if not args or args[0] not in {"systemctl", "install", "rm", "tee", "mkdir", "chmod", "chown"}:
            raise RuntimeError("unexpected privileged command: " + repr(args))
        return dispatch(args[0], args[1:])
    if command == "uname":
        print("x86_64" if "-m" in args else "Linux")
        return 0
    if command == "id":
        if "-un" in args or "-nu" in args:
            print("runner-test")
        elif "-g" in args:
            print(os.getgid())
        else:
            # Exercise the nonroot CLI contract even in a root-run container.
            # Bash's -O checks still use real ownership of temporary fixtures.
            print(1000)
        return 0
    if command == "stat":
        path = Path(args[-1])
        fmt = option(args, "-c", "--format", "-f")
        if fmt not in {"%u", "%U"}:
            raise RuntimeError("unexpected stat format: " + repr(args))
        print(path.stat().st_uid if fmt == "%u" else "runner-test")
        return 0
    if command == "curl":
        url = next((arg for arg in reversed(args) if arg.startswith("https://")), "")
        output = option(args, "-o", "--output")
        if output:
            if STATE.get("download_failure"):
                return 22
            shutil.copyfile(ROOT / "package.tar.gz", guarded_path(output))
            return 0
        failure = STATE.get("api_failure")
        if failure == "transport":
            return 7
        if failure == "http":
            if any(arg == "--fail" or (arg.startswith("-") and not arg.startswith("--") and "f" in arg) for arg in args):
                return 22
            print(json.dumps({"message": "Bad credentials"}))
        elif failure == "null":
            print('{"token": null}')
        elif failure == "missing":
            print('{"message": "Bad credentials"}')
        elif failure == "invalid_json":
            print("not json")
        else:
            print(json.dumps({"token": "removal-token" if url.endswith("/remove-token") else "registration-token"}))
        return 0
    if command == "config":
        removing = bool(args and args[0] == "remove")
        if STATE.get("remove_failure" if removing else "config_failure"):
            return 1
        directory = guarded_path(os.getcwd())
        if removing:
            for filename in (".runner", ".credentials"):
                (directory / filename).unlink(missing_ok=True)
        else:
            (directory / ".runner").write_text(json.dumps({"gitHubUrl": option(args, "--url")}))
            (directory / ".credentials").write_text("fixture credentials\n")
        return 0
    if command == "systemctl":
        action = next((arg for arg in args if not arg.startswith("-")), "")
        if action == "daemon-reload":
            return 1 if STATE.get("reload_failure") else 0
        unit = next((arg for arg in reversed(args) if arg.startswith("github-runner@")), "")
        unit, values = unit_properties(unit)
        if action == "show":
            properties = [arg.split("=", 1)[1] for arg in args if arg.startswith("--property=")]
            if not properties:
                prop = option(args, "--property", "-p")
                properties = [prop] if prop else list(values)
            for prop in properties:
                print(values.get(prop, "") if "--value" in args else prop + "=" + str(values.get(prop, "")))
            return 0
        if action == "is-active":
            return 0 if values.get("active", False) else 3
        if action in {"start", "stop", "enable", "disable"}:
            if STATE.get(action + "_failure"):
                return 1
            entry = STATE.setdefault("units", {}).setdefault(unit, {})
            if action in {"start", "stop"}:
                entry["active"] = action == "start"
            else:
                entry["enabled"] = action == "enable"
            save()
            return 0
        raise RuntimeError("unexpected systemctl operation: " + repr(args))
    if command in {"install", "tee"}:
        target = guarded_path(args[-1])
        target.parent.mkdir(parents=True, exist_ok=True)
        if command == "tee":
            target.write_text(sys.stdin.read())
        else:
            shutil.copyfile(args[-2], target)
        return 0
    if command == "rm":
        recursive = any("r" in arg.lower() for arg in args if arg.startswith("-"))
        for value in args:
            if not value or value.startswith("-"):
                continue
            target = guarded_path(value)
            if target.is_dir() and not target.is_symlink():
                if not recursive:
                    return 1
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
        return 0
    if command == "mkdir":
        for value in args:
            if not value.startswith("-"):
                guarded_path(value).mkdir(parents="-p" in args, exist_ok="-p" in args)
        return 0
    if command in {"chmod", "chown"}:
        for value in args[1:]:
            if not value.startswith("-"):
                guarded_path(value)
        return 0
    raise RuntimeError("unexpected mock command: " + command)


if __name__ == "__main__":
    command = Path(sys.argv[0]).name
    arguments = sys.argv[1:]
    if arguments[:1] == ["--mock-command"]:
        command, arguments = arguments[1], arguments[2:]
    try:
        sys.exit(dispatch(command, arguments))
    except Exception as error:
        print("fixture rejected operation: " + str(error), file=sys.stderr)
        sys.exit(99)
