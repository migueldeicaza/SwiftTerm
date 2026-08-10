#!/usr/bin/env python3
"""Capture harness windows from a process that has Screen Recording access."""

import argparse
import json
import os
import socket
import subprocess
from pathlib import Path


MAXIMUM_REQUEST_BYTES = 65_536
SCREEN_CAPTURE = "/usr/sbin/screencapture"


def process_request(payload: bytes) -> dict[str, object]:
    try:
        request = json.loads(payload)
        window_id = int(request["windowID"])
        output = Path(request["output"])
        if window_id <= 0 or not output.is_absolute():
            raise ValueError("windowID must be positive and output must be absolute")
        result = subprocess.run(
            [SCREEN_CAPTURE, "-x", "-o", "-l", str(window_id), str(output)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or f"screencapture exited with status {result.returncode}"
            return {"ok": False, "message": message}
        return {"ok": output.is_file() and output.stat().st_size > 0}
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        return {"ok": False, "message": str(error)}


def process_is_running(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, help="Unix socket path")
    parser.add_argument("--watch-pid", required=True, type=int, help="Exit when this process exits")
    options = parser.parse_args()

    socket_path = Path(options.socket)
    socket_path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        listener.listen(4)
        listener.settimeout(1)
        try:
            while process_is_running(options.watch_pid):
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                with connection:
                    request = bytearray()
                    while not request.endswith(b"\n") and len(request) <= MAXIMUM_REQUEST_BYTES:
                        chunk = connection.recv(4096)
                        if not chunk:
                            break
                        request.extend(chunk)
                    response = process_request(bytes(request).rstrip(b"\n"))
                    connection.sendall(json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n")
        finally:
            socket_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
