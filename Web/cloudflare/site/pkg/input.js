import { KeyboardInputController, defaultKeyboardShortcut } from './keyboard.js';
const modifiers = (event) => (event.shiftKey ? 1 : 0) | (event.altKey ? 2 : 0) | (event.ctrlKey ? 4 : 0) | (event.metaKey ? 8 : 0);
/** DOM input ownership for one terminal. Transport and rendering stay with the host. */
export class TerminalInputController {
    terminal;
    surface;
    input;
    options;
    listeners = new AbortController();
    keyboard;
    gesture;
    selectionGeneration;
    focused;
    disposed = false;
    disposing = false;
    refreshing = false;
    scrollFrame = 0;
    scrollTime = 0;
    wheelRemainderX = 0;
    wheelRemainderY = 0;
    wheelRoute = '';
    lastMotion = '';
    pendingReleases = [];
    lastClick;
    constructor(terminal, surface, input, options) {
        this.terminal = terminal;
        this.surface = surface;
        this.input = input;
        this.options = options;
        this.keyboard = new KeyboardInputController(terminal, input, {
            canInput: this.prepareInput, onInput: this.inputReady, onError: this.error,
            onRelease: event => { this.pendingReleases.push({ device: 'key', event }); this.refresh(); },
            shortcut: this.shortcut, layout: options.layout, optionAsMeta: options.optionAsMeta,
        });
        const signal = this.listeners.signal;
        surface.addEventListener('pointerdown', this.pointerDown, { signal });
        surface.addEventListener('pointermove', this.pointerMove, { signal });
        surface.addEventListener('pointerup', this.pointerUp, { signal });
        surface.addEventListener('pointercancel', this.pointerCancel, { signal });
        surface.addEventListener('lostpointercapture', this.pointerCancel, { signal });
        surface.addEventListener('wheel', this.wheel, { passive: false, signal });
        surface.addEventListener('contextmenu', this.contextMenu, { signal });
        input.addEventListener('copy', this.copy, { signal });
        input.addEventListener('paste', this.paste, { signal });
        input.addEventListener('focus', this.updateFocus, { signal });
        input.addEventListener('blur', this.blur, { signal });
        window.addEventListener('focus', this.updateFocus, { signal });
        window.addEventListener('blur', this.blur, { signal });
        document.addEventListener('visibilitychange', this.visibility, { signal });
        this.visibility();
        this.refresh();
    }
    canInput = () => !this.disposed && !this.input.disabled && (this.options.canInput?.() ?? true);
    prepareInput = () => { this.refresh(); return this.canInput() && this.pendingReleases.length === 0; };
    error = (error) => { if (this.options.onError)
        this.options.onError(error);
    else
        console.error(error); };
    attempt(body) { if (!this.disposed) {
        try {
            body();
        }
        catch (error) {
            this.error(error);
        }
    } }
    inputReady = () => { this.options.onInput?.(); this.refresh(); };
    /** Call after PTY output, resize, or transport pressure changes. */
    refresh() {
        if (this.disposed || this.refreshing)
            return;
        this.refreshing = true;
        try {
            while (this.pendingReleases.length && this.canInput()) {
                const release = this.pendingReleases[0];
                const sent = release.device === 'key' ? this.terminal.sendKeyResult(release.event) === 'sent' : this.terminal.sendMouse(release.event);
                this.pendingReleases.shift();
                if (sent)
                    this.options.onInput?.();
            }
            this.keyboard.resume();
            const state = this.terminal.selectionState();
            if (this.selectionGeneration !== state.generation) {
                this.selectionGeneration = state.generation;
                this.options.onSelection?.(state);
            }
            // Keep the native IME candidate window close to the terminal cursor.
            const geometry = this.options.geometry(), rect = this.surface.getBoundingClientRect();
            const cursor = geometry.cursor;
            if (cursor) {
                const sx = rect.width / (geometry.cols * geometry.cellWidth), sy = rect.height / (geometry.rows * geometry.cellHeight);
                this.input.style.left = `${this.surface.offsetLeft + Math.max(0, Math.min(geometry.cols - 1, cursor.x)) * geometry.cellWidth * (geometry.rowScale?.(cursor.y) ?? 1) * sx}px`;
                this.input.style.top = `${this.surface.offsetTop + Math.max(0, Math.min(geometry.rows - 1, cursor.y)) * geometry.cellHeight * sy}px`;
            }
        }
        catch (error) {
            this.error(error);
        }
        finally {
            this.refreshing = false;
        }
    }
    shortcut = (event) => {
        if ((event.metaKey || (event.ctrlKey && event.shiftKey)) && event.key.toLowerCase() === 'a') {
            event.preventDefault();
            this.attempt(() => { this.terminal.selectionAll(); this.refresh(); });
            return true;
        }
        return this.options.shortcut ? this.options.shortcut(event) : defaultKeyboardShortcut(event);
    };
    updateFocus = () => this.attempt(() => {
        const focused = document.activeElement === this.input && document.hasFocus() && !document.hidden;
        if (focused !== this.focused) {
            this.focused = focused;
            this.terminal.setFocus(focused);
            this.inputReady();
        }
    });
    blur = () => {
        this.lastClick = undefined;
        this.keyboard.reset();
        this.endGesture();
        this.updateFocus();
    };
    visibility = () => {
        if (document.hidden) {
            this.lastClick = undefined;
            this.keyboard.reset();
            this.endGesture();
        }
        this.attempt(() => this.terminal.setVisible(!document.hidden));
        this.updateFocus();
    };
    point(clientX, clientY) {
        const g = this.options.geometry(), rect = this.surface.getBoundingClientRect();
        const x = Math.max(0, Math.min(g.cols * g.cellWidth - 1, (clientX - rect.left) * g.cols * g.cellWidth / Math.max(1, rect.width)));
        const y = Math.max(0, Math.min(g.rows * g.cellHeight - 1, (clientY - rect.top) * g.rows * g.cellHeight / Math.max(1, rect.height)));
        const row = Math.floor(y / g.cellHeight);
        return { col: Math.min(g.cols - 1, Math.floor(x / (g.cellWidth * (g.rowScale?.(row) ?? 1)))), row, pixelX: Math.floor(x), pixelY: Math.floor(y) };
    }
    captures(state, shift) { return state.mouseMode !== 'off' && (!shift || state.mouseShiftCapture); }
    mouse(action, button, point, flags) {
        const sent = this.terminal.sendMouse({ action, button, ...point, modifiers: flags });
        if (sent)
            this.inputReady();
        return sent;
    }
    countClick(event) {
        const previous = this.lastClick;
        const close = previous && event.timeStamp - previous.time <= 500 &&
            Math.hypot(event.clientX - previous.x, event.clientY - previous.y) <= 5;
        const count = close ? previous.count % 3 + 1 : 1;
        this.lastClick = { time: event.timeStamp, x: event.clientX, y: event.clientY, count };
        return count;
    }
    pointerDown = (event) => this.attempt(() => {
        if (!this.prepareInput() || this.gesture || event.button > 2)
            return;
        const point = this.point(event.clientX, event.clientY), state = this.terminal.inputState();
        const flags = modifiers(event), route = this.captures(state, event.shiftKey) ? 'mouse' : 'selection';
        if (route === 'selection' && event.button !== 0)
            return;
        const clicks = route === 'selection' && !event.shiftKey ? this.countClick(event) : 1;
        if (route === 'mouse' || event.shiftKey)
            this.lastClick = undefined;
        const gesture = { id: event.pointerId, route, button: event.button, anchor: point, last: point,
            started: false, clientX: event.clientX, clientY: event.clientY, modifiers: flags };
        this.gesture = gesture;
        this.lastMotion = '';
        try {
            if (route === 'mouse') {
                if (!this.terminal.sendMouse({ action: 'press', button: event.button, ...point, modifiers: flags })) {
                    this.gesture = undefined;
                    return;
                }
                gesture.started = true;
                event.preventDefault();
                this.inputReady();
            }
            if (this.gesture !== gesture || this.disposed)
                return;
            if (!this.canInput()) {
                this.endGesture();
                return;
            }
            event.preventDefault();
            this.input.focus({ preventScroll: true });
            if (this.gesture !== gesture || this.disposed)
                return;
            if (!this.canInput()) {
                this.endGesture();
                return;
            }
            this.surface.setPointerCapture(event.pointerId);
            if (route === 'selection') {
                if (event.shiftKey || clicks >= 2) {
                    this.terminal.selectionBegin(point.col, point.row, event.shiftKey ? 'extend' : clicks === 3 ? 'row' : 'word');
                    gesture.started = true;
                }
                else
                    this.terminal.selectionClear();
                this.refresh();
            }
        }
        catch (error) {
            if (this.gesture === gesture)
                this.endGesture();
            throw error;
        }
    });
    pointerMove = (event) => this.attempt(() => {
        const gesture = this.gesture;
        if (gesture && gesture.id !== event.pointerId)
            return;
        const point = this.point(event.clientX, event.clientY);
        if (gesture?.route === 'selection') {
            event.preventDefault();
            gesture.clientX = event.clientX;
            gesture.clientY = event.clientY;
            gesture.last = point;
            if (Math.abs(point.pixelX - gesture.anchor.pixelX) > 2 || Math.abs(point.pixelY - gesture.anchor.pixelY) > 2)
                this.lastClick = undefined;
            if (!gesture.started && (Math.abs(point.pixelX - gesture.anchor.pixelX) > 2 || Math.abs(point.pixelY - gesture.anchor.pixelY) > 2)) {
                this.terminal.selectionBegin(gesture.anchor.col, gesture.anchor.row);
                gesture.started = true;
            }
            if (gesture.started) {
                this.terminal.selectionExtend(point.col, point.row);
                this.refresh();
                this.startAutoscroll();
            }
            return;
        }
        if (!this.prepareInput())
            return;
        const state = this.terminal.inputState();
        if (!gesture && (!this.captures(state, event.shiftKey) || state.mouseMode !== 'any'))
            return;
        const button = gesture?.button ?? 3, flags = modifiers(event);
        const position = state.mouseProtocol === 'pixel' ? `${point.pixelX}:${point.pixelY}` : `${point.col}:${point.row}`;
        const key = `${state.mouseMode}:${state.mouseProtocol}:${button}:${flags}:${position}`;
        if (key === this.lastMotion)
            return;
        this.lastMotion = key;
        if (gesture) {
            gesture.last = point;
            gesture.modifiers = flags;
        }
        if (this.mouse('move', button, point, flags))
            event.preventDefault();
    });
    pointerUp = (event) => {
        if (this.gesture?.id !== event.pointerId)
            return;
        event.preventDefault();
        // A failed hit test must not leave the gesture and the pointer capture behind.
        this.attempt(() => {
            const gesture = this.gesture;
            if (!gesture)
                return;
            gesture.last = this.point(event.clientX, event.clientY);
            gesture.modifiers = modifiers(event);
        });
        this.endGesture();
    };
    pointerCancel = (event) => { if (this.gesture?.id === event.pointerId) {
        this.lastClick = undefined;
        this.endGesture();
    } };
    endGesture() {
        const gesture = this.gesture;
        this.gesture = undefined;
        cancelAnimationFrame(this.scrollFrame);
        this.scrollFrame = 0;
        this.scrollTime = 0;
        if (!gesture)
            return;
        this.attempt(() => {
            if (gesture.route === 'mouse' && gesture.started) {
                const release = { action: 'release', button: gesture.button, ...gesture.last, modifiers: gesture.modifiers };
                this.pendingReleases.push({ device: 'mouse', event: release });
                this.refresh();
            }
            else if (gesture.route === 'selection' && gesture.started) {
                this.terminal.selectionExtend(gesture.last.col, gesture.last.row);
                this.refresh();
            }
            if (this.surface.hasPointerCapture(gesture.id))
                this.surface.releasePointerCapture(gesture.id);
        });
    }
    startAutoscroll() { if (!this.scrollFrame)
        this.scrollFrame = requestAnimationFrame(this.autoscroll); }
    autoscroll = (time) => {
        this.scrollFrame = 0;
        const gesture = this.gesture;
        if (!gesture || gesture.route !== 'selection' || !gesture.started || !this.canInput())
            return;
        const rect = this.surface.getBoundingClientRect();
        const distance = gesture.clientY < rect.top ? gesture.clientY - rect.top : gesture.clientY > rect.bottom ? gesture.clientY - rect.bottom : 0;
        if (!distance)
            return;
        if (time - this.scrollTime >= 50)
            this.attempt(() => {
                this.scrollTime = time;
                this.terminal.scrollViewport(Math.sign(distance) * Math.min(6, Math.ceil(Math.abs(distance) / this.options.geometry().cellHeight)));
                gesture.last = this.point(gesture.clientX, gesture.clientY);
                this.terminal.selectionExtend(gesture.last.col, gesture.last.row);
                this.inputReady();
            });
        this.startAutoscroll();
    };
    wheel = (event) => this.attempt(() => {
        if (!this.prepareInput() || event.ctrlKey)
            return; // Preserve browser pinch-to-zoom.
        const state = this.terminal.inputState(), g = this.options.geometry();
        const route = this.captures(state, event.shiftKey) ? 'mouse' : state.alternateScreen ? (state.alternateScroll ? 'keys' : 'none') : 'scroll';
        const routeKey = `${route}:${state.mouseMode}:${state.mouseProtocol}`;
        if (routeKey !== this.wheelRoute) {
            this.wheelRoute = routeKey;
            this.wheelRemainderX = this.wheelRemainderY = 0;
        }
        if (route === 'none')
            return;
        const displayedRowHeight = this.surface.getBoundingClientRect().height / g.rows;
        const scale = event.deltaMode === 1 ? 1 : event.deltaMode === 2 ? g.rows : 1 / Math.max(1, displayedRowHeight);
        this.wheelRemainderX += event.deltaX * scale;
        this.wheelRemainderY += event.deltaY * scale;
        const dx = Math.max(-32, Math.min(32, Math.trunc(this.wheelRemainderX))), dy = Math.max(-32, Math.min(32, Math.trunc(this.wheelRemainderY)));
        this.wheelRemainderX -= Math.trunc(this.wheelRemainderX);
        this.wheelRemainderY -= Math.trunc(this.wheelRemainderY);
        event.preventDefault();
        if (route === 'scroll') {
            if (dy)
                this.terminal.scrollViewport(dy);
        }
        else if (route === 'keys') {
            for (let i = 0; i < Math.abs(dy); i++)
                this.terminal.sendKey({ key: dy < 0 ? 'ArrowUp' : 'ArrowDown' });
        }
        else {
            const point = this.point(event.clientX, event.clientY), flags = modifiers(event);
            for (let i = 0; i < Math.abs(dy); i++)
                this.terminal.sendMouse({ action: 'wheel', button: dy < 0 ? 4 : 5, ...point, modifiers: flags });
            for (let i = 0; i < Math.abs(dx); i++)
                this.terminal.sendMouse({ action: 'wheel', button: dx < 0 ? 6 : 7, ...point, modifiers: flags });
        }
        this.inputReady();
    });
    contextMenu = (event) => this.attempt(() => {
        if (this.captures(this.terminal.inputState(), event.shiftKey))
            event.preventDefault();
    });
    copy = (event) => this.attempt(() => {
        if (!event.clipboardData || !this.terminal.selectionState().active)
            return;
        event.clipboardData.setData('text/plain', this.terminal.selectionText());
        event.preventDefault();
    });
    paste = (event) => this.attempt(() => {
        if (!this.prepareInput() || !event.clipboardData)
            return;
        event.preventDefault();
        const text = event.clipboardData.getData('text/plain').replace(/\r\n?/g, '\n');
        if (this.options.onPaste)
            this.options.onPaste(text, event);
        else {
            this.terminal.paste(text, { clipboard: true });
            this.inputReady();
        }
    });
    dispose() {
        if (this.disposed || this.disposing)
            return;
        this.disposing = true;
        try {
            this.endGesture();
            this.keyboard.dispose();
            this.attempt(() => { this.terminal.setFocus(false); this.options.onInput?.(); });
        }
        finally {
            this.disposed = true;
            this.listeners.abort();
        }
    }
}
