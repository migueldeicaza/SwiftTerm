import { type RenderSnapshot, type SwiftTermTerminal, type SelectionState, type InputGeometry } from '../src/index.js';
/** A validation renderer. Text shaping, fallback, BiDi, ligatures, and emoji can differ from native SwiftTerm. */
export declare class CanvasTerminalRenderer {
    readonly canvas: HTMLCanvasElement;
    readonly terminal: SwiftTermTerminal;
    readonly cellWidth: number;
    readonly cellHeight: number;
    readonly fontFamily: string;
    private context;
    private frame;
    private pending;
    private last?;
    private rows;
    private blinkOn;
    private disposed;
    private dpr;
    private graphics?;
    private images;
    private colors;
    private textMetrics;
    private supportsLetterSpacing;
    private selection?;
    private selectionCanvas?;
    drawnRows: number;
    /** Called after geometry and cursor data reflect the drawn frame. */
    onDraw?: () => void;
    constructor(canvas: HTMLCanvasElement, terminal: SwiftTermTerminal, cellWidth?: number, cellHeight?: number, fontFamily?: string);
    readonly requestFrame: () => void;
    private readonly visibility;
    private readonly tick;
    draw(snapshot: RenderSnapshot, redrawAll?: boolean): void;
    get inputGeometry(): InputGeometry;
    /** Draw selection without changing the cached text rows or terminal snapshot. */
    setSelection(state: SelectionState): void;
    private drawSelection;
    private drawRowAt;
    private acceptGraphics;
    private drawImages;
    private drawRow;
    private cssColor;
    private drawBackgrounds;
    private applyFont;
    private isSimpleASCII;
    private drawText;
    private drawCursor;
    dispose(): void;
}
