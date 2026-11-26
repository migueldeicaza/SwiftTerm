import type { SwiftTermTerminal } from './terminal.js';
import type { SelectionState } from './types.js';
export interface InputGeometry {
    cols: number;
    rows: number;
    cellWidth: number;
    cellHeight: number;
    rowScale?: (row: number) => number;
    cursor?: {
        x: number;
        y: number;
    };
}
export interface TerminalInputOptions {
    geometry: () => InputGeometry;
    canInput?: () => boolean;
    onInput?: () => void;
    onError?: (error: unknown) => void;
    onSelection?: (state: SelectionState) => void;
    onPaste?: (text: string, event: ClipboardEvent) => void;
    shortcut?: (event: KeyboardEvent) => boolean;
    layout?: Readonly<Record<string, string>>;
    optionAsMeta?: boolean;
}
/** DOM input ownership for one terminal. Transport and rendering stay with the host. */
export declare class TerminalInputController {
    readonly terminal: SwiftTermTerminal;
    readonly surface: HTMLCanvasElement;
    readonly input: HTMLTextAreaElement;
    private readonly options;
    private readonly listeners;
    private readonly keyboard;
    private gesture?;
    private selectionGeneration?;
    private focused?;
    private disposed;
    private disposing;
    private refreshing;
    private scrollFrame;
    private scrollTime;
    private wheelRemainderX;
    private wheelRemainderY;
    private wheelRoute;
    private lastMotion;
    private readonly pendingReleases;
    private lastClick?;
    constructor(terminal: SwiftTermTerminal, surface: HTMLCanvasElement, input: HTMLTextAreaElement, options: TerminalInputOptions);
    private readonly canInput;
    private readonly prepareInput;
    private readonly error;
    private attempt;
    private readonly inputReady;
    /** Call after PTY output, resize, or transport pressure changes. */
    refresh(): void;
    private readonly shortcut;
    private readonly updateFocus;
    private readonly blur;
    private readonly visibility;
    private point;
    private captures;
    private mouse;
    private countClick;
    private readonly pointerDown;
    private readonly pointerMove;
    private readonly pointerUp;
    private readonly pointerCancel;
    private endGesture;
    private startAutoscroll;
    private readonly autoscroll;
    private readonly wheel;
    private readonly contextMenu;
    private readonly copy;
    private readonly paste;
    dispose(): void;
}
