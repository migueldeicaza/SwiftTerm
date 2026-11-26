export declare const Status: Readonly<{
    OK: 0;
    INVALID_HANDLE: -1;
    INVALID_ARGUMENT: -2;
    OUT_OF_BOUNDS: -3;
    BUFFER_TOO_SMALL: -4;
    OUT_OF_MEMORY: -5;
    BUSY: -6;
    STALE_GENERATION: -7;
    UNSUPPORTED: -8;
    INTERNAL_ERROR: -9;
}>;
export type ErrorCode = keyof typeof Status | 'DISPOSED' | 'INVALID_ABI' | 'INVALID_SNAPSHOT' | 'INVALID_EVENT' | 'WASI_EXIT';
export declare class SwiftTermError extends Error {
    readonly code: ErrorCode;
    readonly status?: number | undefined;
    constructor(code: ErrorCode, message: string, status?: number | undefined);
}
export declare function statusError(status: number, detail?: string): SwiftTermError;
export declare function uint(value: number, name: string, min?: number, max?: number): number;
