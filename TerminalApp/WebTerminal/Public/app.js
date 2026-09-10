import { ClipboardController } from './clipboard.js';
const encoder = new TextEncoder();
export const MAX_INPUT_BYTES = 64 * 1024;
export const MAX_BUFFERED_BYTES = 1024 * 1024;
const RESUME_BUFFERED_BYTES = 256 * 1024;
const MAX_PROCESS_BYTES = 16 * 1024 * 1024;
const FONT = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';

/** Return common VT input bytes as text, or null to use browser text input. */
export function encodeKey(event, modes = {}) {
  if (event.isComposing || event.keyCode === 229 || event.metaKey) return null;
  const key = event.key, lower = key.toLowerCase();
  if (event.ctrlKey && event.shiftKey && (lower === 'c' || lower === 'v')) return null;
  const modifier = 1 + (event.shiftKey ? 1 : 0) + (event.altKey ? 2 : 0) + (event.ctrlKey ? 4 : 0);
  const cursors = { ArrowUp: 'A', ArrowDown: 'B', ArrowRight: 'C', ArrowLeft: 'D', Home: 'H', End: 'F' };
  if (modes.applicationKeypad && modifier === 1) {
    const keypad = { Numpad0: 'p', Numpad1: 'q', Numpad2: 'r', Numpad3: 's', Numpad4: 't', Numpad5: 'u', Numpad6: 'v', Numpad7: 'w', Numpad8: 'x', Numpad9: 'y', NumpadDecimal: 'n', NumpadDivide: 'o', NumpadMultiply: 'j', NumpadSubtract: 'm', NumpadAdd: 'k', NumpadEnter: 'M', NumpadEqual: 'X' };
    if (keypad[event.code]) return `\x1bO${keypad[event.code]}`;
  }
  if (cursors[key]) return modifier === 1 ? `\x1b${modes.applicationCursor ? 'O' : '['}${cursors[key]}` : `\x1b[1;${modifier}${cursors[key]}`;
  const numbered = { Insert: 2, Delete: 3, PageUp: 5, PageDown: 6, F5: 15, F6: 17, F7: 18, F8: 19, F9: 20, F10: 21, F11: 23, F12: 24 };
  if (numbered[key]) return `\x1b[${numbered[key]}${modifier === 1 ? '' : `;${modifier}`}~`;
  const functions = { F1: 'P', F2: 'Q', F3: 'R', F4: 'S' };
  if (functions[key]) return modifier === 1 ? `\x1bO${functions[key]}` : `\x1b[1;${modifier}${functions[key]}`;
  let text;
  if (key === 'Enter') text = '\r';
  else if (key === 'Backspace') text = '\x7f';
  else if (key === 'Tab') return event.shiftKey ? '\x1b[Z' : '\t';
  else if (key === 'Escape') return '\x1b';
  else if (event.ctrlKey) {
    if (key === ' ' || key === '2') text = '\x00';
    else if (key === '6') text = '\x1e';
    else if (key === '-') text = '\x1f';
    else if (key === '?' || key === '8') text = '\x7f';
    else if (key.length === 1 && key.toUpperCase().charCodeAt(0) >= 64 && key.toUpperCase().charCodeAt(0) <= 95) text = String.fromCharCode(key.toUpperCase().charCodeAt(0) & 31);
    else return null;
  } else if (event.altKey && [...key].length === 1) text = key;
  else return null;
  return event.altKey ? `\x1b${text}` : text;
}

export function gridDimensions(width, height, cellWidth, cellHeight) {
  return {
    cols: Math.max(2, Math.min(500, Math.floor(width / cellWidth) || 2)),
    rows: Math.max(2, Math.min(300, Math.floor(height / cellHeight) || 2))
  };
}

/** A successful send means the browser accepted the bytes into its send buffer. */
export function sendBytes(socket, bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > MAX_INPUT_BYTES) return { ok: false, reason: 'size' };
  if (socket.readyState !== 1) return { ok: false, reason: 'closed' };
  if (socket.bufferedAmount + bytes.byteLength > MAX_BUFFERED_BYTES) return { ok: false, reason: 'backpressure' };
  try { socket.send(bytes); return { ok: true }; }
  catch { return { ok: false, reason: 'closed' }; }
}

