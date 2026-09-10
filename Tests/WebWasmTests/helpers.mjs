import { readFile, access } from 'node:fs/promises';
import { loadSwiftTerm } from '../../Web/dist/index.js';
import { createWasiImports } from '../../Web/dist/wasi.js';
export const artifactURL = variant => new URL(`../../Web/dist/swiftterm-${variant}.wasm`, import.meta.url);
export async function exists(url) { try { await access(url); return true; } catch { return false; } }
export const load = async variant => loadSwiftTerm({ wasm: await readFile(artifactURL(variant)) });
export async function raw(variant) {
  const module = await WebAssembly.compile(await readFile(artifactURL(variant)));let memory;
  const instance=await WebAssembly.instantiate(module,{wasi_snapshot_preview1:createWasiImports(()=>memory)});
  const e=instance.exports;memory=e.memory;e._initialize?.();
  const write=(handle,data)=>{const bytes=typeof data==='string'?new TextEncoder().encode(data):data,p=e.swiftterm_wasm_alloc(bytes.length)>>>0;try{new Uint8Array(memory.buffer,p,bytes.length).set(bytes);return e.swiftterm_terminal_write(handle,p,bytes.length);}finally{e.swiftterm_wasm_free(p);}};
  const copy=(handle,prefix)=>{const n=e[`${prefix}_size`](handle),p=e.swiftterm_wasm_alloc(n)>>>0;try{const result=e[`${prefix}_copy`](handle,p,n);if(result<0)throw new Error(`copy: ${result}`);return new Uint8Array(memory.buffer,p,result).slice();}finally{e.swiftterm_wasm_free(p);}};
  return {e,module,write,copy};
}
export function logical(snapshot) { const {generation,byteLength,...rest}=snapshot;return rest; }
export const traces = [
  '', 'ASCII\r\nnext', 'e\u0301 界 👩‍💻', '\x1b[31;44mred\x1b[0m',
  '\x1b[38;5;196;48;5;21m256\x1b[0m', '\x1b[38;2;18;52;86;48;2;1;2;3mRGB\x1b[0m',
  '\x1b[1;2;3;4;5;7;8;9mstyles\x1b[0m', '\x1b[4:1m1\x1b[4:2m2\x1b[4:3m3\x1b[4:4m4\x1b[4:5m5\x1b[0m',
  '\x1b[?5hreverse\x1b[?5l', '\x1b[?1049halt\x1b[?1049l', '\x1b[2 q\x1b[?25l\x1b[?25h',
  '\x1b[?2026hbatch\x1b[?2026l', '\x1b[1;1H\x1b#6double\x1b#5', 'line\r\n'.repeat(60),
  '\x1b]0;title\x07\x1b]7;file:///tmp\x07\x1b[6n',
];
