import { CellStyle, type RenderSnapshot, type RenderRow, type GraphicsSnapshot, type GraphicsPlacement, type SwiftTermTerminal } from '../src/index.js';
function color(rgba: number): string { return `rgba(${rgba >>> 24},${(rgba >>> 16) & 255},${(rgba >>> 8) & 255},${(rgba & 255) / 255})`; }
/** A validation renderer. Text shaping, fallback, BiDi, ligatures, and emoji can differ from native SwiftTerm. */
export class CanvasTerminalRenderer {
  private context: CanvasRenderingContext2D;
  private frame = 0;
  private pending = true;
  private last?: RenderSnapshot;
  private rows = new Map<number, RenderRow>();
  private blinkOn = true;
  private disposed = false;
  private dpr = 0;
  private graphics?: GraphicsSnapshot;
  private images = new Map<bigint, { generation: bigint; canvas: HTMLCanvasElement }>();
  public drawnRows = 0;
  constructor(readonly canvas: HTMLCanvasElement, readonly terminal: SwiftTermTerminal, readonly cellWidth = 10, readonly cellHeight = 20, readonly fontFamily = 'monospace') {
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Canvas 2D is unavailable.');
    this.context = context;
    window.addEventListener('focus', this.focus);
    window.addEventListener('blur', this.focus);
    document.addEventListener('visibilitychange', this.visibility);
    window.addEventListener('resize', this.requestFrame);
    const grid = terminal.snapshot();
    terminal.resize(grid.cols, grid.rows, cellWidth, cellHeight);
    this.focus(); this.visibility();
    this.frame = requestAnimationFrame(this.tick);
  }
  readonly requestFrame = (): void => { this.pending = true; };
  private readonly focus = (): void => { this.terminal.setFocus(document.hasFocus()); this.pending = true; };
  private readonly visibility = (): void => { this.terminal.setVisible(!document.hidden); this.pending = true; };
  private readonly tick = (time: number): void => {
    if (this.disposed) return;
    try {
      if (this.terminal.poll()) this.pending = true;
      if (this.pending) {
        this.pending = false;
        const snapshot = this.terminal.snapshot();
        if (snapshot.synchronizedOutput) {
          // Poll the reactor until synchronization ends or its timeout expires.
          this.pending = true;
          return;
        }
        const graphics = this.terminal.graphicsSnapshot();
        if (graphics) this.acceptGraphics(graphics);
        this.draw(snapshot, !!graphics);
        if (graphics) this.terminal.markGraphicsRendered(graphics.generation);
        this.terminal.markFrameRendered(snapshot.generation);
      }
      const blink = !this.last?.cursor.blink || !this.last.cursor.focused || Math.floor(time / 500) % 2 === 0;
      if (blink !== this.blinkOn || this.dpr !== (window.devicePixelRatio || 1)) {
        this.blinkOn = blink;
        if (this.last) {
          if (this.dpr !== (window.devicePixelRatio || 1)) this.draw(this.last, true);
          else if (this.graphics?.placements.length) this.draw(this.last, true);
          else { this.drawRowAt(this.last.cursor.y); this.drawCursor(this.last); }
        }
      }
    } catch (error) { this.pending = true; console.error(error); }
    finally { this.frame = requestAnimationFrame(this.tick); }
  };
  draw(snapshot: RenderSnapshot, redrawAll = false): void {
    const changedSize = !this.last || this.last.cols !== snapshot.cols || this.last.rows !== snapshot.rows;
    const ratio = window.devicePixelRatio || 1;
    if (changedSize) this.rows.clear();
    if (changedSize || this.dpr !== ratio) {
      this.dpr = ratio;
      this.canvas.width = Math.round(snapshot.cols * this.cellWidth * ratio);
      this.canvas.height = Math.round(snapshot.rows * this.cellHeight * ratio);
      this.canvas.style.width = `${snapshot.cols * this.cellWidth}px`;
      this.canvas.style.height = `${snapshot.rows * this.cellHeight}px`;
      this.context.setTransform(ratio, 0, 0, ratio, 0, 0);
      redrawAll = true;
    }
    for (const row of snapshot.rowData) this.rows.set(row.y, row);
    this.drawnRows = 0;
    if (this.graphics?.placements.length) redrawAll = true;
    if (redrawAll || snapshot.dirty === 'full') {
      this.context.fillStyle = color(snapshot.defaultBackground);
      this.context.fillRect(0, 0, snapshot.cols * this.cellWidth, snapshot.rows * this.cellHeight);
      this.drawImages(p => !(p.flags & 2) && p.z < -1073741824);
      for (const row of this.rows.values()) this.drawRow(row, 'background');
      this.drawImages(p => !(p.flags & 2) && p.z >= -1073741824 && p.z < 0);
      for (const row of this.rows.values()) this.drawRow(row, 'text');
      this.drawImages(p => !!(p.flags & 2) || p.z >= 0);
    } else {
      for (const row of snapshot.rowData) this.drawRow(row);
    }
    this.last = snapshot;
    if (redrawAll || snapshot.dirty === 'full' || snapshot.rowData.some(row => row.y === snapshot.cursor.y)) this.drawCursor(snapshot);
  }
  private drawRowAt(y: number): void { const row = this.rows.get(y); if (row) this.drawRow(row); }
  private acceptGraphics(snapshot: GraphicsSnapshot): void {
    const live = new Set(snapshot.images.map(image => image.id));
    for (const id of this.images.keys()) if (!live.has(id)) this.images.delete(id);
    for (const image of snapshot.images) {
      const previous = this.images.get(image.id);
      if (previous?.generation === image.generation) continue;
      if (!image.pixels.length) throw new Error('The graphics cache has no pixels for this image.');
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d');
      if (!context) throw new Error('Canvas 2D is unavailable.');
      context.putImageData(new ImageData(new Uint8ClampedArray(image.pixels), image.width, image.height), 0, 0);
      this.images.set(image.id, { generation: image.generation, canvas });
    }
    this.graphics = snapshot;
  }
  private drawImages(include: (placement: GraphicsPlacement) => boolean): void {
    if (!this.graphics) return;
    const placements = this.graphics.placements.filter(include).sort((a, b) => a.z - b.z || (a.order < b.order ? -1 : a.order > b.order ? 1 : 0));
    for (const p of placements) {
      const image = this.images.get(p.image)?.canvas;
      if (image) this.context.drawImage(image, p.source[0], p.source[1], p.source[2], p.source[3], p.destination[0], p.destination[1], p.destination[2], p.destination[3]);
    }
  }
  private drawRow(row: RenderRow, pass: 'all' | 'background' | 'text' = 'all'): void {
    if (pass !== 'background') this.drawnRows++;
    const ctx = this.context, w = this.cellWidth, h = this.cellHeight, doubleWidth = !!(row.flags & 14), doubleHeight = !!(row.flags & 12);
    ctx.save();
    ctx.beginPath(); ctx.rect(0, row.y * h, this.canvas.width / this.dpr, h); ctx.clip();
    ctx.translate(0, row.y * h - ((row.flags & 8) ? h : 0));
    ctx.scale(doubleWidth ? 2 : 1, doubleHeight ? 2 : 1);
    if (pass !== 'text') for (const [x, cell] of row.cells.entries()) {
      if (pass === 'background' && (cell.flags & 32)) continue;
      ctx.fillStyle = color(cell.background); ctx.fillRect(x * w, 0, w, h);
    }
    if (pass !== 'background') for (const [x, cell] of row.cells.entries()) {
      if (!cell.width || (cell.flags & 64) || cell.style & CellStyle.invisible) continue;
      ctx.save(); ctx.beginPath(); ctx.rect(x * w, 0, cell.width * w, h); ctx.clip();
      ctx.fillStyle = color(cell.foreground);
      ctx.font = `${cell.style & CellStyle.italic ? 'italic ' : ''}${cell.style & CellStyle.bold ? 'bold ' : ''}${Math.floor(h * 0.75)}px ${this.fontFamily}`;
      ctx.textBaseline = 'alphabetic';
      ctx.fillText(cell.text, x * w, h * 0.78);
      if (cell.style & CellStyle.crossedOut) ctx.fillRect(x * w, h * 0.5, cell.width * w, 1);
      const underline = cell.underlineStyle || (cell.style & CellStyle.underline ? 1 : 0);
      if (underline) {
        ctx.strokeStyle = color(cell.underlineColor); ctx.lineWidth = 1;
        ctx.setLineDash(underline === 4 ? [1, 2] : underline === 5 ? [4, 3] : []);
        ctx.beginPath();
        if (underline === 3) {
          for (let dx = 0; dx <= cell.width * w; dx++) { const y = h - 2 + Math.sin(dx * Math.PI / 3); if (dx === 0) ctx.moveTo(x * w, y); else ctx.lineTo(x * w + dx, y); }
        } else { ctx.moveTo(x * w, h - 2); ctx.lineTo((x + cell.width) * w, h - 2); }
        ctx.stroke();
        if (underline === 2) { ctx.beginPath(); ctx.moveTo(x * w, h - 4); ctx.lineTo((x + cell.width) * w, h - 4); ctx.stroke(); }
      }
      ctx.restore();
    }
    ctx.restore();
  }
  private drawCursor(snapshot: RenderSnapshot): void {
    const cursor = snapshot.cursor;
    if (!cursor.visible || document.hidden || !this.blinkOn) return;
    const x = Math.max(0, Math.min(snapshot.cols - 1, cursor.x)) * this.cellWidth, y = cursor.y * this.cellHeight;
    const ctx = this.context;
    ctx.save(); ctx.fillStyle = color(cursor.rgba); ctx.strokeStyle = color(cursor.rgba);
    if (!cursor.focused) ctx.strokeRect(x + 0.5, y + 0.5, this.cellWidth - 1, this.cellHeight - 1);
    else if (cursor.shape === 'bar') ctx.fillRect(x, y, 2, this.cellHeight);
    else if (cursor.shape === 'underline') ctx.fillRect(x, y + this.cellHeight - 2, this.cellWidth, 2);
    else { ctx.globalAlpha = 0.55; ctx.fillRect(x, y, this.cellWidth, this.cellHeight); }
    ctx.restore();
  }
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true; cancelAnimationFrame(this.frame);
    this.images.clear(); this.graphics = undefined;
    window.removeEventListener('focus', this.focus); window.removeEventListener('blur', this.focus);
    document.removeEventListener('visibilitychange', this.visibility); window.removeEventListener('resize', this.requestFrame);
  }
}
