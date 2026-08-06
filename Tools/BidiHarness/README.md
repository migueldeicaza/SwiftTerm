# SwiftTerm BiDi Harness

This AppKit application hosts `TerminalView` without a shell or PTY. It shows a WebKit reference beside the terminal and exposes a local Unix-domain socket for repeatable visual tests.

The harness enables SwiftTerm's automatic newline conversion. A line feed also
returns the cursor to column zero. This matches the output processing that a
PTY normally supplies and lets text fixtures keep their original LF line
endings.

## Prerequisites

The harness requires macOS 13 or later, Xcode, Python 3, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The launch script uses
XcodeGen to update the Xcode project before each build.

## Inspect scenarios in the app

```sh
Tools/BidiHarness/Scripts/run-harness.sh --artifacts /tmp/bidi-artifacts
```

The script builds and opens the AppKit app. The app shows SwiftTerm on the left,
a WebKit reference on the right, and the current state below the two views.

Use the controls at the top of the window to inspect a test:

- Select a scenario from the first menu.
- Use **Previous**, **Next**, and **Reset** to move through its steps.
- Set the column and row values, and select **Resize**, to test reflow.
- Use **Top** and **Bottom** to move through the scrollback buffer.
- Select the Core Graphics or Metal renderer.
- Select **Respect terminal** or **Legacy LTR** to change the host policy.
- Select **Capture** to save the current view and its state.

The scenarios cover the original author sample, paragraph reflow, the six BiDi
modes, reset and saved state, box mirroring, combining marks and controls,
selection and arrow keys, scrollback editing, and the paragraph-size limit.

The WebKit pane shows the expected output for the current step. It does not
show output from later steps. For implicit mode, WebKit applies its BiDi
algorithm. For explicit mode, the pane shows the expected display cells and
does not apply another BiDi pass. The Legacy LTR host policy intentionally
does not match the implicit WebKit result.

In **Reset, save, restore, and query**, the first line is an implicit paragraph.
The second line is an explicit RTL paragraph. Its application data is already
in display order, and SwiftTerm reverses the cells and puts column zero at the
right edge. The Arabic `after DECSTR` line first appears in step 3. This line
proves that DECSTR restores the default implicit mode for new paragraphs. It
does not change the first two paragraphs.

To build and run the app in Xcode, use these commands:

```sh
cd Tools/BidiHarness
xcodegen generate
open BidiHarness.xcodeproj
```

Select the `BidiHarness` scheme and select **Run**. When Xcode starts the app,
the app uses temporary default paths for the socket and artifacts.

## Control the app

The launch script prints one JSON object with the process identifier, control
socket path, capture socket path, artifact root, run identifier, and log paths.
Use the control socket path with the control client:

```sh
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock listScenarios
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock loadScenario '{"scenario":"author-sample"}'
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock gotoStep '{"step":"narrow-36"}'
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock capture '{"name":"narrow-review"}'
```

Each request and response is one JSON object followed by a newline. The socket has user-only permissions. The harness serializes commands on the AppKit main thread.

The channel can load steps, resize and scroll the terminal, set the cursor,
change the renderer and host policy, send keys, click and drag, reset the
terminal, and save captures. Use `status` to inspect the current terminal state:

```sh
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock status
```

## Capture the test suite

Use `runSuite` to replay and capture all marked checkpoints with Core Graphics
and Metal:

```sh
Tools/BidiHarness/Scripts/harnessctl.py --socket /path/to/control.sock runSuite '{}'
```

You can get the socket path from the launch result and run only the Core
Graphics suite with this Bash example:

```sh
launch=$(Tools/BidiHarness/Scripts/run-harness.sh --artifacts /tmp/bidi-artifacts)
socket=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["socket"])' <<<"$launch")
Tools/BidiHarness/Scripts/harnessctl.py --socket "$socket" runSuite \
    '{"renderers":["coreGraphics"]}'
```

Results are in this directory:

```text
/tmp/bidi-artifacts/<run-id>/<scenario>/<step>/<renderer>.png
```

Each checkpoint also contains a JSON manifest and `logical-buffer.txt`. The
manifest records the dimensions, viewport, cursor, BiDi state, renderer,
selection, assertions, and timings. The images are review artifacts. They are
not pixel-test baselines.

You can inspect the Metal renderer in the app without special permission. Metal
window capture needs access in **System Settings > Privacy & Security > Screen
& System Audio Recording**. Give access to the terminal application that runs
`run-harness.sh`. The launch script starts a local capture helper because the
Core Graphics window API does not include `CAMetalLayer` content. The helper
exits when the harness exits. If access is not available, the harness returns
`captureUnavailable`. It does not save a black pane or substitute a Core
Graphics image.

When Xcode starts the app directly, there is no capture helper. You can inspect
Metal in the live app, but Metal capture returns `captureUnavailable`. Start the
app with `run-harness.sh` when you need Metal artifacts.

## Local validation

```sh
Tools/BidiHarness/Scripts/smoke-test.sh
```

The script builds and launches the app, exercises both renderers, validates available artifacts, and closes the app.

The script accepts a `captureUnavailable` result for Metal when Screen Recording access is not available.
