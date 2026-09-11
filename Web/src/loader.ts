import { SwiftTermError, statusError } from './errors.js';
import { SwiftTermTerminal } from './terminal.js';
import { createWasiImports } from './wasi.js';
import type { SwiftTermModuleOptions, TerminalOptions } from './types.js';
export const requiredExports = Object.freeze([
  'swiftterm_wasm_abi_version', 'swiftterm_wasm_capabilities', 'swiftterm_wasm_layout_size',
  'swiftterm_wasm_alloc', 'swiftterm_wasm_free', 'swiftterm_wasm_last_error_size', 'swiftterm_wasm_last_error_copy',
  'swiftterm_terminal_create', 'swiftterm_terminal_destroy', 'swiftterm_terminal_reset', 'swiftterm_terminal_resize',
  'swiftterm_terminal_set_focus', 'swiftterm_terminal_set_visibility', 'swiftterm_terminal_write',
  'swiftterm_terminal_output_size', 'swiftterm_terminal_output_copy', 'swiftterm_terminal_output_consume',
  'swiftterm_render_update', 'swiftterm_render_snapshot_size', 'swiftterm_render_snapshot_copy', 'swiftterm_render_clean',
  'swiftterm_terminal_event_size', 'swiftterm_terminal_event_copy', 'swiftterm_terminal_event_consume'
]);
export const extensionExports: Readonly<Record<number, readonly string[]>> = Object.freeze({
  32: ['swiftterm_terminal_key'],
  64: ['swiftterm_terminal_mouse', 'swiftterm_terminal_pointer_modes'],
  128: ['swiftterm_terminal_input_modes'],
  256: ['swiftterm_terminal_paste'],
  512: ['swiftterm_terminal_clipboard_configure', 'swiftterm_terminal_clipboard_complete', 'swiftterm_terminal_clipboard_reset'],
  1024: ['swiftterm_graphics_update', 'swiftterm_graphics_snapshot_size', 'swiftterm_graphics_snapshot_copy', 'swiftterm_graphics_clean'],
  2048: ['swiftterm_graphics_update', 'swiftterm_graphics_snapshot_size', 'swiftterm_graphics_snapshot_copy', 'swiftterm_graphics_clean'],
  4096: ['swiftterm_graphics_update', 'swiftterm_graphics_snapshot_size', 'swiftterm_graphics_snapshot_copy', 'swiftterm_graphics_clean'],
  8192: ['swiftterm_terminal_poll'],
  16384: ['swiftterm_terminal_text'],
  32768: ['swiftterm_terminal_scroll', 'swiftterm_terminal_selection', 'swiftterm_terminal_selection_state_size', 'swiftterm_terminal_selection_state_copy', 'swiftterm_terminal_selection_text_size', 'swiftterm_terminal_selection_text_copy'],
});
type RawFunction = (...args: number[]) => number;
/** Internal memory owner. Views must never survive a call into WASM. */
export class WasmRuntime {
  readonly memory: WebAssembly.Memory;
  readonly capabilities: number;
  constructor(private readonly exports: WebAssembly.Exports) {
    if (!(exports.memory instanceof WebAssembly.Memory) || '_start' in exports) throw new SwiftTermError('INVALID_ABI', 'Expected a reactor with exported memory and no _start.');
    this.memory = exports.memory;
    for (const name of requiredExports) if (typeof exports[name] !== 'function') throw new SwiftTermError('INVALID_ABI', `Missing export: ${name}.`);
    if (exports._initialize !== undefined) {
      if (typeof exports._initialize !== 'function') throw new SwiftTermError('INVALID_ABI', 'Invalid reactor initializer.');
      exports._initialize();
    }
    if (this.call('swiftterm_wasm_abi_version') !== 1) throw new SwiftTermError('INVALID_ABI', 'Unsupported ABI version.');
    this.capabilities = this.call('swiftterm_wasm_capabilities') >>> 0;
    for (const [bit, names] of Object.entries(extensionExports)) if (this.capabilities & Number(bit)) {
      for (const name of names) if (typeof exports[name] !== 'function') throw new SwiftTermError('INVALID_ABI', `Missing capability export: ${name}.`);
    }
    const runtimeBits = this.capabilities & 3;
    if (runtimeBits !== 1 && runtimeBits !== 2) throw new SwiftTermError('INVALID_ABI', 'Exactly one runtime capability must be set.');
    if ((this.capabilities & 28) !== 28) throw new SwiftTermError('INVALID_ABI', 'Required render and event capabilities are missing.');
    for (const [index, size] of [104, 16, 32, 16].entries()) if (this.call('swiftterm_wasm_layout_size', index + 1) !== size) throw new SwiftTermError('INVALID_ABI', `Invalid layout size ${index + 1}.`);
  }
  call(name: string, ...args: number[]): number { return (this.exports[name] as RawFunction)(...args); }
  check(value: number, handle = 0): number { if (value < 0) throw statusError(value, this.errorDetail(handle)); return value; }
  private errorDetail(handle: number): string {
    let ptr = 0;
    try {
      const length = this.call('swiftterm_wasm_last_error_size', handle);
      if (length <= 0 || length > 1024 * 1024) return '';
      ptr = this.call('swiftterm_wasm_alloc', length) >>> 0;
      if (!ptr) return '';
      const copied = this.call('swiftterm_wasm_last_error_copy', handle, ptr, length);
      return copied >= 0 && copied <= length ? new TextDecoder().decode(this.copyMemory(ptr, copied)) : '';
    } catch { return ''; } finally { if (ptr) this.call('swiftterm_wasm_free', ptr); }
  }
  copyMemory(ptr: number, size: number): Uint8Array {
    const buffer = this.memory.buffer;
    if (ptr > buffer.byteLength || size > buffer.byteLength - ptr) throw new SwiftTermError('OUT_OF_BOUNDS', 'The module returned an invalid buffer.');
    return new Uint8Array(buffer, ptr, size).slice();
  }
  withBuffer<T>(size: number, body: (ptr: number) => T): T {
    if (!size) return body(0);
    const ptr = this.call('swiftterm_wasm_alloc', size) >>> 0;
    if (!ptr) throw statusError(-5, this.errorDetail(0));
    try {
      if (ptr > this.memory.buffer.byteLength || size > this.memory.buffer.byteLength - ptr) throw new SwiftTermError('OUT_OF_BOUNDS', 'The allocator returned an invalid buffer.');
      return body(ptr);
    } finally { this.check(this.call('swiftterm_wasm_free', ptr)); }
  }
  read(handle: number, sizeName: string, copyName: string, limit: number): Uint8Array {
    const size = this.check(this.call(sizeName, handle), handle);
    if (size > limit) throw new SwiftTermError('OUT_OF_BOUNDS', 'The module returned an oversized buffer.');
    if (!size) return new Uint8Array();
    return this.withBuffer(size, ptr => {
      const written = this.check(this.call(copyName, handle, ptr, size), handle);
      if (written !== size) throw new SwiftTermError('INTERNAL_ERROR', 'The copied buffer size changed during a read.');
      return this.copyMemory(ptr, written);
    });
  }
}
export class SwiftTermModule {
  private constructor(private readonly runtime: WasmRuntime) {}
  get capabilities(): number { return this.runtime.capabilities; }
  static async load(options: SwiftTermModuleOptions): Promise<SwiftTermModule> {
    let source = options.wasm;
    if (!source) {
      if (!options.wasmURL) throw new SwiftTermError('INVALID_ARGUMENT', 'Set wasmURL or wasm.');
      const response = await fetch(options.wasmURL);
      if (!response.ok) throw new SwiftTermError('INVALID_ARGUMENT', `Cannot load WASM: HTTP ${response.status}.`);
      source = await response.arrayBuffer();
    }
    const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    let memory: WebAssembly.Memory | undefined;
    const wasi = createWasiImports(() => { if (!memory) throw new SwiftTermError('INVALID_ABI', 'WASI was called before reactor initialization.'); return memory; });
    const imports: WebAssembly.Imports = { ...options.wasi, wasi_snapshot_preview1: { ...wasi, ...options.wasi?.wasi_snapshot_preview1 } };
    for (const item of WebAssembly.Module.imports(module)) {
      if (item.kind !== 'function' || typeof imports[item.module]?.[item.name] !== 'function') throw new SwiftTermError('INVALID_ABI', `Unsupported WASM import: ${item.module}.${item.name}.`);
    }
    const instance = await WebAssembly.instantiate(module, imports);
    memory = instance.exports.memory as WebAssembly.Memory;
    return new SwiftTermModule(new WasmRuntime(instance.exports));
  }
  createTerminal(options: TerminalOptions): SwiftTermTerminal { return new SwiftTermTerminal(this.runtime, options); }
}
export const loadSwiftTerm = (options: SwiftTermModuleOptions): Promise<SwiftTermModule> => SwiftTermModule.load(options);
