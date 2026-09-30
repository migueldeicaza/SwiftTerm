const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
export const MAX_CLIPBOARD_BYTES = 512 * 1024;
const status = { ok: 0, denied: 1, unsupported: 2, busy: 3, invalid: 4, ioError: 5, tooLarge: 6 };
const supported = type => type === 'text/plain' || type === 'image/png';
const denied = error => error?.name === 'NotAllowedError' || error?.name === 'SecurityError';
function base64Bytes(value) {
  const raw = atob(value);
  if (raw.length > MAX_CLIPBOARD_BYTES) throw new RangeError('Clipboard data is too large.');
  return Uint8Array.from(raw, char => char.charCodeAt(0));
}

/** Prepare all representations before a write. Never publish a partial item. */
export function makeClipboardItem(representations, Item = globalThis.ClipboardItem) {
  if (!Item || !Array.isArray(representations) || !representations.length || representations.length > 16) throw new TypeError('The clipboard format is not supported.');
  const blobs = {}; let total = 0;
  for (const representation of representations) {
    const type = representation.mimeType.toLowerCase();
    if (!supported(type) || (Item.supports && !Item.supports(type)) || Object.hasOwn(blobs, type)) throw new TypeError('The clipboard format is not supported.');
    const bytes = base64Bytes(representation.base64); total += bytes.length;
    if (total > MAX_CLIPBOARD_BYTES) throw new RangeError('Clipboard data is too large.');
    if (type === 'text/plain') {
      try { decoder.decode(bytes); } catch { const error = new Error('Clipboard text is not valid UTF-8.'); error.name = 'DataError'; throw error; }
    }
    blobs[type] = new Blob([bytes], { type });
  }
  return new Item(blobs);
}

