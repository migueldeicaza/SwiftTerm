import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { createRequire } from 'node:module';
import { checkCanvasCellGrid } from './canvas-grid.mjs';
const require=createRequire(new URL('../../Web/package.json',import.meta.url));
const playwright=process.env.PLAYWRIGHT_MODULE_PATH?require(process.env.PLAYWRIGHT_MODULE_PATH):require('playwright');
const root=resolve(new URL('../../',import.meta.url).pathname);
const url='http://swiftterm.test';
{
  for(const name of (process.env.BROWSERS||'chromium,firefox,webkit').split(',')){
    const browser=await playwright[name].launch({headless:true});
    try{
      const context=await browser.newContext({deviceScaleFactor:2});
      await context.route('**/*',async route=>{
        try { const path=resolve(root,'.'+decodeURIComponent(new URL(route.request().url()).pathname));
          if(!path.startsWith(root+sep))throw new Error('Invalid path');
          const body=await readFile(path);await route.fulfill({status:200,contentType:({'.html':'text/html','.js':'text/javascript','.wasm':'application/wasm'})[extname(path)]||'application/octet-stream',body});
        } catch { await route.fulfill({status:404,body:'Not found'}); }
      });
      for(const variant of (process.env.WASM_VARIANTS||'full,embedded').split(',')){
        const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
        await page.goto(`${url}/Web/example/index.html?variant=${variant}`);
        await page.waitForFunction(()=>window.swifttermExample?.renderer.drawnRows>0);
        await checkCanvasCellGrid(page);
        const first=await page.evaluate(()=>{const{terminal,renderer}=window.swifttermExample;return{width:renderer.canvas.width,height:renderer.canvas.height,cols:terminal.snapshot().cols,pixels:[...renderer.canvas.getContext('2d').getImageData(0,0,20,20).data].some(v=>v!==0)};});
        assert.deepEqual(first,{width:1600,height:960,cols:80,pixels:true});
        const partial=await page.evaluate(()=>{const{terminal,renderer}=window.swifttermExample;terminal.write('\x1b[6;1Hpartial');const s=terminal.snapshot();renderer.draw(s);terminal.markFrameRendered(s.generation);return{dirty:s.dirty,included:s.rowData.length,drawn:renderer.drawnRows,rows:s.rows};});
        assert.equal(partial.dirty,'partial');assert.equal(partial.drawn,partial.included);assert.ok(partial.drawn<partial.rows);
        const resized=await page.evaluate(()=>{const{terminal,renderer}=window.swifttermExample;terminal.resize(60,12,10,20);const s=terminal.snapshot();renderer.draw(s);terminal.markFrameRendered(s.generation);return[renderer.canvas.width,renderer.canvas.height,s.dirty];});assert.deepEqual(resized,[1200,480,'full']);
        await page.evaluate(()=>{const{terminal,renderer}=window.swifttermExample;terminal.setFocus(false);terminal.setVisible(false);renderer.requestFrame();});
        await page.waitForTimeout(30);
        assert.equal(await page.evaluate(()=>window.swifttermExample.terminal.snapshot().cursor.focused),false);
        await page.evaluate(()=>{const{terminal,renderer}=window.swifttermExample;terminal.setVisible(true);terminal.setFocus(true);terminal.write('\x1b[1 q');renderer.requestFrame();});
        await page.waitForTimeout(550);
        assert.equal(await page.evaluate(()=>window.swifttermExample.terminal.snapshot().cursor.blink),true);
        if (variant === 'full') {
          await page.evaluate(() => {
            const { terminal, renderer } = window.swifttermExample;
            terminal.reset(); terminal.write('\x1b[?25l');
            // Red image below the default background. Explicit blue must cover it.
            terminal.write('\x1b_Ga=T,f=32,s=1,v=1,i=1,p=1,c=3,r=1,C=1,z=-2147483648;/wAA/w==\x1b\\');
            terminal.write('\x1b[1;2H\x1b[44m \x1b[0m');
            renderer.requestFrame();
          });
          await page.waitForTimeout(100);
          const pixels = await page.evaluate(() => {
            const { renderer } = window.swifttermExample, ctx = renderer.canvas.getContext('2d');
            return [5, 15, 25].map(x => [...ctx.getImageData(x * 2, 10 * 2, 1, 1).data]);
          });
          assert.deepEqual(pixels[0], [255,0,0,255]); assert.notDeepEqual(pixels[1], [255,0,0,255]); assert.deepEqual(pixels[2], [255,0,0,255]);
          await page.evaluate(() => { const {terminal, renderer} = window.swifttermExample; terminal.write('\x1b_Ga=d,d=A;\x1b\\'); renderer.requestFrame(); });
          await page.waitForTimeout(100);
          assert.deepEqual(await page.evaluate(() => [...window.swifttermExample.renderer.canvas.getContext('2d').getImageData(10,20,1,1).data]), [0,0,0,255]);
        }
        // Worker initialization, copied snapshots, and generation acknowledgement.
        const worker=await page.evaluate(async variant=>{
          const w=new Worker('../dist/example/worker.js',{type:'module'});let id=0;
          const send=data=>new Promise((resolve,reject)=>{const request=++id;const callback=e=>{if(e.data.id===request){w.removeEventListener('message',callback);e.data.error?reject(new Error(e.data.error)):resolve(e.data);}};w.addEventListener('message',callback);w.postMessage({...data,id:request});});
          try{await send({type:'init',wasmURL:new URL(`../dist/swiftterm-${variant}.wasm`,location.href).href,options:{cols:10,rows:2,scrollback:0}});await send({type:'write',bytes:new TextEncoder().encode('worker')});const{snapshot}=await send({type:'snapshot'});await send({type:'clean',generation:snapshot.generation});await send({type:'dispose'});return snapshot.rowData[0].cells.map(c=>c.text).join('');}finally{w.terminate();}
        },variant);assert.match(worker,/worker/);
        const recreated=await page.evaluate(()=>{const{terminal,renderer,module}=window.swifttermExample;renderer.dispose();terminal.dispose();terminal.dispose();const next=module.createTerminal({cols:4,rows:2,scrollback:0});next.write('new');const text=next.snapshot().rowData[0].cells.map(c=>c.text).join('');next.dispose();return text;});assert.equal(recreated,'new');
        assert.deepEqual(errors,[]);await page.close();console.log(`${name} ${variant}: passed`);
      }
      await context.close();
    }finally{await browser.close();}
  }
}
