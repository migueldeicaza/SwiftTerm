import test from 'node:test';
import assert from 'node:assert/strict';
import { TerminalInputController } from '../../Web/dist/src/input.js';

class Target {
  handlers = new Map();
  addEventListener(name, fn, options = {}) {
    const entries = this.handlers.get(name) ?? [];
    entries.push({ fn, signal: options.signal }); this.handlers.set(name, entries);
  }
  removeEventListener(name, fn) { this.handlers.set(name, (this.handlers.get(name) ?? []).filter(e => e.fn !== fn)); }
  emit(name, fields = {}) {
    const event = new Event(name, { cancelable: true });
    const { timeStamp, ...values } = fields;
    if (timeStamp !== undefined) Object.defineProperty(event, 'timeStamp', { value: timeStamp });
    Object.assign(event, { button: 0, pointerId: 1, clientX: 110, clientY: 60, detail: 0,
      shiftKey: false, altKey: false, ctrlKey: false, metaKey: false,
      key: '', code: '', repeat: false, location: 0, getModifierState: () => false,
      deltaX: 0, deltaY: 0, deltaMode: 0, ...values });
    for (const entry of this.handlers.get(name) ?? []) if (!entry.signal?.aborted) entry.fn(event);
    return event;
  }
}
function fixture(t, { state: initialState = {}, geometry: customGeometry = {}, options = {} } = {}) {
  const old = Object.fromEntries(['window', 'document', 'requestAnimationFrame', 'cancelAnimationFrame'].map(k => [k, globalThis[k]]));
  const window = new Target(), document = new Target();
  document.hidden = false; document.activeElement = null; document.hasFocus = () => document.windowFocused;
  document.windowFocused = true;
  const frames = new Map(); let nextFrame = 0;
  globalThis.window = window; globalThis.document = document;
  globalThis.requestAnimationFrame = fn => { frames.set(++nextFrame, fn); return nextFrame; };
  globalThis.cancelAnimationFrame = id => frames.delete(id);
  const surface = new Target(), input = new Target(), calls = [], errors = [];
  const geometry = { cols: 20, rows: 10, cellWidth: 10, cellHeight: 10, ...customGeometry };
  const rect = { left: 100, top: 50, width: 400, height: 200, bottom: 250, right: 500 };
  surface.getBoundingClientRect = () => rect; surface.offsetLeft = 0; surface.offsetTop = 0;
  const captures = new Set();
  surface.setPointerCapture = id => captures.add(id); surface.hasPointerCapture = id => captures.has(id);
  surface.releasePointerCapture = id => { captures.delete(id); surface.emit('lostpointercapture', { pointerId: id }); };
  input.value = ''; input.disabled = false; input.style = {};
  input.ownerDocument = { defaultView: { navigator: { platform: 'Linux' } } };
  const focus = target => {
    const previous = document.activeElement; document.activeElement = target;
    if (previous !== target) { previous?.emit('blur'); target?.emit('focus'); }
  };
  input.focus = () => focus(input);
  const state = { mouseMode: 'off', mouseProtocol: 'sgr', mouseShiftCapture: false, alternateScreen: false, alternateScroll: false,
    kittyKeyboardFlags: 0, applicationCursor: false, applicationKeypad: false, bracketedPaste: false, kittyPaste: false, ...initialState };
  const selection = { generation: 0n, active: false, spans: [], topRow: 0, maximumTopRow: 100, alternateScreen: false };
  let selectedText = 'core selection';
  const terminal = {
    inputState: () => state, selectionState: () => ({ ...selection }), selectionText: () => selectedText,
    sendMouse: event => { calls.push(['mouse', { ...event }]); return true; },
    sendKey: event => { calls.push(['key', { ...event }]); return true; },
    sendKeyResult: event => { calls.push(['key', { ...event }]); return 'sent'; },
    sendText: text => calls.push(['text', text]),
    selectionBegin: (...args) => { calls.push(['begin', ...args]); selection.active = true; selection.generation++; },
    selectionExtend: (...args) => { calls.push(['extend', ...args]); selection.generation++; },
    selectionClear: () => { calls.push(['clear']); selection.active = false; selection.generation++; },
    selectionAll: () => { calls.push(['all']); selection.active = true; selection.generation++; },
    scrollViewport: delta => calls.push(['scroll', delta]),
    setFocus: focused => calls.push(['focus', focused]), setVisible: visible => calls.push(['visible', visible]),
    paste: (...args) => calls.push(['paste', ...args]),
  };
  const controller = new TerminalInputController(terminal, surface, input, {
    geometry: () => geometry, onError: error => errors.push(error), ...options,
  });
  t.after(() => {
    controller.dispose(); assert.deepEqual(errors, []);
    for (const [key, value] of Object.entries(old)) { if (value === undefined) delete globalThis[key]; else globalThis[key] = value; }
  });
  return { surface, input, terminal, controller, document, window, geometry, rect, captures, state, selection, calls, errors, focus,
    setText: text => { selectedText = text; },
    mouse: () => calls.filter(c => c[0] === 'mouse').map(c => c[1]),
    runFrame: time => { const work = [...frames.values()]; frames.clear(); for (const fn of work) fn(time); }, frames };
}

