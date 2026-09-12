import { performance } from 'node:perf_hooks';
import { writeFile } from 'node:fs/promises';
import { load } from './helpers.mjs';
import { WasmRuntime } from '../../Web/dist/loader.js';
let measured;
const originalCall=WasmRuntime.prototype.call;
WasmRuntime.prototype.call=function(name,...args){
  if(measured){measured.memoryBefore??=this.memory.buffer.byteLength;if(name==='swiftterm_wasm_alloc')measured.allocCalls++;}
  const result=originalCall.call(this,name,...args);
  if(measured)measured.memoryAfter=this.memory.buffer.byteLength;
  return result;
};
const results=[];
for(const variant of (process.env.WASM_VARIANTS||'full,embedded').split(',')){
  const m=await load(variant);
  for(const [name,action,iterations] of [
    ['full-80x24',t=>t.reset(),100],
    ['partial-one-row',t=>t.write('\x1b[1;1Hchanged'),100],
    ['rapid-scroll',t=>t.write('scroll\r\n'.repeat(100)),30],
    ['resize',t=>{t.resize(100,40);t.resize(80,24);},30],
    ['10MiB-stream',t=>t.write('x'.repeat(10*1024*1024)),1]
  ]){
    const t=m.createTerminal({cols:80,rows:24,scrollback:100});t.markFrameRendered(t.snapshot().generation);
    const heap=process.memoryUsage().heapUsed,start=performance.now();let bytes=0;measured={allocCalls:0,memoryBefore:null,memoryAfter:0};
    for(let n=0;n<iterations;n++){action(t);const s=t.snapshot();bytes+=s.byteLength;t.markFrameRendered(s.generation);}
    results.push({variant,name,iterations,milliseconds:performance.now()-start,meanSnapshotBytes:bytes/iterations,heapDeltaBytes:process.memoryUsage().heapUsed-heap,hostAllocationCalls:measured.allocCalls,wasmMemoryGrowthBytes:measured.memoryAfter-measured.memoryBefore});measured=undefined;t.dispose();
  }
}
// hostAllocationCalls counts ABI host-buffer allocations, not internal Swift allocations.
WasmRuntime.prototype.call=originalCall;
// heapDeltaBytes is retained JS heap change. It is not an allocation count or WASM allocation total.
console.log(JSON.stringify(results,null,2));
if(process.env.BENCHMARK_OUTPUT)await writeFile(process.env.BENCHMARK_OUTPUT,JSON.stringify(results,null,2)+'\n');
