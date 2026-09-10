import { readdir, copyFile, writeFile } from 'node:fs/promises';
for (const file of await readdir(new URL('./dist/src/', import.meta.url))) {
  await copyFile(new URL(`./dist/src/${file}`, import.meta.url), new URL(`./dist/${file}`, import.meta.url));
}
await writeFile(new URL('./dist/package.json', import.meta.url), JSON.stringify({
  name: '@swiftterm/wasm', version: '0.1.0', type: 'module', main: './index.js', types: './index.d.ts',
  exports: { '.': { types: './index.d.ts', import: './index.js' }, './swiftterm-full.wasm': './swiftterm-full.wasm', './swiftterm-embedded.wasm': './swiftterm-embedded.wasm' }, license: 'MIT'
}, null, 2) + '\n');

await copyFile(new URL('../LICENSE', import.meta.url), new URL('./dist/LICENSE', import.meta.url));
