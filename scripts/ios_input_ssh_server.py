#!/usr/bin/env python3
"""Run a loopback SSH echo server for the iOSTerminal sample app.

Install Paramiko with `python3 -m pip install paramiko` before you run this file.
The server accepts one session at a time. It does not start a system shell.
"""

import argparse
import codecs
import json
import socket
import threading
from datetime import datetime, timezone

import paramiko


class InputServer(paramiko.ServerInterface):
    def __init__(self, username: str, password: str) -> None:
        self.username = username
        self.password = password
        self.shell_requested = threading.Event()

    def check_auth_password(self, username: str, password: str) -> int:
        if username == self.username and password == self.password:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username: str) -> str:
        return "password"

    def check_channel_request(self, kind: str, channel_id: int) -> int:
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(
        self, channel: paramiko.Channel, term: bytes, width: int, height: int,
        pixelwidth: int, pixelheight: int, modes: bytes,
    ) -> bool:
        return True

    def check_channel_shell_request(self, channel: paramiko.Channel) -> bool:
        self.shell_requested.set()
        return True


def record(event: str, **fields: object) -> None:
    payload = {
        "time": datetime.now(timezone.utc).isoformat(),
        "event": event,
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def serve_session(channel: paramiko.Channel) -> None:
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    line: list[str] = []
    previous_was_return = False
    channel.sendall(
        "SwiftTerm local input test. Type Korean text and press Return.\r\n"
        "The server logs each received byte chunk and each completed line.\r\n> "
    )
    while True:
        data = channel.recv(4096)
        if not data:
            return
        record("input", hex=data.hex(), text=data.decode("utf-8", "backslashreplace"))
        for character in decoder.decode(data):
            if character == "\n" and previous_was_return:
                previous_was_return = False
                continue
            previous_was_return = character == "\r"
            if character in ("\x7f", "\x08"):
                if line:
                    line.pop()
            elif character in ("\r", "\n"):
                text = "".join(line)
                record("line", text=text)
                channel.sendall(f"\r\nreceived: {text}\r\n> ")
                line.clear()
                continue
            elif character.isprintable():
                line.append(character)
            channel.sendall("\r\x1b[2K> " + "".join(line))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--username", default="swiftterm")
    parser.add_argument("--password", default="swiftterm")
    args = parser.parse_args()

    host_key = paramiko.ECDSAKey.generate(bits=256)
    with socket.create_server((args.host, args.port), reuse_port=False) as listener:
        record("listening", host=args.host, port=args.port, username=args.username)
        try:
            while True:
                connection, address = listener.accept()
                record("connected", address=str(address))
                transport = paramiko.Transport(connection)
                transport.add_server_key(host_key)
                server = InputServer(args.username, args.password)
                try:
                    transport.start_server(server=server)
                    channel = transport.accept(10)
                    if channel is None or not server.shell_requested.wait(10):
                        record("session_rejected")
                        continue
                    serve_session(channel)
                except (EOFError, OSError, paramiko.SSHException) as error:
                    record("session_error", detail=str(error))
                finally:
                    transport.close()
                    record("disconnected")
        except KeyboardInterrupt:
            record("stopped")


if __name__ == "__main__":
    main()
