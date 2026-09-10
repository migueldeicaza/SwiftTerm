import { SwiftTermError } from './errors.js';
export interface GraphicsImage { id: bigint; generation: bigint; width: number; height: number; pixels: Uint8Array; }
export interface GraphicsPlacement { image: bigint; source: readonly number[]; destination: readonly number[]; z: number; flags: number; token: bigint; order: bigint; }
export interface GraphicsSnapshot { generation: bigint; images: GraphicsImage[]; placements: GraphicsPlacement[]; }
/** Validate and copy a graphics packet. No result retains WASM memory. */
export function decodeGraphics(bytes: Uint8Array): GraphicsSnapshot {
  const invalid = (): never => { throw new SwiftTermError('INVALID_SNAPSHOT', 'Invalid graphics snapshot.'); };
  if (bytes.length < 32 || bytes.length > 256 * 1024 * 1024) invalid();
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u = (o: number) => v.getUint32(o, true), wide = (o: number) => v.getBigUint64(o, true);
  const count = u(16), placements = u(20), start = u(24), placementStart = u(28);
  if (u(0) !== 0x58475453 || v.getUint16(4, true) !== 1 || v.getUint16(6, true) !== 32 || count > 65536 || placements > 262144 || start !== 32 || placementStart !== 32 + count * 32 || placementStart + placements * 64 > bytes.length) invalid();
  const images: GraphicsImage[] = [], result: GraphicsPlacement[] = [], ids = new Set<bigint>();
  let pixelOffset = placementStart + placements * 64;
  for (let n = 0; n < count; n++) {
    const o = start + n * 32, id = wide(o), width = u(o + 16), height = u(o + 20), offset = u(o + 24), size = u(o + 28);
    if (ids.has(id) || !width || !height || width * height > 16 * 1024 * 1024 || offset !== pixelOffset || size > bytes.length - offset || (size !== 0 && size !== width * height * 4)) invalid();
    ids.add(id); pixelOffset += size;
    images.push({ id, generation: wide(o + 8), width, height, pixels: bytes.slice(offset, offset + size) });
  }
  if (pixelOffset !== bytes.length) invalid();
  for (let n = 0; n < placements; n++) {
    const o = placementStart + n * 64, image = wide(o);
    const rects = Array.from({ length: 8 }, (_, i) => v.getFloat32(o + 8 + i * 4, true));
    if (!ids.has(image) || rects.some(x => !Number.isFinite(x)) || rects[2] <= 0 || rects[3] <= 0 || rects[6] <= 0 || rects[7] <= 0) invalid();
    result.push({ image, source: rects.slice(0, 4), destination: rects.slice(4), z: v.getInt32(o + 40, true), flags: u(o + 44), token: wide(o + 48), order: wide(o + 56) });
  }
  return { generation: wide(8), images, placements: result };
}
