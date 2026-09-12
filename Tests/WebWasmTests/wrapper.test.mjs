import test from 'node:test';
import assert from 'node:assert/strict';
import { WasmRuntime, requiredExports } from '../../Web/dist/loader.js';
import { SwiftTermTerminal } from '../../Web/dist/index.js';
import { createWasiImports, wasiImportNames, wasiMemoryRange } from '../../Web/dist/wasi.js';
function mock() {
  const memory=new WebAssembly.Memory({initial:1});let initialized=0,destroyed=0,freed=0,output=Uint8Array.of(1,2,3),next=1024;
  const e=Object.fromEntries(requiredExports.map(n=>[n,()=>0]));Object.assign(e,{memory,_initialize:()=>initialized++,swiftterm_wasm_abi_version:()=>1,swiftterm_wasm_capabilities:()=>29,swiftterm_wasm_layout_size:id=>[0,104,16,32,16][id],swiftterm_terminal_create:()=>1,swiftterm_terminal_destroy:()=>{destroyed++;return 0;},swiftterm_wasm_alloc:n=>{memory.grow(1);const ptr=next;next+=n+8;return ptr;},swiftterm_wasm_free:()=>{memory.grow(1);freed++;return 0;},swiftterm_terminal_output_size:()=>{memory.grow(1);return output.length;},swiftterm_terminal_output_copy:(_h,p)=>{memory.grow(1);new Uint8Array(memory.buffer,p,output.length).set(output);return output.length;},swiftterm_terminal_output_consume:(_h,n)=>{output=output.slice(n);return 0;}});
  return {e,memory,counts:()=>({initialized,destroyed,freed})};
}
test('wrapper refreshes views after allocations, copy, and free; queues need explicit consumption',()=>{
  const m=mock(),r=new WasmRuntime(m.e),t=new SwiftTermTerminal(r,{cols:80,rows:24});
  let written;m.e.swiftterm_terminal_write=(_h,p,n)=>{m.memory.grow(1);written=new Uint8Array(m.memory.buffer,p,n).slice();return 0;};
  t.write('é');assert.deepEqual([...written],[195,169]);const output=t.readOutput();assert.deepEqual([...output],[1,2,3]);assert.deepEqual(t.readOutput(),output);t.consumeOutput(2);assert.deepEqual([...t.readOutput()],[3]);
  t.dispose();t.dispose();assert.deepEqual(m.counts(),{initialized:1,destroyed:1,freed:4});assert.throws(()=>t.write('x'),{code:'DISPOSED'});assert.throws(()=>t.drainEvents(),{code:'DISPOSED'});
});
test('wrapper guards reentrancy and maps statuses',()=>{
  const m=mock(),t=new SwiftTermTerminal(new WasmRuntime(m.e),{cols:80,rows:24});
  m.e.swiftterm_terminal_reset=()=>{assert.throws(()=>t.reset(),{code:'BUSY'});return -7;};assert.throws(()=>t.reset(),{code:'STALE_GENERATION'});
  assert.throws(()=>t.resize(1,2),{code:'INVALID_ARGUMENT'});assert.throws(()=>t.markFrameRendered(-1n),{code:'INVALID_ARGUMENT'});t.dispose();
});
test('module checks version, required symbols, capabilities, and all layouts',()=>{
  for(const change of [e=>delete e.swiftterm_render_clean,e=>e._start=()=>0,e=>e.swiftterm_wasm_abi_version=()=>2,e=>e.swiftterm_wasm_capabilities=()=>31,e=>e.swiftterm_wasm_layout_size=()=>16]){const m=mock();change(m.e);assert.throws(()=>new WasmRuntime(m.e),{code:'INVALID_ABI'});}
});
test('WASI shim has explicit imports and validates writes without host access',()=>{
  const memory=new WebAssembly.Memory({initial:1}),w=createWasiImports(()=>memory);
  assert.deepEqual(Object.keys(w).sort(),[...wasiImportNames].sort());
  assert.equal(w.args_sizes_get(0,4),0);assert.equal(w.args_sizes_get(65535,4),21);assert.equal(w.path_open(),76);assert.equal(w.fd_prestat_get(),8);
  assert.equal(w.random_get(65535,2),21);assert.equal(w.fd_write(1,65535,1,0),21);assert.throws(()=>w.proc_exit(3),{code:'WASI_EXIT'});
});

test('WASI ranges interpret high-bit i32 values as unsigned offsets and sizes',()=>{
  assert.equal(wasiMemoryRange(0x100000000,-1,1),true);
  assert.equal(wasiMemoryRange(0x100000000,-1,2),false);
  assert.equal(wasiMemoryRange(65536,-1,0),false);
  assert.equal(wasiMemoryRange(0x100000000,0,-1),true);
  assert.equal(wasiMemoryRange(0x100000000,2,-1),false);
});
