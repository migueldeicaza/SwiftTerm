import test from 'node:test';
import assert from 'node:assert/strict';
import { load, raw, artifactURL, exists } from './helpers.mjs';

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const output = terminal => {
  const bytes = terminal.readOutput();
  terminal.consumeOutput(bytes.length);
  return decoder.decode(bytes);
};
const pointer = (action, button = 0, overrides = {}) => ({
  action, button, col: 2, row: 3, pixelX: 20, pixelY: 60, ...overrides,
});
const invalid = operation => assert.throws(operation, { code: 'INVALID_ARGUMENT' });

for (const variant of (process.env.WASM_VARIANTS || 'full,embedded').split(',')) {
  test(`${variant}: committed text, mouse, selection, and viewport`,
    { skip: !await exists(artifactURL(variant)) }, async t => {
      const module = await load(variant);
      assert.equal(module.capabilities & (64 | 16384 | 32768), 64 | 16384 | 32768);

      await t.test('committed text follows Kitty modes and does not use paste framing', () => {
        const terminal = module.createTerminal({ cols: 20, rows: 4 });
        try {
          for (const flags of [0, 1, 2, 3, 8, 10, 24, 31]) {
            terminal.reset();
            terminal.write(`\x1b[>${flags}u\x1b[?2004h\x1b[?5522h`);
            output(terminal);
            terminal.sendText('日本');
            assert.equal(output(terminal), (flags & 24) === 24 ? '\x1b[0;;26085:26412u' : '日本', `flags ${flags}`);
            terminal.sendText('');
            assert.equal(output(terminal), '');
          }
          terminal.reset();
          terminal.sendKey({ key: 'ArrowUp' });
          terminal.sendText('e\u0301😀');
          terminal.sendKey({ key: 'ArrowDown' });
          assert.equal(output(terminal), '\x1b[Ae\u0301😀\x1b[B');
          invalid(() => terminal.sendText('x'.repeat(65537)));
          invalid(() => terminal.sendText('界'.repeat(22000)));
          invalid(() => terminal.sendText(null));
        } finally { terminal.dispose(); }
      });

      await t.test('mouse modes and exact press, release, motion, and wheel bytes', () => {
        const terminal = module.createTerminal({ cols: 80, rows: 24 });
        try {
          const initial = terminal.inputState();
          assert.equal(initial.mouseMode, 'off');
          assert.equal(initial.mouseProtocol, 'legacy');
          assert.equal(initial.mouseShiftCapture, false);
          assert.equal(initial.alternateScroll, true);
          assert.equal(terminal.sendMouse(pointer('press')), false);
          assert.equal(output(terminal), '');

          terminal.write('\x1b[?9h');
          assert.equal(terminal.inputState().mouseMode, 'x10');
          assert.equal(terminal.sendMouse(pointer('press', 0, { modifiers: 15 })), true);
          assert.equal(terminal.sendMouse(pointer('release')), false);
          assert.equal(terminal.sendMouse(pointer('move')), false);
          assert.equal(output(terminal), '\x1b[M #$');

          terminal.write('\x1b[?1000h\x1b[?1006h');
          assert.equal(terminal.inputState().mouseMode, 'vt200');
          assert.equal(terminal.inputState().mouseProtocol, 'sgr');
          for (const button of [0, 1, 2]) {
            assert.equal(terminal.sendMouse(pointer('press', button, { modifiers: 15 })), true);
            assert.equal(terminal.sendMouse(pointer('release', button, { modifiers: 15 })), true);
            assert.equal(output(terminal), `\x1b[<${28 + button};3;4M\x1b[<${28 + button};3;4m`);
          }
          assert.equal(terminal.sendMouse(pointer('move', 0)), false);
          assert.equal(output(terminal), '');
          terminal.write('\x1b[?1002h');
          assert.equal(terminal.inputState().mouseMode, 'button');
          assert.equal(terminal.sendMouse(pointer('move', 3)), false);
          assert.equal(terminal.sendMouse(pointer('move', 1)), true);
          assert.equal(output(terminal), '\x1b[<33;3;4M');
          terminal.write('\x1b[?1003h');
          assert.equal(terminal.inputState().mouseMode, 'any');
          assert.equal(terminal.sendMouse(pointer('move', 3)), true);
          for (const button of [4, 5, 6, 7]) assert.equal(terminal.sendMouse(pointer('wheel', button)), true);
          assert.equal(output(terminal), '\x1b[<35;3;4M\x1b[<64;3;4M\x1b[<65;3;4M\x1b[<66;3;4M\x1b[<67;3;4M');

          terminal.resize(80, 24, 10, 20);
          terminal.write('\x1b[?1016h');
          assert.equal(terminal.inputState().mouseProtocol, 'pixel');
          terminal.sendMouse(pointer('press', 2));
          terminal.sendMouse(pointer('release', 2));
          terminal.sendMouse(pointer('wheel', 5));
          assert.equal(output(terminal), '\x1b[<2;21;61M\x1b[<2;21;61m\x1b[<65;21;61M');
          for (const [mode, protocol, expected] of [
            [1005, 'utf8', '\x1b[M##$'], [1015, 'urxvt', '\x1b[35;3;4M'],
          ]) {
            terminal.write(`\x1b[?${mode}h`);
            assert.equal(terminal.inputState().mouseProtocol, protocol);
            terminal.sendMouse(pointer('release', 2));
            assert.equal(output(terminal), expected);
          }
          terminal.write('\x1b[>1s\x1b[?1049h\x1b[?1007l');
          assert.equal(terminal.inputState().mouseShiftCapture, true);
          assert.equal(terminal.inputState().alternateScreen, true);
          assert.equal(terminal.inputState().alternateScroll, false);
          terminal.write('\x1b[>0s\x1b[?1049l');
          assert.equal(terminal.inputState().mouseShiftCapture, false);
          assert.equal(terminal.inputState().alternateScreen, false);
          invalid(() => terminal.sendMouse(pointer('press', 3)));
          invalid(() => terminal.sendMouse(pointer('wheel', 0)));
          invalid(() => terminal.sendMouse(pointer('press', 0, { col: 80 })));
          invalid(() => terminal.sendMouse(pointer('press', 0, { row: 24 })));
          invalid(() => terminal.sendMouse(pointer('press', 0, { pixelX: 800 })));
          invalid(() => terminal.sendMouse(pointer('press', 0, { modifiers: 16 })));
          invalid(() => terminal.sendMouse(pointer('unknown')));
        } finally { terminal.dispose(); }
      });

      await t.test('scrollback snapshots hide offscreen cursors and keep ABI coordinates valid', () => {
        const terminal = module.createTerminal({ cols: 12, rows: 4, scrollback: 20 });
        try {
          terminal.write(Array.from({ length: 10 }, (_, i) => `line${i}`).join('\r\n'));
          assert.equal(terminal.snapshot().cursor.visible, true);
          terminal.scrollViewport(-1);
          const scrolled = terminal.snapshot();
          assert.equal(scrolled.cursor.visible, false);
          assert.equal(scrolled.cursor.y, 3);
          terminal.scrollViewportTo(0);
          assert.equal(terminal.snapshot().cursor.visible, false);
          terminal.scrollViewportTo(terminal.viewportState().maximumTopRow);
          assert.equal(terminal.snapshot().cursor.visible, true);
          terminal.write('\x1b[?25l');
          assert.equal(terminal.snapshot().cursor.visible, false);
        } finally { terminal.dispose(); }
      });

      await t.test('mouse pixels can exceed 65535 within the logical screen', () => {
        const terminal = module.createTerminal({ cols: 1024, rows: 24 });
        try {
          terminal.resize(1024, 24, 100, 20);
          terminal.write('\x1b[?1000h\x1b[?1016h');
          assert.equal(terminal.sendMouse(pointer('press', 0, { col: 700, pixelX: 70000 })), true);
          assert.equal(output(terminal), '\x1b[<0;70001;61M');
          assert.equal(terminal.sendMouse(pointer('release', 0, { col: 1023, row: 23, pixelX: 102399, pixelY: 479 })), true);
          assert.equal(output(terminal), '\x1b[<0;102400;480m');
          invalid(() => terminal.sendMouse(pointer('press', 0, { pixelX: 102400 })));
          invalid(() => terminal.sendMouse(pointer('press', 0, { pixelY: 480 })));
          invalid(() => terminal.sendMouse(pointer('press', 0, { pixelX: 0x7fffffff })));
          assert.equal(output(terminal), '');
        } finally { terminal.dispose(); }
      });

      await t.test('selection spans use exclusive ends and preserve complete Unicode cells', () => {
        const terminal = module.createTerminal({ cols: 10, rows: 3 });
        try {
          terminal.write('0123456789');
          terminal.selectionBegin(9, 0);
          assert.equal(terminal.selectionText(), '9');
          const last = terminal.selectionState();
          assert.equal(last.active, true);
          assert.deepEqual(last.spans, [{ row: 0, startCol: 9, endCol: 10 }]);
          assert.deepEqual(terminal.selectionState(), last, 'reads do not change the selection revision');
          terminal.selectionBegin(8, 0);
          assert.equal(terminal.selectionText(), '8');
          assert.deepEqual(terminal.selectionState().spans, [{ row: 0, startCol: 8, endCol: 9 }]);
          assert.ok(terminal.selectionState().generation > last.generation);
          terminal.selectionExtend(7, 0);
          assert.equal(terminal.selectionText(), '78');
          terminal.selectionExtend(9, 0);
          assert.equal(terminal.selectionText(), '89');
          assert.deepEqual(last.spans, [{ row: 0, startCol: 9, endCol: 10 }], 'prior snapshots are owned');
          terminal.reset();
          terminal.write('a界e\u0301😀z');
          terminal.selectionBegin(2, 0);
          assert.equal(terminal.selectionText(), '界');
          assert.deepEqual(terminal.selectionState().spans, [{ row: 0, startCol: 1, endCol: 3 }]);
          terminal.selectionBegin(3, 0);
          assert.equal(terminal.selectionText(), 'e\u0301');
          terminal.selectionBegin(5, 0, 'word');
          assert.equal(terminal.selectionText(), '😀');
          assert.deepEqual(terminal.selectionState().spans, [{ row: 0, startCol: 4, endCol: 6 }]);
          terminal.selectionClear();
          assert.equal(terminal.selectionText(), '');
          assert.equal(terminal.selectionState().active, false);
          assert.deepEqual(terminal.selectionState().spans, []);
          invalid(() => terminal.selectionBegin(10, 0));
          invalid(() => terminal.selectionBegin(0, 3));
          invalid(() => terminal.selectionBegin(-1, 0));
          invalid(() => terminal.selectionBegin(0, 0, 'invalid'));
        } finally { terminal.dispose(); }
      });

      await t.test('word extension includes punctuation and complete emoji targets', () => {
        const terminal = module.createTerminal({ cols: 10, rows: 3 });
        try {
          for (const [suffix, width] of [['!', 1], ['😀', 2]]) {
            for (const shift of [false, true]) {
              terminal.reset();
              terminal.write('abc ' + suffix);
              terminal.selectionBegin(1, 0, 'word');
              if (shift) terminal.selectionBegin(4 + width - 1, 0, 'extend');
              else terminal.selectionExtend(4 + width - 1, 0);
              assert.equal(terminal.selectionText(), 'abc ' + suffix);
              assert.deepEqual(terminal.selectionState().spans, [{ row: 0, startCol: 0, endCol: 4 + width }]);
            }
          }
          terminal.reset();
          terminal.write('! abc');
          terminal.selectionBegin(3, 0, 'word');
          terminal.selectionBegin(0, 0, 'extend');
          assert.equal(terminal.selectionText(), '! abc');
        } finally { terminal.dispose(); }
      });

      await t.test('word, row, Shift, soft wrap, and selection lifecycle', () => {
        const terminal = module.createTerminal({ cols: 10, rows: 3 });
        try {
          terminal.write('hello abcd\r\nnext');
          terminal.selectionBegin(7, 0, 'word');
          assert.equal(terminal.selectionText(), 'abcd');
          terminal.selectionExtend(1, 0);
          assert.equal(terminal.selectionText(), 'hello abcd');
          terminal.selectionBegin(1, 0, 'row');
          assert.equal(terminal.selectionText(), 'hello abcd');
          terminal.selectionExtend(2, 1);
          assert.equal(terminal.selectionText(), 'hello abcd\nnext');
          terminal.selectionAll();
          assert.equal(terminal.selectionText(), 'hello abcd\nnext');
          terminal.resize(5, 3);
          assert.equal(terminal.selectionState().active, false);
          terminal.reset();
          terminal.write('abcdefgh');
          terminal.selectionBegin(3, 0);
          terminal.selectionBegin(2, 1, 'extend');
          assert.equal(terminal.selectionText(), 'defgh');
          assert.deepEqual(terminal.selectionState().spans, [
            { row: 0, startCol: 3, endCol: 5 }, { row: 1, startCol: 0, endCol: 3 },
          ]);
          terminal.reset();
          terminal.write('abcde');
          terminal.selectionBegin(1, 0);
          terminal.write('\x1b[1;5HX');
          assert.equal(terminal.selectionText(), 'b', 'output outside the range preserves selection');
          terminal.write('\x1b[1;2HX');
          assert.equal(terminal.selectionState().active, false);
          terminal.selectionBegin(0, 0);
          terminal.write('\x1b[?1049h');
          assert.equal(terminal.selectionState().active, false);
          assert.equal(terminal.viewportState().alternateScreen, true);
          terminal.write('alt');
          terminal.selectionAll();
          terminal.write('\x1b[?1049l');
          assert.equal(terminal.selectionState().active, false);
          terminal.selectionAll();
          terminal.reset();
          assert.equal(terminal.selectionText(), '');
        } finally { terminal.dispose(); }
      });

      await t.test('viewport coordinates, copied history, scrolling, and history eviction', () => {
        const terminal = module.createTerminal({ cols: 8, rows: 2, scrollback: 2 });
        try {
          terminal.write('zero\r\none\r\ntwo\r\nthree');
          assert.deepEqual(terminal.viewportState(), { topRow: 2, maximumTopRow: 2, alternateScreen: false });
          terminal.scrollViewport(-0x80000000);
          assert.equal(terminal.viewportState().topRow, 0);
          terminal.selectionBegin(0, 0, 'row');
          terminal.selectionExtend(0, 1);
          assert.equal(terminal.selectionText(), 'zero\none');
          terminal.scrollViewport(1);
          assert.deepEqual(terminal.selectionState().spans, [{ row: 0, startCol: 0, endCol: 8 }]);
          assert.equal(terminal.selectionText(), 'zero\none', 'copy includes rows outside the viewport');
          terminal.selectionBegin(0, 0, 'word');
          assert.equal(terminal.selectionText(), 'one', 'pointer row uses the current viewport');
          terminal.write('\r\nfour');
          assert.equal(terminal.viewportState().topRow, 0);
          assert.equal(terminal.selectionText(), 'one');
          terminal.write('\r\nfive');
          assert.equal(terminal.selectionState().active, false);
          terminal.selectionAll();
          assert.equal(terminal.selectionText(), 'two\nthree\nfour\nfive');
          terminal.scrollViewport(0x7fffffff);
          assert.equal(terminal.viewportState().topRow, 2);
          terminal.scrollViewportTo(-3);
          assert.equal(terminal.viewportState().topRow, 0);
          terminal.scrollViewportTo(0x7fffffff);
          assert.equal(terminal.viewportState().topRow, 2);
          invalid(() => terminal.scrollViewport(0.5));
          invalid(() => terminal.scrollViewportTo(0x80000000));
        } finally { terminal.dispose(); }
        assert.throws(() => terminal.selectionState(), { code: 'DISPOSED' });
        assert.throws(() => terminal.sendText('x'), { code: 'DISPOSED' });
      });
    });

  test(`${variant}: raw interaction ABI rejects invalid data and owns size/copy buffers`,
    { skip: !await exists(artifactURL(variant)) }, async () => {
      const { e, write, copy } = await raw(variant);
      const handle = e.swiftterm_terminal_create(10, 3, 2);
      try {
        assert.equal(e.swiftterm_terminal_pointer_modes(0), -1);
        assert.equal(e.swiftterm_terminal_text(0, 0, 0), -1);
        assert.equal(e.swiftterm_terminal_text(handle, 0xffffffff, 1), -3);
        assert.equal(e.swiftterm_terminal_text(handle, 0, 65537), -2);
        const malformed = e.swiftterm_wasm_alloc(1) >>> 0;
        try {
          new Uint8Array(e.memory.buffer, malformed, 1)[0] = 0xff;
          assert.equal(e.swiftterm_terminal_text(handle, malformed, 1), -2);
        } finally { e.swiftterm_wasm_free(malformed); }
        assert.equal(e.swiftterm_terminal_mouse(0, 0, 0, 0, 0, 0, 0, 0), -1);
        for (const args of [
          [4, 0, 0, 0, 0, 0, 0], [0, 3, 0, 0, 0, 0, 0],
          [3, 0, 0, 0, 0, 0, 0], [0, 0, 16, 0, 0, 0, 0],
          [0, 0, 0, 10, 0, 0, 0], [0, 0, 0, 0, 3, 0, 0],
          [0, 0, 0, 0, 0, 0xffffffff, 0],
        ]) assert.equal(e.swiftterm_terminal_mouse(handle, ...args), -2);
        assert.equal(e.swiftterm_terminal_scroll(0, 0, 0), -1);
        assert.equal(e.swiftterm_terminal_scroll(handle, 0, 2), -2);
        assert.equal(e.swiftterm_terminal_selection(0, 0, 0, 0, 0), -1);
        for (const args of [[4, 0, 0, 0], [0, 0, 0, 4], [0, 10, 0, 0], [0, 0, 3, 0], [0, 0xffffffff, 0, 0]]) {
          assert.equal(e.swiftterm_terminal_selection(handle, ...args), -2);
        }
        for (const prefix of ['selection_state', 'selection_text']) {
          assert.equal(e[`swiftterm_terminal_${prefix}_size`](0), -1);
          assert.equal(e[`swiftterm_terminal_${prefix}_copy`](handle, 0xffffffff, 1), -3);
        }

        assert.equal(write(handle, '0123456789'), 0);
        assert.equal(e.swiftterm_terminal_selection(handle, 0, 9, 0, 0), 0);
        const state = copy(handle, 'swiftterm_terminal_selection_state');
        const view = new DataView(state.buffer, state.byteOffset, state.byteLength);
        assert.equal(state.length, 44);
        assert.equal(view.getUint32(0, true), 1);
        assert.equal(view.getUint32(20, true), 1);
        assert.equal(view.getUint32(24, true), 1);
        assert.equal(view.getUint32(28, true), 0);
        assert.deepEqual([...state.slice(32)], [0, 0, 0, 0, 9, 0, 0, 0, 10, 0, 0, 0]);
        assert.deepEqual(copy(handle, 'swiftterm_terminal_selection_text'), encoder.encode('9'));
        assert.equal(e.swiftterm_terminal_selection(handle, 2, 0, 0, 0), 0);
        const destination = e.swiftterm_wasm_alloc(44) >>> 0;
        try {
          assert.equal(e.swiftterm_terminal_selection_state_copy(handle, destination, 43), -4);
          assert.equal(e.swiftterm_terminal_selection_state_copy(handle, destination, 44), 44);
          assert.deepEqual(new Uint8Array(e.memory.buffer, destination, 44).slice(), state);
          assert.equal(e.swiftterm_terminal_selection_text_copy(handle, destination, 0), -4);
          assert.equal(e.swiftterm_terminal_selection_text_copy(handle, destination, 1), 1);
          assert.equal(new Uint8Array(e.memory.buffer, destination, 1)[0], 57);
        } finally { e.swiftterm_wasm_free(destination); }
        assert.equal(e.swiftterm_terminal_selection_state_size(handle), 32);
        assert.equal(e.swiftterm_terminal_selection_text_size(handle), 0);
      } finally { assert.equal(e.swiftterm_terminal_destroy(handle), 0); }
    });
}
