import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../../Web/package.json', import.meta.url));
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH || 'playwright');
const origin = new URL(process.argv[2] || 'http://127.0.0.1:8080');
assert.equal(origin.protocol, 'http:');
assert.ok(['localhost', '127.0.0.1'].includes(origin.hostname));
const command = process.argv.slice(3).join(' ');
if (!command) throw new Error('Pass a shell command to measure.');

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
await page.addInitScript(() => {
  window.performanceCounters = {
    fillText: 0, fillRect: 0, receivedFrames: 0, receivedBytes: 0,
    sentFrames: 0, sentBytes: 0, messageHandlerMilliseconds: 0,
    longTasks: 0, longTaskMilliseconds: 0, paintedText: ''
  };
  const fillText = CanvasRenderingContext2D.prototype.fillText;
  CanvasRenderingContext2D.prototype.fillText = function (...args) {
    const counters = window.performanceCounters;
    counters.fillText++;
    counters.paintedText = (counters.paintedText + args[0]).slice(-500000);
    return fillText.apply(this, args);
  };
  const fillRect = CanvasRenderingContext2D.prototype.fillRect;
  CanvasRenderingContext2D.prototype.fillRect = function (...args) {
    window.performanceCounters.fillRect++;
    return fillRect.apply(this, args);
  };
  const addEventListener = WebSocket.prototype.addEventListener;
  WebSocket.prototype.addEventListener = function (type, listener, options) {
    if (type !== 'message') return addEventListener.call(this, type, listener, options);
    return addEventListener.call(this, type, function (event) {
      const counters = window.performanceCounters;
      counters.receivedFrames++;
      counters.receivedBytes += typeof event.data === 'string' ? event.data.length : event.data.byteLength;
      const start = performance.now();
      try { return listener.call(this, event); }
      finally { counters.messageHandlerMilliseconds += performance.now() - start; }
    }, options);
  };
  const send = WebSocket.prototype.send;
  WebSocket.prototype.send = function (data) {
    const counters = window.performanceCounters;
    counters.sentFrames++;
    counters.sentBytes += typeof data === 'string' ? data.length : data.byteLength;
    return send.call(this, data);
  };
  new PerformanceObserver(list => {
    for (const entry of list.getEntries()) {
      window.performanceCounters.longTasks++;
      window.performanceCounters.longTaskMilliseconds += entry.duration;
    }
  }).observe({ type: 'longtask', buffered: true });
});

try {
  await page.goto(origin.href);
  await page.waitForFunction(() => document.querySelector('#status')?.dataset.state === 'connected');
  await page.locator('#terminal-canvas').click();
  await page.keyboard.insertText('stty -echo');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(100);
  await page.evaluate(() => {
    const counters = window.performanceCounters;
    for (const key of Object.keys(counters)) counters[key] = typeof counters[key] === 'string' ? '' : 0;
  });
  const start = performance.now();
  await page.keyboard.insertText(`${command}; printf '\\n__SWIFTTERM_DONE__\\n'; stty echo`);
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.performanceCounters.paintedText.includes('__SWIFTTERM_DONE__'), undefined, { timeout: 120000 });
  const elapsedMilliseconds = performance.now() - start;
  await page.waitForTimeout(100);
  const { paintedText: _, ...counters } = await page.evaluate(() => window.performanceCounters);
  console.log(JSON.stringify({ elapsedMilliseconds, ...counters }, null, 2));
} finally {
  await browser.close();
}