export function decodeServerMessage(text) {
  if (typeof text !== 'string' || text.length > 16 * 1024) throw new Error('Invalid server message.');
  let message;
  try { message = JSON.parse(text); } catch { throw new Error('Invalid server message.'); }
  if (!message || typeof message !== 'object') throw new Error('Invalid server message.');
  if (message.type === 'ready') return { type: 'ready' };
  if (message.type === 'exit' && (message.code === null || Number.isInteger(message.code))) return { type: 'exit', code: message.code };
  if (message.type === 'error' && typeof message.message === 'string') return { type: 'error', message: message.message.slice(0, 2048) };
  throw new Error('Unknown server message.');
}

export class ShellClient {
  constructor(module, Renderer, elements, Socket = WebSocket) {
    this.module = module;
    this.Renderer = Renderer;
    this.elements = elements;
    this.Socket = Socket;
    this.connection = null;
    this.disposed = false;
    this.composing = false;
    this.resizeFrame = 0;
    this.listeners = new AbortController();
    const { input, screen, reconnect } = elements, signal = this.listeners.signal;
    input.addEventListener('keydown', event => {
      if (event.key === 'Escape' && event.shiftKey && !event.isComposing) { event.preventDefault(); reconnect.focus(); return; }
      this.key(event);
    }, { signal });
    input.addEventListener('keyup', event => this.key(event, true), { signal });
    input.addEventListener('compositionstart', () => { this.composing = true; }, { signal });
    input.addEventListener('compositionend', () => {
      this.composing = false;
      const text = input.value; input.value = '';
      if (text) this.sendInput(text);
    }, { signal });
    input.addEventListener('input', event => {
      if (this.composing || event.isComposing) return;
      const text = input.value; input.value = '';
      if (text) this.sendInput(text);
    }, { signal });
    input.addEventListener('paste', event => {
      if (!event.clipboardData) return;
      event.preventDefault();
      const text = event.clipboardData.getData('text/plain').replace(/\r\n?/g, '\n');
      this.connection?.clipboard?.capturePaste(text);
      this.paste(text);
    }, { signal });
    screen.addEventListener('pointerdown', event => {
      if (event.button === 0 && !input.disabled) {
        // Keep the pointer default action from moving focus back to the canvas.
        event.preventDefault(); input.focus({ preventScroll: true });
      }
    }, { signal });
    reconnect.addEventListener('click', () => this.connect(), { signal });
    elements.pasteAllow?.addEventListener('click', () => {
      const pending = this.pendingPaste; this.pendingPaste = null; elements.pastePanel.hidden = true;
      if (pending?.connection === this.connection) this.paste(pending.text, true);
    }, { signal });
    elements.pasteDeny?.addEventListener('click', () => { this.pendingPaste = null; elements.pastePanel.hidden = true; }, { signal });
    this.observer = new ResizeObserver(() => {
      if (!this.resizeFrame) this.resizeFrame = requestAnimationFrame(() => { this.resizeFrame = 0; this.resize(); });
    });
    this.observer.observe(screen);
  }

  status(text, state = 'connecting') {
    this.elements.status.textContent = text;
    this.elements.status.dataset.state = state;
  }

