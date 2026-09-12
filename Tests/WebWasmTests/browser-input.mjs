import assert from 'node:assert/strict';

export async function checkBrowserInput(page) {
  const take = () => page.evaluate(() => {
    const t = window.swifttermExample.terminal, bytes = t.readOutput();
    t.consumeOutput(bytes.length); return new TextDecoder().decode(bytes);
  });
  const text = page.locator('textarea');
  await page.evaluate(() => {
    const { terminal, input, stopStream } = window.swifttermExample;
    stopStream(); terminal.reset(); terminal.write('\x1b[>31u'); input.refresh();
  });
  await text.focus(); await take();
  await page.keyboard.down('Shift'); await page.keyboard.down('A');
  await page.keyboard.up('Shift'); await page.keyboard.up('A');
  const keys = await take();
  assert.match(keys, /\x1b\[97:65;2;65u/, 'Shift+A keeps unshifted identity and associated uppercase text');
  assert.match(keys, /\x1b\[97;1:3u/, 'release keeps the press identity after Shift changes');
  assert.doesNotMatch(keys, /\x1b\[65[:;]/);

  // This exercises the DOM composition path. Native OS IMEs need manual checks too.
  await text.evaluate(input => {
    input.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    input.value = '日本';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: '日本', inputType: 'insertCompositionText', isComposing: true }));
    input.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '日本' }));
    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: '日本', inputType: 'insertText' }));
  });
  assert.equal(await take(), '\x1b[0;;26085:26412u', 'one Kitty text event per composition commit');

  await page.evaluate(() => {
    const { terminal } = window.swifttermExample;
    terminal.reset(); terminal.write('\x1b[?1004h');
    const button = document.createElement('button'); button.id = 'focus-outside'; button.textContent = 'Outside'; document.body.append(button);
  });
  await take(); await page.locator('#focus-outside').focus();
  assert.equal(await take(), '\x1b[O', 'page controls must remove terminal focus');
  await text.focus(); assert.equal(await take(), '\x1b[I');

  await page.evaluate(() => {
    const { terminal, renderer, input } = window.swifttermExample;
    terminal.reset(); terminal.write('hello world\x1b[?1000h\x1b[?1006h');
    renderer.requestFrame(); input.refresh();
  });
  await page.waitForTimeout(30);
  const box = await page.locator('canvas').first().boundingBox();
  await page.mouse.click(box.x + 15, box.y + 25, { button: 'right' });
  assert.equal(await take(), '\x1b[<2;2;2M\x1b[<2;2;2m', 'SGR right-button release preserves button identity');
  await page.evaluate(() => {
    const { terminal, renderer } = window.swifttermExample;
    terminal.write('\x1b[?1003h\x1b[?1016h');
    renderer.canvas.style.transformOrigin = 'top left'; renderer.canvas.style.transform = 'scale(.5)';
    renderer.canvas.addEventListener('pointerdown', event => {
      const rect = renderer.canvas.getBoundingClientRect();
      window.scaledPoint = { x: event.clientX - rect.left, y: event.clientY - rect.top };
    }, { once: true });
  });
  await page.mouse.click(box.x + 8, box.y + 13, { button: 'right' });
  const scaledClick = await take();
  // WebKit rounds event positions when the canvas starts at a fractional CSS pixel.
  const scaledPoint = await page.evaluate(() => window.scaledPoint);
  const px = Math.floor(scaledPoint.x * 2) + 1, py = Math.floor(scaledPoint.y * 2) + 1;
  assert.ok(scaledClick.endsWith(`\x1b[<2;${px};${py}M\x1b[<2;${px};${py}m`), 'half-size CSS display maps to logical pixels without a DPR multiplier');
  await page.evaluate(() => {
    const { terminal, renderer } = window.swifttermExample;
    renderer.canvas.style.transform = ''; delete window.scaledPoint; terminal.write('\x1b[?1002h\x1b[?1006h');
  });
  await page.mouse.move(box.x + 15, box.y + 25); await take();
  await page.mouse.down();
  await page.mouse.move(box.x + box.width + 20, box.y + box.height + 20, { steps: 4 }); await page.mouse.up();
  const drag = await take();
  assert.ok(drag.startsWith('\x1b[<0;2;2M') && drag.endsWith('\x1b[<0;80;24m'), 'captured pointer releases outside the canvas with bounded coordinates');
  await page.evaluate(() => window.swifttermExample.terminal.write('\x1b[?1000h'));
  await page.keyboard.down('Shift');
  await page.mouse.move(box.x + 5, box.y + 10); await page.mouse.down();
  await page.mouse.move(box.x + 45, box.y + 10, { steps: 4 }); await page.mouse.up();
  await page.keyboard.up('Shift');
  assert.equal(await take(), '', 'local Shift selection must not send mouse packets');
  assert.equal(await page.evaluate(() => window.swifttermExample.terminal.selectionText()), 'hello');
  const copied = await text.evaluate(input => {
    const data = new DataTransfer(), event = new ClipboardEvent('copy', { clipboardData: data, cancelable: true, bubbles: true });
    input.dispatchEvent(event); return { prevented: event.defaultPrevented, text: data.getData('text/plain') };
  });
  assert.deepEqual(copied, { prevented: true, text: 'hello' });
  const highlighted = await page.evaluate(() => {
    const overlay = document.querySelector('canvas[aria-hidden="true"]');
    return overlay && [...overlay.getContext('2d').getImageData(1, 1, 1, 1).data].some(value => value !== 0);
  });
  assert.equal(highlighted, true, 'selection overlay is visible');

  await page.evaluate(() => {
    const { terminal, input } = window.swifttermExample;
    terminal.write('\x1b[?1000l'); terminal.selectionClear(); input.refresh();
  });
  await page.mouse.dblclick(box.x + 75, box.y + 10);
  assert.equal(await page.evaluate(() => window.swifttermExample.terminal.selectionText()), 'world', 'real double click selects a word');
  // Start a new sequence outside the previous click interval.
  await page.waitForTimeout(600);
  await page.mouse.click(box.x + 15, box.y + 10, { clickCount: 3 });
  assert.equal(await page.evaluate(() => window.swifttermExample.terminal.selectionText()), 'hello world', 'real triple click selects a row');

  await page.evaluate(() => {
    const { terminal, renderer, input } = window.swifttermExample;
    terminal.reset(); terminal.resize(12, 4, 10, 20);
    terminal.write(Array.from({ length: 10 }, (_, i) => `line${i}`).join('\r\n'));
    renderer.requestFrame(); input.refresh();
    window.wheelEvents = [];
    renderer.canvas.addEventListener('wheel', event => window.wheelEvents.push({ deltaY: event.deltaY, deltaMode: event.deltaMode, rows: renderer.inputGeometry.rows, height: renderer.canvas.getBoundingClientRect().height }), { once: true });
  });
  await page.waitForTimeout(30);
  const before = await page.evaluate(() => window.swifttermExample.terminal.viewportState());
  const resized = await page.locator('canvas').first().boundingBox();
  // Playwright wheel units differ by browser and DPR. Check the DOM delta.
  await page.mouse.move(resized.x + 35, resized.y + 35); await page.mouse.wheel(0, -50);
  await page.waitForTimeout(50);
  const after = await page.evaluate(() => window.swifttermExample.terminal.viewportState());
  const [wheel] = await page.evaluate(() => window.wheelEvents);
  const lines = Math.trunc(wheel.deltaY * (wheel.deltaMode === 1 ? 1 : wheel.deltaMode === 2 ? wheel.rows : wheel.rows / wheel.height));
  assert.ok(lines < 0, 'browser delivers an upward wheel event');
  assert.equal(after.topRow, before.topRow + lines, 'DOM wheel delta reaches core scrollback');

  await page.evaluate(async () => {
    const { TerminalInputController } = await import('../dist/index.js');
    const { CanvasTerminalRenderer } = await import('../dist/example/canvas2d.js');
    const holder = document.createElement('div'); holder.style.position = 'relative';
    const canvas = document.createElement('canvas'), textarea = document.createElement('textarea');
    textarea.id = 'second-input'; holder.append(canvas, textarea); document.body.append(holder);
    const terminal = window.swifttermExample.module.createTerminal({ cols: 20, rows: 4 });
    const renderer = new CanvasTerminalRenderer(canvas, terminal);
    const input = new TerminalInputController(terminal, canvas, textarea, {
      geometry: () => renderer.inputGeometry, onInput: () => renderer.requestFrame(),
      onSelection: state => renderer.setSelection(state),
    });
    terminal.write('\x1b[?1004h'); window.swifttermExample.terminal.write('\x1b[?1004h');
    terminal.consumeOutput(terminal.readOutput().length);
    window.secondTerminal = { terminal, renderer, input, holder };
  });
  await take(); await page.locator('#second-input').focus(); await page.keyboard.type('two');
  const second = await page.evaluate(() => {
    const t = window.secondTerminal.terminal, bytes = t.readOutput(); t.consumeOutput(bytes.length);
    return { text: new TextDecoder().decode(bytes), firstFocused: window.swifttermExample.terminal.snapshot().cursor.focused,
      secondFocused: t.snapshot().cursor.focused };
  });
  assert.deepEqual(second, { text: '\x1b[Itwo', firstFocused: false, secondFocused: true }, 'two terminals keep separate input and focus');
  assert.equal(await take(), '\x1b[O');
  await page.evaluate(() => {
    const { terminal, renderer, input, holder } = window.secondTerminal;
    input.dispose(); renderer.dispose(); terminal.dispose(); holder.remove(); delete window.secondTerminal;
  });
  await text.focus();

  await page.evaluate(() => {
    const { terminal, renderer, input } = window.swifttermExample;
    terminal.reset(); terminal.resize(80, 24, 10, 20); renderer.requestFrame(); input.refresh();
    document.querySelector('#focus-outside').remove(); delete window.wheelEvents;
  });
  await page.waitForFunction(() => {
    const { renderer } = window.swifttermExample;
    return renderer.canvas.width === 80 * 10 * devicePixelRatio && renderer.canvas.height === 24 * 20 * devicePixelRatio;
  });
}
