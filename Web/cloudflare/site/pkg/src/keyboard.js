const punctuation = {
    Backquote: '`', Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']',
    Backslash: '\\', IntlBackslash: '\\', Semicolon: ';', Quote: "'", Comma: ',', Period: '.', Slash: '/',
};
const shifts = {
    '~': '`', '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
    '_': '-', '+': '=', '{': '[', '}': ']', '|': '\\', ':': ';', '"': "'", '<': ',', '>': '.', '?': '/',
};
function scalar(text) { return [...text].length === 1 ? text.codePointAt(0) : 0; }
function baseKey(code) {
    if (/^Key[A-Z]$/.test(code))
        return code.slice(3).toLowerCase();
    if (/^Digit[0-9]$/.test(code))
        return code.slice(5);
    return punctuation[code] ?? '';
}
function macPlatform() { return /Mac|iPhone|iPad/.test(globalThis.navigator?.platform ?? ''); }
/**
 * The default browser/terminal split. `mac` defaults to the running platform.
 * macOS puts the browser shortcuts on Command, which leaves Control for the
 * terminal: Ctrl+L, Ctrl+W and Ctrl+N stay terminal keys there.
 */
export function defaultKeyboardShortcut(event, mac = macPlatform()) {
    const key = event.key.toLowerCase();
    return (event.metaKey && ['a', 'c', 'v', 'x', 'r', 'l', 'w', 't', 'n', 'q', '+', '-', '0', '='].includes(key)) ||
        (event.ctrlKey && event.shiftKey && ['c', 'v'].includes(key)) ||
        (!mac && event.ctrlKey && !event.altKey && ['l', 't', 'w', 'n', '+', '-', '0', '='].includes(key)) ||
        (event.shiftKey && event.key === 'Insert');
}
/** Routes browser keyboard and committed text through the terminal input service. */
export class KeyboardInputController {
    terminal;
    input;
    options;
    listeners = [];
    presses = new Map();
    layout = new Map();
    observed = new Map();
    releases = [];
    composing = false;
    dead = false;
    duplicateCommit = null;
    compositionEndedAt = -Infinity;
    disposed = false;
    flushing = false;
    mac;
    constructor(terminal, input, options = {}) {
        this.terminal = terminal;
        this.input = input;
        this.options = options;
        const navigator = input.ownerDocument?.defaultView?.navigator ?? globalThis.navigator;
        this.mac = /Mac|iPhone|iPad/.test(navigator?.platform ?? '');
        for (const [code, key] of Object.entries(options.layout ?? {}))
            this.layout.set(code, key);
        const keyboard = navigator?.keyboard;
        // The map is optional. A denied permission must not disable keyboard input.
        if (keyboard?.getLayoutMap) {
            void keyboard.getLayoutMap().then(map => {
                if (!this.disposed)
                    map.forEach((key, code) => {
                        if (!Object.hasOwn(options.layout ?? {}, code))
                            this.layout.set(code, key);
                    });
            }).catch(() => { });
        }
        this.listen('keydown', event => this.keydown(event));
        this.listen('keyup', event => this.keyup(event));
        this.listen('beforeinput', event => this.beforeinput(event));
        this.listen('input', event => this.textInput(event));
        this.listen('compositionstart', () => {
            this.composing = true;
            this.dead = false;
            this.duplicateCommit = null;
            this.compositionEndedAt = -Infinity;
        });
        this.listen('compositionend', event => {
            this.composing = false;
            this.dead = false;
            // Empty data is a cancelled composition, not the last preedit value.
            const text = event.data ?? input.value;
            input.value = '';
            this.duplicateCommit = text;
            this.compositionEndedAt = this.now();
            if (text)
                this.commit(text);
        });
        this.listen('blur', () => this.reset());
    }
    now() { return globalThis.performance?.now() ?? Date.now(); }
    listen(name, handler) {
        const listener = (event) => {
            if (this.disposed)
                return;
            try {
                handler(event);
            }
            catch (error) {
                this.options.onError?.(error);
            }
        };
        this.input.addEventListener(name, listener);
        this.listeners.push(() => this.input.removeEventListener(name, listener));
    }
    enabled() { return !this.disposed && (this.options.canInput?.() ?? true); }
    id(event) { return event.code || `${event.key}:${event.location}`; }
    modifiers(event, consumed = false) {
        return (event.shiftKey ? 1 : 0) | (event.altKey && !consumed ? 2 : 0) | (event.ctrlKey && !consumed ? 4 : 0) |
            (event.metaKey ? 8 : 0) | (event.getModifierState?.('CapsLock') ? 64 : 0) | (event.getModifierState?.('NumLock') ? 128 : 0);
    }
    consumedModifiers(event) {
        return !!scalar(event.key) && (!!event.getModifierState?.('AltGraph') ||
            (this.mac && !this.options.optionAsMeta && event.altKey && !event.ctrlKey && !event.metaKey));
    }
    normalize(event, consumed) {
        const base = baseKey(event.code), printable = !!scalar(event.key);
        const caps = !!event.getModifierState?.('CapsLock');
        if (printable && !event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey && !caps) {
            this.observed.set(event.code, event.key);
        }
        const known = this.layout.get(event.code) ?? this.observed.get(event.code);
        let primary = event.key;
        if (printable) {
            if (known && scalar(known))
                primary = known;
            else if (event.shiftKey || caps) {
                // Letter case is layout-independent. Only infer US punctuation when no layout is known.
                const lower = event.key.toLowerCase();
                if (scalar(lower) && lower !== event.key)
                    primary = lower;
                else if (event.shiftKey && this.layout.size === 0 && shifts[event.key] === base)
                    primary = base;
            }
        }
        return { key: primary, code: event.code, modifiers: this.modifiers(event, consumed),
            text: printable && (consumed || (!event.ctrlKey && !event.altKey && !event.metaKey)) ? event.key : undefined,
            shiftedKey: printable && event.shiftKey && event.key !== primary ? scalar(event.key) : 0,
            baseLayoutKey: scalar(base) };
    }
    keydown(event) {
        const id = this.id(event), existing = this.presses.get(id);
        if (existing) {
            if (existing.route === 'host')
                return;
            if (existing.route === 'ignored') {
                event.preventDefault();
                return;
            }
            if (this.composing || event.isComposing || event.keyCode === 229)
                return;
            if (!this.ready()) {
                event.preventDefault();
                return;
            }
            const next = this.normalize(event, this.consumedModifiers(event));
            const result = this.terminal.sendKeyResult({ ...next, key: existing.key.key, baseLayoutKey: existing.key.baseLayoutKey, eventType: 2 });
            if (result !== 'text')
                event.preventDefault();
            if (result === 'sent') {
                existing.route = 'sent';
                this.options.onInput?.();
            }
            return;
        }
        const key = this.normalize(event, this.consumedModifiers(event));
        if (this.composing || event.isComposing || event.keyCode === 229 || event.key === 'Dead' || event.key === 'Process') {
            if (event.key === 'Dead')
                this.dead = true;
            this.presses.set(id, { route: 'host', key });
            return;
        }
        // Safari can send compositionend immediately before the unmarked commit Enter.
        if (event.key === 'Enter' && this.now() - this.compositionEndedAt < 50) {
            event.preventDefault();
            this.presses.set(id, { route: 'ignored', key });
            return;
        }
        this.compositionEndedAt = -Infinity;
        this.duplicateCommit = null;
        if (!this.consumedModifiers(event) && (this.options.shortcut ? this.options.shortcut(event) : defaultKeyboardShortcut(event, this.mac))) {
            this.presses.set(id, { route: 'host', key });
            return;
        }
        if (!this.ready()) {
            event.preventDefault();
            this.presses.set(id, { route: 'ignored', key });
            return;
        }
        if (this.dead && scalar(event.key)) {
            this.presses.set(id, { route: 'text', key });
            return;
        }
        const result = this.terminal.sendKeyResult({ ...key, eventType: 1 });
        this.presses.set(id, { route: result, key, consumed: this.consumedModifiers(event) });
        if (result !== 'text')
            event.preventDefault();
        if (result === 'sent')
            this.options.onInput?.();
    }
    keyup(event) {
        const id = this.id(event), press = this.presses.get(id);
        this.presses.delete(id);
        if (!press || press.route !== 'sent')
            return;
        event.preventDefault();
        this.queueRelease({ ...press.key, modifiers: this.modifiers(event, press.consumed || this.consumedModifiers(event)), text: undefined, eventType: 3 });
        this.resume();
    }
    beforeinput(event) {
        if (this.composing || event.isComposing)
            return;
        if (!this.enabled()) {
            event.preventDefault();
            return;
        }
        if (this.duplicateCommit !== null && this.now() - this.compositionEndedAt < 50 && (event.inputType === 'insertFromComposition' ||
            (event.data === this.duplicateCommit && event.inputType === 'insertText'))) {
            event.preventDefault();
            this.input.value = '';
            return;
        }
        if ((event.inputType === 'insertLineBreak' || event.inputType === 'insertParagraph') &&
            this.now() - this.compositionEndedAt < 50)
            event.preventDefault();
    }
    textInput(event) {
        if (this.composing || event.isComposing)
            return;
        const text = this.input.value || event.data || '';
        this.input.value = '';
        if (this.duplicateCommit !== null) {
            const duplicate = event.inputType === 'insertFromComposition' ||
                (text === this.duplicateCommit && this.now() - this.compositionEndedAt < 50);
            this.duplicateCommit = null;
            if (duplicate)
                return;
        }
        this.dead = false;
        if (text)
            this.commit(text);
    }
    commit(text) {
        if (!this.ready())
            return;
        this.terminal.sendText(text);
        this.options.onInput?.();
    }
    ready() { this.resume(); return this.enabled() && this.releases.length === 0; }
    queueRelease(event) {
        if (this.options.onRelease)
            this.options.onRelease(event);
        else
            this.releases.push(event);
    }
    /** Send deferred releases before the next key or text input. Call after transport input resumes. */
    resume() {
        if (this.flushing || !this.enabled())
            return;
        this.flushing = true;
        try {
            while (this.releases.length && this.enabled()) {
                const result = this.terminal.sendKeyResult(this.releases[0]);
                this.releases.shift();
                if (result === 'sent')
                    this.options.onInput?.();
            }
        }
        finally {
            this.flushing = false;
        }
    }
    /** Clear browser state, and release only keys whose presses reached the terminal. */
    reset() {
        const presses = [...this.presses.values()];
        this.presses.clear();
        for (const press of presses) {
            if (press.route === 'sent')
                this.queueRelease({ ...press.key, modifiers: 0, text: undefined, eventType: 3 });
        }
        this.presses.clear();
        this.input.value = '';
        this.composing = false;
        this.dead = false;
        this.duplicateCommit = null;
        this.compositionEndedAt = -Infinity;
        this.resume();
    }
    dispose() {
        if (this.disposed)
            return;
        try {
            this.reset();
        }
        finally {
            this.disposed = true;
            for (const remove of this.listeners)
                remove();
            this.listeners.length = 0;
            this.releases.length = 0;
        }
    }
}