  connect() {
    if (this.disposed) return;
    this.disconnect();
    this.status('Connecting to the local shell…');
    this.elements.title.textContent = 'Local shell';
    const measuring = this.elements.canvas.getContext('2d');
    measuring.font = `15px ${FONT}`;
    const cellWidth = Math.min(200, Math.max(1, Math.ceil(measuring.measureText('M').width))), cellHeight = 20;
    const size = gridDimensions(this.elements.screen.clientWidth, this.elements.screen.clientHeight, cellWidth, cellHeight);
    let terminal, renderer, socket;
    try {
      terminal = this.module.createTerminal({ ...size, scrollback: 10000 });
      renderer = new this.Renderer(this.elements.canvas, terminal, cellWidth, cellHeight, FONT);
      const url = new URL('/terminal', location.href); url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      socket = new this.Socket(url);
    } catch (error) {
      renderer?.dispose(); terminal?.dispose();
      this.status(error.message || 'Cannot open the terminal.', 'error');
      this.elements.reconnect.disabled = false;
      return;
    }
    socket.binaryType = 'arraybuffer';
    const connection = { terminal, renderer, socket, cellWidth, cellHeight, ...size, ready: false, ended: false, paused: false, rejectedInput: false, resizePending: true, replyPending: false, timer: 0 };
    this.connection = connection;
    if (this.elements.clipboard) connection.clipboard = new ClipboardController(terminal, this.elements.clipboard, () => this.pump(), globalThis.navigator?.clipboard, globalThis.ClipboardItem, !!(this.module.capabilities & 512));
    this.elements.reconnect.disabled = false;
    socket.addEventListener('open', () => {
      if (this.connection !== connection) return;
      this.resize(true);
    });
    socket.addEventListener('message', event => {
      if (this.connection !== connection || connection.ended) return;
      try {
        if (typeof event.data === 'string') {
          const message = decodeServerMessage(event.data);
          if (message.type === 'ready') {
            connection.ready = true; this.status('Connected · Local shell', 'connected'); this.pump();
            if (!this.elements.input.disabled) this.elements.input.focus({ preventScroll: true });
          } else if (message.type === 'exit') {
            connection.ended = true; connection.ready = false;
            this.status(message.code === null ? 'Shell exited. Reconnect to start a new shell.' : `Shell exited with code ${message.code}. Reconnect to start a new shell.`, 'closed');
            this.updateInput();
          } else this.fail(message.message);
        } else {
          if (!(event.data instanceof ArrayBuffer) || event.data.byteLength > MAX_PROCESS_BYTES) throw new Error('The server sent an invalid output frame.');
          terminal.write(new Uint8Array(event.data));
          renderer.requestFrame();
          this.events(connection);
          this.pump();
        }
      } catch (error) { this.fail(error.message || 'Terminal processing failed.'); }
    });
    socket.addEventListener('error', () => {
      if (this.connection === connection && !connection.ended) this.fail('The shell connection failed. Check the server, then reconnect.');
    });
    socket.addEventListener('close', () => {
      if (this.connection !== connection) return;
      if (!connection.ended) this.status('Disconnected. Reconnect to start a new shell.', 'closed');
      connection.ready = false; connection.ended = true; this.updateInput();
    });
    connection.timer = window.setInterval(() => this.pump(), 50);
    this.resize(); this.updateInput();
  }

  resize(force = false) {
    const connection = this.connection;
    if (!connection || connection.ended) return;
    try {
      const size = gridDimensions(this.elements.screen.clientWidth, this.elements.screen.clientHeight, connection.cellWidth, connection.cellHeight);
      if (force || size.cols !== connection.cols || size.rows !== connection.rows) {
        Object.assign(connection, size);
        connection.terminal.resize(size.cols, size.rows, connection.cellWidth, connection.cellHeight);
        connection.renderer.requestFrame(); connection.resizePending = true;
      }
      this.elements.geometry.textContent = `${size.cols} × ${size.rows}`;
      this.sendResize();
    } catch (error) { this.fail(error.message || 'Cannot resize the terminal.'); }
  }

  sendResize() {
    const c = this.connection;
    if (!c || !c.resizePending || c.socket.readyState !== 1) return;
    const message = JSON.stringify({ type: 'resize', cols: c.cols, rows: c.rows, cellWidth: c.cellWidth, cellHeight: c.cellHeight });
    if (c.socket.bufferedAmount + encoder.encode(message).length > MAX_BUFFERED_BYTES) return;
    c.socket.send(message); c.resizePending = false;
  }

  pump() {
    const c = this.connection;
    if (!c || c.ended || c.socket.readyState !== 1) return;
    try {
      if (this.module.capabilities & 8192) { if (c.terminal.poll()) c.renderer.requestFrame(); }
      this.events(c); c.clipboard?.expire();
      this.sendResize();
      const output = c.terminal.readOutput();
      let offset = 0;
      while (offset < output.length) {
        const bytes = output.subarray(offset, Math.min(offset + MAX_INPUT_BYTES, output.length));
        const result = sendBytes(c.socket, bytes);
        if (!result.ok) break;
        // A failed send leaves these reply bytes in the engine queue for the next poll.
        c.terminal.consumeOutput(bytes.length); offset += bytes.length;
      }
      c.replyPending = offset < output.length;
      if (c.replyPending || c.socket.bufferedAmount >= MAX_BUFFERED_BYTES) c.paused = true;
      else if (c.paused && c.socket.bufferedAmount <= RESUME_BUFFERED_BYTES) c.paused = false;
      this.updateInput();
    } catch (error) { this.fail(error.message || 'Cannot send terminal replies.'); }
  }

