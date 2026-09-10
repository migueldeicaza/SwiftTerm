import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../../../Web/package.json', import.meta.url));
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH || 'playwright');
const origin = new URL(process.argv[2] || 'http://127.0.0.1:8080');
assert.equal(origin.protocol, 'http:');
assert.ok(['localhost', '127.0.0.1'].includes(origin.hostname));
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
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
  await page.evaluate(() => { window.paintedText = ''; });
  await page.keyboard.type('mc');
  const start = performance.now();
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.paintedText.includes('Help') && window.paintedText.includes('Quit'), undefined, { timeout: 5000 });
  const elapsed = performance.now() - start;
  assert.ok(elapsed < 1500, `Midnight Commander took ${elapsed.toFixed(1)} ms to paint.`);
  await page.keyboard.press('F10');
  assert.deepEqual(errors, []);
  console.log(`PASS: canvas focus, typed input, Ctrl-C, and complete mc footer painted in ${elapsed.toFixed(1)} ms.`);
} finally { await browser.close(); }
