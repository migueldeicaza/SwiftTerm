import assert from 'node:assert/strict';

// Compare real canvas pixels with text placed separately at each cell origin.
// A short run cannot expose the cumulative drift from fractional font advances.
export async function checkCanvasCellGrid(page) {
  const results = await page.evaluate(async () => {
    const { CanvasTerminalRenderer } = await import('../dist/example/canvas2d.js');
    const { CellStyle } = await import('../dist/index.js');
    const results = [];
    const ratio = window.devicePixelRatio || 1;
    for (const font of ['monospace', 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace']) {
      for (const fallback of [false, true]) {
        for (const style of [0, CellStyle.bold, CellStyle.italic, CellStyle.bold | CellStyle.italic]) {
          const canvas = document.createElement('canvas');
          const ctx = canvas.getContext('2d');
          if (fallback) {
            // Exercise a browser without letterSpacing using its real text rasterizer.
            const legacy = new Proxy(ctx, {
              has: (target, key) => key !== 'letterSpacing' && Reflect.has(target, key),
              get: (target, key) => typeof target[key] === 'function' ? target[key].bind(target) : target[key],
              set: (target, key, value) => Reflect.set(target, key, value),
            });
            canvas.getContext = () => legacy;
          }
          const cell = { text: '|', width: 1, foreground: 0xffffffff, background: 0x000000ff,
            underlineColor: 0xffffffff, style, underlineStyle: 0, flags: 0 };
          const snapshot = { cols: 80, rows: 1, dirty: 'full', generation: 1n,
            defaultBackground: 0x000000ff, rowData: [{ y: 0, flags: 0, cells: Array(80).fill(cell) }],
            cursor: { x: 79, y: 0, visible: false } };
          const terminal = { snapshot: () => snapshot, resize() {}, setFocus() {}, setVisible() {} };
          const renderer = new CanvasTerminalRenderer(canvas, terminal, 10, 20, font);
          try {
            renderer.draw(snapshot);
            const reference = document.createElement('canvas');
            reference.width = canvas.width; reference.height = canvas.height;
            const expected = reference.getContext('2d');
            expected.setTransform(ratio, 0, 0, ratio, 0, 0);
            expected.fillStyle = 'black'; expected.fillRect(0, 0, 800, 20);
            expected.fillStyle = 'white'; expected.textBaseline = 'alphabetic';
            expected.font = `${style & CellStyle.italic ? 'italic ' : ''}${style & CellStyle.bold ? 'bold ' : ''}15px ${font}`;
            for (let column = 0; column < 80; column++) {
              expected.save(); expected.beginPath(); expected.rect(column * 10, 0, 10, 20); expected.clip();
              expected.fillText('|', column * 10, 20 * 0.78); expected.restore();
            }
            const actual = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
            const wanted = expected.getImageData(0, 0, canvas.width, canvas.height).data;
            let mismatches = 0;
            for (let i = 0; i < actual.length; i++) if (actual[i] !== wanted[i]) mismatches++;
            results.push({ font, fallback, style, mismatches });
          } finally { renderer.dispose(); }
        }
      }
    }
    return results;
  });
  for (const result of results) assert.equal(result.mismatches, 0, `80-column cell alignment: ${JSON.stringify(result)}`);
}