  events(connection) {
    for (const item of connection.terminal.drainEvents()) {
      if (item.type === 'title') this.elements.title.textContent = item.text.slice(0, 200) || 'Local shell';
      else if (item.type === 'clipboardWrite' || item.type === 'clipboardRequest') connection.clipboard?.accept(item);
    }
  }

  key(event, release = false) {
    if (event.isComposing || event.keyCode === 229 || this.composing) return;
    if (event.getModifierState?.('AltGraph') && [...event.key].length === 1) return;
    const lower = event.key?.toLowerCase();
    // Keep browser clipboard and window shortcuts reachable.
    if ((event.metaKey && ['c', 'v', 'x', 'r', 'l', 'w', 't'].includes(lower)) ||
        (event.ctrlKey && event.shiftKey && ['c', 'v'].includes(lower))) return;
    const c = this.connection;
    if (!c || !c.ready || c.ended || c.paused) return;
    if (this.module.capabilities & 32) {
      this.pump();
      if (c.paused) { event.preventDefault(); return; }
      const modifiers = (event.shiftKey ? 1 : 0) | (event.altKey ? 2 : 0) | (event.ctrlKey ? 4 : 0) | (event.metaKey ? 8 : 0)
        | (event.getModifierState?.('CapsLock') ? 64 : 0) | (event.getModifierState?.('NumLock') ? 128 : 0);
      const text = [...event.key].length === 1 && !event.ctrlKey && !event.altKey && !event.metaKey ? event.key : undefined;
      const base = /^Key[A-Z]$/.test(event.code ?? '') ? event.code.slice(3).toLowerCase().codePointAt(0) : 0;
      try {
        const handled = c.terminal.sendKey({ key: event.key, code: event.code ?? '', modifiers,
          eventType: release ? 3 : event.repeat ? 2 : 1, text,
          shiftedKey: event.shiftKey && text ? text.codePointAt(0) : 0, baseLayoutKey: base });
        if (handled) event.preventDefault();
        this.pump();
      } catch (error) { this.fail(error.message); }
    } else if (!release) {
      const modes = this.module.capabilities & 128 ? c.terminal.inputModes() : {};
      const text = encodeKey(event, modes);
      if (text !== null) { event.preventDefault(); this.sendInput(text); }
    }
  }

  paste(text, allowUnsafe = false) {
    const c = this.connection;
    if (!c || !c.ready || c.ended) return;
    if (text.length > MAX_INPUT_BYTES || encoder.encode(text).length > MAX_INPUT_BYTES) { this.status('Paste was not sent. Send at most 64 KiB at a time.', 'error'); return; }
    this.pump(); if (c.paused) { c.rejectedInput = true; this.updateInput(); return; }
    try {
      if (!(this.module.capabilities & 256)) { this.status('This artifact has no paste API. Rebuild the WASM assets.', 'error'); return; }
      c.terminal.paste(text, { clipboard: true, allowUnsafe });
      this.pump();
    } catch (error) {
      if (error.code === 'INVALID_ARGUMENT' && !allowUnsafe && /approval/.test(error.message)) {
        this.pendingPaste = { connection: c, text };
        if (this.elements.pastePanel) this.elements.pastePanel.hidden = false;
        this.status('Paste needs approval. Newlines can run shell commands.', 'paused');
      } else this.status(error.message || 'Paste failed.', 'error');
    }
  }

  updateInput() {
    const c = this.connection;
    const enabled = !!c && c.ready && !c.ended && !c.paused && c.socket.readyState === 1;
    const wasDisabled = this.elements.input.disabled;
    this.elements.input.disabled = !enabled;
    if (c?.paused && !c.ended) this.status(c.rejectedInput ? 'Input paused. The last input was not sent; send it again after the connection resumes.' : 'Input paused while the connection sends queued data.', 'paused');
    else if (enabled && this.elements.status.dataset.state === 'paused') {
      this.status(c.rejectedInput ? 'Connected. The last input was not sent; send it again.' : 'Connected · Local shell', 'connected');
      if (wasDisabled) this.elements.input.focus({ preventScroll: true });
    }
  }

