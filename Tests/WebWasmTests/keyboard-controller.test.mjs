import test from 'node:test';
import assert from 'node:assert/strict';
import { KeyboardInputController } from '../../Web/dist/src/keyboard.js';

class Input extends EventTarget {
  value = '';
  ownerDocument;
  constructor(navigator = { platform: 'Linux' }) { super(); this.ownerDocument = { defaultView: { navigator } }; }
  emit(type, fields = {}) {
    const event = new Event(type, { cancelable: true });
    Object.assign(event, { key: '', code: '', location: 0, repeat: false, shiftKey: false, altKey: false,
      ctrlKey: false, metaKey: false, isComposing: false, getModifierState: () => false, ...fields });
    this.dispatchEvent(event);
    return event;
  }
  down(key, code, fields) { return this.emit('keydown', { key, code, ...fields }); }
  up(key, code, fields) { return this.emit('keyup', { key, code, ...fields }); }
  text(text, fields = {}) { this.value = text; return this.emit('input', { data: text, inputType: 'insertText', ...fields }); }
}
function setup(options = {}, route = 'sent', navigator) {
  const input = new Input(navigator), keys = [], output = [], errors = [];
  const terminal = {
    sendKeyResult(event) {
      keys.push({ ...event });
      const result = typeof route === 'function' ? route(event) : route;
      if (result === 'sent') output.push({ ...event });
      return result;
    },
    sendText(text) { output.push(new TextEncoder().encode(text)); },
  };
  const controller = new KeyboardInputController(terminal, input, { onError: e => errors.push(e), ...options });
  return { input, keys, output, errors, controller };
}

test('Shift+A keeps a lowercase primary after Shift is released, with current release modifiers', () => {
  const { input, keys, controller } = setup({ shortcut: () => false });
  input.down('A', 'KeyA', { shiftKey: true });
  input.up('Shift', 'ShiftLeft');
  input.up('a', 'KeyA');
  assert.deepEqual(keys, [
    { key: 'a', code: 'KeyA', modifiers: 1, text: 'A', shiftedKey: 65, baseLayoutKey: 97, eventType: 1 },
    { key: 'a', code: 'KeyA', modifiers: 0, text: undefined, shiftedKey: 65, baseLayoutKey: 97, eventType: 3 },
  ]);
  controller.dispose();
});

test('Ctrl+Shift punctuation separates alternate keys from text and supplies physical digit/punctuation identities', () => {
  const { input, keys, controller } = setup({ shortcut: () => false });
  for (const [code, shifted] of [['Digit1', '!'], ['Slash', '?'], ['BracketLeft', '{'], ['Equal', '+']]) {
    input.down(shifted, code, { shiftKey: true, ctrlKey: true }); input.up(shifted, code);
  }
  assert.deepEqual(keys.filter(k => k.eventType === 1).map(k => [k.key, k.shiftedKey, k.baseLayoutKey, k.modifiers, k.text]),
    [['1', 33, 49, 5, undefined], ['/', 63, 47, 5, undefined], ['[', 123, 91, 5, undefined], ['=', 43, 61, 5, undefined]]);
  controller.dispose();
});

test('CapsLock preserves text case and records CapsLock without changing primary identity', () => {
  const { input, keys, controller } = setup();
  input.down('A', 'KeyA', { getModifierState: name => name === 'CapsLock' }); input.up('a', 'KeyA');
  assert.equal(keys[0].key, 'a'); assert.equal(keys[0].text, 'A'); assert.equal(keys[0].modifiers, 64);
  assert.equal(keys[1].key, 'a');
  controller.dispose();
});

test('host owns shortcuts through repeat and release; caller policy can permit a default browser shortcut', () => {
  let hostCalls = 0;
  const { input, keys, controller } = setup({ shortcut: event => { hostCalls++; return event.metaKey; } });
  input.down('c', 'KeyC', { metaKey: true });
  input.down('c', 'KeyC', { repeat: true }); input.up('c', 'KeyC');
  assert.equal(hostCalls, 1); assert.deepEqual(keys, []);
  input.down('l', 'KeyL', { ctrlKey: true }); input.up('l', 'KeyL');
  assert.deepEqual(keys.map(k => k.eventType), [1, 3]);
  controller.dispose();
  const defaults = setup();
  defaults.input.down('r', 'KeyR', { metaKey: true }); defaults.input.up('r', 'KeyR');
  assert.deepEqual(defaults.keys, []); defaults.controller.dispose();
});

