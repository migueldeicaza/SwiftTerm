import { SwiftTermError } from './errors.js';
import type { HostEvent } from './types.js';
const decoder = new TextDecoder('utf-8', { fatal: true });
export function decodeEvent(bytes: Uint8Array): HostEvent {
  const bad = (): never => { throw new SwiftTermError('INVALID_EVENT', 'Invalid host event.'); };
  if (bytes.length < 16 || bytes.length > 8 * 1024 * 1024) bad();
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), type = v.getUint16(0, true);
  const p = bytes.subarray(16), n = p.length, u = (o: number) => v.getUint32(16 + o, true);
  if (v.getUint32(8, true) !== n) bad();
  const base = { id: v.getUint32(4, true), flags: v.getUint16(2, true) };
  const size = (s: number) => { if (n !== s) bad(); };
  const text = (data: Uint8Array) => { try { return decoder.decode(data); } catch { return bad(); } };
  const optional = (value: number) => value === 0xffffffff ? null : value;
  switch (type) {
    case 1: case 12: size(0); return { ...base, type: type === 1 ? 'bell' : 'syncOutputTimeout' };
    case 2: case 3: case 4: case 13: return { ...base, type: ({2: 'title', 3: 'iconTitle', 4: 'currentDirectory', 13: 'currentDocument'} as const)[type], text: text(p) };
    case 5: {
      if (n < 8) bad(); const a = u(0), b = u(4); if (a > n - 8 || b !== n - 8 - a) bad();
      return { ...base, type: 'notification', title: text(p.subarray(8, 8 + a)), body: text(p.subarray(8 + a)) };
    }
    case 6: return { ...base, type: 'clipboardWrite', data: p.slice() };
    case 7: size(8); return { ...base, type: 'resizeRequest', cols: u(0), rows: u(4) };
    case 8: size(4); if (p[0] > 2 || p[1] > 1 || p[2] > 1) bad(); return { ...base, type: 'cursorStyle', shape: (['block', 'bar', 'underline'] as const)[p[0]], blink: !!p[1], visible: !!p[2] };
    case 9: size(12); if (u(0) > 4) bad(); return { ...base, type: 'colorChange', kind: u(0), index: optional(u(4)), rgba: optional(u(8)) };
    case 10: size(8); return { ...base, type: 'progress', state: u(0), progress: optional(u(4)) };
    case 11: size(4); if (u(0) > 1) bad(); return { ...base, type: 'syncOutputChanged', enabled: !!u(0) };
    case 20: {
      if (n < 12 || n > 1024 * 1024 || u(0) === 0 || u(1 * 4) > 5 || u(8) !== n - 12) bad();
      let data: unknown;
      try { data = JSON.parse(text(p.subarray(12))); } catch { return bad(); }
      if (!data || typeof data !== 'object' || Array.isArray(data)) return bad();
      const object = data as Record<string, unknown>;
      if (object.location !== 'standard' || (object.name !== undefined && (typeof object.name !== 'string' || object.name.length > 4096))) bad();
      const mimes = object.mimeTypes ?? [], records = object.representations ?? [];
      if (!Array.isArray(mimes) || mimes.length > 16 || !mimes.every(x => typeof x === 'string' && x.length <= 128)) return bad();
      if (!Array.isArray(records) || records.length > 16) return bad();
      const representations = records.map(record => {
        if (!record || typeof record !== 'object' || typeof record.mimeType !== 'string' || record.mimeType.length > 128 ||
            typeof record.base64 !== 'string' || record.base64.length > 700000 || record.base64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(record.base64)) return bad();
        return { mimeType: record.mimeType as string, base64: record.base64 as string };
      });
      return { ...base, type: 'clipboardRequest', request: { id: u(0),
        operation: (['readPermission', 'writePermission', 'list', 'read', 'write', 'osc52Read'] as const)[u(4)],
        location: 'standard', name: object.name as string | undefined, mimeTypes: mimes, representations } };
    }
    case 14: size(4); return { ...base, type: 'mouseMode', mode: u(0) };
    default: return { ...base, type: 'unknown', eventType: type, data: p.slice() };
  }
}