test('mouse press captures the pointer; outside release retains its button and is sent only once', t => {
  const f = fixture(t, { state: { mouseMode: 'button' } });
  assert.equal(f.surface.emit('pointerdown', { button: 2, clientX: 160, clientY: 90 }).defaultPrevented, true);
  assert.equal(f.document.activeElement, f.input); assert.equal(f.captures.has(1), true);
  f.surface.emit('pointermove', { button: -1, clientX: 180, clientY: 110 });
  f.surface.emit('pointerup', { button: 2, clientX: 800, clientY: 400 });
  assert.deepEqual(f.mouse().map(e => [e.action, e.button, e.col, e.row]), [['press', 2, 3, 2], ['move', 2, 4, 3], ['release', 2, 19, 9]]);
  assert.equal(f.captures.size, 0);
  f.surface.emit('pointerup', { button: 2 }); assert.equal(f.mouse().length, 3);
});

test('Shift selects locally for the entire gesture unless the terminal explicitly captures Shift', t => {
  const f = fixture(t, { state: { mouseMode: 'button' } });
  f.surface.emit('pointerdown', { shiftKey: true, clientX: 140, clientY: 70 });
  f.surface.emit('pointermove', { shiftKey: false, clientX: 200, clientY: 70 });
  f.surface.emit('pointerup', { clientX: 200, clientY: 70 });
  assert.deepEqual(f.mouse(), []);
  assert.ok(f.calls.some(c => c[0] === 'begin' && c[1] === 2 && c[2] === 1 && c[3] === 'extend'));
  assert.ok(f.calls.some(c => c[0] === 'extend' && c[1] === 5 && c[2] === 1));
  f.state.mouseShiftCapture = true;
  f.surface.emit('pointerdown', { shiftKey: true }); f.surface.emit('pointerup', { shiftKey: false });
  assert.deepEqual(f.mouse().map(e => [e.action, e.modifiers]), [['press', 1], ['release', 0]]);
});

test('a simple click clears selection; dragging selects core cells; double and triple clicks use core word and row selection', t => {
  const f = fixture(t);
  f.surface.emit('pointerdown'); f.surface.emit('pointerup');
  assert.equal(f.calls.filter(c => c[0] === 'clear').length, 1);
  assert.equal(f.calls.filter(c => c[0] === 'begin').length, 0);
  f.surface.emit('pointerdown', { clientX: 120, clientY: 70 });
  f.surface.emit('pointermove', { clientX: 220, clientY: 70 }); f.surface.emit('pointerup', { clientX: 220, clientY: 70 });
  assert.ok(f.calls.some(c => c[0] === 'begin' && c[1] === 1 && c[2] === 1));
  assert.ok(f.calls.some(c => c[0] === 'extend' && c[1] === 6 && c[2] === 1));
  for (let click = 0; click < 3; click++) { f.surface.emit('pointerdown', { detail: 0 }); f.surface.emit('pointerup'); }
  assert.deepEqual(f.calls.filter(c => c[0] === 'begin').slice(-2).map(c => c[3]), ['word', 'row']);
  assert.deepEqual(f.mouse(), []);
});

