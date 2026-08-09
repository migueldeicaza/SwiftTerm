#!/usr/bin/env python3
"""Send one JSON Lines request to a running SwiftTerm BiDi harness."""

import argparse
import json
import socket
import sys
import uuid


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, help="Unix socket path")
    parser.add_argument("command", help="Harness command")
    parser.add_argument("arguments", nargs="?", default="{}", help="JSON object with command arguments")
    options = parser.parse_args()

    try:
        arguments = json.loads(options.arguments)
    except json.JSONDecodeError as error:
        parser.error(f"invalid arguments JSON: {error}")
    if not isinstance(arguments, dict):
        parser.error("arguments must be a JSON object")

    request = {
        "id": str(uuid.uuid4()),
        "command": options.command,
        "arguments": arguments,
    }
    payload = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(options.socket)
        connection.sendall(payload)
        response = bytearray()
        while not response.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("the harness closed the connection before it sent a response")
            response.extend(chunk)

    decoded = json.loads(response)
    print(json.dumps(decoded, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if decoded.get("ok") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConnectionError, OSError, RuntimeError) as error:
        print(f"harnessctl: {error}", file=sys.stderr)
        raise SystemExit(2)

