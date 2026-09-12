import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { requiredExports, extensionExports } from '../../Web/dist/loader.js';
import { wasiImportNames } from '../../Web/dist/wasi.js';
import { artifactURL, exists, load, raw, logical, traces } from './helpers.mjs';
const variants=(process.env.WASM_VARIANTS||'full,embedded').split(',');
for(const variant of variants){
  const available=await exists(artifactURL(variant));
  if(!available&&process.env.REQUIRE_WASM==='1')throw new Error(`Missing ${artifactURL(variant).pathname}`);
  test(`${variant}: ABI symbols, lifecycle, memory, handles, queues, and errors`,{skip:!available},async()=>{
    const {e,module,write,copy}=await raw(variant);
    const known = new Set(['memory', ...requiredExports, ...Object.values(extensionExports).flat(), '_initialize']);
    for (const item of WebAssembly.Module.exports(module)) assert.ok(known.has(item.name), `Unknown export ${item.name}`);
    for (const name of requiredExports) assert.equal(typeof e[name], 'function', name);
    for(const i of WebAssembly.Module.imports(module)){assert.equal(i.module,'wasi_snapshot_preview1');assert.ok(wasiImportNames.includes(i.name),i.name);}
    assert.equal(e.swiftterm_wasm_abi_version(),1);assert.equal(e.swiftterm_wasm_capabilities()&3,variant==='full'?1:2);
    assert.deepEqual([1,2,3,4].map(n=>e.swiftterm_wasm_layout_size(n)),[104,16,32,16]);
    assert.equal(e.swiftterm_terminal_create(1,24,0),0);assert.ok(e.swiftterm_wasm_last_error_size(0)>0);
    const h=e.swiftterm_terminal_create(8,3,0)>>>0;assert.ok(h);
    assert.equal(e.swiftterm_terminal_reset(0),-1);assert.equal(e.swiftterm_terminal_reset(0xffffffff),-1);
    assert.equal(e.swiftterm_terminal_write(h,0,0),0);assert.equal(e.swiftterm_terminal_write(h,0xffffffff,2),-3);
    assert.equal(e.swiftterm_terminal_write(h,1,0xffffffff),-2);assert.equal(e.swiftterm_terminal_resize(h,1,3,0,0),-2);
    assert.equal(e.swiftterm_terminal_set_focus(h,2),-2);assert.equal(e.swiftterm_terminal_set_visibility(h,0),-2);
    const p=e.swiftterm_wasm_alloc(16)>>>0;assert.ok(p);assert.equal(e.swiftterm_wasm_free(p+1),-2);assert.equal(e.swiftterm_wasm_free(p),0);assert.equal(e.swiftterm_wasm_free(p),-2);assert.equal(e.swiftterm_wasm_free(0),0);
    assert.equal(write(h,'\x1b[6n'),0);const replies=copy(h,'swiftterm_terminal_output');assert.ok(replies.length);assert.deepEqual(copy(h,'swiftterm_terminal_output'),replies);
    const dst=e.swiftterm_wasm_alloc(replies.length)>>>0;assert.equal(e.swiftterm_terminal_output_copy(h,dst,replies.length-1),-4);assert.equal(e.swiftterm_terminal_output_copy(h,dst,replies.length),replies.length);e.swiftterm_wasm_free(dst);
    assert.equal(e.swiftterm_terminal_output_consume(h,replies.length+1),-2);
    assert.equal(e.swiftterm_terminal_output_consume(h,2),0);
    assert.deepEqual(copy(h,'swiftterm_terminal_output'),replies.slice(2));
    assert.equal(e.swiftterm_terminal_output_consume(h,replies.length-2),0);assert.equal(e.swiftterm_terminal_output_size(h),0);
    assert.equal(write(h,'\x1b]2;hello\x07'),0);const event=copy(h,'swiftterm_terminal_event');assert.ok(event.length>=16);assert.deepEqual(copy(h,'swiftterm_terminal_event'),event);assert.equal(e.swiftterm_terminal_event_consume(h),0);
    assert.equal(e.swiftterm_render_update(h),2);const frame=copy(h,'swiftterm_render_snapshot'),v=new DataView(frame.buffer);
    assert.equal(write(h,'new'),0);assert.equal(e.swiftterm_render_clean(h,v.getUint32(8,true),v.getUint32(12,true)),-7);
    assert.equal(e.swiftterm_terminal_destroy(h),0);assert.equal(e.swiftterm_terminal_destroy(h),-1);
    for(let n=0;n<200;n++){const next=e.swiftterm_terminal_create(2,1,0)>>>0;assert.ok(next);assert.notEqual(next,h);assert.equal(e.swiftterm_terminal_reset(h),-1);assert.equal(e.swiftterm_terminal_destroy(next),0);}
  });
  test(`${variant}: typed snapshots, damage, Unicode, colors, cursor, and separate terminals`,{skip:!available},async()=>{
    const m=await load(variant),t=m.createTerminal({cols:12,rows:4,scrollback:0}),other=m.createTerminal({cols:4,rows:2,scrollback:0});
    let s=t.snapshot();assert.equal(s.dirty,'full');assert.equal(s.rowData.length,4);t.markFrameRendered(s.generation);s=t.snapshot();assert.equal(s.dirty,'clean');assert.equal(s.rowData.length,0);
    t.write('e\u0301界');s=t.snapshot();assert.equal(s.rowData[0].cells[0].text,'é');assert.equal(s.rowData[0].cells[1].text,'界');assert.equal(s.rowData[0].cells[1].width,2);assert.equal(s.rowData[0].cells[2].width,0);assert.equal(s.rowData[0].cells[2].text,'');t.markFrameRendered(s.generation);
    t.write('\x1b[1;1H\x1b[38;2;18;52;86;48;2;1;2;3mX');s=t.snapshot();assert.equal(s.rowData[0].cells[0].foreground,0x123456ff);assert.equal(s.rowData[0].cells[0].background,0x010203ff);t.markFrameRendered(s.generation);
    t.write('\x1b[1;1H\x1b[7mY');s=t.snapshot();assert.equal(s.rowData[0].cells[0].foreground,0x010203ff);assert.equal(s.rowData[0].cells[0].background,0x123456ff);t.markFrameRendered(s.generation);
    t.write('\x1b[0m\x1b[?5h');s=t.snapshot();assert.equal(s.dirty,'full');assert.equal(s.reverseVideo,true);t.markFrameRendered(s.generation);
    t.write('\x1b[?1049h');s=t.snapshot();assert.equal(s.alternateScreen,true);assert.equal(s.dirty,'full');t.write('\x1b[?1049l');assert.equal(t.snapshot().alternateScreen,false);
    for(const [n,shape,blink] of [[1,'block',true],[2,'block',false],[3,'underline',true],[4,'underline',false],[5,'bar',true],[6,'bar',false]]){t.write(`\x1b[${n} q`);const c=t.snapshot().cursor;assert.equal(c.shape,shape);assert.equal(c.blink,blink);}
    t.write('\x1b[?25l');assert.equal(t.snapshot().cursor.visible,false);t.write('\x1b[?25h');assert.equal(t.snapshot().cursor.visible,true);
    t.reset();t.resize(9,3,10,20);s=t.snapshot();assert.equal(s.cols,9);assert.equal(s.rows,3);assert.equal(s.dirty,'full');
    assert.equal(other.snapshot().rowData[0].cells[0].text,'');other.write('other');assert.equal(t.snapshot().rowData[0].cells[0].text,'');
    const prior=s;t.write('x');assert.equal(prior.rowData[0].cells[0].text,'');assert.throws(()=>t.markFrameRendered(prior.generation),{code:'STALE_GENERATION'});
    t.dispose();t.dispose();other.dispose();assert.throws(()=>t.snapshot(),{code:'DISPOSED'});
  });
  test(`${variant}: styles, wrapped rows, reply and host-event pull queues`,{skip:!available},async()=>{
    const t=(await load(variant)).createTerminal({cols:20,rows:4,scrollback:0});
    t.write('\x1b[1;2;3;4;5;7;8;9mX');let s=t.snapshot();assert.equal(s.rowData[0].cells[0].style&255,255);
    t.reset();for(let n=1;n<=5;n++)t.write(`\x1b[4:${n}m${n}`);s=t.snapshot();assert.deepEqual(s.rowData[0].cells.slice(0,5).map(c=>c.underlineStyle),[1,2,3,4,5]);
    t.reset();t.write('a'.repeat(21));s=t.snapshot();assert.ok(s.rowData.some(r=>r.flags&1));
    t.reset();t.drainEvents();
    t.write('\x07\x1b]2;title\x07\x1b]1;icon\x07\x1b]7;file:///tmp\x07\x1b[6n');
    const replies=t.readOutput();assert.match(new TextDecoder().decode(replies),/\x1b\[\d+;\d+R/);assert.deepEqual(t.readOutput(),replies);t.consumeOutput(replies.length);assert.equal(t.readOutput().length,0);
    const first=t.peekEvent();assert.deepEqual(t.peekEvent(),first);const events=t.drainEvents();for(const type of ['bell','title','iconTitle'])assert.ok(events.some(e=>e.type===type),type);assert.ok(!events.some(e=>e.type==='currentDirectory'||e.type==='currentDocument'));assert.equal(t.drainEvents().length,0);t.dispose();
  });
  test(`${variant}: notification, clipboard, resize, cursor, palette, progress, sync, and mouse events`,{skip:!available},async()=>{
    const t=(await load(variant)).createTerminal({cols:80,rows:24,scrollback:0});t.drainEvents();
    const cases=[
      ['notification','\x1b]777;notify;title;body\x07',e=>assert.deepEqual([e.title,e.body],['title','body'])],
      ['clipboardWrite','\x1b]52;c;aGk=\x07',e=>assert.deepEqual([...e.data],[104,105])],
      ['resizeRequest','\x1b[8;20;60t',e=>assert.deepEqual([e.cols,e.rows],[60,20])],
      ['cursorStyle','\x1b[3 q',e=>assert.deepEqual([e.shape,e.blink],['underline',true])],
      ['colorChange','\x1b]4;1;#123456\x07',e=>assert.deepEqual([e.kind,e.index,e.rgba],[3,1,0x123456ff])],
      ['progress','\x1b]9;4;1;50\x07',e=>assert.deepEqual([e.state,e.progress],[1,50])],
      ['syncOutputChanged','\x1b[?2026h',e=>assert.equal(e.enabled,true)],
      ['syncOutputChanged','\x1b[?2026l',e=>assert.equal(e.enabled,false)],
      ['mouseMode','\x1b[?1000h',e=>assert.equal(e.mode,2)]
    ];
    for(const[type,input,check]of cases){t.write(input);const e=t.drainEvents().find(e=>e.type===type);assert.ok(e,type);check(e);}
    t.write('\x1b]52;c;?\x07');assert.equal(t.readOutput().length,0);t.dispose();
  });
  test(`${variant}: synchronized output timeout is delivered on the next snapshot`,{skip:!available},async()=>{
    const t=(await load(variant)).createTerminal({cols:8,rows:2,scrollback:0});t.drainEvents();t.write('\x1b[?2026hbatch');
    assert.equal(t.snapshot().synchronizedOutput,true);await new Promise(resolve=>setTimeout(resolve,1100));
    assert.equal(t.snapshot().synchronizedOutput,false);assert.ok(t.drainEvents().some(e=>e.type==='syncOutputTimeout'));t.dispose();
  });
  test(`${variant}: event queue pressure returns an error and preserves accepted events`,{skip:!available},async()=>{
    const {e,write}=await raw(variant),h=e.swiftterm_terminal_create(2,1,0);const bells=new Uint8Array(65536).fill(7);let status=0,calls=0;
    while(status===0&&calls++<10)status=write(h,bells);
    assert.equal(status,-5);assert.ok(e.swiftterm_terminal_event_size(h)>=16);assert.equal(write(h,'x'),-5);
    let consumed=0;while(e.swiftterm_terminal_event_size(h)>0){assert.equal(e.swiftterm_terminal_event_consume(h),0);assert.ok(++consumed<=524288);}
    assert.equal(e.swiftterm_terminal_reset(h),0);assert.equal(write(h,'x'),0);e.swiftterm_terminal_destroy(h);
  });
  test(`${variant}: output queue pressure preserves accepted reply bytes`,{skip:!available},async()=>{
    const {e,write}=await raw(variant),h=e.swiftterm_terminal_create(2,1,0);const queries='\x1b[6n'.repeat(262144);let status=0,calls=0;
    while(status===0&&calls++<10)status=write(h,queries);
    assert.equal(status,-5);const size=e.swiftterm_terminal_output_size(h);assert.ok(size>0&&size<=8*1024*1024);
    assert.equal(e.swiftterm_terminal_output_consume(h,size),0);
    while(e.swiftterm_terminal_event_size(h)>0)e.swiftterm_terminal_event_consume(h);
    assert.equal(e.swiftterm_terminal_reset(h),0);assert.equal(write(h,'x'),0);e.swiftterm_terminal_destroy(h);
  });
  test(`${variant}: seeded ABI operations and invalid pointer ranges do not trap`,{skip:!available},async()=>{
    const {e,write,copy}=await raw(variant);let h=e.swiftterm_terminal_create(20,5,10),seed=123;
    const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
    for(let n=0;n<600;n++){
      switch(random()%8){
        case 0:assert.equal(write(h,Uint8Array.from({length:random()%100},()=>random()%256)),0);break;
        case 1:assert.equal(e.swiftterm_terminal_resize(h,2+random()%40,1+random()%10,0,0),0);break;
        case 2:{assert.ok(e.swiftterm_render_update(h)>=0);const b=copy(h,'swiftterm_render_snapshot'),v=new DataView(b.buffer);assert.equal(e.swiftterm_render_clean(h,v.getUint32(8,true),v.getUint32(12,true)),0);break;}
        case 3:assert.equal(e.swiftterm_terminal_write(h,0xfffffff0,128),-3);break;
        case 4:assert.equal(e.swiftterm_terminal_reset(h),0);break;
        case 5:assert.equal(e.swiftterm_terminal_set_focus(h,random()%2),0);break;
        case 6:{e.swiftterm_terminal_destroy(h);assert.equal(e.swiftterm_terminal_reset(h),-1);h=e.swiftterm_terminal_create(20,5,10);break;}
        case 7:{const out=e.swiftterm_terminal_output_size(h);assert.ok(out>=0);assert.equal(e.swiftterm_terminal_output_consume(h,out),0);break;}
      }
    }e.swiftterm_terminal_destroy(h);
  });
}
const both=await exists(artifactURL('full'))&&await exists(artifactURL('embedded'));
test('Full and Embedded produce identical logical snapshots and queue bytes',{skip:!both},async()=>{
  const modules=await Promise.all(['full','embedded'].map(load)),terms=modules.map(m=>m.createTerminal({cols:40,rows:10,scrollback:100}));
  let corpus=[...traces];
  if(process.env.VT_CORPUS_DIR){for(const name of (await readdir(process.env.VT_CORPUS_DIR)).sort())corpus.push(await readFile(`${process.env.VT_CORPUS_DIR}/${name}`));}
  let seed=17;for(let n=0;n<100;n++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;corpus.push(`\x1b[${1+seed%10};${1+(seed>>>8)%40}H\x1b[${30+seed%8}m${String.fromCodePoint(32+seed%90)}`);}
  for(const input of corpus){for(const t of terms)t.write(input);const snapshots=terms.map(t=>t.snapshot());assert.deepEqual(logical(snapshots[0]),logical(snapshots[1]));assert.deepEqual(terms[0].readOutput(),terms[1].readOutput());assert.deepEqual(terms[0].drainEvents(),terms[1].drainEvents());terms.forEach((t,i)=>t.markFrameRendered(snapshots[i].generation));}
  terms.forEach(t=>t.dispose());
});
