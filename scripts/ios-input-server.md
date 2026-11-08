# Local iOS keyboard test server

The sample iOS app can connect to this small SSH server on the Mac. The server
does not start a shell or run commands. It logs each input byte chunk and the
resulting line after Backspace edits. Use it to check the bytes sent by
`TerminalView` when you type with the Korean keyboard.

1. Install the server dependency in a temporary Python environment:

   ```sh
   python3 -m venv /tmp/swiftterm-ios-input-venv
   /tmp/swiftterm-ios-input-venv/bin/pip install paramiko
   ```

2. Start the server from the repository root:

   ```sh
   /tmp/swiftterm-ios-input-venv/bin/python scripts/ios_input_ssh_server.py
   ```

   It listens on `127.0.0.1:2222` and accepts `swiftterm` / `swiftterm`.
   These are test credentials. Keep the server on the loopback address.

3. Run `TerminalApp/iOSTerminal.xcodeproj` in an iOS simulator. In its login
   view, use host `127.0.0.1`, port `2222`, username `swiftterm`, and password
   `swiftterm`. Tap **Connect**.

4. In the simulator Settings app, add the Korean **2-Set** keyboard under
   General > Keyboard > Keyboards. Return to iOSTerminal, select that keyboard,
   and tap the keys for `되`, `않`, and `밟`. Press Return after each word.

The server prints JSON lines. An `input` event contains the received bytes in
hexadecimal. A `line` event contains the result after Backspace edits. Check
both values: a correct final line alone does not show whether the terminal sent
DEL plus replacement text. Text injection tools can submit a composed string
directly and may skip the keyboard composition path. Use keyboard taps to test
that path.
