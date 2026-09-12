import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { decodeSnapshot } from '../../Web/dist/snapshot.js';
import { artifactURL, exists, load, logical } from './helpers.mjs';
const directory=new URL('../SwiftTermTests/Fixtures/GhosttyFuzzCorpus/',import.meta.url);
function archive(bytes){
  assert.equal(bytes.subarray(0,5).toString(),'STFZ1');let offset=9;const count=bytes.readUInt32LE(5),entries=[];
  const take=n=>{assert.ok(n>=0&&n<=bytes.length-offset);const data=bytes.subarray(offset,offset+n);offset+=n;return data;};
  for(let n=0;n<count;n++){const name=take(take(2).readUInt16LE()).toString();const data=take(take(4).readUInt32LE());entries.push({name,data});}assert.equal(offset,bytes.length);return entries;
}
const available=await exists(artifactURL('full'))&&await exists(artifactURL('embedded'));
test('Ghostty corpus matches Full, Embedded, and optional native reference at selected boundaries',{skip:!available,timeout:600000},async()=>{
  const modules=await Promise.all(['full','embedded'].map(load));let checked=0;
  for(const file of (await readdir(directory)).filter(f=>f.endsWith('.stfuzz')).sort()){
    for(const entry of archive(await readFile(new URL(file,directory)))){
      // Check the final state of each corpus item. Also check two intermediate boundaries in the seed archives.
      const ends=file.includes('initial')?[...new Set([Math.floor(entry.data.length/3),Math.floor(entry.data.length*2/3),entry.data.length])]:[entry.data.length];
      for(const end of ends){
        const terms=modules.map(m=>m.createTerminal({cols:80,rows:24,scrollback:0}));
        try{
          const input=entry.data.subarray(0,end);terms.forEach(t=>t.write(input));const snapshots=terms.map(t=>t.snapshot());
          assert.deepEqual(logical(snapshots[0]),logical(snapshots[1]),`${file}/${entry.name}@${end}`);
          if(process.env.SWIFTTERM_NATIVE_SNAPSHOT){
            const result=spawnSync(process.env.SWIFTTERM_NATIVE_SNAPSHOT,['--snapshot'],{input,maxBuffer:256*1024*1024,timeout:10000});
            assert.equal(result.status,0,`${file}/${entry.name}: ${result.error||result.stderr}`);
            assert.deepEqual(logical(snapshots[0]),logical(decodeSnapshot(result.stdout)),`native ${file}/${entry.name}@${end}`);
          }
          checked++;
        }finally{terms.forEach(t=>t.dispose());}
      }
    }
  }
  assert.ok(checked>3300);console.log(`Compared ${checked} corpus snapshots${process.env.SWIFTTERM_NATIVE_SNAPSHOT?' with native SwiftTerm':''}.`);
});
