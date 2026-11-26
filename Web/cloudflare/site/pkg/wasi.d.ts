/** Explicit preview1 shim. No filesystem, process, environment, or stdin access. */
export declare const wasiImportNames: readonly string[];
/** WASI pointer and size parameters are unsigned i32 values. */
export declare function wasiMemoryRange(byteLength: number, pointer: number, length: number): boolean;
export declare function createWasiImports(getMemory: () => WebAssembly.Memory): WebAssembly.ModuleImports;
