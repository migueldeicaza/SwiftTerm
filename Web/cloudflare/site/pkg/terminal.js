import { SwiftTermError, uint } from './errors.js';
import { decodeGraphics } from './graphics.js';
import { decodeSnapshot } from './snapshot.js';
import { decodeEvent } from './events.js';
const encoder = new TextEncoder();
export class SwiftTermTerminal {
    runtime;
    handle;
    busy = false;
    /** Use SwiftTermModule.createTerminal to create terminals that share a module. */
    constructor(runtime, options) {
        this.runtime = runtime;
        const cols = uint(options.cols, 'cols', 2, 1024), rows = uint(options.rows, 'rows', 1, 1024), scrollback = uint(options.scrollback ?? 10000, 'scrollback', 0, 100000);
        this.handle = runtime.call('swiftterm_terminal_create', cols, rows, scrollback) >>> 0;
        if (!this.handle)
            runtime.check(-5);
    }
    run(body) {
        if (!this.handle)
            throw new SwiftTermError('DISPOSED', 'The terminal is disposed.');
        if (this.busy)
            throw new SwiftTermError('BUSY', 'The terminal is already in use.', -6);
        this.busy = true;
        try {
            return body();
        }
        finally {
            this.busy = false;
        }
    }
    status(name, ...args) { return this.runtime.check(this.runtime.call(name, this.handle, ...args), this.handle); }
    write(data) {
        this.run(() => {
            // Check the string length before UTF-8 conversion. Then check its byte length.
            if (typeof data === 'string' && data.length > 16 * 1024 * 1024)
                throw new SwiftTermError('INVALID_ARGUMENT', 'One write cannot exceed 16 MiB.');
            const bytes = typeof data === 'string' ? encoder.encode(data) : data;
            uint(bytes.byteLength, 'write length', 0, 16 * 1024 * 1024);
            this.runtime.withBuffer(bytes.byteLength, ptr => {
                // alloc can grow memory. Get the view after alloc and discard it before write.
                new Uint8Array(this.runtime.memory.buffer, ptr, bytes.byteLength).set(bytes);
                this.status('swiftterm_terminal_write', ptr, bytes.byteLength);
            });
        });
    }
    requireCapability(bit) {
        if (!(this.runtime.capabilities & bit))
            throw new SwiftTermError('UNSUPPORTED', 'This WASM artifact does not support this operation.', -8);
    }
    inputBytes(name, bytes, ...prefix) {
        return this.runtime.withBuffer(bytes.byteLength, ptr => {
            new Uint8Array(this.runtime.memory.buffer, ptr, bytes.byteLength).set(bytes);
            return this.status(name, ...prefix, ptr, bytes.byteLength);
        });
    }
    inputModes() {
        return this.run(() => {
            this.requireCapability(128);
            const bits = this.status('swiftterm_terminal_input_modes');
            return { applicationCursor: !!(bits & 1), applicationKeypad: !!(bits & 2), bracketedPaste: !!(bits & 4),
                kittyPaste: !!(bits & 8), kittyKeyboardFlags: (bits >>> 8) & 31 };
        });
    }
    /** Return true if the core handled the key. False leaves text input to the browser. */
    sendKey(event) {
        return this.sendKeyResult(event) !== 'text';
    }
    /** Distinguish a queued key from a filtered event and browser text input. */
    sendKeyResult(event) {
        return this.run(() => {
            this.requireCapability(32);
            const strings = [event.key, event.code ?? '', event.text ?? ''];
            if (strings.some(x => typeof x !== 'string'))
                throw new SwiftTermError('INVALID_ARGUMENT', 'Key values must be strings.');
            const parts = strings.map(x => encoder.encode(x));
            if (parts[0].length > 128 || parts[1].length > 128 || parts[2].length > 2048)
                throw new SwiftTermError('INVALID_ARGUMENT', 'The key event is too large.');
            const bytes = new Uint8Array(28 + parts.reduce((n, x) => n + x.length, 0)), view = new DataView(bytes.buffer);
            const words = [uint(event.modifiers ?? 0, 'modifiers', 0, 255), uint(event.eventType ?? 1, 'eventType', 1, 3), ...parts.map(x => x.length),
                uint(event.shiftedKey ?? 0, 'shiftedKey', 0, 0x10ffff), uint(event.baseLayoutKey ?? 0, 'baseLayoutKey', 0, 0x10ffff)];
            words.forEach((x, i) => view.setUint32(i * 4, x, true));
            let offset = 28;
            for (const part of parts) {
                bytes.set(part, offset);
                offset += part.length;
            }
            const result = this.inputBytes('swiftterm_terminal_key', bytes);
            if (result > 2)
                throw new SwiftTermError('INTERNAL_ERROR', 'Invalid key disposition.');
            return ['text', 'sent', 'ignored'][result];
        });
    }
    /** Submit committed text, including IME input, without paste semantics. */
    sendText(text) {
        this.run(() => {
            this.requireCapability(16384);
            if (typeof text !== 'string' || text.length > 65536)
                throw new SwiftTermError('INVALID_ARGUMENT', 'Text input cannot exceed 64 KiB.');
            const bytes = encoder.encode(text);
            uint(bytes.length, 'text size', 0, 65536);
            this.inputBytes('swiftterm_terminal_text', bytes);
        });
    }
    inputState() {
        const modes = this.inputModes();
        return this.run(() => {
            this.requireCapability(64);
            const bits = this.status('swiftterm_terminal_pointer_modes');
            const mouseMode = ['off', 'x10', 'vt200', 'button', 'any'][bits & 7];
            const mouseProtocol = ['legacy', 'utf8', 'sgr', 'urxvt', 'pixel'][(bits >>> 3) & 7];
            if (!mouseMode || !mouseProtocol)
                throw new SwiftTermError('INTERNAL_ERROR', 'Invalid mouse mode.');
            return { ...modes, mouseMode, mouseProtocol, mouseShiftCapture: !!(bits & 64), alternateScroll: !!(bits & 128), alternateScreen: !!(bits & 256) };
        });
    }
    sendMouse(event) {
        return this.run(() => {
            this.requireCapability(64);
            const action = ['press', 'release', 'move', 'wheel'].indexOf(event.action);
            uint(action, 'mouse action', 0, 3);
            return this.status('swiftterm_terminal_mouse', action, uint(event.button, 'button', 0, 7), uint(event.modifiers ?? 0, 'modifiers', 0, 15), uint(event.col, 'column', 0, 1023), uint(event.row, 'row', 0, 1023), uint(event.pixelX, 'pixelX', 0, 0x7ffffffe), uint(event.pixelY, 'pixelY', 0, 0x7ffffffe)) !== 0;
        });
    }
    scrollViewport(lines) { this.scroll(lines, false); }
    scrollViewportTo(topRow) { this.scroll(topRow, true); }
    scroll(value, absolute) {
        this.run(() => {
            this.requireCapability(32768);
            if (!Number.isInteger(value) || value < -0x80000000 || value > 0x7fffffff)
                throw new SwiftTermError('INVALID_ARGUMENT', 'Scroll position must be a signed 32-bit integer.');
            this.status('swiftterm_terminal_scroll', value, absolute ? 1 : 0);
        });
    }
    selectionBegin(col, row, mode = 'character') {
        const value = ['character', 'word', 'row', 'extend'].indexOf(mode);
        uint(value, 'selection mode', 0, 3);
        this.select(0, col, row, value);
    }
    selectionExtend(col, row) { this.select(1, col, row, 0); }
    selectionClear() { this.select(2, 0, 0, 0); }
    selectionAll() { this.select(3, 0, 0, 0); }
    select(action, col, row, mode) {
        this.run(() => { this.requireCapability(32768); this.status('swiftterm_terminal_selection', action, uint(col, 'column', 0, 1024), uint(row, 'row', 0, 1023), mode); });
    }
    selectionState() {
        return this.run(() => {
            this.requireCapability(32768);
            const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_selection_state_size', 'swiftterm_terminal_selection_state_copy', 32 + 1024 * 12);
            const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
            if (bytes.length < 32 || view.getUint32(0, true) !== 1)
                throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection state.');
            const count = view.getUint32(24, true), flags = view.getUint32(20, true);
            if (count > 1024 || bytes.length !== 32 + count * 12)
                throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection span count.');
            const spans = [];
            for (let i = 0; i < count; i++) {
                const offset = 32 + i * 12, row = view.getUint32(offset, true), startCol = view.getUint32(offset + 4, true), endCol = view.getUint32(offset + 8, true);
                if (row > 1023 || startCol > endCol || endCol > 1024)
                    throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid selection span.');
                spans.push({ row, startCol, endCol });
            }
            return { generation: BigInt(view.getUint32(4, true)) | BigInt(view.getUint32(8, true)) << 32n,
                topRow: view.getUint32(12, true), maximumTopRow: view.getUint32(16, true), active: !!(flags & 1), alternateScreen: !!(flags & 2), spans };
        });
    }
    viewportState() { const { topRow, maximumTopRow, alternateScreen } = this.selectionState(); return { topRow, maximumTopRow, alternateScreen }; }
    selectionText() {
        return this.run(() => {
            this.requireCapability(32768);
            const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_selection_text_size', 'swiftterm_terminal_selection_text_copy', 256 * 1024 * 1024);
            return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        });
    }
    /** Queue one paste. allowUnsafe requires explicit approval from the user. */
    paste(text, options = {}) {
        return this.run(() => {
            this.requireCapability(256);
            if (typeof text !== 'string' || text.length > 512 * 1024)
                throw new SwiftTermError('INVALID_ARGUMENT', 'A paste cannot exceed 512 KiB.');
            const bytes = encoder.encode(text);
            uint(bytes.length, 'paste size', 0, 512 * 1024);
            return this.runtime.withBuffer(bytes.length, ptr => {
                new Uint8Array(this.runtime.memory.buffer, ptr, bytes.length).set(bytes);
                return this.status('swiftterm_terminal_paste', ptr, bytes.length, (options.clipboard ? 1 : 0) | (options.allowUnsafe ? 2 : 0)) === 1 ? 'event' : 'text';
            });
        });
    }
    configureClipboard(capabilities) {
        this.run(() => { this.requireCapability(512); this.status('swiftterm_terminal_clipboard_configure', uint(capabilities, 'clipboard capabilities', 0, 3)); });
    }
    completeClipboard(id, status, data = new Uint8Array()) {
        this.run(() => {
            this.requireCapability(512);
            if (!(data instanceof Uint8Array))
                throw new SwiftTermError('INVALID_ARGUMENT', 'Clipboard data must be bytes.');
            uint(data.length, 'clipboard size', 0, 512 * 1024);
            this.inputBytes('swiftterm_terminal_clipboard_complete', data, uint(id, 'request ID', 1), uint(status, 'clipboard status', 0, 6));
        });
    }
    resetClipboard() { this.run(() => { this.requireCapability(512); this.status('swiftterm_terminal_clipboard_reset'); }); }
    poll() { return this.run(() => { this.requireCapability(8192); return this.status('swiftterm_terminal_poll') !== 0; }); }
    reset() { this.run(() => { this.status('swiftterm_terminal_reset'); }); }
    resize(cols, rows, cellWidthPx = 0, cellHeightPx = 0) {
        this.run(() => { this.status('swiftterm_terminal_resize', uint(cols, 'cols', 2, 1024), uint(rows, 'rows', 1, 1024), uint(cellWidthPx, 'cellWidthPx'), uint(cellHeightPx, 'cellHeightPx')); });
    }
    setFocus(focused) { this.run(() => { if (typeof focused !== 'boolean')
        throw new SwiftTermError('INVALID_ARGUMENT', 'focused must be Boolean.'); this.status('swiftterm_terminal_set_focus', focused ? 1 : 0); }); }
    setVisible(visible) { this.run(() => { if (typeof visible !== 'boolean')
        throw new SwiftTermError('INVALID_ARGUMENT', 'visible must be Boolean.'); this.status('swiftterm_terminal_set_visibility', visible ? 1 : 2); }); }
    snapshot() {
        return this.run(() => {
            const dirty = this.status('swiftterm_render_update');
            const snapshot = decodeSnapshot(this.runtime.read(this.handle, 'swiftterm_render_snapshot_size', 'swiftterm_render_snapshot_copy', 256 * 1024 * 1024));
            if (snapshot.dirty !== ['clean', 'partial', 'full'][dirty])
                throw new SwiftTermError('INVALID_SNAPSHOT', 'Render status does not match snapshot damage.');
            return snapshot;
        });
    }
    /** Return new graphics state, or null if the last frame is current. */
    graphicsSnapshot() {
        return this.run(() => {
            if (!(this.runtime.capabilities & 1024))
                return null;
            if (!this.status('swiftterm_graphics_update'))
                return null;
            return decodeGraphics(this.runtime.read(this.handle, 'swiftterm_graphics_snapshot_size', 'swiftterm_graphics_snapshot_copy', 256 * 1024 * 1024));
        });
    }
    markGraphicsRendered(generation) {
        this.run(() => {
            this.requireCapability(1024);
            if (typeof generation !== 'bigint' || generation < 0n || generation > 0xffffffffffffffffn)
                throw new SwiftTermError('INVALID_ARGUMENT', 'Invalid graphics generation.');
            this.status('swiftterm_graphics_clean', Number(generation & 0xffffffffn), Number(generation >> 32n));
        });
    }
    markFrameRendered(generation) {
        this.run(() => {
            if (typeof generation !== 'bigint' || generation < 0n || generation > 0xffffffffffffffffn)
                throw new SwiftTermError('INVALID_ARGUMENT', 'Generation must fit in an unsigned 64-bit integer.');
            this.status('swiftterm_render_clean', Number(generation & 0xffffffffn), Number(generation >> 32n));
        });
    }
    /** Copy queued reply bytes. Call consumeOutput only after the transport accepts them. */
    readOutput() { return this.run(() => this.runtime.read(this.handle, 'swiftterm_terminal_output_size', 'swiftterm_terminal_output_copy', 8 * 1024 * 1024)); }
    consumeOutput(byteCount) { this.run(() => { this.status('swiftterm_terminal_output_consume', uint(byteCount, 'byteCount', 0, 8 * 1024 * 1024)); }); }
    /** Copy the first event without consuming it. */
    peekEvent() {
        return this.run(() => {
            const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_event_size', 'swiftterm_terminal_event_copy', 8 * 1024 * 1024);
            return bytes.length ? decodeEvent(bytes) : null;
        });
    }
    consumeEvent() { this.run(() => { this.status('swiftterm_terminal_event_consume'); }); }
    drainEvents() {
        return this.run(() => {
            const events = [];
            let total = 0;
            for (;;) {
                const bytes = this.runtime.read(this.handle, 'swiftterm_terminal_event_size', 'swiftterm_terminal_event_copy', 8 * 1024 * 1024);
                if (!bytes.length)
                    return events;
                total += bytes.length;
                if (total > 8 * 1024 * 1024)
                    throw new SwiftTermError('INTERNAL_ERROR', 'Event queue did not drain within its limit.');
                events.push(decodeEvent(bytes));
                this.status('swiftterm_terminal_event_consume');
            }
        });
    }
    dispose() {
        if (!this.handle)
            return;
        this.run(() => { this.status('swiftterm_terminal_destroy'); this.handle = 0; });
    }
}
