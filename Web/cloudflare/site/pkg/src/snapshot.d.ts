import type { RenderSnapshot } from './types.js';
/** Decode into copied values. No value holds a view of WASM memory. */
export declare function decodeSnapshot(bytes: Uint8Array): RenderSnapshot;
