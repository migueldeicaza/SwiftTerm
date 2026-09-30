// Run against a server that is already running:
// node TerminalApps/WebTerminal/BrowserTests/server-smoke.mjs http://127.0.0.1:8080
// The test starts one shell, runs printf/stty, and exits that shell with code 7.
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { loadSwiftTerm } from '../../../Web/dist/index.js';
import { decodeServerMessage } from '../Public/app.js';

const base = new URL(process.argv[2] || process.env.WEB_TERMINAL_URL || 'http://127.0.0.1:8080');
assert.equal(base.protocol, 'http:', 'Use the local HTTP server URL.');
assert.equal(base.hostname, '127.0.0.1', 'This smoke test accepts 127.0.0.1 only.');
assert.ok(!base.username && !base.password && base.pathname === '/' && !base.search && !base.hash, 'Use an origin URL without a path or credentials.');

// Node's built-in WebSocket does not accept an Origin header. Use a small
// RFC 6455 transport so the test does not weaken the server's Origin check.
class SmokeWebSocket {
  constructor(socket, initialBytes) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.messages = [];
    this.waiting = null;
    this.fragment = null;
    this.closed = false;
    this.failure = null;
    socket.on('data', bytes => this.receive(bytes));
    socket.on('error', error => this.fail(error));
    socket.on('close', () => {
      this.closed = true;
      if (this.waiting) this.fail(new Error('The WebSocket closed before the expected message arrived.'));
    });
    if (initialBytes.length) this.receive(initialBytes);
  }
  fail(error) {
    this.failure = error;
    if (this.waiting) { const waiting = this.waiting; this.waiting = null; clearTimeout(waiting.timer); waiting.reject(error); }
  }
  deliver(message) {
    if (this.waiting) { const waiting = this.waiting; this.waiting = null; clearTimeout(waiting.timer); waiting.resolve(message); }
    else this.messages.push(message);
  }
  receive(bytes) {
    try {
      assert.ok(this.buffer.length + bytes.length <= 32 * 1024 * 1024, 'Server frame buffer exceeded its limit.');
      this.buffer = Buffer.concat([this.buffer, bytes]);
      while (this.buffer.length >= 2) {
        const first = this.buffer[0], second = this.buffer[1], opcode = first & 15, final = !!(first & 128);
        assert.equal(first & 112, 0, 'Unexpected WebSocket extension bits.');
        assert.equal(second & 128, 0, 'Server frames must not be masked.');
        let length = second & 127, offset = 2;
        if (length === 126) { if (this.buffer.length < 4) return; length = this.buffer.readUInt16BE(2); offset = 4; }
        else if (length === 127) {
          if (this.buffer.length < 10) return;
          const large = this.buffer.readBigUInt64BE(2); assert.ok(large <= 16n * 1024n * 1024n, 'Server frame is too large.');
          length = Number(large); offset = 10;
        }
        assert.ok(length <= 16 * 1024 * 1024);
        if (this.buffer.length < offset + length) return;
        const payload = this.buffer.subarray(offset, offset + length);
        this.buffer = this.buffer.subarray(offset + length);
        if (opcode >= 8) {
          assert.ok(final && length <= 125, 'Invalid WebSocket control frame.');
          if (opcode === 9) this.sendFrame(10, payload);
          else if (opcode === 8) { this.deliver({ type: 'close' }); this.close(payload); return; }
          else assert.equal(opcode, 10, 'Unknown WebSocket control opcode.');
          continue;
        }
        if (opcode === 0) {
          assert.ok(this.fragment, 'Unexpected continuation frame.');
          this.fragment.parts.push(payload); this.fragment.size += payload.length;
        } else {
          assert.ok((opcode === 1 || opcode === 2) && !this.fragment, 'Invalid data frame sequence.');
          this.fragment = { opcode, parts: [payload], size: payload.length };
        }
        assert.ok(this.fragment.size <= 16 * 1024 * 1024, 'Server message is too large.');
        if (final) {
          const data = Buffer.concat(this.fragment.parts), type = this.fragment.opcode === 1 ? 'text' : 'binary';
          this.fragment = null;
          this.deliver({ type, data: type === 'text' ? new TextDecoder('utf-8', { fatal: true }).decode(data) : data });
        }
      }
    } catch (error) { this.fail(error); this.socket.destroy(); }
  }
  sendFrame(opcode, data) {
    assert.ok(!this.closed && !this.socket.destroyed, 'Cannot send into a closed socket.');
    const bytes = Buffer.from(data);
    assert.ok(bytes.length <= 65536, 'Client frame exceeds 64 KiB.');
    assert.ok(this.socket.writableLength + bytes.length < 1024 * 1024, 'Client send buffer exceeded its limit.');
    const extended = bytes.length < 126 ? 0 : bytes.length <= 65535 ? 2 : 8;
    const header = Buffer.alloc(2 + extended + 4), mask = randomBytes(4);
    header[0] = 128 | opcode; header[1] = 128 | (extended === 0 ? bytes.length : extended === 2 ? 126 : 127);
    if (extended === 2) header.writeUInt16BE(bytes.length, 2);
    if (extended === 8) header.writeBigUInt64BE(BigInt(bytes.length), 2);
    mask.copy(header, 2 + extended);
    const masked = Buffer.from(bytes); for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
    // A false return value means buffered, not rejected. Never retry these bytes.
    this.socket.write(Buffer.concat([header, masked]));
  }
  sendText(text) { this.sendFrame(1, Buffer.from(text)); }
  sendBinary(bytes) { this.sendFrame(2, bytes); }
  next(timeout = 15000) {
    if (this.messages.length) return Promise.resolve(this.messages.shift());
    if (this.failure) return Promise.reject(this.failure);
    if (this.closed) return Promise.reject(new Error('The WebSocket is closed.'));
    assert.equal(this.waiting, null, 'Only one test reader is supported.');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiting = null; reject(new Error('Timed out waiting for terminal output.')); this.socket.destroy(); }, timeout);
      this.waiting = { resolve, reject, timer };
    });
  }
  close(payload = Buffer.from([3, 232])) {
    if (this.closed) return;
    if (!this.socket.destroyed) { try { this.sendFrame(8, payload); } catch {} this.socket.end(); }
    this.closed = true;
  }
}

