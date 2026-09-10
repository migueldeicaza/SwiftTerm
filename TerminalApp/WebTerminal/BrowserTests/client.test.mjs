import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeKey, gridDimensions, sendBytes, decodeServerMessage, MAX_INPUT_BYTES, MAX_BUFFERED_BYTES, ShellClient } from '../Public/app.js';
const key = (key, modifiers = {}) => encodeKey({ key, ...modifiers });
test('common VT keys preserve input direction and leave text/IME to the browser', () => {
  assert.equal(key('Enter'), '\r'); assert.equal(key('Backspace'), '\x7f'); assert.equal(key('Delete'), '\x1b[3~');
  assert.equal(key('ArrowUp'), '\x1b[A'); assert.equal(key('ArrowLeft', { ctrlKey: true }), '\x1b[1;5D');
  assert.equal(key('ArrowDown', { altKey: true, shiftKey: true }), '\x1b[1;4B');
  assert.equal(key('c', { ctrlKey: true }), '\x03'); assert.equal(key(' ', { ctrlKey: true }), '\x00');
  assert.equal(key('x', { altKey: true }), '\x1bx'); assert.equal(key('Tab', { shiftKey: true }), '\x1b[Z');
  assert.equal(key('F1'), '\x1bOP'); assert.equal(key('F12'), '\x1b[24~');
  assert.equal(key('a'), null); assert.equal(key('é'), null); assert.equal(key('Enter', { isComposing: true }), null);
  assert.equal(key('v', { metaKey: true }), null); assert.equal(key('v', { ctrlKey: true, shiftKey: true }), null);
});
test('grid sizes stay within server bounds', () => {
  assert.deepEqual(gridDimensions(809, 499, 10, 20), { cols: 80, rows: 24 });
  assert.deepEqual(gridDimensions(0, 0, 10, 20), { cols: 2, rows: 2 });
  assert.deepEqual(gridDimensions(100000, 100000, 1, 1), { cols: 500, rows: 300 });
});
test('bounded input sends only into an open socket and reports failed sends', () => {
  const sent = [], socket = { readyState: 0, bufferedAmount: 0, send: bytes => sent.push(bytes) };
  assert.deepEqual(sendBytes(socket, Uint8Array.of(1)), { ok: false, reason: 'closed' });
  socket.readyState = 1;
  assert.deepEqual(sendBytes(socket, new Uint8Array(MAX_INPUT_BYTES + 1)), { ok: false, reason: 'size' });
  socket.bufferedAmount = MAX_BUFFERED_BYTES;
  assert.deepEqual(sendBytes(socket, Uint8Array.of(1)), { ok: false, reason: 'backpressure' });
  assert.equal(sent.length, 0); socket.bufferedAmount = 0;
  assert.deepEqual(sendBytes(socket, Uint8Array.of(1)), { ok: true }); assert.deepEqual([...sent[0]], [1]);
  socket.send = () => { throw new Error('closed during send'); };
  assert.deepEqual(sendBytes(socket, Uint8Array.of(1)), { ok: false, reason: 'closed' });
});
test('server control frames are small typed records', () => {
  assert.deepEqual(decodeServerMessage('{"type":"ready"}'), { type: 'ready' });
  assert.deepEqual(decodeServerMessage('{"type":"exit","code":null}'), { type: 'exit', code: null });
  assert.deepEqual(decodeServerMessage('{"type":"exit","code":2}'), { type: 'exit', code: 2 });
  assert.deepEqual(decodeServerMessage('{"type":"error","message":"failed"}'), { type: 'error', message: 'failed' });
  for (const invalid of ['null', '[]', '{', '{"type":"exit","code":"0"}', '{"type":"unknown"}', 'x'.repeat(17000)]) assert.throws(() => decodeServerMessage(invalid));
});
test('shell client sends resize and user bytes, writes process bytes, retains replies, and disposes old connections', () => {
  const names = ['window', 'location', 'ResizeObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const old = Object.fromEntries(names.map(name => [name, globalThis[name]]));
  class Element extends EventTarget {
    disabled = true; value = ''; dataset = {}; textContent = ''; clientWidth = 809; clientHeight = 499; focused = false;
    focus() { this.focused = true; }
    getContext() { return { measureText: () => ({ width: 10 }) }; }
  }
  class Socket extends EventTarget {
    static latest; readyState = 0; bufferedAmount = 0; sent = [];
    constructor(url) { super(); this.url = url.href; Socket.latest = this; }
    send(data) { if (this.throwSend) throw new Error('send failed'); this.sent.push(data); this.bufferedAmount += typeof data === 'string' ? data.length : data.length; }
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
    open() { this.readyState = 1; this.dispatchEvent(new Event('open')); }
    message(data) { this.dispatchEvent(new MessageEvent('message', { data })); }
  }
  const terminals = [], renderers = [];
  const module = { capabilities: 256, createTerminal: options => {
    const terminal = { options, writes: [], resizes: [], disposed: 0, output: new Uint8Array(),
      paste(text, options) { this.lastPaste = { text, options }; this.output = new TextEncoder().encode(text.replace(/\n/g, '\r')); },
      write(bytes) { this.writes.push(bytes); }, resize(...args) { this.resizes.push(args); },
      readOutput() { return this.output.slice(); }, consumeOutput(n) { this.output = this.output.slice(n); }, drainEvents() { return []; }, dispose() { this.disposed++; }
    }; terminals.push(terminal); return terminal;
  } };
  class Renderer { disposed = 0; frames = 0; constructor() { renderers.push(this); } requestFrame() { this.frames++; } dispose() { this.disposed++; } }
  globalThis.window = { setInterval: () => 0 };
  globalThis.location = new URL('http://127.0.0.1:8080/');
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  globalThis.requestAnimationFrame = () => 0; globalThis.cancelAnimationFrame = () => {};
  const elements = Object.fromEntries(['input', 'screen', 'reconnect', 'canvas', 'status', 'title', 'geometry'].map(name => [name, new Element()]));
  let client;
  try {
    client = new ShellClient(module, Renderer, elements, Socket); client.connect();
    const socket = Socket.latest, terminal = terminals[0]; assert.equal(socket.url, 'ws://127.0.0.1:8080/terminal');
    client.sendInput('x'); assert.equal(socket.sent.length, 0); socket.open();
    assert.deepEqual(JSON.parse(socket.sent[0]), { type: 'resize', cols: 80, rows: 24, cellWidth: 10, cellHeight: 20 });
    assert.equal(elements.input.disabled, true); socket.message('{"type":"ready"}'); assert.equal(elements.input.disabled, false);
    elements.input.focused = false;
    const pointer = new Event('pointerdown', { cancelable: true }); Object.assign(pointer, { button: 0 });
    elements.screen.dispatchEvent(pointer); assert.ok(pointer.defaultPrevented); assert.ok(elements.input.focused, 'canvas clicks retain terminal input focus');
    client.sendInput('é'); assert.deepEqual([...socket.sent.at(-1)], [195, 169]); assert.equal(terminal.writes.length, 0, 'user bytes must not enter terminal.write');
    const compositionSends = socket.sent.length;
    elements.input.dispatchEvent(new Event('compositionstart'));
    elements.input.value = '日本'; elements.input.dispatchEvent(new Event('input'));
    assert.equal(socket.sent.length, compositionSends);
    elements.input.dispatchEvent(new Event('compositionend'));
    elements.input.dispatchEvent(new Event('input'));
    assert.equal(socket.sent.length, compositionSends + 1, 'IME commits must be sent once');
    assert.equal(new TextDecoder().decode(socket.sent.at(-1)), '日本');
    const paste = new Event('paste', { cancelable: true });
    Object.assign(paste, { clipboardData: { getData: () => 'one\ntwo\r\n' } });
    elements.input.dispatchEvent(paste); assert.ok(paste.defaultPrevented);
    assert.equal(new TextDecoder().decode(socket.sent.at(-1)), 'one\rtwo\r');
    assert.deepEqual(terminal.lastPaste, { text: 'one\ntwo\n', options: { clipboard: true, allowUnsafe: false } });
    const leave = new Event('keydown', { cancelable: true }); Object.assign(leave, { key: 'Escape', shiftKey: true });
    elements.input.dispatchEvent(leave); assert.ok(elements.reconnect.focused);
    socket.message(Uint8Array.of(72, 105).buffer); assert.deepEqual([...terminal.writes[0]], [72, 105]); assert.ok(renderers[0].frames > 0);
    terminal.output = Uint8Array.of(27, 91, 82); socket.bufferedAmount = MAX_BUFFERED_BYTES; client.pump();
    assert.deepEqual([...terminal.output], [27, 91, 82]); assert.equal(elements.input.disabled, true); assert.equal(elements.status.dataset.state, 'paused');
    socket.bufferedAmount = 0; client.pump(); assert.equal(terminal.output.length, 0); assert.deepEqual([...socket.sent.at(-1)], [27, 91, 82]); assert.equal(elements.input.disabled, false);
    terminal.output = Uint8Array.of(9); socket.throwSend = true; client.pump(); assert.deepEqual([...terminal.output], [9]); socket.throwSend = false;
    client.connect(); assert.equal(terminal.disposed, 1); assert.equal(renderers[0].disposed, 1); assert.equal(socket.readyState, 3);
    socket.message(Uint8Array.of(88).buffer); assert.equal(terminal.writes.length, 1, 'old socket events must be ignored');
    const next = Socket.latest; next.open(); next.message('{"type":"ready"}'); next.message('{"type":"exit","code":0}'); assert.equal(elements.input.disabled, true); assert.match(elements.status.textContent, /code 0/);
    client.dispose(); client.dispose(); assert.equal(terminals[1].disposed, 1); assert.equal(renderers[1].disposed, 1);
  } finally {
    client?.dispose();
    for (const [name, value] of Object.entries(old)) { if (value === undefined) delete globalThis[name]; else globalThis[name] = value; }
  }
});

test('fallback keys use application cursor and physical keypad modes', () => {
  assert.equal(encodeKey({key: 'ArrowUp'}, {applicationCursor: true}), '\x1bOA');
  assert.equal(encodeKey({key: 'Home'}, {applicationCursor: true}), '\x1bOH');
  assert.equal(encodeKey({key: 'ArrowUp', ctrlKey: true}, {applicationCursor: true}), '\x1b[1;5A');
  assert.equal(encodeKey({key: '1', code: 'Numpad1'}, {applicationKeypad: true}), '\x1bOq');
  assert.equal(encodeKey({key: 'Enter', code: 'NumpadEnter'}, {applicationKeypad: true}), '\x1bOM');
});