test('cancellation releases the last mouse position and button, and ignores a different pointer', t => {
  const f = fixture(t, { state: { mouseMode: 'button' } });
  f.surface.emit('pointerdown', { button: 1 });
  f.surface.emit('pointercancel', { pointerId: 2 }); assert.equal(f.mouse().length, 1);
  f.surface.emit('pointermove', { clientX: 200, clientY: 130 });
  f.surface.emit('pointercancel'); f.surface.emit('lostpointercapture');
  assert.deepEqual(f.mouse().map(e => [e.action, e.button, e.col, e.row]), [['press', 1, 0, 0], ['move', 1, 5, 4], ['release', 1, 5, 4]]);
});

test('CSS scaling and double-width rows affect cell coordinates but not logical pixel coordinates', t => {
  const f = fixture(t, { state: { mouseMode: 'any', mouseProtocol: 'pixel' }, geometry: { rowScale: row => row === 1 ? 2 : 1 } });
  f.surface.emit('pointerdown', { clientX: 230, clientY: 80 }); f.surface.emit('pointerup', { clientX: 230, clientY: 80 });
  assert.deepEqual(f.mouse()[0], { action: 'press', button: 0, col: 3, row: 1, pixelX: 65, pixelY: 15, modifiers: 0 });
  f.surface.emit('pointermove', { clientX: 230, clientY: 60 });
  assert.deepEqual(f.mouse().at(-1), { action: 'move', button: 3, col: 6, row: 0, pixelX: 65, pixelY: 5, modifiers: 0 });
});

test('cell motion suppresses duplicate coordinates while pixel motion retains movement inside a cell', t => {
  const f = fixture(t, { state: { mouseMode: 'any' } });
  f.surface.emit('pointermove', { clientX: 110 }); f.surface.emit('pointermove', { clientX: 112 });
  assert.equal(f.mouse().length, 1);
  f.state.mouseProtocol = 'pixel';
  f.surface.emit('pointermove', { clientX: 110 }); f.surface.emit('pointermove', { clientX: 112 });
  assert.deepEqual(f.mouse().slice(-2).map(e => e.pixelX), [5, 6]);
});

test('wheel fractions accumulate and reset across mouse, alternate-screen, and local scrolling routes', t => {
  const f = fixture(t); Object.assign(f.rect, { width: 200, height: 100, right: 300, bottom: 150 });
  assert.equal(f.surface.emit('wheel', { deltaY: 5 }).defaultPrevented, true);
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), []);
  f.surface.emit('wheel', { deltaY: 5 }); assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), [['scroll', 1]]);
  f.surface.emit('wheel', { deltaY: 5 }); f.state.mouseMode = 'button';
  f.surface.emit('wheel', { deltaY: 5 }); assert.equal(f.mouse().length, 0);
  f.surface.emit('wheel', { deltaY: 5 }); assert.equal(f.mouse()[0].button, 5);
  f.state.mouseMode = 'off'; f.state.alternateScreen = true; f.state.alternateScroll = true;
  f.surface.emit('wheel', { deltaY: -2, deltaMode: 1 });
  assert.deepEqual(f.calls.filter(c => c[0] === 'key').map(c => c[1].key), ['ArrowUp', 'ArrowUp']);
  assert.equal(f.surface.emit('wheel', { deltaY: 10, ctrlKey: true }).defaultPrevented, false);
});