function upgrade(origin) {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString('base64');
    const headers = { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': key };
    if (origin !== null) headers.Origin = origin;
    const request = http.request(new URL('/terminal', base), { headers });
    request.setTimeout(10000, () => request.destroy(new Error('WebSocket upgrade timed out.')));
    request.on('error', reject);
    request.on('response', response => { response.resume(); resolve({ status: response.statusCode }); });
    request.on('upgrade', (response, socket, head) => {
      try {
        const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        assert.equal(response.statusCode, 101); assert.equal(response.headers['sec-websocket-accept'], accept);
        socket.setTimeout(0);
        resolve({ status: 101, channel: new SmokeWebSocket(socket, head) });
      } catch (error) { socket.destroy(); reject(error); }
    });
    request.end();
  });
}

async function get(path, expectedType) {
  const response = await fetch(new URL(path, base), { signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, 200, `${path} must be available.`);
  assert.match(response.headers.get('content-type') || '', expectedType, `${path} has an incorrect content type.`);
  return response;
}

let channel, terminal;
try {
  const html = await (await get('/', /^text\/html/)).text(); assert.match(html, /terminal-canvas/);
  await (await get('/app.js', /(?:javascript|ecmascript)/)).arrayBuffer();
  await (await get('/styles.css', /^text\/css/)).arrayBuffer();
  for (const path of ['/assets/index.js', '/assets/src/index.js', '/assets/example/canvas2d.js']) await (await get(path, /(?:javascript|ecmascript)/)).arrayBuffer();
  const wasm = await (await get('/assets/swiftterm-embedded.wasm', /^application\/wasm/)).arrayBuffer();
  assert.deepEqual([...new Uint8Array(wasm, 0, 4)], [0, 97, 115, 109], 'The WASM response must be a module.');
  const module = await loadSwiftTerm({ wasm }); terminal = module.createTerminal({ cols: 80, rows: 24, scrollback: 0 });
  for (const origin of ['http://foreign.invalid', null]) {
    const rejected = await upgrade(origin);
    if (rejected.channel) rejected.channel.close();
    assert.notEqual(rejected.status, 101, `The server must reject ${origin === null ? 'a missing Origin' : 'a foreign Origin'}.`);
  }
  channel = (await upgrade(base.origin)).channel; assert.ok(channel);
  let output = '', ready = false;
  const decoder = new TextDecoder();
  async function readUntil(predicate) {
    const deadline = Date.now() + 20000;
    for (;;) {
      assert.ok(Date.now() < deadline, 'Terminal operation timed out.');
      const message = await channel.next(Math.max(1, deadline - Date.now()));
      if (message.type === 'binary') {
        output += decoder.decode(message.data, { stream: true }); assert.ok(output.length <= 4 * 1024 * 1024, 'Unexpected output volume.');
        terminal.write(message.data);
        const replies = terminal.readOutput();
        if (replies.length) { channel.sendBinary(replies); terminal.consumeOutput(replies.length); }
      } else if (message.type === 'text') {
        const control = decodeServerMessage(message.data);
        if (control.type === 'error') throw new Error(control.message);
        if (control.type === 'ready') ready = true;
        if (predicate(control)) return control;
      } else throw new Error('The shell closed before the expected result.');
      if (predicate(null)) return null;
    }
  }
  await readUntil(() => ready);
  channel.sendText(JSON.stringify({ type: 'resize', cols: 91, rows: 31, cellWidth: 10, cellHeight: 20 }));
  terminal.resize(91, 31, 10, 20);
  const nonce = randomBytes(6).toString('hex'), marker = `__SWIFTTERM_SMOKE_${nonce}__`, done = `__SWIFTTERM_DONE_${nonce}__`;
  channel.sendBinary(Buffer.from(`printf '\\n%s%s\\n' '__SWIFTTERM_' 'SMOKE_${nonce}__'; stty size; printf '\\n%s%s\\n' '__SWIFTTERM_' 'DONE_${nonce}__'\r`));
  await readUntil(() => output.includes(`\n${done}\r\n`) || output.includes(`\n${done}\n`));
  const result = output.slice(output.indexOf(marker), output.indexOf(done));
  assert.match(result, /\r?\n31\s+91\r?\n/, 'The PTY must use the requested rows and columns.');
  const snapshot = terminal.snapshot(); assert.equal(snapshot.cols, 91); assert.equal(snapshot.rows, 31);
  assert.ok(snapshot.rowData.some(row => row.cells.map(cell => cell.text).join('').includes(marker)), 'WASM must parse the shell output.');
  terminal.markFrameRendered(snapshot.generation);
  channel.sendBinary(Buffer.from('exit 7\r'));
  const exit = await readUntil(control => control?.type === 'exit'); assert.equal(exit.code, 7, 'The server must report the shell exit code.');
  console.log('PASS: HTTP assets, WASM MIME/ABI, Origin rejection, PTY command, resize, parsed output, and exit status.');
} finally { channel?.close(); terminal?.dispose(); }
