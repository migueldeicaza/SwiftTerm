// Run against a server that is already running:
// node TerminalApps/WebTerminal/BrowserTests/backend-live.mjs http://127.0.0.1:8080
// Requires mc and /usr/bin/python3. Tests Ctrl-C, Kitty files, and mc latency.
// The test starts one shell and exits it when the checks finish.
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

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

let channel;
try {
  channel = (await upgrade(base.origin)).channel;
  let output = '';
  async function until(marker) {
    while (!output.includes(marker)) {
      const message = await channel.next(10000);
      if (message.type === 'binary') output += message.data.toString('utf8');
      else if (message.type === 'text' && JSON.parse(message.data).type === 'error') throw Error(message.data);
      assert.ok(output.length < 8 * 1024 * 1024);
    }
    output = output.slice(output.indexOf(marker) + marker.length);
  }
  channel.sendBinary(Buffer.from("stty -echo; printf '\\137READY\\137'; PS1=''; PS2=''\r"));
  await until('_READY_');
  for (let i = 0; i < 5; i++) {
    channel.sendBinary(Buffer.from("cat; printf '\\137STOPPED\\137'\r"));
    channel.sendBinary(Buffer.from(`catprobe${i}\r`));
    await until(`catprobe${i}`);
    const start = performance.now();
    channel.sendBinary(Buffer.from([3]));
    await until('_STOPPED_');
    console.log(`Ctrl-C run ${i + 1}: ${(performance.now()-start).toFixed(1)} ms`);
  }
  const python = "import os,base64; p=os.path.join(os.environ['TMPDIR'],'tty-graphics-protocol-live.rgba'); d=bytes(range(256))*1024; open(p,'wb').write(d); print('\\x1b_Ga=T,t=f,f=32,s=256,v=256,i=81,q=2;'+base64.b64encode(p.encode()).decode()+'\\x1b\\\\',end=''); print('_FILEDONE_',flush=True)";
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  channel.sendBinary(Buffer.from(`/usr/bin/python3 -c ${shellQuote(python)}\r`));
  while (!output.includes('_FILEDONE_')) {
    const message = await channel.next(10000);
    if (message.type === 'binary') output += message.data.toString('utf8');
    assert.ok(output.length < 1024 * 1024);
  }
  const packets = [...output.matchAll(/\x1b_G([^;]*);([^\x1b]*)\x1b\\/g)];
  assert.ok(packets.length > 1);
  assert.match(packets[0][1], /t=d/);
  assert.ok(packets.every(packet => packet[2].length <= 4096));
  const decoded = Buffer.from(packets.map(packet => packet[2]).join(''), 'base64');
  assert.equal(decoded.length, 262144);
  for (let i = 0; i < decoded.length; i++) assert.equal(decoded[i], i & 255);
  console.log(`Kitty file transport: ${decoded.length} bytes, ${packets.length} chunks, exact content`);
  output = '';
  channel.sendBinary(Buffer.from("command -v mc; printf '\\137MCCHECK\\137'\r"));
  await until('_MCCHECK_');
  const start = performance.now();
  channel.sendBinary(Buffer.from("mc; printf '\\137MCDONE\\137'\r"));
  // Wait for mc's screen setup, then send F10 (the xterm function-key sequence).
  await until('\u001b[');
  console.log(`mc first screen: ${(performance.now()-start).toFixed(1)} ms`);
  channel.sendBinary(Buffer.from('\u001b[21~'));
  await until('_MCDONE_');
  console.log(`mc start and exit: ${(performance.now()-start).toFixed(1)} ms`);
  channel.sendBinary(Buffer.from('exit\r'));
} finally { channel?.close(); }
