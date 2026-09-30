import test from 'node:test';
import assert from 'node:assert/strict';
import { load, raw, artifactURL, exists } from './helpers.mjs';
const encoder = new TextEncoder(), decoder = new TextDecoder();
const b64 = text => Buffer.from(text).toString('base64');
const osc = text => `\x1b]5522;${text}\x1b\\`;
const output = terminal => { const bytes = terminal.readOutput(); terminal.consumeOutput(bytes.length); return decoder.decode(bytes); };
async function request(terminal, operation) {
  for (let n = 0; n < 30; n++) {
    terminal.poll();
    const events = terminal.drainEvents();
    const event = events.find(x => x.type === 'clipboardRequest' && x.request.operation === operation);
    if (event) return event.request;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  assert.fail(`Missing clipboard request: ${operation}`);
}
for (const variant of (process.env.WASM_VARIANTS || 'full,embedded').split(',')) {
  test(`${variant}: core key modes and paste use bounded ordered output`, {skip: !await exists(artifactURL(variant))}, async () => {
    const module = await load(variant);
    assert.equal(module.capabilities & (32 | 128 | 256), 32 | 128 | 256);
    const terminal = module.createTerminal({cols: 80, rows: 24});
    assert.deepEqual(terminal.inputModes(), { applicationCursor: false, applicationKeypad: false, bracketedPaste: false, kittyPaste: false, kittyKeyboardFlags: 0 });
    assert.equal(terminal.sendKey({key: 'a', text: 'a'}), false);
    assert.equal(output(terminal), '');
    terminal.sendKey({key: 'ArrowUp'}); assert.equal(output(terminal), '\x1b[A');
    terminal.sendKey({key: 'End', code: 'Numpad1'}); assert.equal(output(terminal), '\x1b[F');
    terminal.write('\x1b[?1h\x1b=\x1b[?2004h');
    const modes = terminal.inputModes(); assert.equal(modes.applicationCursor, true); assert.equal(modes.applicationKeypad, true); assert.equal(modes.bracketedPaste, true);
    terminal.sendKey({key: 'ArrowUp'}); terminal.sendKey({key: '1', code: 'Numpad1'});
    terminal.paste('line1\nline2', {clipboard: true});
    assert.equal(output(terminal), '\x1bOA\x1bOq\x1b[200~line1\nline2\x1b[201~');
    terminal.reset(); assert.throws(() => terminal.paste('one\ntwo'), {code: 'INVALID_ARGUMENT'}); assert.equal(output(terminal), '');
    terminal.paste('one\ntwo', {allowUnsafe: true}); assert.equal(output(terminal), 'one\rtwo');
    terminal.paste('a\x1bb\x03c'); assert.equal(output(terminal), 'a b c');
    terminal.write('\x1b[>3u'); assert.equal(terminal.inputModes().kittyKeyboardFlags, 3);
    terminal.sendKey({key: 'a', modifiers: 4, eventType: 1});
    terminal.sendKey({key: 'a', modifiers: 4, eventType: 3});
    assert.equal(output(terminal), '\x1b[97;5u\x1b[97;5:3u');
    assert.throws(() => terminal.sendKey({key: 'x', modifiers: 256}), {code: 'INVALID_ARGUMENT'});
    terminal.dispose(); assert.throws(() => terminal.inputModes(), {code: 'DISPOSED'});
  });
}
test('Full: clipboard service opt-in, OSC52 selector, Kitty reads/writes, cancellation, and paste tokens', async () => {
  const module = await load('full'); assert.ok(module.capabilities & 512);
  const terminal = module.createTerminal({cols: 80, rows: 24});
  terminal.write('\x1b[?5522$p'); assert.match(output(terminal), /5522;0\$y/);
  terminal.configureClipboard(3); terminal.write('\x1b[?5522$p'); assert.match(output(terminal), /5522;2\$y/);
  terminal.write('\x1b]52;c;?\x07'); let event = await request(terminal, 'osc52Read');
  assert.equal(output(terminal), ''); terminal.completeClipboard(event.id, 0, encoder.encode('copied'));
  assert.equal(output(terminal), `\x1b]52;c;${b64('copied')}\x1b\\`);
  assert.throws(() => terminal.completeClipboard(event.id, 0), {code: 'INVALID_ARGUMENT'});
  terminal.write(osc(`type=read:id=read;${b64('text/plain')}`));
  event = await request(terminal, 'list'); terminal.completeClipboard(event.id, 0, encoder.encode('["text/plain"]'));
  event = await request(terminal, 'readPermission'); terminal.completeClipboard(event.id, 0);
  event = await request(terminal, 'read'); assert.deepEqual(event.mimeTypes, ['text/plain']); terminal.completeClipboard(event.id, 0, encoder.encode('hello'));
  terminal.poll(); let reply = output(terminal); assert.match(reply, /type=read:status=OK:id=read/); assert.match(reply, /type=read:status=DATA:id=read:mime=dGV4dC9wbGFpbg==;aGVsbG8=/); assert.match(reply, /type=read:status=DONE:id=read/);
  terminal.write(osc('type=write:id=write') + osc(`type=wdata:mime=${b64('text/plain')};${b64('new text')}`) + osc('type=wdata'));
  event = await request(terminal, 'writePermission'); terminal.completeClipboard(event.id, 0);
  event = await request(terminal, 'write'); assert.deepEqual(event.representations, [{mimeType: 'text/plain', base64: b64('new text')}]); terminal.completeClipboard(event.id, 0);
  terminal.poll(); assert.match(output(terminal), /type=write:status=DONE:id=write/);
  terminal.write(osc(`type=read:loc=primary;${b64('.')}`)); terminal.poll(); assert.match(output(terminal), /status=ENOSYS/);
  terminal.write('\x1b]52;c;?\x07'); event = await request(terminal, 'osc52Read'); terminal.resetClipboard();
  assert.throws(() => terminal.completeClipboard(event.id, 0, encoder.encode('stale')), {code: 'INVALID_ARGUMENT'}); assert.equal(output(terminal), '');
  terminal.write('\x1b]52;c;?\x07'.repeat(20));
  terminal.poll(); const bounded = terminal.drainEvents().filter(event => event.type === 'clipboardRequest');
  assert.equal(bounded.length, 16, 'pending clipboard requests are bounded');
  for (const item of bounded) terminal.completeClipboard(item.request.id, 1);
  assert.equal(output(terminal), '', 'denied OSC52 reads do not reveal data');
  terminal.write('\x1b[?5522h'); assert.equal(terminal.paste('token text', {clipboard: true}), 'event');
  reply = output(terminal); assert.match(reply, /type=read:status=OK:pw=/); assert.match(reply, /mime=Lg==/); assert.match(reply, /status=DONE/);
  terminal.configureClipboard(0); terminal.write('\x1b[?5522$p'); assert.match(output(terminal), /5522;0\$y/);
  terminal.dispose();
});
test('input ABI rejects invalid pointers and malformed key records without a trap', async () => {
  const {e} = await raw('full'), handle = e.swiftterm_terminal_create(80,24,0);
  assert.equal(e.swiftterm_terminal_input_modes(0), -1);
  assert.equal(e.swiftterm_terminal_key(handle,0xffffffff,28), -3);
  assert.equal(e.swiftterm_terminal_key(handle,0,1), -2);
  assert.equal(e.swiftterm_terminal_paste(handle,0xffffffff,1,0), -3);
  assert.equal(e.swiftterm_terminal_paste(handle,0,0,4), -2);
  assert.equal(e.swiftterm_terminal_clipboard_configure(handle,4), -2);
  assert.equal(e.swiftterm_terminal_clipboard_complete(handle,999,0,0,0), -2);
  e.swiftterm_terminal_destroy(handle);
});
