import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../../../Web/package.json', import.meta.url));
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH || 'playwright');
const origin = new URL(process.argv[2] || 'http://127.0.0.1:8080');
assert.equal(origin.protocol, 'http:');
assert.ok(['localhost', '127.0.0.1'].includes(origin.hostname));
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [], mouseFrames = [];
let processOutput = '';
page.on('websocket', socket => {
  socket.on('framesent', ({ payload }) => {
    const text = typeof payload === 'string' ? payload : payload.toString('utf8');
    mouseFrames.push(...text.match(/\x1b\[<\d+;\d+;\d+[Mm]/g) ?? []);
  });
  socket.on('framereceived', ({ payload }) => {
    if (typeof payload !== 'string') processOutput = (processOutput + payload.toString('utf8')).slice(-1000000);
  });
});
page.on('pageerror', error => errors.push(error.message));
await page.addInitScript(() => {
  window.paintedText = '';
  const original = CanvasRenderingContext2D.prototype.fillText;
  CanvasRenderingContext2D.prototype.fillText = function (...args) {
    window.paintedText = (window.paintedText + args[0]).slice(-250000);
    return original.apply(this, args);
  };
});
try {
  await page.goto(origin.href);
  await page.waitForFunction(() => document.querySelector('#status').dataset.state === 'connected');
  await page.locator('#terminal-canvas').click();
  assert.equal(await page.evaluate(() => document.activeElement.id), 'terminal-input');
  await page.keyboard.type("cat; printf '\\137INTERRUPTED\\137\\n'");
  await page.keyboard.press('Enter');
  await page.keyboard.type('browser input'); await page.keyboard.press('Enter');
  await page.keyboard.press('Control+c');
  await page.waitForFunction(() => window.paintedText.includes('_INTERRUPTED_'), undefined, { timeout: 5000 });
  // A raw PTY probe checks the Kitty bytes produced by real browser key events.
  const probe = `import os, select, termios, time, tty
old = termios.tcgetattr(0)
data = bytearray()
try:
    tty.setraw(0)
    os.write(1, b"\\x1b[>31u_KITTY_READY_\\r\\n")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        ready, _, _ = select.select([0], [], [], 0.1)
        if ready:
            data.extend(os.read(0, 4096))
            if data.endswith(b"\\x1b[97;1:3u"):
                break
finally:
    os.write(1, b"\\x1b[<u")
    termios.tcsetattr(0, termios.TCSANOW, old)
os.write(1, ("\\r\\n_KITTY_HEX_" + data.hex() + "_END_\\r\\n").encode())
`;
  await page.evaluate(() => { window.paintedText = ''; });
  await page.keyboard.insertText(`python3 -c "import base64;exec(base64.b64decode('${Buffer.from(probe).toString('base64')}'))"`);
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.paintedText.includes('_KITTY_READY_'), undefined, { timeout: 5000 });
  await page.keyboard.down('Shift'); await page.keyboard.down('A');
  await page.keyboard.up('Shift'); await page.keyboard.up('A');
  await page.waitForFunction(() => window.paintedText.includes('_END_'), undefined, { timeout: 5000 });
  const result = /_KITTY_HEX_([0-9a-f]+)_END_/.exec(processOutput);
  assert.ok(result, 'The raw PTY probe must return its captured bytes.');
  const expected = '\x1b[57441;2u\x1b[97:65;2;65u\x1b[57441;1:3u\x1b[97;1:3u';
  assert.equal(result[1], Buffer.from(expected).toString('hex'), 'Shift+A retains key 97 after Shift is released.');
  await page.evaluate(() => { window.paintedText = ''; });
  await page.keyboard.type('mc');
  const start = performance.now();
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.paintedText.includes('Help') && window.paintedText.includes('Quit'), undefined, { timeout: 5000 });
  const elapsed = performance.now() - start;
  assert.ok(elapsed < 1500, `Midnight Commander took ${elapsed.toFixed(1)} ms to paint.`);
  await page.evaluate(() => { window.paintedText = ''; });
  const canvas = await page.locator('#terminal-canvas').boundingBox();
  await page.mouse.click(canvas.x + 20, canvas.y + 10);
  await page.waitForFunction(() => window.paintedText.replace(/\s/g, '').includes('Listingformat'), undefined, { timeout: 5000 });
  assert.deepEqual(mouseFrames.slice(-2), ['\x1b[<0;3;1M', '\x1b[<0;3;1m']);
  // Close the menu with a mouse click. A lone Escape has an application timeout.
  await page.mouse.click(canvas.x + 400, canvas.y + 210);
  await page.waitForTimeout(100);
  await page.evaluate(() => { window.paintedText = ''; });
  const dragStart = mouseFrames.length;
  await page.mouse.move(canvas.x + 100, canvas.y + 110);
  await page.mouse.down({ button: 'right' });
  await page.mouse.move(canvas.x + 100, canvas.y + 150, { steps: 2 });
  await page.mouse.up({ button: 'right' });
  await page.waitForFunction(() => window.paintedText.replace(/\s/g, '').includes('in3files'), undefined, { timeout: 5000 });
  assert.deepEqual(mouseFrames.slice(dragStart), ['\x1b[<2;11;6M', '\x1b[<34;11;7M', '\x1b[<34;11;8M', '\x1b[<2;11;8m']);
  await page.keyboard.press('F10');
  assert.deepEqual(errors, []);
  console.log(`PASS: canvas focus, typed input, Ctrl-C, Kitty Shift+A bytes, mc mouse menu/drag, and complete mc footer painted in ${elapsed.toFixed(1)} ms.`);
} finally { await browser.close(); }
