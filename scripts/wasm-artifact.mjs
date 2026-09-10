import { readFile, writeFile } from 'node:fs/promises';
import { gzipSync, brotliCompressSync, constants } from 'node:zlib';
import assert from 'node:assert/strict';
const [command, path, argument] = process.argv.slice(2);
const bytes = await readFile(path);
const module = await WebAssembly.compile(bytes);
const exports = WebAssembly.Module.exports(module);
const imports = WebAssembly.Module.imports(module);
const names = exports.map(item => item.name).sort();
const importNames = imports.map(item => `${item.module}.${item.name}`).sort();
const readList = async path => (await readFile(path, 'utf8')).split('\n').map(s => s.trim()).filter(s => s && !s.startsWith('#')).sort();
if (command === 'probe') {
    assert.deepEqual(names, ['_initialize', 'memory', 'swiftterm_probe']);
    console.log('Swift WASM export and reactor probe passed.');
} else if (command === 'check') {
    assert(['full', 'embedded'].includes(argument), 'Specify full or embedded.');
    assert.deepEqual(names, await readList('scripts/wasm/exports.txt'), 'WASM export table changed.');
    assert.deepEqual(importNames, await readList(`scripts/wasm/imports-${argument}.txt`), 'WASM import table changed.');
    assert(exports.every(e => e.kind === (e.name === 'memory' ? 'memory' : 'function')));
    assert(imports.every(i => i.kind === 'function'));
    console.log(`${argument} ABI import/export tables passed (${exports.length} exports, ${imports.length} imports).`);
} else if (command === 'inspect') {
    console.log(JSON.stringify({ exports, imports }, null, 2));
} else if (command === 'strip') {
    // Read WASM sections directly. Remove only names and debug custom sections.
    const chunks = [bytes.subarray(0, 8)];
    let at = 8;
    function leb() {
        let value = 0, scale = 1;
        for (let count = 0; count < 5; count++) {
            assert(at < bytes.length, 'Truncated WASM section.');
            const byte = bytes[at++];
            value += (byte & 127) * scale;
            if (!(byte & 128)) return value;
            scale *= 128;
        }
        throw new Error('Invalid WASM section length.');
    }
    while (at < bytes.length) {
        const start = at;
        const id = bytes[at++];
        const size = leb();
        const end = at + size;
        assert(end <= bytes.length);
        let remove = false;
        if (id === 0) {
            const length = leb();
            assert(at + length <= end);
            const name = bytes.toString('utf8', at, at + length);
            remove = name === 'name' || name.startsWith('.debug_') || name.startsWith('reloc..debug_');
        }
        if (!remove) chunks.push(bytes.subarray(start, end));
        at = end;
    }
    const stripped = Buffer.concat(chunks);
    assert(WebAssembly.validate(stripped));
    await writeFile(argument, stripped);
} else if (command === 'smoke' || command === 'command') {
    const { WASI } = await import('node:wasi');
    const wasi = new WASI({ version: 'preview1', args: ['swiftterm'], env: {}, preopens: {}, returnOnExit: true });
    const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
    if (command === 'command') {
        assert.equal(wasi.start(instance), 0);
    } else {
        assert(!('_start' in instance.exports));
        wasi.initialize(instance);
        const api = instance.exports;
        assert.equal(api.swiftterm_wasm_abi_version(), 1);
        const handle = api.swiftterm_terminal_create(8, 2, 0);
        assert(handle > 0);
        const ptr = api.swiftterm_wasm_alloc(4);
        assert(ptr > 0);
        new Uint8Array(api.memory.buffer, ptr, 4).set([87, 65, 83, 77]);
        assert.equal(api.swiftterm_terminal_write(handle, ptr, 4), 0);
        assert.equal(api.swiftterm_wasm_free(ptr), 0);
        assert.equal(api.swiftterm_render_update(handle), 2);
        assert(api.swiftterm_render_snapshot_size(handle) > 104);
        assert.equal(api.swiftterm_terminal_destroy(handle), 0);
        console.log('SwiftTerm browser reactor smoke check passed.');
    }
} else if (command === 'sizes') {
    const sizes = { file: path.split('/').at(-1), bytes: bytes.length, gzip: gzipSync(bytes).length, brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 5 } }).length, brotliQuality: 5 };
    await writeFile(`${path}.sizes.json`, JSON.stringify(sizes, null, 2) + '\n');
    console.log(JSON.stringify(sizes));
} else {
    throw new Error(`Unknown artifact operation: ${command}`);
}
