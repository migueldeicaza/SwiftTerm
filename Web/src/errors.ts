export const Status = Object.freeze({ OK: 0, INVALID_HANDLE: -1, INVALID_ARGUMENT: -2, OUT_OF_BOUNDS: -3, BUFFER_TOO_SMALL: -4, OUT_OF_MEMORY: -5, BUSY: -6, STALE_GENERATION: -7, UNSUPPORTED: -8, INTERNAL_ERROR: -9 });
export type ErrorCode = keyof typeof Status | 'DISPOSED' | 'INVALID_ABI' | 'INVALID_SNAPSHOT' | 'INVALID_EVENT' | 'WASI_EXIT';
export class SwiftTermError extends Error {
  constructor(public readonly code: ErrorCode, message: string, public readonly status?: number) {
    super(message); this.name = 'SwiftTermError';
  }
}
export function statusError(status: number, detail = ''): SwiftTermError {
  const code = (Object.entries(Status).find(([, value]) => value === status)?.[0] ?? 'INTERNAL_ERROR') as ErrorCode;
  return new SwiftTermError(code, detail || `SwiftTerm returned ${code} (${status}).`, status);
}
export function uint(value: number, name: string, min = 0, max = 0xffffffff): number {
  if (!Number.isInteger(value) || value < min || value > max) throw new SwiftTermError('INVALID_ARGUMENT', `${name} must be an integer from ${min} to ${max}.`, -2);
  return value;
}
