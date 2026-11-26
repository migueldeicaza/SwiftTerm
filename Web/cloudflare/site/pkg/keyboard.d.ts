import type { SwiftTermTerminal } from './terminal.js';
import type { TerminalKeyEvent } from './types.js';
export interface KeyboardInputOptions {
    canInput?: () => boolean;
    onInput?: () => void;
    onError?: (error: unknown) => void;
    /** Optional owner that queues releases in order with other input devices. */
    onRelease?: (event: TerminalKeyEvent) => void;
    /** Return true to keep this press and its release outside the terminal. Replaces the default policy. */
    shortcut?: (event: KeyboardEvent) => boolean;
    /** Unshifted characters, indexed by KeyboardEvent.code. */
    layout?: Readonly<Record<string, string>>;
    /** On macOS, send printable Option combinations as terminal Alt keys. */
    optionAsMeta?: boolean;
}
/**
 * The default browser/terminal split. `mac` defaults to the running platform.
 * macOS puts the browser shortcuts on Command, which leaves Control for the
 * terminal: Ctrl+L, Ctrl+W and Ctrl+N stay terminal keys there.
 */
export declare function defaultKeyboardShortcut(event: KeyboardEvent, mac?: boolean): boolean;
/** Routes browser keyboard and committed text through the terminal input service. */
export declare class KeyboardInputController {
    private readonly terminal;
    private readonly input;
    private readonly options;
    private readonly listeners;
    private readonly presses;
    private readonly layout;
    private readonly observed;
    private readonly releases;
    private composing;
    private dead;
    private duplicateCommit;
    private compositionEndedAt;
    private disposed;
    private flushing;
    private readonly mac;
    constructor(terminal: SwiftTermTerminal, input: HTMLTextAreaElement, options?: KeyboardInputOptions);
    private now;
    private listen;
    private enabled;
    private id;
    private modifiers;
    private consumedModifiers;
    private normalize;
    private keydown;
    private keyup;
    private beforeinput;
    private textInput;
    private commit;
    private ready;
    private queueRelease;
    /** Send deferred releases before the next key or text input. Call after transport input resumes. */
    resume(): void;
    /** Clear browser state, and release only keys whose presses reached the terminal. */
    reset(): void;
    dispose(): void;
}