  sendInput(text) {
    const c = this.connection;
    if (!text) return;
    if (!c || !c.ready || c.ended || c.socket.readyState !== 1) { this.status('Input was not sent. Connect to a shell first.', 'closed'); return; }
    if (text.length > MAX_INPUT_BYTES) { this.status('Input was not sent. Send at most 64 KiB at a time.', 'error'); return; }
    const bytes = encoder.encode(text);
    if (bytes.length > MAX_INPUT_BYTES) { this.status('Input was not sent. Send at most 64 KiB at a time.', 'error'); return; }
    this.pump();
    if (c.paused) { c.rejectedInput = true; this.updateInput(); return; }
    const result = sendBytes(c.socket, bytes);
    if (result.ok) {
      c.rejectedInput = false;
      if (this.elements.status.dataset.state === 'error' || this.elements.status.dataset.state === 'connected') this.status('Connected · Local shell', 'connected');
      this.pump();
    } else if (result.reason === 'backpressure') {
      c.paused = true; c.rejectedInput = true; this.updateInput();
    } else this.fail('The shell connection closed before input could be sent.');
  }

  fail(message) {
    const c = this.connection;
    if (c) { c.ended = true; c.ready = false; if (c.socket.readyState < 2) c.socket.close(); }
    this.status(message, 'error'); this.updateInput();
  }

  disconnect() {
    const c = this.connection;
    this.connection = null;
    this.elements.input.disabled = true; this.elements.input.value = ''; this.composing = false;
    this.pendingPaste = null; if (this.elements.pastePanel) this.elements.pastePanel.hidden = true;
    if (!c) return;
    clearInterval(c.timer);
    c.clipboard?.dispose(); c.renderer.dispose(); c.terminal.dispose();
    if (c.socket.readyState < 2) c.socket.close();
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true; this.disconnect(); this.observer.disconnect(); this.listeners.abort();
    if (this.resizeFrame) cancelAnimationFrame(this.resizeFrame);
  }
}

async function start() {
  const elements = {
    canvas: document.querySelector('#terminal-canvas'), input: document.querySelector('#terminal-input'),
    screen: document.querySelector('#screen'), status: document.querySelector('#status'),
    clipboard: { enable: document.querySelector('#clipboard-enable'), panel: document.querySelector('#clipboard-panel'), message: document.querySelector('#clipboard-message'), allow: document.querySelector('#clipboard-allow'), deny: document.querySelector('#clipboard-deny') },
    pastePanel: document.querySelector('#paste-panel'), pasteAllow: document.querySelector('#paste-allow'), pasteDeny: document.querySelector('#paste-deny'),
    reconnect: document.querySelector('#reconnect'), title: document.querySelector('#session-title'), geometry: document.querySelector('#geometry')
  };
  const variant = new URL(location.href).searchParams.get('variant') === 'embedded' ? 'embedded' : 'full';
  document.querySelector('#engine').textContent = `${variant === 'full' ? 'Full' : 'Embedded'} WASM`;
  let client, gone = false;
  window.addEventListener('pagehide', () => { gone = true; client?.dispose(); }, { once: true });
  try {
    const [{ loadSwiftTerm }, { CanvasTerminalRenderer }] = await Promise.all([
      import('/assets/index.js'), import('/assets/example/canvas2d.js')
    ]);
    const module = await loadSwiftTerm({ wasmURL: `/assets/swiftterm-${variant}.wasm` });
    if (gone) return;
    client = new ShellClient(module, CanvasTerminalRenderer, elements); client.connect();
  } catch (error) {
    elements.status.textContent = `Cannot load the terminal: ${error.message}`;
    elements.status.dataset.state = 'error';
    elements.reconnect.textContent = 'Reload'; elements.reconnect.disabled = false;
    elements.reconnect.addEventListener('click', () => location.reload());
  }
}
if (typeof document !== 'undefined') void start();