test('inactive alternate-screen wheel routing discards prior scroll fractions', t => {
  const f = fixture(t); Object.assign(f.rect, { width: 200, height: 100, right: 300, bottom: 150 });
  f.surface.emit('wheel', { deltaY: 5 });
  f.state.alternateScreen = true; assert.equal(f.surface.emit('wheel', { deltaY: 5 }).defaultPrevented, false);
  f.state.alternateScreen = false; f.surface.emit('wheel', { deltaY: 5 });
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), []);
});

test('wheel page and horizontal deltas produce semantic wheel buttons', t => {
  const f = fixture(t, { state: { mouseMode: 'any' } });
  f.surface.emit('wheel', { deltaY: -1, deltaMode: 2 });
  assert.equal(f.mouse().length, 10); assert.ok(f.mouse().every(e => e.action === 'wheel' && e.button === 4));
  f.surface.emit('wheel', { deltaX: 2, deltaMode: 1 });
  assert.deepEqual(f.mouse().slice(-2).map(e => e.button), [7, 7]);
});

test('a deferred mouse release precedes the next press after transport pressure clears', t => {
  let enabled = true;
  const f = fixture(t, { state: { mouseMode: 'button' }, options: { canInput: () => enabled } });
  f.surface.emit('pointerdown'); enabled = false; f.surface.emit('pointerup');
  assert.deepEqual(f.mouse().map(e => e.action), ['press']);
  enabled = true; f.surface.emit('pointerdown', { pointerId: 2 }); f.surface.emit('pointerup', { pointerId: 2 });
  assert.deepEqual(f.mouse().map(e => e.action), ['press', 'release', 'press', 'release']);
});

test('selection autoscroll is bounded and stops when input becomes unavailable', t => {
  let enabled = true;
  const f = fixture(t, { options: { canInput: () => enabled } });
  f.surface.emit('pointerdown'); f.surface.emit('pointermove', { clientY: 1000 }); f.runFrame(100);
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), [['scroll', 6]]);
  enabled = false; f.controller.refresh(); f.runFrame(200); f.runFrame(300);
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), [['scroll', 6]]);
});

test('copy uses core selection text, and inactive selection leaves browser copy unchanged', t => {
  const f = fixture(t, { state: { mouseMode: 'any' } }), copied = [];
  const clipboardData = { setData: (...args) => copied.push(args) };
  assert.equal(f.input.emit('copy', { clipboardData }).defaultPrevented, false);
  f.selection.active = true; f.setText('界e\u0301🙂\nscrollback');
  assert.equal(f.input.emit('copy', { clipboardData }).defaultPrevented, true);
  assert.deepEqual(copied, [['text/plain', '界e\u0301🙂\nscrollback']]);
});

test('terminal focus follows the textarea, window focus, and visibility; disposal clears focus and listeners', t => {
  const f = fixture(t);
  assert.deepEqual(f.calls.filter(c => c[0] === 'focus'), [['focus', false]]);
  f.focus(f.input); f.focus(new Target()); f.focus(f.input);
  f.document.windowFocused = false; f.window.emit('blur');
  f.document.windowFocused = true; f.window.emit('focus');
  f.document.hidden = true; f.document.emit('visibilitychange');
  f.document.hidden = false; f.document.emit('visibilitychange');
  assert.deepEqual(f.calls.filter(c => c[0] === 'focus').map(c => c[1]), [false, true, false, true, false, true, false, true]);
  f.controller.dispose();
  assert.deepEqual(f.calls.filter(c => c[0] === 'focus').at(-1), ['focus', false]);
  const count = f.calls.length; f.surface.emit('pointerdown'); f.input.emit('keydown', { key: 'a', code: 'KeyA' });
  f.window.emit('focus'); assert.equal(f.calls.length, count);
});

