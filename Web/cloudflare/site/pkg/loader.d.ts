import { SwiftTermTerminal } from './terminal.js';
import type { SwiftTermModuleOptions, TerminalOptions } from './types.js';
export declare const requiredExports: readonly string[];
export declare const extensionExports: Readonly<Record<number, readonly string[]>>;
/** Internal memory owner. Views must never survive a call into WASM. */
export declare class WasmRuntime {
    private readonly exports;
    readonly memory: WebAssembly.Memory;
    readonly capabilities: number;
    constructor(exports: WebAssembly.Exports);
    call(name: string, ...args: number[]): number;
    check(value: number, handle?: number): number;
    private errorDetail;
    copyMemory(ptr: number, size: number): Uint8Array;
    withBuffer<T>(size: number, body: (ptr: number) => T): T;
    read(handle: number, sizeName: string, copyName: string, limit: number): Uint8Array;
}
export declare class SwiftTermModule {
    private readonly runtime;
    private constructor();
    get capabilities(): number;
    static load(options: SwiftTermModuleOptions): Promise<SwiftTermModule>;
    createTerminal(options: TerminalOptions): SwiftTermTerminal;
}
export declare const loadSwiftTerm: (options: SwiftTermModuleOptions) => Promise<SwiftTermModule>;
