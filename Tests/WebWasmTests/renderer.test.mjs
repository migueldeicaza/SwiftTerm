import test from 'node:test';
import assert from 'node:assert/strict';
import { CanvasTerminalRenderer } from '../../Web/dist/example/canvas2d.js';
test('Canvas draws included rows, scales pixels, owns blink, defers synchronized frames, and retries a failed frame',()=>{
  const old=Object.fromEntries(['window','document','requestAnimationFrame','cancelAnimationFrame'].map(k=>[k,globalThis[k]]));
  let scheduled,marks=0,fail=false,fills=0,reads=0;const texts=[],spacings=[];
  const listeners=new Map();
  globalThis.window={devicePixelRatio:2,addEventListener:(n,fn)=>listeners.set(n,fn),removeEventListener:n=>listeners.delete(n)};
  globalThis.document={hidden:false,hasFocus:()=>true,addEventListener:(n,fn)=>listeners.set(n,fn),removeEventListener:n=>listeners.delete(n)};
  globalThis.requestAnimationFrame=fn=>{scheduled=fn;return 1;};globalThis.cancelAnimationFrame=()=>{};
  const context=Object.fromEntries(['save','restore','beginPath','rect','clip','translate','scale','setTransform','stroke','moveTo','lineTo','setLineDash','strokeRect'].map(n=>[n,()=>{}]));
  context.letterSpacing='0px';context.measureText=()=>({width:9});context.fillRect=()=>fills++;context.fillText=text=>{if(fail)throw new Error('draw failed');texts.push(text);spacings.push(context.letterSpacing);};
  const canvas={getContext:()=>context,style:{},width:0,height:0};
  const cell={text:'界',width:2,foreground:0xffffffff,background:0x000000ff,underlineColor:0xff0000ff,style:67,underlineStyle:3,flags:0,semanticKind:0,linkId:0};
  const row=y=>({y,flags:0,cells:[cell,{...cell,text:'',width:0}]});
  let snapshot={generation:1n,dirty:'full',cols:2,rows:2,rowData:[row(0),row(1)],cursor:{x:999,y:0,shape:'bar',visible:true,blink:true,focused:true,rgba:0xffffffff},defaultBackground:0x000000ff};
  const terminal={resize:()=>{},poll:()=>false,graphicsSnapshot:()=>null,markGraphicsRendered:()=>{},setFocus:()=>{},setVisible:()=>{},snapshot:()=>{reads++;return snapshot;},markFrameRendered:()=>marks++};
  let renderer;
  try{
    renderer=new CanvasTerminalRenderer(canvas,terminal);scheduled(0);assert.equal(marks,1);assert.equal(renderer.drawnRows,2);assert.equal(canvas.width,40);assert.equal(canvas.height,80);
    snapshot={...snapshot,generation:2n,dirty:'partial',rowData:[row(1)]};renderer.requestFrame();scheduled(0);assert.equal(marks,2);assert.equal(renderer.drawnRows,1);
    const plain={...cell,text:'a',width:1,style:0,underlineStyle:0};const beforeText=texts.length;
    renderer.draw({...snapshot,generation:20n,rowData:[{y:1,flags:0,cells:[plain,{...plain,text:'b'}]}]});
    assert.deepEqual(texts.slice(beforeText),['ab'],'adjacent plain ASCII cells draw as one run');
    assert.equal(spacings.at(-1),'1px','ASCII runs advance by the fixed cell width');
    snapshot={...snapshot,dirty:'clean',rowData:[]};const before=fills;renderer.requestFrame();scheduled(0);assert.equal(fills,before,'clean frames do not draw the cursor over its previous pixels');
    scheduled(600);assert.ok(fills>before,'blink redraws its cached row without a WASM snapshot');
    snapshot={...snapshot,generation:3n,dirty:'full',rowData:[row(0),row(1)]};fail=true;renderer.requestFrame();const successful=marks;
    const originalError=console.error;console.error=()=>{};try{scheduled(600);}finally{console.error=originalError;}
    assert.equal(marks,successful);fail=false;scheduled(600);assert.equal(marks,successful+1);
    snapshot={...snapshot,generation:4n,synchronizedOutput:true};renderer.requestFrame();
    const syncMarks=marks,syncFills=fills,syncReads=reads;scheduled(600);scheduled(1200);
    assert.equal(marks,syncMarks,'synchronized frames must not be marked clean');
    assert.equal(fills,syncFills,'synchronized frames must not draw');
    assert.equal(reads,syncReads+2,'polling continues without new input to service the timeout');
    snapshot={...snapshot,generation:5n,synchronizedOutput:false};scheduled(1200);
    assert.equal(marks,syncMarks+1,'the frame is marked clean after synchronization ends');
    assert.ok(fills>syncFills,'the deferred frame is drawn after synchronization ends');
    renderer.dispose();renderer.dispose();assert.equal(listeners.size,0);
  }finally{renderer?.dispose();for(const[k,v]of Object.entries(old)){if(v===undefined)delete globalThis[k];else globalThis[k]=v;}}
});

test('Canvas without letterSpacing places glyphs at cell origins unless the font advance is exact',()=>{
  const keys=['window','document','requestAnimationFrame','cancelAnimationFrame'];
  const old=Object.fromEntries(keys.map(key=>[key,globalThis[key]]));
  globalThis.window={devicePixelRatio:1,addEventListener(){},removeEventListener(){}};
  globalThis.document={hidden:false,hasFocus:()=>true,addEventListener(){},removeEventListener(){}};
  globalThis.requestAnimationFrame=()=>1;globalThis.cancelAnimationFrame=()=>{};
  try {
    for(const advance of [9.03,9.995,10]) {
      const calls=[];
      const context=Object.fromEntries(['save','restore','beginPath','rect','clip','translate','scale','setTransform','fillRect'].map(name=>[name,()=>{}]));
      context.measureText=()=>({width:advance});context.fillText=(...args)=>calls.push(args);
      const canvas={getContext:()=>context,style:{},width:0,height:0};
      const cell={text:'M',width:1,foreground:0xffffffff,background:0xff,style:0,underlineStyle:0,flags:0};
      const snapshot={cols:80,rows:1,dirty:'full',generation:1n,defaultBackground:0xff,
        rowData:[{y:0,flags:0,cells:Array(80).fill(cell)}],cursor:{visible:false}};
      const terminal={snapshot:()=>snapshot,resize(){},setFocus(){},setVisible(){}};
      const renderer=new CanvasTerminalRenderer(canvas,terminal,10,20);
      try {
        renderer.draw(snapshot);
        if(advance===10) assert.deepEqual(calls,[['M'.repeat(80),0,20*0.78]]);
        else {
          assert.equal(calls.length,80,`Font advance ${advance} must not accumulate inside a run`);
          for(let col=0;col<80;col++) { assert.equal(calls[col][0],'M'); assert.equal(calls[col][1],col*10); }
        }
      } finally { renderer.dispose(); }
    }
  } finally { for(const[key,value]of Object.entries(old)){if(value===undefined)delete globalThis[key];else globalThis[key]=value;} }
});