test('the default policy keeps Control keys in the terminal on macOS only', () => {
  const mac = setup({}, 'sent', { platform: 'MacIntel' });
  mac.input.down('l', 'KeyL', { ctrlKey: true }); mac.input.up('l', 'KeyL');
  assert.deepEqual(mac.keys.map(k => [k.key, k.eventType]), [['l', 1], ['l', 3]]);
  mac.input.down('r', 'KeyR', { metaKey: true }); mac.input.up('r', 'KeyR');
  assert.equal(mac.keys.length, 2, 'Command shortcuts stay with the browser');
  mac.controller.dispose();
  const other = setup();
  other.input.down('l', 'KeyL', { ctrlKey: true }); other.input.up('l', 'KeyL');
  assert.deepEqual(other.keys, []);
  other.controller.dispose();
});

test('repeat uses the original press identity; unmatched and ignored releases are absent', () => {
  const { input, keys, controller } = setup({}, event => event.key === 'Shift' ? 'ignored' : 'sent');
  input.up('x', 'KeyX'); input.down('Shift', 'ShiftLeft'); input.up('Shift', 'ShiftLeft');
  input.down('A', 'KeyA', { shiftKey: true }); input.down('a', 'KeyA', { repeat: true }); input.up('a', 'KeyA');
  assert.deepEqual(keys.map(k => [k.key, k.eventType]), [['Shift', 1], ['a', 1], ['a', 2], ['a', 3]]);
  controller.dispose();
});

test('legacy printable input stays editable and sends UTF-8 text through the terminal exactly once', () => {
  const { input, keys, output, controller } = setup({}, 'text');
  assert.equal(input.down('a', 'KeyA').defaultPrevented, false);
  assert.equal(input.emit('beforeinput', { data: 'a', inputType: 'insertText' }).defaultPrevented, false);
  input.text('a'); input.up('a', 'KeyA');
  assert.equal(keys.length, 1); assert.deepEqual(output, [new Uint8Array([97])]); assert.equal(input.value, '');
  controller.dispose();
});

test('provided and observed layouts control primary characters while physical codes remain PC base alternatives', async () => {
  const { input, keys, controller } = setup({ layout: { KeyQ: 'a', Digit1: '&', Slash: ':' } });
  input.down('A', 'KeyQ', { shiftKey: true }); input.up('a', 'KeyQ');
  input.down('1', 'Digit1', { shiftKey: true }); input.up('&', 'Digit1');
  input.down('?', 'Slash', { shiftKey: true }); input.up(':', 'Slash');
  assert.deepEqual(keys.filter(k => k.eventType === 1).map(k => [k.key, k.baseLayoutKey]), [['a', 113], ['&', 49], [':', 47]]);
  controller.dispose();
  const observed = setup();
  observed.input.down('é', 'Digit2'); observed.input.up('é', 'Digit2');
  observed.input.down('2', 'Digit2', { shiftKey: true });
  assert.equal(observed.keys.at(-1).key, 'é'); observed.controller.dispose();
  const mapped = setup({}, 'sent', { platform: 'Linux', keyboard: { getLayoutMap: async () => new Map([['KeyY', 'z']]) } });
  await Promise.resolve();
  mapped.input.down('Z', 'KeyY', { shiftKey: true });
  assert.equal(mapped.keys[0].key, 'z'); assert.equal(mapped.keys[0].baseLayoutKey, 121); mapped.controller.dispose();
});

test('AltGraph and macOS Option text consume shortcut modifiers', () => {
  const graph = setup({ shortcut: () => { throw new Error('Text must not enter shortcut policy'); }, layout: { KeyQ: 'q' } });
  graph.input.down('@', 'KeyQ', { ctrlKey: true, altKey: true, getModifierState: name => name === 'AltGraph' });
  assert.equal(graph.keys[0].modifiers, 0); assert.equal(graph.keys[0].text, '@'); assert.deepEqual(graph.errors, []);
  graph.input.up('q', 'KeyQ', { ctrlKey: true, altKey: true }); assert.equal(graph.keys[1].modifiers, 0);
  graph.controller.dispose();
  const option = setup({ layout: { KeyS: 's' } }, 'sent', { platform: 'MacIntel' });
  option.input.down('ß', 'KeyS', { altKey: true });
  assert.equal(option.keys[0].modifiers, 0); assert.equal(option.keys[0].text, 'ß'); option.controller.dispose();
  const meta = setup({ optionAsMeta: true }, 'sent', { platform: 'MacIntel' });
  meta.input.down('s', 'KeyS', { altKey: true }); assert.equal(meta.keys[0].modifiers, 2); assert.equal(meta.keys[0].text, undefined);
  meta.controller.dispose();
});