/** Each OS clipboard call starts in a visible button click or a paste event. */
export class ClipboardController {
  constructor(terminal, elements, onOutput, api = globalThis.navigator?.clipboard, Item = globalThis.ClipboardItem, serviceAvailable = true) {
    this.serviceAvailable = serviceAvailable;
    this.terminal = terminal; this.elements = elements; this.onOutput = onOutput;
    this.api = api; this.Item = Item; this.queue = []; this.active = null;
    this.disposed = false; this.enabled = false; this.cached = null; this.epoch = 0;
    this.abort = new AbortController();
    const signal = this.abort.signal;
    elements.enable?.addEventListener('click', () => this.enabled ? this.disable() : this.enable(), { signal });
    elements.allow?.addEventListener('click', () => { void this.run(); }, { signal });
    elements.deny?.addEventListener('click', () => this.reject(), { signal });
    if (elements.enable) { elements.enable.disabled = !(serviceAvailable && api?.read && api?.write && Item); elements.enable.textContent = 'Enable clipboard'; }
    this.show();
    // Capability negotiation does not read or change clipboard data.
    if (serviceAvailable && api?.read && api?.write && Item) this.enable();
  }
  enable() {
    if (this.disposed || this.enabled || !this.serviceAvailable || !this.api?.read || !this.api?.write || !this.Item) return;
    try {
      this.terminal.configureClipboard(3); this.enabled = true; this.userDisabled = false;
      if (this.elements.enable) { this.elements.enable.disabled = false; this.elements.enable.textContent = 'Disable clipboard'; }
      this.onOutput();
    } catch (error) { this.note(error.message); }
  }
  disable() {
    if (this.disposed || !this.enabled) return;
    try {
      this.terminal.configureClipboard(0); this.enabled = false; this.userDisabled = true; this.epoch++;
      this.queue = []; this.cached = null;
      if (this.elements.enable) this.elements.enable.textContent = 'Enable clipboard';
      this.show(); this.onOutput();
    } catch (error) { this.note(error.message); }
  }
  note(text) { if (this.elements.message) this.elements.message.textContent = text; }
  complete(request, result, bytes = new Uint8Array()) {
    if (this.disposed || this.userDisabled || !request?.id) return;
    try { this.terminal.completeClipboard(request.id, result, bytes); this.onOutput(); }
    catch (error) { this.note(error.message || 'The clipboard request expired.'); }
  }
  capturePaste(text) {
    if (this.disposed || this.userDisabled) return;
    // This data came from a browser paste event, which is a user action.
    this.cached = { time: Date.now(), types: ['text/plain'], blobs: new Map([['text/plain', new Blob([text], { type: 'text/plain' })]]) };
  }
  accept(event) {
    if (this.disposed || this.userDisabled) return;
    const request = event.type === 'clipboardRequest' ? event.request : null;
    if (request && !this.enabled) { this.complete(request, status.denied); return; }
    if (this.queue.length + (this.active ? 1 : 0) >= 16) { if (request) this.complete(request, status.busy); return; }
    // Read permission follows a format list that the user has just captured.
    if (request?.operation === 'readPermission' && this.cached && Date.now() - this.cached.time < 30000) {
      this.complete(request, status.ok); return;
    }
    if (request?.operation === 'read' && this.cached && Date.now() - this.cached.time < 30000) {
      void this.readCaptured(request); return;
    }
    this.queue.push({ request, data: event.type === 'clipboardWrite' ? event.data : undefined, expires: Date.now() + 29000 });
    this.show();
  }
  async readCaptured(request) {
    const blob = this.cached?.blobs.get(request.mimeTypes[0]);
    if (!blob) { this.complete(request, status.unsupported); return; }
    if (blob.size > MAX_CLIPBOARD_BYTES) { this.complete(request, status.tooLarge); return; }
    try { this.complete(request, status.ok, new Uint8Array(await blob.arrayBuffer())); }
    catch { this.complete(request, status.ioError); }
  }
  expire() {
    if (this.disposed) return;
    const old = this.queue.filter(item => item.expires <= Date.now());
    this.queue = this.queue.filter(item => item.expires > Date.now());
    for (const item of old) this.complete(item.request, status.denied);
    if (this.cached && Date.now() - this.cached.time >= 30000) this.cached = null;
    this.show();
  }
  show() {
    const item = this.active ?? this.queue[0], { panel, allow, deny, message } = this.elements;
    if (panel) panel.hidden = !item || !!this.userDisabled;
    if (allow) allow.disabled = !!this.active;
    if (deny) deny.disabled = !!this.active;
    if (!item || !message) return;
    const op = item.request?.operation;
    const action = !item.request || op === 'write' ? 'Copy application data to the clipboard' : op === 'writePermission' ? 'Allow this application clipboard write' : 'Read the clipboard for the application';
    message.textContent = `${action}?${item.request?.name ? ` Application: ${item.request.name.slice(0, 120)}` : ''}`;
    if (allow) allow.textContent = !item.request || op === 'write' ? 'Copy to clipboard' : op === 'writePermission' ? 'Allow write' : 'Read clipboard';
  }
  reject() {
    if (this.active) return;
    const item = this.queue.shift();
    if (item) this.complete(item.request, status.denied);
    this.show();
  }
  async run() {
    if (this.disposed || this.userDisabled || this.active) return;
    const item = this.queue.shift(); if (!item) return;
    if (item.expires <= Date.now()) { this.complete(item.request, status.denied); this.show(); return; }
    this.active = item; this.show();
    const request = item.request, epoch = this.epoch;
    try {
      if (!request) {
        if (!this.api?.writeText) throw new TypeError('Clipboard writes are not available.');
        if (item.data.length > MAX_CLIPBOARD_BYTES) throw new RangeError('Clipboard data is too large.');
        await this.api.writeText(decoder.decode(item.data));
      } else if (request.operation === 'writePermission') {
        // The actual atomic write has its own button so browser activation is current.
        this.complete(request, status.ok);
      } else if (request.operation === 'write') {
        const clipboardItem = makeClipboardItem(request.representations, this.Item);
        await this.api.write([clipboardItem]); this.complete(request, status.ok);
      } else {
        // Start the read before the first await to retain browser user activation.
        const items = await this.api.read();
        const blobs = new Map();
        for (const item of items.slice(0, 1)) {
          for (const type of item.types) if (supported(type)) {
            const blob = await item.getType(type);
            if (blob.size > MAX_CLIPBOARD_BYTES) throw new RangeError('Clipboard data is too large.');
            blobs.set(type, blob);
          }
        }
        if (this.disposed || epoch !== this.epoch) return;
        this.cached = { time: Date.now(), types: [...blobs.keys()], blobs };
        if (request.operation === 'list') this.complete(request, status.ok, encoder.encode(JSON.stringify(this.cached.types)));
        else if (request.operation === 'readPermission') this.complete(request, status.ok);
        else if (request.operation === 'osc52Read') await this.readCaptured({ ...request, mimeTypes: ['text/plain'] });
        else await this.readCaptured(request);
      }
    } catch (error) {
      const result = denied(error) ? status.denied : ['DataError', 'InvalidCharacterError'].includes(error?.name) ? status.invalid : error instanceof RangeError ? status.tooLarge : error instanceof TypeError ? status.unsupported : status.ioError;
      this.complete(request, result); this.note(error.message || 'Clipboard access failed.');
    } finally { this.active = null; if (!this.disposed) this.show(); }
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true; this.abort.abort(); this.queue = []; this.cached = null;
    if (this.elements.panel) this.elements.panel.hidden = true;
  }
}
