import { loadSwiftTerm, type SwiftTermTerminal } from '../src/index.js';
// Module worker: one worker owns the instance and serializes all terminal operations.
let terminal: SwiftTermTerminal | undefined;
let sequence = Promise.resolve();
const scope = globalThis as unknown as { onmessage: ((event: MessageEvent) => void) | null; postMessage: (data: unknown, transfer?: Transferable[]) => void };
scope.onmessage = (event: MessageEvent) => {
  sequence = sequence.then(async () => {
    const id = event.data?.id;
    try {
      if (!event.data || typeof event.data !== 'object') throw new Error('Invalid worker message.');
      const { type } = event.data;
      if (type === 'init') {
        terminal?.dispose(); terminal = undefined;
        const module = await loadSwiftTerm({ wasmURL: event.data.wasmURL });
        terminal = module.createTerminal(event.data.options);
      } else {
        if (!terminal) throw new Error('Initialize the terminal first.');
        if (type === 'write') terminal.write(event.data.bytes);
        else if (type === 'key') { scope.postMessage({ id, handled: terminal.sendKey(event.data.event) }); return; }
        else if (type === 'paste') { scope.postMessage({ id, result: terminal.paste(event.data.text, event.data.options) }); return; }
        else if (type === 'inputModes') { scope.postMessage({ id, modes: terminal.inputModes() }); return; }
        else if (type === 'poll') { scope.postMessage({ id, changed: terminal.poll() }); return; }
        else if (type === 'configureClipboard') terminal.configureClipboard(event.data.capabilities);
        else if (type === 'completeClipboard') terminal.completeClipboard(event.data.requestId, event.data.status, event.data.bytes);
        else if (type === 'resetClipboard') terminal.resetClipboard();
        else if (type === 'resize') terminal.resize(event.data.cols, event.data.rows, event.data.cellWidthPx, event.data.cellHeightPx);
        else if (type === 'clean') terminal.markFrameRendered(event.data.generation);
        else if (type === 'focus') terminal.setFocus(event.data.focused);
        else if (type === 'visible') terminal.setVisible(event.data.visible);
        else if (type === 'consumeOutput') terminal.consumeOutput(event.data.byteCount);
        else if (type === 'snapshot') { scope.postMessage({ id, snapshot: terminal.snapshot() }); return; }
        else if (type === 'output') { const bytes = terminal.readOutput(); scope.postMessage({ id, bytes }, [bytes.buffer]); return; }
        else if (type === 'events') { scope.postMessage({ id, events: terminal.drainEvents() }); return; }
        else if (type === 'dispose') { terminal.dispose(); terminal = undefined; }
        else throw new Error(`Unknown worker message: ${type}.`);
      }
      scope.postMessage({ id, ok: true });
    } catch (error) { scope.postMessage({ id, error: error instanceof Error ? error.message : String(error) }); }
  });
};
