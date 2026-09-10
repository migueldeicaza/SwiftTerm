import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeSnapshot } from '../../Web/dist/snapshot.js';
import { decodeEvent } from '../../Web/dist/events.js';
import { SwiftTermError } from '../../Web/dist/errors.js';
export function fixture() {
  const text = new TextEncoder().encode('e\u0301界'), b = new Uint8Array(248 + text.length), v = new DataView(b.buffer);
  const u=(o,n)=>v.setUint32(o,n,true), i=(o,n)=>v.setInt32(o,n,true);
  u(0,0x53575453);v.setUint16(4,1,true);v.setUint16(6,104,true);u(8,7);u(12,1);u(16,4);u(20,4);u(24,1);u(28,2);u(32,1);i(36,0);i(40,0);i(44,-1);i(48,-1);i(52,999);u(76,104);u(80,120);u(84,4);u(88,248);u(92,text.length);u(116,4);
  v.setUint8(61,1);u(64,0x123456ff);u(68,0x010203ff);u(72,0xffffffff);
  for(let c=0;c<4;c++){ const o=120+c*32;u(o+8,0x123456ff);u(o+12,0x010203ff);v.setUint8(o+26,1); }
  u(124,3);u(152,3);u(156,3);v.setUint8(178,2);v.setUint8(210,0);v.setUint8(213,4);b.set(text,248);return b;
}
test('snapshot preserves UTF-8, width, colors, generation, and copied values',()=>{
  const b=fixture(),s=decodeSnapshot(b);b.fill(0);
  assert.equal(s.generation,0x100000007n);assert.equal(s.cursor.x,4);assert.equal(s.cursor.focused,true);
  assert.deepEqual(s.rowData[0].cells.map(c=>[c.text,c.width]),[['é',1],['界',2],['',0],['',1]]);
  assert.equal(s.rowData[0].cells[0].foreground,0x123456ff);assert.ok(Object.isFrozen(s.rowData[0].cells));
});
test('snapshot rejects truncated, overlapping, unaligned, and overflowing records',()=>{
  const mutations=[[0,0],[20,0],[28,3],[32,999],[76,105],[80,104],[84,0xffffffff],[88,0xffffffff],[92,999],[112,7],[120,999],[124,0xffffffff]];
  for(const [o,n] of mutations){const b=fixture();new DataView(b.buffer).setUint32(o,n,true);assert.throws(()=>decodeSnapshot(b),SwiftTermError);}
  for(let n=0;n<fixture().length;n++)assert.throws(()=>decodeSnapshot(fixture().subarray(0,n)),SwiftTermError);
  const b=fixture();b[248]=255;assert.throws(()=>decodeSnapshot(b),{code:'INVALID_SNAPSHOT'});
});
const event=(type,payload=new Uint8Array())=>{const b=new Uint8Array(16+payload.length),v=new DataView(b.buffer);v.setUint16(0,type,true);v.setUint32(4,4,true);v.setUint32(8,payload.length,true);b.set(payload,16);return b;};
const words=(...values)=>{const b=new Uint8Array(values.length*4),v=new DataView(b.buffer);values.forEach((n,i)=>v.setUint32(i*4,n,true));return b;};
test('all version 1 host event records decode',()=>{
  const payloads=[[],[65],[65],[65],[1,0,0,0,1,0,0,0,65,66],[0,255],words(80,24),[2,1,1,0],words(3,5,0xff0000ff),words(1,0xffffffff),words(1),[],[65],words(4)];
  const types=['bell','title','iconTitle','currentDirectory','notification','clipboardWrite','resizeRequest','cursorStyle','colorChange','progress','syncOutputChanged','syncOutputTimeout','currentDocument','mouseMode'];
  payloads.forEach((p,i)=>assert.equal(decodeEvent(event(i+1,Uint8Array.from(p))).type,types[i]));
  assert.equal(decodeEvent(event(10,words(1,0xffffffff))).progress,null);
  assert.equal(decodeEvent(event(99,Uint8Array.of(1))).type,'unknown');
});
test('event decoder rejects malformed payloads and lengths',()=>{
  for(const type of [1,5,7,8,9,10,11,12,14])assert.throws(()=>decodeEvent(event(type,Uint8Array.of(1))),SwiftTermError);
  assert.throws(()=>decodeEvent(event(2,Uint8Array.of(255))),SwiftTermError);
  const b=event(1);new DataView(b.buffer).setUint32(8,0xffffffff,true);assert.throws(()=>decodeEvent(b),SwiftTermError);
});
test('deterministic byte mutations cannot leak RangeError from binary decoders',()=>{
  let seed=17;const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
  for(let n=0;n<2000;n++){
    const b=n%2?fixture():event(5,words(0,0));for(let j=0;j<4;j++)b[random()%b.length]=random()&255;
    try{(n%2?decodeSnapshot:decodeEvent)(b);}catch(error){assert.ok(error instanceof SwiftTermError,error);}
  }
});

test('clipboard event requests reject malformed JSON, MIME records, IDs, and base64', () => {
  const make = (operation, object) => {
    const json = new TextEncoder().encode(JSON.stringify(object)), payload = new Uint8Array(12 + json.length);
    payload.set(words(123, operation, json.length)); payload.set(json, 12); return event(20, payload);
  };
  const bytes = make(4, {location: 'standard', representations: [{mimeType: 'text/plain', base64: 'aGk='}]});
  const decoded = decodeEvent(bytes); assert.equal(decoded.type, 'clipboardRequest'); assert.equal(decoded.request.id, 123);
  assert.deepEqual(decoded.request.representations, [{mimeType: 'text/plain', base64: 'aGk='}]);
  for (const bad of [make(6, {location: 'standard'}), make(2, {location: 'primary'}), make(2, {location: 'standard', mimeTypes: [123]}), make(4, {location: 'standard', representations: [{mimeType:'text/plain', base64:'bad!'}]})]) assert.throws(() => decodeEvent(bad), {code:'INVALID_EVENT'});
  const truncated = bytes.slice(0,-1); assert.throws(() => decodeEvent(truncated), {code:'INVALID_EVENT'});
});
