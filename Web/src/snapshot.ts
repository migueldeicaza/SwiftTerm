import { SwiftTermError } from './errors.js';
import type { RenderSnapshot, RenderRow, RenderCell, CursorState, DirtyKind } from './types.js';
const decoder = new TextDecoder('utf-8', { fatal: true });
function invalid(message: string): never { throw new SwiftTermError('INVALID_SNAPSHOT', message); }
/** Decode into copied values. No value holds a view of WASM memory. */
export function decodeSnapshot(bytes: Uint8Array): RenderSnapshot {
  if (bytes.byteLength < 104 || bytes.byteLength > 256 * 1024 * 1024) invalid('Invalid snapshot size.');
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u = (o: number) => v.getUint32(o, true), i = (o: number) => v.getInt32(o, true);
  if (u(0) !== 0x53575453 || v.getUint16(4, true) !== 1 || v.getUint16(6, true) !== 104) invalid('Invalid snapshot header.');
  const cols = u(20), rows = u(24), kind = u(28), count = u(32), cellCount = u(84);
  if (cols < 2 || cols > 1024 || rows < 1 || rows > 1024 || kind > 2 || count > rows || cellCount !== count * cols) invalid('Invalid grid or record count.');
  const region = (offset: number, length: number) => {
    if (offset % 8 || offset < 104 || length > bytes.length || offset > bytes.length - length) invalid('Invalid snapshot region.');
    return offset + length;
  };
  const rowOffset = u(76), cellOffset = u(80), textOffset = u(88), textLength = u(92);
  if (region(rowOffset, count * 16) > cellOffset || region(cellOffset, cellCount * 32) > textOffset || region(textOffset, textLength) !== bytes.length) invalid('Snapshot regions overlap or have invalid lengths.');
  const range = (start: number, end: number, visible = true): readonly [number, number] | null => {
    if (start === -1 && end === -1) return null;
    if (start < 0 || end < start || (visible && end >= rows)) invalid('Invalid dirty range.');
    return Object.freeze([start, end]) as readonly [number, number];
  };
  const dirtyRange = range(i(36), i(40)), scrollDirtyRange = range(i(44), i(48), false);
  if ((kind === 0 && (count || dirtyRange)) || (kind === 2 && (count !== rows || dirtyRange?.[0] !== 0 || dirtyRange?.[1] !== rows - 1)) || (kind === 1 && (!dirtyRange || count !== dirtyRange[1] - dirtyRange[0] + 1))) invalid('Dirty rows do not match the header.');
  if (v.getUint8(60) > 2 || v.getUint8(61) > 1 || v.getUint8(62) > 1 || i(56) < 0 || i(56) >= rows) invalid('Invalid cursor state.');
  const rowData: RenderRow[] = [];
  for (let r = 0; r < count; r++) {
    const ro = rowOffset + r * 16, y = u(ro), first = u(ro + 8), length = u(ro + 12);
    if (y !== (dirtyRange?.[0] ?? 0) + r || length !== cols || first !== r * cols || first + length > cellCount) invalid('Invalid row record.');
    const cells: RenderCell[] = [];
    for (let c = 0; c < length; c++) {
      const co = cellOffset + (first + c) * 32, offset = u(co), n = u(co + 4), width = v.getUint8(co + 26), underlineStyle = v.getUint8(co + 27), semanticKind = v.getUint8(co + 28), flags = v.getUint8(co + 29);
      if (offset > textLength || n > textLength - offset || width > 2 || underlineStyle > 5 || semanticKind > 6 || ((flags & 4) && (width !== 0 || n !== 0))) invalid('Invalid cell record.');
      let text: string;
      try { text = decoder.decode(bytes.subarray(textOffset + offset, textOffset + offset + n)); } catch { invalid('Invalid UTF-8 in a cell.'); }
      cells.push(Object.freeze({ text, width: width as 0 | 1 | 2, foreground: u(co + 8), background: u(co + 12), underlineColor: u(co + 16), linkId: u(co + 20), style: v.getUint16(co + 24, true), underlineStyle, semanticKind, flags }));
    }
    rowData.push(Object.freeze({ y, flags: u(ro + 4), cells: Object.freeze(cells) }));
  }
  const flags = u(16);
  const cursor: CursorState = Object.freeze({ x: Math.max(0, Math.min(cols, i(52))), y: i(56), shape: (['block', 'bar', 'underline'] as const)[v.getUint8(60)], visible: !!v.getUint8(61), blink: !!v.getUint8(62), focused: !!(flags & 4), rgba: u(72) });
  return Object.freeze({ generation: BigInt(u(8)) | (BigInt(u(12)) << 32n), dirty: (['clean', 'partial', 'full'] as DirtyKind[])[kind], cols, rows, cursor, rowData: Object.freeze(rowData), dirtyRange, scrollDirtyRange, alternateScreen: !!(flags & 1), reverseVideo: !!(flags & 2), synchronizedOutput: !!(flags & 8), defaultForeground: u(64), defaultBackground: u(68), byteLength: bytes.length });
}
