#!/usr/bin/env python3
"""Isolated acceptance using a compiled setup driver and a built Local helper.

No model calls, client upgrades, credentials or real user config edits. HOME is
inherited unchanged; Foundation home, CODEX_HOME and XDG roots are isolated.
agy is checked through its installed command and native-shaped payloads only:
its interactive loader/trust/account flow is not exercised by this script.
"""
import json
import os
from pathlib import Path
import queue
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


def main():
    driver, binary, report_path = map(Path, sys.argv[1:4])
    driver, binary = driver.resolve(), binary.resolve()
    with tempfile.TemporaryDirectory(prefix="ap-native-", dir="/tmp") as work:
        root = Path(work)
        home = root / "home"
        home.mkdir()
        project = root / "project"
        project.mkdir()
        local = home / ".agentpet-local"
        local.mkdir()
        sock_path = local / "agentpet.sock"
        env = os.environ.copy()
        env.update(CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home / ".codex"),
                   AGENTPET_LOCAL_HOME=str(local), XDG_CONFIG_HOME=str(home / ".config"),
                   XDG_DATA_HOME=str(home / ".local/share"), XDG_STATE_HOME=str(home / ".local/state"),
                   XDG_CACHE_HOME=str(home / ".cache"), TMPDIR=work + "/")
        for key in ["OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT",
                    "OPENCODE_AUTH_JSON", "OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME"]:
            env.pop(key, None)
        env["OPENCODE_DISABLE_MODELS_FETCH"] = "true"
        env["OPENCODE_TEST_HOME"] = str(home)
        env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "true"
        env["OPENCODE_PURE"] = "false"
        env.pop("OPENCODE_DB", None)
        env.pop("OPENCODE_WORKSPACE_ID", None)
        opencode_version = subprocess.run(["opencode", "--version"], env=env, capture_output=True, text=True, timeout=5, check=True).stdout.strip()
        opencode_v2 = bool(re.fullmatch(r"(?:opencode\s+v?)?2\.\d+\.\d+(?:[-+][\w.-]+)?", opencode_version))
        frames = []
        lock = threading.Lock()
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(sock_path))
        server.listen()
        server.settimeout(0.2)
        stopped = threading.Event()

        def listen():
            while not stopped.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(2)
                    data = b""
                    while b"\n" not in data:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                    with lock:
                        frames.extend(json.loads(line) for line in data.splitlines() if line)

        listener = threading.Thread(target=listen, daemon=True)
        listener.start()
        checks = []

        def check(value, name):
            assert value, name
            checks.append(name)

        def setup(action, kind):
            return subprocess.run([str(driver), action, kind, str(home), str(binary), str(sock_path)],
                                  cwd=project, env=env, check=True, capture_output=True, text=True).stdout.strip()

        def wait_frames(count):
            end = time.monotonic() + 5
            while time.monotonic() < end:
                with lock:
                    if len(frames) >= count:
                        return
                time.sleep(.02)
            raise AssertionError("helper transport timed out")

        # Use exactly the shell command written by the new installer.
        for kind in ["codex", "antigravity", "opencode"]:
            check(setup("install", kind) == "configured", kind + " fresh install")
        codex_path = home / ".codex/hooks.json"
        agy_path = home / ".gemini/config/hooks.json"
        codex = json.loads(codex_path.read_text())["hooks"]
        agy = json.loads(agy_path.read_text())["agentpet"]
        check("PreToolUse" not in agy, "agy observer does not register permission gate")
        payloads = [
            (codex["UserPromptSubmit"][0]["hooks"][0]["command"], {"session_id": "isolated-codex", "hook_event_name": "UserPromptSubmit", "cwd": str(project), "prompt": "PRIVATE_SENTINEL"}, "codex"),
            (codex["Stop"][0]["hooks"][0]["command"], {"session_id": "isolated-codex", "hook_event_name": "Stop", "cwd": str(project)}, "codex"),
            (agy["PreInvocation"][0]["command"], {"conversationId": "isolated-agy", "workspacePaths": [str(project)], "invocationNum": 1}, "antigravity"),
            (agy["Stop"][0]["command"], {"conversationId": "isolated-agy", "terminationReason": "completed", "fullyIdle": True}, "antigravity"),
        ]
        for command, payload, kind in payloads:
            result = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(payload), env=env, cwd=project,
                                    capture_output=True, text=True, timeout=5, check=True)
            check(result.stdout.strip() == ("{}" if kind == "antigravity" else ""), kind + " safe stdout")
        wait_frames(4)
        check("PRIVATE_SENTINEL" not in json.dumps(frames), "prompt excluded from helper events")
        check(not (local / "queue").exists(), "installed commands reached isolated live socket")

        # Inspect native Codex hooks without trusting or executing them.
        config = home / ".codex/config.toml"
        config.write_text('cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n')

        def codex_hooks():
            stderr = tempfile.TemporaryFile()
            child = subprocess.Popen(["codex", "app-server", "--stdio"], cwd=project, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                     text=True, bufsize=1, start_new_session=True)
            messages = queue.Queue()
            def read():
                for line in child.stdout:
                    messages.put(json.loads(line))
            thread = threading.Thread(target=read, daemon=True)
            thread.start()
            def send(value):
                child.stdin.write(json.dumps(value) + "\n")
                child.stdin.flush()
            def response(i):
                end = time.monotonic() + 20
                while time.monotonic() < end:
                    value = messages.get(timeout=max(.1, end - time.monotonic()))
                    if value.get("id") == i:
                        assert "error" not in value, value
                        return value["result"]
                raise AssertionError("Codex app-server response timed out")
            try:
                send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "agentpet-isolated-check", "version": "1"}, "capabilities": {"experimentalApi": True}}})
                response(1)
                send({"method": "initialized"})
                send({"id": 2, "method": "hooks/list", "params": {"cwds": [str(project)]}})
                return response(2)
            finally:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
                stderr.close()

        native_hooks = codex_hooks()
        (root / "codex-hooks-before.json").write_text(json.dumps(native_hooks, indent=2))
        flattened = json.dumps(native_hooks)
        check(str(binary) in flattened, "Codex native loader sees installed helper")
        native_entries = [hook for item in native_hooks["data"] for hook in item["hooks"] if str(binary) in (hook.get("command") or "")]
        check(len(native_entries) == 6 and all(hook["enabled"] and hook["trustStatus"] == "untrusted" for hook in native_entries), "all six Codex hooks loaded and left for native trust review")

        def opencode_session(expect_event=False):
            if opencode_v2:
                # The V2 server requires authenticated access. Use its native
                # private-server CLI transport instead of an unauthenticated
                # HTTP request or disabling the server's access checks.
                # A deliberately nonexistent model fails locally with no model
                # dispatch, while activating the location's real plugin API.
                result = subprocess.run(["opencode", "run", "--standalone", "--model",
                    "agentpet-native-fixture-missing/no-route", "--format", "json", "--title",
                    "AgentPet no-model verification", "Synthetic input"], cwd=project, env=env,
                    capture_output=True, text=True, timeout=35)
                values = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                failure = next(value for value in values if value.get("type") == "error")
                check(result.returncode != 0 and failure.get("error", {}).get("type") == "provider.no-route",
                      "OpenCode V2 nonexistent provider fails locally without model dispatch")
                sid = failure["sessionID"]
                if expect_event:
                    end = time.monotonic() + 5
                    while time.monotonic() < end and not any(frame.get("session_id") == sid and frame.get("result") == "failed" for frame in frames):
                        time.sleep(.02)
                    check(any(frame.get("session_id") == sid and frame.get("result") == "failed" for frame in frames),
                          "OpenCode V2 native plugin observes failed execution")
                return sid
            child = subprocess.Popen(["opencode", "serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs", "--log-level", "debug" if opencode_v2 else "DEBUG"],
                                     cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1, start_new_session=True)
            output = queue.Queue()
            all_lines = []
            def read():
                for line in child.stdout:
                    all_lines.append(line)
                    output.put(line)
            threading.Thread(target=read, daemon=True).start()
            try:
                lines = []
                end = time.monotonic() + 35
                address = None
                while time.monotonic() < end:
                    line = output.get(timeout=max(.1, end-time.monotonic()))
                    lines.append(line)
                    match = re.search(r"http://127\.0\.0\.1:\d+", line)
                    if match:
                        address = match.group(0)
                        break
                assert address, "OpenCode server did not start"
                req = urllib.request.Request(address + "/session", data=b"{}", headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=35) as result:
                    sid = json.load(result)["id"]
                if expect_event:
                    end = time.monotonic() + 5
                    while time.monotonic() < end:
                        if any(sid in json.dumps(frame) for frame in frames):
                            break
                        time.sleep(.02)
                else:
                    time.sleep(.5)
                return sid
            finally:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
                report_path.with_suffix(".opencode.log").write_text("".join(all_lines))

        first_session = opencode_session(expect_event=True)
        if not opencode_v2:
            wait_frames(5)
            check(any(first_session in json.dumps(frame) for frame in frames), "OpenCode V1 native discovery emits session event")
        check(not (local / "queue").exists(), "native plugin reached isolated socket")

        for kind in ["codex", "antigravity", "opencode"]:
            check(setup("remove", kind) == "absent", kind + " complete registration removal")
            check(setup("remove", kind) == "absent", kind + " repeat removal")
        removed_hooks = codex_hooks()
        check(str(binary) not in json.dumps(removed_hooks), "Codex native loader no longer sees helper")
        time.sleep(.2)
        with lock:
            before = len(frames)
        second_session = opencode_session()
        time.sleep(.5)
        with lock:
            check(len(frames) == before and not any(second_session in json.dumps(f) for f in frames), "OpenCode reload has no removed-plugin reporting")
        check(config.read_text() == 'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n', "Codex shared config preserved")
        stopped.set()
        listener.join(timeout=2)
        server.close()
        versions = {name: subprocess.run([name, "--version"], env=env, capture_output=True, text=True, timeout=5, check=True).stdout.strip() for name in ["codex", "agy", "opencode"]}
        report = {"versions": versions, "checks": checks, "frames": frames, "codexNativeHooksBefore": native_hooks,
                  "codexNativeHooksAfter": removed_hooks, "limits": ["agy native interactive loading not exercised", "no model calls or native trust bypass", "project-local custom registrations outside scope"]}
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print("PASS:", len(checks), "isolated integration checks")


if __name__ == "__main__":
    main()