test('Japanese composition commits once and its Enter press and release never reach the terminal', () => {
  const { input, keys, output, controller } = setup();
  input.emit('compositionstart'); input.down('Process', 'KeyN', { keyCode: 229 }); input.text('に', { isComposing: true });
  input.down('Enter', 'Enter', { isComposing: true });
  input.emit('compositionend', { data: '日本' }); input.up('Enter', 'Enter'); input.up('n', 'KeyN');
  input.text('日本', { inputType: 'insertFromComposition' });
  assert.deepEqual(keys, []); assert.deepEqual(output, [new TextEncoder().encode('日本')]);
  controller.dispose();
});

test('Safari compositionend before unmarked Enter does not leak Enter; cancelled and dead-key text is correct', () => {
  const { input, keys, output, controller } = setup();
  input.emit('compositionstart'); input.value = 'x'; input.emit('compositionend', { data: '' });
  assert.deepEqual(output, []);
  input.emit('compositionstart'); input.emit('compositionend', { data: 'é' });
  assert.equal(input.down('Enter', 'Enter').defaultPrevented, true); input.up('Enter', 'Enter');
  assert.deepEqual(keys, []); assert.equal(output.length, 1);
  controller.reset(); input.down('Dead', 'Quote'); input.up('Dead', 'Quote'); input.down('e', 'KeyE');
  input.text('é'); input.up('e', 'KeyE');
  assert.deepEqual(keys, []); assert.deepEqual(output, [new Uint8Array([195, 169]), new Uint8Array([195, 169])]);
  controller.dispose();
});

test('blur releases sent presses only, and pressure defers releases ahead of new input', () => {
  let enabled = true;
  const { input, keys, controller } = setup({ canInput: () => enabled });
  input.down('a', 'KeyA'); input.down('c', 'KeyC', { metaKey: true }); enabled = false;
  input.emit('blur'); assert.equal(keys.length, 1);
  input.down('b', 'KeyB'); input.up('b', 'KeyB'); assert.equal(keys.length, 1);
  enabled = true; controller.resume(); input.down('x', 'KeyX'); input.up('x', 'KeyX');
  assert.deepEqual(keys.map(k => [k.key, k.eventType]), [['a', 1], ['a', 3], ['x', 1], ['x', 3]]);
  input.up('a', 'KeyA'); assert.equal(keys.length, 4);
  controller.dispose(); input.down('z', 'KeyZ'); assert.equal(keys.length, 4);
});


test('composition final input before compositionend and after compositionend sends the same single commit', () => {
  for (const finalBeforeEnd of [true, false]) {
    const { input, output, controller } = setup();
    input.emit('compositionstart');
    if (finalBeforeEnd) input.text('日本', { inputType: 'insertText' });
    input.emit('compositionend', { data: '日本' });
    if (!finalBeforeEnd) input.text('日本', { inputType: 'insertText' });
    assert.deepEqual(output, [new TextEncoder().encode('日本')]);
    controller.dispose();
  }
});

test('pressure during a release flush leaves subsequent releases ordered before committed text', () => {
  let enabled = true, remaining = Infinity;
  const { input, output, controller } = setup({
    canInput: () => enabled,
    onInput: () => { if (--remaining === 0) enabled = false; },
  });
  input.down('a', 'KeyA'); input.down('b', 'KeyB');
  enabled = false; input.emit('blur');
  enabled = true; remaining = 1; controller.resume();
  assert.deepEqual(output.map(k => [k.key, k.eventType]), [['a', 1], ['b', 1], ['a', 3]]);
  enabled = true; remaining = Infinity; input.text('日本');
  assert.deepEqual(output.slice(0, 4).map(k => [k.key, k.eventType]), [['a', 1], ['b', 1], ['a', 3], ['b', 3]]);
  assert.deepEqual(output[4], new TextEncoder().encode('日本')); controller.dispose();
});
