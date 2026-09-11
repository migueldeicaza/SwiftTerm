import test from 'node:test';
import assert from 'node:assert/strict';
import { gridDimensions, sendBytes, decodeServerMessage, MAX_INPUT_BYTES, MAX_BUFFERED_BYTES, ShellClient } from '../Public/app.js';
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
test('shell client connects the input controller to one ordered output queue and disposes old connections', () => {
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
    send(data) { if (this.throwSend) throw new Error('send failed'); this.sent.push(data); this.bufferedAmount += data.length; }
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
    open() { this.readyState = 1; this.dispatchEvent(new Event('open')); }
    message(data) { this.dispatchEvent(new MessageEvent('message', { data })); }
  }
  const terminals = [], renderers = [], controllers = [], lifecycle = [], browserKeys = [];
  const module = { capabilities: 256, createTerminal: options => {
    const terminal = { options, writes: [], resizes: [], texts: [], disposed: 0, output: new Uint8Array(),
      queue(bytes) { this.output = Uint8Array.from([...this.output, ...bytes]); },
      sendText(text) { this.texts.push(text); this.queue(new TextEncoder().encode(text)); },
      paste(text, options) { this.lastPaste = { text, options }; this.queue(new TextEncoder().encode(text.replace(/\n/g, '\r'))); },
      write(bytes) { this.writes.push(bytes); }, resize(...args) { this.resizes.push(args); },
      readOutput() { return this.output.slice(); }, consumeOutput(n) { this.output = this.output.slice(n); },
      drainEvents() { return []; }, dispose() { lifecycle.push('terminal'); this.disposed++; }
    }; terminals.push(terminal); return terminal;
  } };
  class Renderer {
    disposed = 0; frames = 0; selections = [];
    inputGeometry = { cols: 80, rows: 24, cellWidth: 10, cellHeight: 20, rowScale: row => row === 2 ? 2 : 1, cursor: { x: 3, y: 2 } };
    constructor() { renderers.push(this); }
    requestFrame() { this.frames++; }
    setSelection(state) { this.selections.push(state); }
    dispose() { lifecycle.push('renderer'); this.disposed++; }
  }
  // DOM routing has its own controller tests. This fake checks the host contract.
  class InputController {
    disposed = 0; refreshes = 0;
    constructor(terminal, surface, input, options) { Object.assign(this, { terminal, surface, input, options }); controllers.push(this); }
    commit(text) {
      if (!this.options.canInput()) return false;
      this.terminal.sendText(text); this.options.onInput(); return true;
    }
    refresh() { this.refreshes++; }
    dispose() { lifecycle.push('input'); this.disposed++; }
  }
  const browserShortcut = event => { browserKeys.push(event.key); return event.metaKey; };
  globalThis.window = { setInterval: () => 0 };
  globalThis.location = new URL('http://127.0.0.1:8080/');
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  globalThis.requestAnimationFrame = () => 0; globalThis.cancelAnimationFrame = () => {};
  const elements = Object.fromEntries(['input', 'screen', 'reconnect', 'canvas', 'status', 'title', 'geometry'].map(name => [name, new Element()]));
  let client;
  try {
    client = new ShellClient(module, Renderer, elements, Socket, InputController, browserShortcut); client.connect();
    const socket = Socket.latest, terminal = terminals[0], controller = controllers[0], renderer = renderers[0];
    assert.equal(socket.url, 'ws://127.0.0.1:8080/terminal');
    assert.equal(controller.terminal, terminal); assert.equal(controller.surface, elements.canvas); assert.equal(controller.input, elements.input);
    assert.deepEqual(controller.options.geometry(), renderer.inputGeometry); assert.equal(controller.options.geometry().rowScale(2), 2);
    assert.equal(controller.options.canInput(), false); assert.equal(controller.commit('before ready'), false);
    client.sendInput('x'); assert.equal(socket.sent.length, 0); assert.deepEqual(terminal.texts, []);
    socket.open();
    assert.deepEqual(JSON.parse(socket.sent[0]), { type: 'resize', cols: 80, rows: 24, cellWidth: 10, cellHeight: 20 });
    assert.equal(elements.input.disabled, true); socket.message('{"type":"ready"}');
    assert.equal(elements.input.disabled, false); assert.equal(controller.options.canInput(), true); assert.equal(elements.input.focused, true);

    // Engine replies, direct host input, and controller commits share the same pump.
    terminal.queue(Uint8Array.of(27, 91, 82)); const start = socket.sent.length;
    assert.equal(controller.commit('é'), true); client.sendInput('日本');
    assert.deepEqual(socket.sent.slice(start).map(bytes => [...bytes]), [[27, 91, 82], [195, 169], [230, 151, 165, 230, 156, 172]]);
    assert.deepEqual(terminal.texts, ['é', '日本']); assert.equal(terminal.output.length, 0);
    assert.equal(terminal.writes.length, 0, 'user input does not enter terminal.write');
    client.sendInput('x'.repeat(MAX_INPUT_BYTES + 1)); assert.deepEqual(terminal.texts, ['é', '日本']);
    assert.match(elements.status.textContent, /64 KiB/);

    const captures = [];
    client.connection.clipboard = { capturePaste: text => captures.push(text), expire() {}, dispose() { lifecycle.push('clipboard'); } };
    controller.options.onPaste('one\ntwo\n');
    assert.deepEqual(captures, ['one\ntwo\n']);
    assert.deepEqual(terminal.lastPaste, { text: 'one\ntwo\n', options: { clipboard: true, allowUnsafe: false } });
    assert.equal(new TextDecoder().decode(socket.sent.at(-1)), 'one\rtwo\r');
    const selection = { generation: 1n, active: true, spans: [{ row: 1, startCol: 2, endCol: 5 }] };
    controller.options.onSelection(selection); assert.deepEqual(renderer.selections, [selection]);
    const leave = new Event('keydown', { cancelable: true }); Object.assign(leave, { key: 'Escape', shiftKey: true });
    assert.equal(controller.options.shortcut(leave), true); assert.ok(leave.defaultPrevented); assert.ok(elements.reconnect.focused);
    assert.equal(controller.options.shortcut({ key: 'r', metaKey: true }), true); assert.deepEqual(browserKeys, ['r']);

    const frames = renderer.frames, refreshes = controller.refreshes;
    socket.message(Uint8Array.of(72, 105).buffer); assert.deepEqual([...terminal.writes[0]], [72, 105]);
    assert.ok(renderer.frames > frames); assert.ok(controller.refreshes > refreshes);
    const beforeDraw = controller.refreshes; renderer.onDraw();
    assert.ok(controller.refreshes > beforeDraw, 'drawn cursor changes update the IME position');
    elements.screen.clientWidth = 1000; elements.screen.clientHeight = 600; client.resize();
    assert.deepEqual(terminal.resizes.at(-1), [100, 30, 10, 20]);
    assert.deepEqual(JSON.parse(socket.sent.at(-1)), { type: 'resize', cols: 100, rows: 30, cellWidth: 10, cellHeight: 20 });
    assert.equal(controller.options.geometry().cols, 100, 'input uses the resized grid before the next draw');
    renderer.inputGeometry = { ...renderer.inputGeometry, cols: 100, rows: 30 };
    assert.equal(controller.options.geometry().cols, 100, 'geometry is read from the current renderer state');

    terminal.queue(Uint8Array.of(27, 91, 82)); socket.bufferedAmount = MAX_BUFFERED_BYTES; client.pump();
    assert.deepEqual([...terminal.output], [27, 91, 82]); assert.equal(elements.input.disabled, true);
    assert.equal(elements.status.dataset.state, 'paused'); assert.equal(controller.options.canInput(), false);
    assert.equal(controller.commit('blocked'), false); assert.deepEqual(terminal.texts, ['é', '日本']);
    const pausedRefreshes = controller.refreshes;
    socket.bufferedAmount = 0; client.pump();
    assert.equal(terminal.output.length, 0); assert.deepEqual([...socket.sent.at(-1)], [27, 91, 82]);
    assert.equal(elements.input.disabled, false); assert.ok(controller.refreshes > pausedRefreshes);
    terminal.queue(Uint8Array.of(9)); socket.throwSend = true; client.pump();
    assert.deepEqual([...terminal.output], [9]); socket.throwSend = false;

    client.connect();
    assert.equal(terminal.disposed, 1); assert.equal(renderer.disposed, 1); assert.equal(controller.disposed, 1);
    assert.deepEqual(lifecycle.slice(0, 4), ['input', 'clipboard', 'renderer', 'terminal']);
    assert.equal(socket.readyState, 3); assert.equal(controller.options.canInput(), false);
    socket.message(Uint8Array.of(88).buffer); assert.equal(terminal.writes.length, 1, 'old socket events are ignored');
    const next = Socket.latest; next.open(); next.message('{"type":"ready"}'); next.message('{"type":"exit","code":0}');
    assert.equal(elements.input.disabled, true); assert.match(elements.status.textContent, /code 0/);
    assert.equal(controllers[1].options.canInput(), false);
    client.connect(); Socket.latest.open(); Socket.latest.message('{"type":"ready"}');
    controllers[2].options.onError(new Error('terminal input failed'));
    assert.equal(elements.status.dataset.state, 'error'); assert.equal(elements.status.textContent, 'terminal input failed');
    // One rejected input call reports, and leaves the shell connected.
    assert.equal(Socket.latest.readyState, 1); assert.equal(elements.input.disabled, false);
    assert.equal(controllers[2].options.canInput(), true);
    const unsupported = new Error('This WASM artifact does not support this operation.'); unsupported.code = 'UNSUPPORTED';
    controllers[2].options.onError(unsupported);
    assert.match(elements.status.textContent, /Rebuild the WASM assets/);
    assert.equal(Socket.latest.readyState, 1);
    client.dispose(); client.dispose();
    for (let index = 1; index < 3; index++) {
      assert.equal(terminals[index].disposed, 1); assert.equal(renderers[index].disposed, 1); assert.equal(controllers[index].disposed, 1);
    }
  } finally {
    client?.dispose();
    for (const [name, value] of Object.entries(old)) { if (value === undefined) delete globalThis[name]; else globalThis[name] = value; }
  }
});