test('the outer controller permits a caller to replace default browser shortcut routing', t => {
  const f = fixture(t, { options: { shortcut: () => false } });
  assert.equal(f.input.emit('keydown', { key: 'l', code: 'KeyL', ctrlKey: true }).defaultPrevented, true);
  assert.deepEqual(f.calls.filter(c => c[0] === 'key').map(c => c[1].key), ['l']);
});

test('deferred mouse release precedes resumed hover motion and paste', t => {
  let enabled = true;
  const f = fixture(t, { state: { mouseMode: 'any' }, options: { canInput: () => enabled } });
  f.surface.emit('pointerdown'); enabled = false; f.surface.emit('pointerup'); enabled = true;
  f.surface.emit('pointermove', { clientX: 200 });
  assert.deepEqual(f.mouse().map(e => e.action), ['press', 'release', 'move']);
  f.surface.emit('pointerdown'); enabled = false; f.surface.emit('pointerup'); enabled = true;
  f.input.emit('paste', { clipboardData: { getData: () => 'a\r\nb' } });
  assert.deepEqual(f.calls.filter(c => ['mouse', 'paste'].includes(c[0])).slice(-3).map(c => c[0] === 'mouse' ? c[1].action : c[0]),
    ['press', 'release', 'paste']);
  assert.deepEqual(f.calls.filter(c => c[0] === 'paste'), [['paste', 'a\nb', { clipboard: true }]]);
});

test('pixel wheel deltas use the CSS height of a row', t => {
  const f = fixture(t);
  f.surface.emit('wheel', { deltaY: 10 });
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), []);
  f.surface.emit('wheel', { deltaY: 10 });
  assert.deepEqual(f.calls.filter(c => c[0] === 'scroll'), [['scroll', 1]]);
});

test('IME textarea tracks the cursor on a double-width row after CSS scaling', t => {
  const f = fixture(t, { geometry: { cursor: { x: 3, y: 1 }, rowScale: row => row === 1 ? 2 : 1 } });
  assert.equal(f.input.style.left, '120px');
  assert.equal(f.input.style.top, '20px');
});

test('two terminal controllers keep focus and key releases with their own textarea', t => {
  const f = fixture(t), input2 = new Target(), surface2 = new Target(), second = [];
  Object.assign(input2, { value: '', disabled: false, style: {}, ownerDocument: f.input.ownerDocument });
  input2.focus = () => f.focus(input2);
  Object.assign(surface2, { offsetLeft: 0, offsetTop: 0, getBoundingClientRect: () => f.rect });
  const terminal2 = { ...f.terminal,
    setFocus: value => second.push(['focus', value]),
    sendKeyResult: event => { second.push(['key', { ...event }]); return 'sent'; },
  };
  const other = new TerminalInputController(terminal2, surface2, input2, { geometry: () => f.geometry });
  try {
    f.focus(f.input); f.input.emit('keydown', { key: 'a', code: 'KeyA' }); f.focus(input2);
    input2.emit('keydown', { key: 'b', code: 'KeyB' }); input2.emit('keyup', { key: 'b', code: 'KeyB' });
    assert.deepEqual(f.calls.filter(c => c[0] === 'focus').map(c => c[1]), [false, true, false]);
    assert.deepEqual(second.filter(c => c[0] === 'focus').map(c => c[1]), [false, true]);
    assert.deepEqual(f.calls.filter(c => c[0] === 'key').map(c => [c[1].key, c[1].eventType]), [['a', 1], ['a', 3]]);
    assert.deepEqual(second.filter(c => c[0] === 'key').map(c => [c[1].key, c[1].eventType]), [['b', 1], ['b', 3]]);
  } finally { other.dispose(); }
});


