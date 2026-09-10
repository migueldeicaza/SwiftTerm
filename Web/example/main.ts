import { loadSwiftTerm } from '../src/index.js';
import { CanvasTerminalRenderer } from './canvas2d.js';
const variant = new URL(location.href).searchParams.get('variant') === 'embedded' ? 'embedded' : 'full';
const module = await loadSwiftTerm({ wasmURL: `../dist/swiftterm-${variant}.wasm` });
const terminal = module.createTerminal({ cols: 80, rows: 24 });
const canvas = document.querySelector('canvas')!;
const renderer = new CanvasTerminalRenderer(canvas, terminal);
terminal.write('\x1b[1;36mSwiftTerm WASM\x1b[0m\r\nASCII, e\u0301, 界, 👩‍💻\r\n\x1b[3mItalic\x1b[0m and \x1b[4munderline\x1b[0m\r\n');
let counter = 0;
const timer = window.setInterval(() => { terminal.write(`\x1b[6;1HLive stream: ${++counter}`); renderer.requestFrame(); }, 1000);
// Test access contains objects, not pointers. A real application supplies PTY output here.
Object.assign(window, { swifttermExample: { module, terminal, renderer } });
window.addEventListener('pagehide', () => { clearInterval(timer); renderer.dispose(); terminal.dispose(); }, { once: true });
