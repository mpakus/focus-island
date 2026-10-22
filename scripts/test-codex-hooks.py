#!/usr/bin/env python3
"""Exercise the built helper using disposable sockets and synthetic hook inputs."""
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time


def main():
    binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/OpenIslandHooks").resolve()
    with tempfile.TemporaryDirectory(prefix="fi-codex-", dir="/tmp") as folder:
        path = f"{folder}/bridge.sock"
        env = {**os.environ, "FOCUS_ISLAND_SOCKET_PATH": path}
        payload = json.dumps({"session_id": "fixture", "hook_event_name": "Stop",
                              "last_assistant_message": "Finished", "tool_response": "discard-me"}).encode()

        def run(label, data, extra=None):
            start = time.monotonic()
            result = subprocess.run([str(binary), "--source", "codex"], input=data,
                                    capture_output=True, env={**env, **(extra or {})}, timeout=2)
            elapsed = time.monotonic() - start
            assert result.returncode == 0 and result.stdout == b"{}\n", (label, result)
            assert elapsed < 1.5, (label, elapsed)
            print(f"{label}: exit=0, no-op JSON, {elapsed:.3f}s")

        run("missing bridge", payload)
        run("malformed input", b"not json")
        run("oversized input", b"x" * 1_048_577)
        run("empty input", b"")
        run("skip switch", payload, {"OPEN_ISLAND_SKIP_HOOKS": "1"})
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(1)
        listener.settimeout(2)
        received = []

        def stalled_bridge():
            connection, _ = listener.accept()
            connection.settimeout(2)
            with connection:
                data = b""
                while not data.endswith(b"\n"):
                    data += connection.recv(65_536)
                received.append(json.loads(data))
                # Leave the acknowledgement absent until the helper's receive timeout.
                while connection.recv(1):
                    pass

        thread = threading.Thread(target=stalled_bridge)
        thread.start()
        process = subprocess.Popen([str(binary), "--source", "codex"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        process.stdin.write(payload[:20])
        process.stdin.flush()
        time.sleep(0.03)
        process.stdin.write(payload[20:])
        process.stdin.close()
        start = time.monotonic()
        process.wait(timeout=2)
        assert process.returncode == 0 and process.stdout.read() == b"{}\n"
        thread.join(timeout=3)
        listener.close()
        assert not thread.is_alive() and len(received) == 1
        wire = json.dumps(received[0])
        assert "processCodexHook" in wire and "discard-me" not in wire
        print(f"chunked stdin + stalled bridge: sanitized envelope, {time.monotonic() - start:.3f}s")

        # stdin is deliberately kept open: the whole-helper deadline must still win.
        start = time.monotonic()
        process = subprocess.Popen([str(binary), "--source", "codex"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        process.wait(timeout=2)
        process.stdin.close()
        elapsed = time.monotonic() - start
        assert process.returncode == 0 and process.stdout.read() == b"{}\n" and elapsed < 1.5
        print(f"stalled stdin: exit=0, no-op JSON, {elapsed:.3f}s")


if __name__ == "__main__":
    main()