test('zero-detail pointer clicks cycle character, word, row and restart after time, distance, drag, or blur', t => {
  const f = fixture(t);
  const click = fields => { f.surface.emit('pointerdown', { detail: 0, ...fields }); f.surface.emit('pointerup', fields); };
  for (let i = 0; i < 4; i++) click({ timeStamp: 1000 + i * 50 });
  assert.deepEqual(f.calls.filter(c => ['clear', 'begin'].includes(c[0])).map(c => c[0] === 'clear' ? 'clear' : c[3]), ['clear', 'word', 'row', 'clear']);
  click({ timeStamp: 1800 });
  assert.equal(f.calls.filter(c => ['clear', 'begin'].includes(c[0])).at(-1)[0], 'clear');
  click({ timeStamp: 1850, clientX: 150 });
  assert.equal(f.calls.filter(c => ['clear', 'begin'].includes(c[0])).at(-1)[0], 'clear');
  f.surface.emit('pointerdown', { timeStamp: 1900, clientX: 150 });
  f.surface.emit('pointermove', { clientX: 200 }); f.surface.emit('pointerup', { clientX: 200 });
  click({ timeStamp: 1950, clientX: 200 });
  assert.equal(f.calls.filter(c => ['clear', 'begin'].includes(c[0])).at(-1)[0], 'clear');
  f.focus(new Target()); click({ timeStamp: 2000, clientX: 200 });
  assert.equal(f.calls.filter(c => ['clear', 'begin'].includes(c[0])).at(-1)[0], 'clear');
});

test('deferred keyboard and mouse releases retain their event order in both directions', t => {
  let enabled = true;
  const f = fixture(t, { state: { mouseMode: 'button' }, options: { canInput: () => enabled } });
  for (const keyFirst of [true, false]) {
    f.input.emit('keydown', { key: 'a', code: 'KeyA' }); f.surface.emit('pointerdown'); enabled = false;
    const keyup = () => f.input.emit('keyup', { key: 'a', code: 'KeyA' });
    const mouseup = () => f.surface.emit('pointerup');
    if (keyFirst) { keyup(); mouseup(); } else { mouseup(); keyup(); }
    enabled = true; f.controller.refresh();
    const releases = f.calls.filter(c => (c[0] === 'key' && c[1].eventType === 3) || (c[0] === 'mouse' && c[1].action === 'release'));
    assert.deepEqual(releases.slice(-2).map(c => c[0]), keyFirst ? ['key', 'mouse'] : ['mouse', 'key']);
  }
});

test('blur caused by pressure inside the mouse press callback cannot strand a sent press', t => {
  let f, enabled = true, armed = false;
  f = fixture(t, { state: { mouseMode: 'button' }, options: {
    canInput: () => enabled,
    onInput: () => { if (armed) { armed = false; enabled = false; f.input.disabled = true; f.focus(null); } },
  } });
  f.focus(f.input); armed = true; f.surface.emit('pointerdown');
  assert.deepEqual(f.mouse().map(e => e.action), ['press']); assert.equal(f.captures.size, 0);
  enabled = true; f.input.disabled = false; f.controller.refresh();
  assert.deepEqual(f.mouse().map(e => e.action), ['press', 'release']);
  f.surface.emit('pointerup'); assert.equal(f.mouse().length, 2);
});

test('disposal in a mouse press callback releases the press without restoring pointer capture', t => {
  let f, armed = false;
  f = fixture(t, { state: { mouseMode: 'button' }, options: { onInput: () => { if (armed) f.controller.dispose(); } } });
  f.focus(f.input); armed = true; f.surface.emit('pointerdown');
  assert.deepEqual(f.mouse().map(e => e.action), ['press', 'release']); assert.equal(f.captures.size, 0);
});

test('pointer capture failure releases a sent press and reports the error', t => {
  const errors = [], f = fixture(t, { state: { mouseMode: 'button' }, options: { onError: error => errors.push(error.message) } });
  f.surface.setPointerCapture = () => { throw new Error('capture failed'); };
  f.surface.emit('pointerdown');
  assert.deepEqual(f.mouse().map(e => e.action), ['press', 'release']); assert.deepEqual(errors, ['capture failed']);
});
