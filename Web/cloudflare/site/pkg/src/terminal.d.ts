import { type GraphicsSnapshot } from './graphics.js';
import type { WasmRuntime } from './loader.js';
import type { HostEvent, RenderSnapshot, TerminalOptions, InputModes, TerminalKeyEvent, KeyDisposition, InputState, TerminalMouseEvent, SelectionState, SelectionMode, ViewportState } from './types.js';
export declare class SwiftTermTerminal {
    private readonly runtime;
    private handle;
    private busy;
    /** Use SwiftTermModule.createTerminal to create terminals that share a module. */
    constructor(runtime: WasmRuntime, options: TerminalOptions);
    private run;
    private status;
    write(data: Uint8Array | string): void;
    private requireCapability;
    private inputBytes;
    inputModes(): InputModes;
    /** Return true if the core handled the key. False leaves text input to the browser. */
    sendKey(event: TerminalKeyEvent): boolean;
    /** Distinguish a queued key from a filtered event and browser text input. */
    sendKeyResult(event: TerminalKeyEvent): KeyDisposition;
    /** Submit committed text, including IME input, without paste semantics. */
    sendText(text: string): void;
    inputState(): InputState;
    sendMouse(event: TerminalMouseEvent): boolean;
    scrollViewport(lines: number): void;
    scrollViewportTo(topRow: number): void;
    private scroll;
    selectionBegin(col: number, row: number, mode?: SelectionMode): void;
    selectionExtend(col: number, row: number): void;
    selectionClear(): void;
    selectionAll(): void;
    private select;
    selectionState(): SelectionState;
    viewportState(): ViewportState;
    selectionText(): string;
    /** Queue one paste. allowUnsafe requires explicit approval from the user. */
    paste(text: string, options?: {
        clipboard?: boolean;
        allowUnsafe?: boolean;
    }): 'text' | 'event';
    configureClipboard(capabilities: number): void;
    completeClipboard(id: number, status: number, data?: Uint8Array): void;
    resetClipboard(): void;
    poll(): boolean;
    reset(): void;
    resize(cols: number, rows: number, cellWidthPx?: number, cellHeightPx?: number): void;
    setFocus(focused: boolean): void;
    setVisible(visible: boolean): void;
    snapshot(): RenderSnapshot;
    /** Return new graphics state, or null if the last frame is current. */
    graphicsSnapshot(): GraphicsSnapshot | null;
    markGraphicsRendered(generation: bigint): void;
    markFrameRendered(generation: bigint): void;
    /** Copy queued reply bytes. Call consumeOutput only after the transport accepts them. */
    readOutput(): Uint8Array;
    consumeOutput(byteCount: number): void;
    /** Copy the first event without consuming it. */
    peekEvent(): HostEvent | null;
    consumeEvent(): void;
    drainEvents(): HostEvent[];
    dispose(): void;
}
