import { SwiftTermError, uint } from './errors.js';
import { decodeGraphics, type GraphicsSnapshot } from './graphics.js';
import { decodeSnapshot } from './snapshot.js';
import { decodeEvent } from './events.js';
import type { WasmRuntime } from './loader.js';
import type { HostEvent, RenderSnapshot, TerminalOptions, InputModes, TerminalKeyEvent, KeyDisposition, InputState, TerminalMouseEvent, SelectionState, SelectionMode, ViewportState } from './types.js';
const encoder = new TextEncoder();
export class SwiftTermTerminal {
  private handle: number;
  private busy = false;
  /** Use SwiftTermModule.createTerminal to create terminals that share a module. */
  constructor(private readonly runtime: WasmRuntime, options: TerminalOptions) {
    const cols = uint(options.cols, 'cols', 2, 1024), rows = uint(options.rows, 'rows', 1, 1024), scrollback = uint(options.scrollback ?? 10000, 'scrollback', 0, 100000);
    this.handle = runtime.call('swiftterm_terminal_create', cols, rows, scrollback) >>> 0;
    if (!this.handle) runtime.check(-5);
  }
  private run<T>(body: () => T): T {
    if (!this.handle) throw new SwiftTermError('DISPOSED', 'The terminal is disposed.');
    if (this.busy) throw new SwiftTermError('BUSY', 'The terminal is already in use.', -6);
    this.busy = true;
    try { return body(); } finally { this.busy = false; }
  }
  private status(name: string, ...args: number[]): number { return this.runtime.check(this.runtime.call(name, this.handle, ...args), this.handle); }
  write(data: Uint8Array | string): void {
    this.run(() => {
      // Check the string length before UTF-8 conversion. Then check its byte length.
      if (typeof data === 'string' && data.length > 16 * 1024 * 1024) throw new SwiftTermError('INVALID_ARGUMENT', 'One write cannot exceed 16 MiB.');
      const bytes = typeof data === 'string' ? encoder.encode(data) : data;
      uint(bytes.byteLength, 'write length', 0, 16 * 1024 * 1024);
      this.runtime.withBuffer(bytes.byteLength, ptr => {
        // alloc can grow memory. Get the view after alloc and discard it before write.
        new Uint8Array(this.runtime.memory.buffer, ptr, bytes.byteLength).set(bytes);
        this.status('swiftterm_terminal_write', ptr, bytes.byteLength);
      });
    });
  }
  private requireCapability(bit: number): void {
    if (!(this.runtime.capabilities & bit)) throw new SwiftTermError('UNSUPPORTED', 'This WASM artifact does not support this operation.', -8);
  }
  private inputBytes(name: string, bytes: Uint8Array, ...prefix: number[]): number {
    return this.runtime.withBuffer(bytes.byteLength, ptr => {
      new Uint8Array(this.runtime.memory.buffer, ptr, bytes.byteLength).set(bytes);
      return this.status(name, ...prefix, ptr, bytes.byteLength);
    });
  }
  inputModes(): InputModes {
    return this.run(() => {
      this.requireCapability(128);
      const bits = this.status('swiftterm_terminal_input_modes');
      return { applicationCursor: !!(bits & 1), applicationKeypad: !!(bits & 2), bracketedPaste: !!(bits & 4),
        kittyPaste: !!(bits & 8), kittyKeyboardFlags: (bits >>> 8) & 31 };
    });
  }
  /** Return true if the core handled the key. False leaves text input to the browser. */
  sendKey(event: TerminalKeyEvent): boolean {
    return this.sendKeyResult(event) !== 'text';
  }
  /** Distinguish a queued key from a filtered event and browser text input. */
  sendKeyResult(event: TerminalKeyEvent): KeyDisposition {
    return this.run(() => {
      this.requireCapability(32);
      const strings = [event.key, event.code ?? '', event.text ?? ''];
      if (strings.some(x => typeof x !== 'string')) throw new SwiftTermError('INVALID_ARGUMENT', 'Key values must be strings.');
      const parts = strings.map(x => encoder.encode(x));
      if (parts[0].length > 128 || parts[1].length > 128 || parts[2].length > 2048) throw new SwiftTermError('INVALID_ARGUMENT', 'The key event is too large.');
      const bytes = new Uint8Array(28 + parts.reduce((n, x) => n + x.length, 0)), view = new DataView(bytes.buffer);
      const words = [uint(event.modifiers ?? 0, 'modifiers', 0, 255), uint(event.eventType ?? 1, 'eventType', 1, 3), ...parts.map(x => x.length),
        uint(event.shiftedKey ?? 0, 'shiftedKey', 0, 0x10ffff), uint(event.baseLayoutKey ?? 0, 'baseLayoutKey', 0, 0x10ffff)];
      words.forEach((x, i) => view.setUint32(i * 4, x, true));
      let offset = 28; for (const part of parts) { bytes.set(part, offset); offset += part.length; }
      const result = this.inputBytes('swiftterm_terminal_key', bytes);
      if (result > 2) throw new SwiftTermError('INTERNAL_ERROR', 'Invalid key disposition.');
      return (['text', 'sent', 'ignored'] as const)[result];
    });
  }
  /** Submit committed text, including IME input, without paste semantics. */
  sendText(text: string): void {
    this.run(() => {
      this.requireCapability(16384);
      if (typeof text !== 'string' || text.length > 65536) throw new SwiftTermError('INVALID_ARGUMENT', 'Text input cannot exceed 64 KiB.');
      const bytes = encoder.encode(text); uint(bytes.length, 'text size', 0, 65536);
      this.inputBytes('swiftterm_terminal_text', bytes);
    });
  }
  inputState(): InputState {
    const modes = this.inputModes();
    return this.run(() => {
      this.requireCapability(64);
      const bits = this.status('swiftterm_terminal_pointer_modes');
      const mouseMode = (['off', 'x10', 'vt200', 'button', 'any'] as const)[bits & 7];
      const mouseProtocol = (['legacy', 'utf8', 'sgr', 'urxvt', 'pixel'] as const)[(bits >>> 3) & 7];
      if (!mouseMode || !mouseProtocol) throw new SwiftTermError('INTERNAL_ERROR', 'Invalid mouse mode.');
      return { ...modes, mouseMode, mouseProtocol, mouseShiftCapture: !!(bits & 64), alternateScroll: !!(bits & 128), alternateScreen: !!(bits & 256) };
    });
  }
  sendMouse(event: TerminalMouseEvent): boolean {
    return this.run(() => {
      this.requireCapability(64);
      const action = ['press', 'release', 'move', 'wheel'].indexOf(event.action);
      uint(action, 'mouse action', 0, 3);
      return this.status('swiftterm_terminal_mouse', action, uint(event.button, 'button', 0, 7), uint(event.modifiers ?? 0, 'modifiers', 0, 15),
        uint(event.col, 'column', 0, 1023), uint(event.row, 'row', 0, 1023), uint(event.pixelX, 'pixelX', 0, 0x7ffffffe), uint(event.pixelY, 'pixelY', 0, 0x7ffffffe)) !== 0;
    });
  }
  scrollViewport(lines: number): void { this.scroll(lines, false); }
  scrollViewportTo(topRow: number): void { this.scroll(topRow, true); }
  private scroll(value: number, absolute: boolean): void {
    this.run(() => {
      this.requireCapability(32768);
      if (!Number.isInteger(value) || value < -0x80000000 || value > 0x7fffffff) throw new SwiftTermError('INVALID_ARGUMENT', 'Scroll position must be a signed 32-bit integer.');
      this.status('swiftterm_terminal_scroll', value, absolute ? 1 : 0);
    });
  }
  selectionBegin(col: number, row: number, mode: SelectionMode = 'character'): void {
    const value = ['character', 'word', 'row', 'extend'].indexOf(mode);
    uint(value, 'selection mode', 0, 3); this.select(0, col, row, value);
  }
  selectionExtend(col: number, row: number): void { this.select(1, col, row, 0); }
  selectionClear(): void { this.select(2, 0, 0, 0); }
  selectionAll(): void { this.select(3, 0, 0, 0); }
  private select(action: number, col: number, row: number, mode: number): void {
    this.run(() => { this.requireCapability(32768); this.status('swiftterm_terminal_selection', action, uint(col, 'column', 0, 1024), uint(row, 'row', 0, 1023), mode); });
  }
  selectionState(): SelectionState {
    return this.run(() => {
      this.requireCapability(32768);
      const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_selection_state_size', 'swiftterm_terminal_selection_state_copy', 32 + 1024 * 12);
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      if (bytes.length < 32 || view.getUint32(0, true) !== 1) throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection state.');
      const count = view.getUint32(24, true), flags = view.getUint32(20, true);
      if (count > 1024 || bytes.length !== 32 + count * 12) throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection span count.');
      const spans = [];
      for (let i = 0; i < count; i++) {
        const offset = 32 + i * 12, row = view.getUint32(offset, true), startCol = view.getUint32(offset + 4, true), endCol = view.getUint32(offset + 8, true);
        if (row > 1023 || startCol > endCol || endCol > 1024) throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection span.');
        spans.push({ row, startCol, endCol });
      }
      return { generation: BigInt(view.getUint32(4, true)) | BigInt(view.getUint32(8, true)) << 32n,
        topRow: view.getUint32(12, true), maximumTopRow: view.getUint32(16, true), active: !!(flags & 1), alternateScreen: !!(flags & 2), spans };
    });
  }
  viewportState(): ViewportState { const { topRow, maximumTopRow, alternateScreen } = this.selectionState(); return { topRow, maximumTopRow, alternateScreen }; }
  selectionText(): string {
    return this.run(() => {
      this.requireCapability(32768);
      const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_selection_text_size', 'swiftterm_terminal_selection_text_copy', 256 * 1024 * 1024);
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    });
  }
  /** Queue one paste. allowUnsafe requires explicit approval from the user. */
  paste(text: string, options: { clipboard?: boolean; allowUnsafe?: boolean } = {}): 'text' | 'event' {
    return this.run(() => {
      this.requireCapability(256);
      if (typeof text !== 'string' || text.length > 512 * 1024) throw new SwiftTermError('INVALID_ARGUMENT', 'A paste cannot exceed 512 KiB.');
      const bytes = encoder.encode(text); uint(bytes.length, 'paste size', 0, 512 * 1024);
      return this.runtime.withBuffer(bytes.length, ptr => {
        new Uint8Array(this.runtime.memory.buffer, ptr, bytes.length).set(bytes);
        return this.status('swiftterm_terminal_paste', ptr, bytes.length, (options.clipboard ? 1 : 0) | (options.allowUnsafe ? 2 : 0)) === 1 ? 'event' : 'text';
      });
    });
  }
  configureClipboard(capabilities: number): void {
    this.run(() => { this.requireCapability(512); this.status('swiftterm_terminal_clipboard_configure', uint(capabilities, 'clipboard capabilities', 0, 3)); });
  }
  completeClipboard(id: number, status: number, data: Uint8Array = new Uint8Array()): void {
    this.run(() => {
      this.requireCapability(512);
      if (!(data instanceof Uint8Array)) throw new SwiftTermError('INVALID_ARGUMENT', 'Clipboard data must be bytes.');
      uint(data.length, 'clipboard size', 0, 512 * 1024);
      this.inputBytes('swiftterm_terminal_clipboard_complete', data, uint(id, 'request ID', 1), uint(status, 'clipboard status', 0, 6));
    });
  }
  resetClipboard(): void { this.run(() => { this.requireCapability(512); this.status('swiftterm_terminal_clipboard_reset'); }); }
  poll(): boolean { return this.run(() => { this.requireCapability(8192); return this.status('swiftterm_terminal_poll') !== 0; }); }
  reset(): void { this.run(() => { this.status('swiftterm_terminal_reset'); }); }
  resize(cols: number, rows: number, cellWidthPx = 0, cellHeightPx = 0): void {
    this.run(() => { this.status('swiftterm_terminal_resize', uint(cols, 'cols', 2, 1024), uint(rows, 'rows', 1, 1024), uint(cellWidthPx, 'cellWidthPx'), uint(cellHeightPx, 'cellHeightPx')); });
  }
  setFocus(focused: boolean): void { this.run(() => { if (typeof focused !== 'boolean') throw new SwiftTermError('INVALID_ARGUMENT', 'focused must be Boolean.'); this.status('swiftterm_terminal_set_focus', focused ? 1 : 0); }); }
  setVisible(visible: boolean): void { this.run(() => { if (typeof visible !== 'boolean') throw new SwiftTermError('INVALID_ARGUMENT', 'visible must be Boolean.'); this.status('swiftterm_terminal_set_visibility', visible ? 1 : 2); }); }
  snapshot(): RenderSnapshot {
    return this.run(() => {
      const dirty = this.status('swiftterm_render_update');
      const snapshot = decodeSnapshot(this.runtime.read(this.handle, 'swiftterm_render_snapshot_size', 'swiftterm_render_snapshot_copy', 256 * 1024 * 1024));
      if (snapshot.dirty !== ['clean', 'partial', 'full'][dirty]) throw new SwiftTermError('INVALID_SNAPSHOT', 'Render status does not match snapshot damage.');
      return snapshot;
    });
  }
  /** Return new graphics state, or null if the last frame is current. */
  graphicsSnapshot(): GraphicsSnapshot | null {
    return this.run(() => {
      if (!(this.runtime.capabilities & 1024)) return null;
      if (!this.status('swiftterm_graphics_update')) return null;
      return decodeGraphics(this.runtime.read(this.handle, 'swiftterm_graphics_snapshot_size', 'swiftterm_graphics_snapshot_copy', 256 * 1024 * 1024));
    });
  }
  markGraphicsRendered(generation: bigint): void {
    this.run(() => {
      this.requireCapability(1024);
      if (typeof generation !== 'bigint' || generation < 0n || generation > 0xffffffffffffffffn) throw new SwiftTermError('INVALID_ARGUMENT', 'Invalid graphics generation.');
      this.status('swiftterm_graphics_clean', Number(generation & 0xffffffffn), Number(generation >> 32n));
    });
  }
  markFrameRendered(generation: bigint): void {
    this.run(() => {
      if (typeof generation !== 'bigint' || generation < 0n || generation > 0xffffffffffffffffn) throw new SwiftTermError('INVALID_ARGUMENT', 'Generation must fit in an unsigned 64-bit integer.');
      this.status('swiftterm_render_clean', Number(generation & 0xffffffffn), Number(generation >> 32n));
    });
  }
  /** Copy queued reply bytes. Call consumeOutput only after the transport accepts them. */
  readOutput(): Uint8Array { return this.run(() => this.runtime.read(this.handle, 'swiftterm_terminal_output_size', 'swiftterm_terminal_output_copy', 8 * 1024 * 1024)); }
  consumeOutput(byteCount: number): void { this.run(() => { this.status('swiftterm_terminal_output_consume', uint(byteCount, 'byteCount', 0, 8 * 1024 * 1024)); }); }
  /** Copy the first event without consuming it. */
  peekEvent(): HostEvent | null {
    return this.run(() => {
      const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_event_size', 'swiftterm_terminal_event_copy', 8 * 1024 * 1024);
      return bytes.length ? decodeEvent(bytes) : null;
    });
  }
  consumeEvent(): void { this.run(() => { this.status('swiftterm_terminal_event_consume'); }); }
  drainEvents(): HostEvent[] {
    return this.run(() => {
      const events: HostEvent[] = []; let total = 0;
      for (;;) {
        const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_event_size', 'swiftterm_terminal_event_copy', 8 * 1024 * 1024);
        if (!bytes.length) return events;
        total += bytes.length;
        if (total > 8 * 1024 * 1024) throw new SwiftTermError('INTERNAL_ERROR', 'Event queue did not drain within its limit.');
        events.push(decodeEvent(bytes));
        this.status('swiftterm_terminal_event_consume');
      }
    });
  }
  dispose(): void {
    if (!this.handle) return;
    this.run(() => { this.status('swiftterm_terminal_destroy'); this.handle = 0; });
  }
}
