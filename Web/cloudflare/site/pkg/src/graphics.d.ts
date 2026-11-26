export interface GraphicsImage {
    id: bigint;
    generation: bigint;
    width: number;
    height: number;
    pixels: Uint8Array;
}
export interface GraphicsPlacement {
    image: bigint;
    source: readonly number[];
    destination: readonly number[];
    z: number;
    flags: number;
    token: bigint;
    order: bigint;
}
export interface GraphicsSnapshot {
    generation: bigint;
    images: GraphicsImage[];
    placements: GraphicsPlacement[];
}
/** Validate and copy a graphics packet. No result retains WASM memory. */
export declare function decodeGraphics(bytes: Uint8Array): GraphicsSnapshot;
