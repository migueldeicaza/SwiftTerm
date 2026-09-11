import test from 'node:test';
import assert from 'node:assert/strict';
import { load } from './helpers.mjs';
import { decodeGraphics } from '../../Web/dist/graphics.js';
const kitty = (control, bytes = []) => `\x1b_G${control};${Buffer.from(bytes).toString('base64')}\x1b\\`;
const reply = t => { const bytes = t.readOutput(); t.consumeOutput(bytes.length); return new TextDecoder().decode(bytes); };
test('Full: Kitty replies, pixels, layers, cache, erase, and reset', async () => {
  const t = (await load('full')).createTerminal({ cols: 12, rows: 6, scrollback: 0 });
  try {
    t.resize(12, 6, 10, 20);
    t.write(kitty('a=q,f=24,s=1,v=1,i=91', [255, 0, 0])); assert.match(reply(t), /i=91;OK/);
    t.write(kitty('a=T,f=32,s=2,v=1,i=1,p=1,c=2,r=1,C=1,z=-2147483648', [255,0,0,255,0,255,0,255]));
    let g = t.graphicsSnapshot(); assert.equal(g.images.length, 1); assert.deepEqual([...g.images[0].pixels], [255,0,0,255,0,255,0,255]);
    assert.deepEqual(g.placements[0].destination, [0,0,20,20]); assert.equal(g.placements[0].z, -2147483648);
    t.markGraphicsRendered(g.generation); assert.equal(t.graphicsSnapshot(), null);
    t.write('\x1b[2;1H' + kitty('a=p,i=1,p=2,c=1,r=1,C=1'));
    g = t.graphicsSnapshot(); assert.equal(g.images[0].pixels.length, 0); assert.equal(g.placements.length, 2); t.markGraphicsRendered(g.generation);
    t.write(kitty('a=d,d=A')); g=t.graphicsSnapshot(); assert.equal(g.images.length,0); t.markGraphicsRendered(g.generation);
    t.reset(); g=t.graphicsSnapshot(); assert.equal(g.placements.length,0); t.markGraphicsRendered(g.generation);
  } finally { t.dispose(); }
});
test('Full: Sixel and iTerm PNG reach the graphics snapshot', async () => {
  const t = (await load('full')).createTerminal({ cols: 20, rows: 10, scrollback: 0 });
  try {
    t.resize(20,10,10,20);
    t.write('\x1bPq#1;2;100;0;0#1~\x1b\\');
    let g=t.graphicsSnapshot(); assert.equal(g.images.length,1); assert.ok(g.images[0].pixels.some(x=>x)); t.markGraphicsRendered(g.generation);
    t.reset();
    // One transparent PNG pixel. Decode must still attach the image.
    const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
    t.write(`\x1b]1337;File=inline=1;width=2;height=1:${png}\x07`);
    g=t.graphicsSnapshot(); assert.equal(g.images.length,1); assert.equal(g.images[0].width,1); assert.equal(g.images[0].height,1);
  } finally { t.dispose(); }
});
test('Graphics decoder rejects truncated and oversized record tables', () => {
  assert.throws(()=>decodeGraphics(new Uint8Array(31)), {code:'INVALID_SNAPSHOT'});
  const bytes=new Uint8Array(32), view=new DataView(bytes.buffer);
  view.setUint32(0,0x58475453,true);view.setUint16(4,1,true);view.setUint16(6,32,true);view.setUint32(16,0xffffffff,true);
  assert.throws(()=>decodeGraphics(bytes),{code:'INVALID_SNAPSHOT'});
});
test('Full: Sixel rejects oversized images and excess pixel work, then continues parsing', async () => {
  const t=(await load('full')).createTerminal({cols:12,rows:3,scrollback:0});
  try {
    t.resize(12,3,10,20);
    const payloads = [
      '!999999999999999999999~', '!2147483647~', '!2147483647?~~', '#999999999999999999999~',
      // Include a 72 MB bitmap, whose size fits 32-bit arithmetic.
      '!3000000~', '!20000000~', '!999999999~', '"1;1;4097;4096~',
      // Each pass fits the bitmap limit. Nine passes exceed the pixel-write limit.
      '!8388608@$'.repeat(9),
    ];
    for (const payload of payloads) {
      t.reset();
      t.write(`\x1bPq${payload}\x1b\\OK`);
      assert.equal(t.graphicsSnapshot().images.length,0);
      assert.equal(t.snapshot().rowData[0].cells.slice(0,2).map(cell=>cell.text).join(''),'OK');
      t.write('\x1bPq~\x1b\\');
      assert.equal(t.graphicsSnapshot().images.length,1);
    }
  } finally { t.dispose(); }
});
test('Embedded: graphics unavailable, bracketed paste remains available', async () => {
  const t=(await load('embedded')).createTerminal({cols:12,rows:3});
  try { assert.equal(t.graphicsSnapshot(),null); t.write('\x1b[?2004h'); t.paste('hello'); assert.equal(reply(t),'\x1b[200~hello\x1b[201~'); }
  finally { t.dispose(); }
});
