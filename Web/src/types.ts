export type WasmImports = WebAssembly.Imports;
export interface SwiftTermModuleOptions {
  wasmURL?: URL | string;
  /** Use bytes or a compiled module in Node, workers, and tests. */
  wasm?: BufferSource | WebAssembly.Module;
  wasi?: WasmImports;
}
export interface TerminalOptions { cols: number; rows: number; scrollback?: number }
export type DirtyKind = 'clean' | 'partial' | 'full';
export interface CursorState {
  readonly x: number; readonly y: number;
  readonly shape: 'block' | 'bar' | 'underline';
  readonly visible: boolean; readonly blink: boolean; readonly focused: boolean;
  readonly rgba: number;
}
export interface RenderCell {
  readonly text: string; readonly width: 0 | 1 | 2;
  readonly foreground: number; readonly background: number; readonly underlineColor: number;
  readonly style: number; readonly underlineStyle: number; readonly semanticKind: number;
  readonly flags: number; readonly linkId: number;
}
export interface RenderRow { readonly y: number; readonly flags: number; readonly cells: readonly RenderCell[] }
export interface RenderSnapshot {
  readonly generation: bigint; readonly dirty: DirtyKind;
  readonly cols: number; readonly rows: number; readonly cursor: CursorState;
  readonly rowData: readonly RenderRow[];
  readonly dirtyRange: readonly [number, number] | null;
  readonly scrollDirtyRange: readonly [number, number] | null;
  readonly alternateScreen: boolean; readonly reverseVideo: boolean; readonly synchronizedOutput: boolean;
  readonly defaultForeground: number; readonly defaultBackground: number; readonly byteLength: number;
}
interface EventBase { readonly id: number; readonly flags: number }
export type HostEvent = EventBase & (
  | { readonly type: 'bell' | 'syncOutputTimeout' }
  | { readonly type: 'title' | 'iconTitle' | 'currentDirectory' | 'currentDocument'; readonly text: string }
  | { readonly type: 'notification'; readonly title: string; readonly body: string }
  | { readonly type: 'clipboardWrite'; readonly data: Uint8Array }
  | { readonly type: 'clipboardRequest'; readonly request: ClipboardRequest }
  | { readonly type: 'resizeRequest'; readonly cols: number; readonly rows: number }
  | { readonly type: 'cursorStyle'; readonly shape: CursorState['shape']; readonly blink: boolean; readonly visible: boolean }
  | { readonly type: 'colorChange'; readonly kind: number; readonly index: number | null; readonly rgba: number | null }
  | { readonly type: 'progress'; readonly state: number; readonly progress: number | null }
  | { readonly type: 'syncOutputChanged'; readonly enabled: boolean }
  | { readonly type: 'mouseMode'; readonly mode: number }
  | { readonly type: 'unknown'; readonly eventType: number; readonly data: Uint8Array }
);
export const Capability = Object.freeze({ fullRuntime: 1, embeddedRuntime: 2, dirtyRange: 4, scrollInvariantRange: 8, hostEvents: 16, keyEncoding: 32, mouseEncoding: 64, inputModes: 128, paste: 256, clipboard: 512, kittyGraphics: 1024, sixel: 2048, iTermImages: 4096, poll: 8192 });
export const CellStyle = Object.freeze({ bold: 1, underline: 2, blink: 4, inverse: 8, invisible: 16, dim: 32, italic: 64, crossedOut: 128 });
export const CellFlag = Object.freeze({ selected: 1, protected: 2, wideTail: 4, explicitUnderlineColor: 8, softWrapSpacer: 16, defaultBackground: 32, kittyPlaceholder: 64 });

export interface InputModes {
  readonly applicationCursor: boolean; readonly applicationKeypad: boolean;
  readonly bracketedPaste: boolean; readonly kittyPaste: boolean; readonly kittyKeyboardFlags: number;
}
export interface TerminalKeyEvent {
  key: string; code?: string; modifiers?: number; eventType?: 1 | 2 | 3;
  text?: string; shiftedKey?: number; baseLayoutKey?: number;
}
export interface ClipboardRequest {
  readonly id: number;
  readonly operation: 'readPermission' | 'writePermission' | 'list' | 'read' | 'write' | 'osc52Read';
  readonly location: 'standard'; readonly name?: string;
  readonly mimeTypes: readonly string[];
  readonly representations: readonly { readonly mimeType: string; readonly base64: string }[];
}
export const ClipboardStatus = Object.freeze({ ok: 0, denied: 1, unsupported: 2, busy: 3, invalid: 4, ioError: 5, tooLarge: 6 });
