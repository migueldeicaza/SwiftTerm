import test from 'node:test';
import assert from 'node:assert/strict';
import { ClipboardController, makeClipboardItem, MAX_CLIPBOARD_BYTES } from '../Public/clipboard.js';
class Element extends EventTarget { hidden = false; disabled = false; textContent = ''; }
class Item { static supports(type) { return ['text/plain', 'image/png'].includes(type); } constructor(data) { this.data = data; } }
const encode = value => Buffer.from(value).toString('base64');
function fixture(api = {}) {
  const completions = [], configurations = [];
  const terminal = { configureClipboard(value) { configurations.push(value); }, completeClipboard(...args) { completions.push(args); } };
  const elements = Object.fromEntries(['enable', 'panel', 'message', 'allow', 'deny'].map(x => [x, new Element()]));
  const controller = new ClipboardController(terminal, elements, () => {}, api, Item);
  const request = (operation, fields = {}) => ({ type: 'clipboardRequest', request: { id: 1, operation, location: 'standard', mimeTypes: [], representations: [], ...fields } });
  return { controller, elements, completions, configurations, request };
}
test('clipboard writes prepare all MIME data and reject a partial unsupported item', async () => {
  const item = makeClipboardItem([{ mimeType: 'text/plain', base64: encode('hi') }, { mimeType: 'image/png', base64: encode([137,80,78,71]) }], Item);
  assert.deepEqual(Object.keys(item.data), ['text/plain', 'image/png']); assert.equal(await item.data['text/plain'].text(), 'hi');
  assert.throws(() => makeClipboardItem([{ mimeType: 'text/plain', base64: encode('hi') }, { mimeType: 'text/html', base64: encode('html') }], Item), TypeError);
  assert.throws(() => makeClipboardItem([{ mimeType: 'text/plain', base64: encode(new Uint8Array(MAX_CLIPBOARD_BYTES + 1)) }], Item), RangeError);
});
test('clipboard capabilities are advertised without access; each captured read needs a visible action', async () => {
  let reads = 0;
  const f = fixture({ read: async () => { reads++; return [{ types: ['text/plain', 'image/png', 'text/html'], getType: async type => new Blob([type === 'text/plain' ? 'copied' : 'png'], {type}) }]; }, write: async () => {} });
  assert.deepEqual(f.configurations, [3]); assert.equal(reads, 0);
  assert.equal(f.elements.enable.textContent, 'Disable clipboard');
  f.controller.disable(); assert.deepEqual(f.configurations, [3, 0]);
  f.controller.accept(f.request('list')); assert.equal(f.controller.queue.length, 0); assert.equal(reads, 0);
  f.controller.enable(); assert.deepEqual(f.configurations, [3, 0, 3]);
  f.controller.accept(f.request('list', { id: 2 })); assert.equal(reads, 0); assert.equal(f.elements.panel.hidden, false);
  await f.controller.run(); assert.equal(reads, 1);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(f.completions.at(-1)[2])), ['text/plain', 'image/png']);
  f.controller.accept(f.request('readPermission', { id: 3, mimeTypes: ['text/plain'] })); assert.equal(f.completions.at(-1)[1], 0);
  f.controller.accept(f.request('read', { id: 4, mimeTypes: ['text/plain'] })); await new Promise(resolve => setImmediate(resolve));
  assert.equal(new TextDecoder().decode(f.completions.at(-1)[2]), 'copied'); assert.equal(reads, 1);
  f.controller.dispose();
});
test('clipboard permissions, denial, atomic write, and disposal do not cause automatic effects', async () => {
  const writes = []; const f = fixture({ read: async () => [], write: async items => writes.push(items), writeText: async text => writes.push(text) });
  f.controller.enable();
  f.controller.accept(f.request('writePermission')); assert.equal(writes.length, 0); f.controller.reject(); assert.equal(f.completions.at(-1)[1], 1);
  f.controller.accept(f.request('write', { id: 2, representations: [{ mimeType: 'text/plain', base64: encode('one') }] }));
  assert.equal(writes.length, 0); await f.controller.run(); assert.equal(writes.length, 1); assert.equal(f.completions.at(-1)[1], 0);
  f.controller.accept({ type: 'clipboardWrite', data: new TextEncoder().encode('OSC 52') }); assert.equal(writes.length, 1);
  await f.controller.run(); assert.equal(writes[1], 'OSC 52');
  f.controller.accept(f.request('list', { id: 3 })); f.controller.dispose(); await f.controller.run(); assert.equal(writes.length, 2);
});
test('denied browser reads return EPERM and stale work cannot complete after disposal', async () => {
  const f = fixture({ read: async () => { const error = new Error('Denied'); error.name = 'NotAllowedError'; throw error; }, write: async () => {} });
  f.controller.enable(); f.controller.accept(f.request('osc52Read')); await f.controller.run(); assert.equal(f.completions.at(-1)[1], 1); f.controller.dispose();
  let resolve;
  const pending = fixture({ read: () => new Promise(done => { resolve = done; }), write: async () => {} });
  pending.controller.enable(); pending.controller.accept(pending.request('list')); const run = pending.controller.run();
  pending.controller.dispose(); resolve([]); await run; assert.equal(pending.completions.length, 0);
});

test('browser APIs absent or Embedded do not advertise clipboard protocol services', () => {
  const absent = fixture({}); assert.deepEqual(absent.configurations, []); assert.equal(absent.elements.enable.disabled, true);
  absent.controller.dispose();
  const configurations = [], terminal = {configureClipboard: value => configurations.push(value)};
  const elements = {enable: new Element()};
  const controller = new ClipboardController(terminal, elements, () => {}, {read: async () => [], write: async () => {}}, Item, false);
  assert.deepEqual(configurations, []); assert.equal(elements.enable.disabled, true); controller.dispose();
});
