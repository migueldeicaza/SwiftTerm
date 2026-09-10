import { SwiftTermError } from './errors.js';
/** Explicit preview1 shim. No filesystem, process, environment, or stdin access. */
export const wasiImportNames = Object.freeze([
  'args_get', 'args_sizes_get', 'environ_get', 'environ_sizes_get',
  'fd_close', 'fd_fdstat_get', 'fd_prestat_get', 'fd_prestat_dir_name',
  'fd_read', 'fd_seek', 'fd_write', 'path_open', 'proc_exit', 'random_get', 'clock_time_get', 'clock_res_get', 'fd_fdstat_set_flags', 'fd_filestat_get',
  'fd_filestat_set_size', 'fd_filestat_set_times', 'fd_pread', 'fd_readdir', 'fd_sync', 'fd_tell',
  'path_create_directory', 'path_filestat_get', 'path_filestat_set_times', 'path_link',
  'path_readlink', 'path_remove_directory', 'path_rename', 'path_symlink', 'path_unlink_file', 'poll_oneoff'
]);
/** WASI pointer and size parameters are unsigned i32 values. */
export function wasiMemoryRange(byteLength: number, pointer: number, length: number): boolean {
  const ptr = pointer >>> 0, size = length >>> 0;
  return ptr <= byteLength && size <= byteLength - ptr;
}
export function createWasiImports(getMemory: () => WebAssembly.Memory): WebAssembly.ModuleImports {
  const FAULT = 21, BADF = 8, NOSYS = 52, NOTCAPABLE = 76;
  const range = (ptr: number, size: number): boolean => size <= 0xffffffff && wasiMemoryRange(getMemory().buffer.byteLength, ptr, size);
  const word = (ptr: number, value: number) => { ptr >>>= 0; if (!range(ptr, 4)) return FAULT; new DataView(getMemory().buffer).setUint32(ptr, value, true); return 0; };
  const emptySizes = (count: number, size: number) => { if (!range(count, 4) || !range(size, 4)) return FAULT; word(count, 0); return word(size, 0); };
  return {
    args_get: () => 0, args_sizes_get: emptySizes,
    environ_get: () => 0, environ_sizes_get: emptySizes,
    fd_close: () => BADF,
    fd_fdstat_set_flags: () => BADF, fd_filestat_get: () => BADF,
    fd_filestat_set_size: () => BADF, fd_filestat_set_times: () => BADF,
    fd_pread: () => BADF, fd_readdir: () => BADF, fd_sync: () => BADF, fd_tell: () => BADF,
    path_create_directory: () => NOTCAPABLE, path_filestat_get: () => NOTCAPABLE,
    path_filestat_set_times: () => NOTCAPABLE, path_link: () => NOTCAPABLE,
    path_readlink: () => NOTCAPABLE, path_remove_directory: () => NOTCAPABLE,
    path_rename: () => NOTCAPABLE, path_symlink: () => NOTCAPABLE, path_unlink_file: () => NOTCAPABLE,
    // A browser reactor must not block its event loop waiting for WASI events.
    poll_oneoff: () => NOSYS,
    clock_res_get: (clock: number, ptr: number) => {
      clock >>>= 0; ptr >>>= 0;
      if (clock !== 0 && clock !== 1) return 28;
      if (!range(ptr, 8)) return FAULT;
      new DataView(getMemory().buffer).setBigUint64(ptr, 1_000_000n, true);
      return 0;
    },
    fd_prestat_get: () => BADF,
    fd_prestat_dir_name: () => BADF,
    path_open: () => NOTCAPABLE,
    fd_read: (fd: number, _iov: number, _count: number, read: number) => fd === 0 ? word(read, 0) : BADF,
    fd_seek: () => BADF,
    fd_fdstat_get: (fd: number, ptr: number) => {
      fd >>>= 0; ptr >>>= 0;
      if (fd < 0 || fd > 2) return BADF;
      if (!range(ptr, 24)) return FAULT;
      new Uint8Array(getMemory().buffer, ptr, 24).fill(0);
      new DataView(getMemory().buffer).setUint8(ptr, 2); // character device
      return 0;
    },
    // Discard runtime diagnostics. Applications receive terminal bytes through the output queue.
    fd_write: (fd: number, iov: number, count: number, written: number) => {
      fd >>>= 0; iov >>>= 0; count >>>= 0; written >>>= 0;
      if (fd !== 1 && fd !== 2) return BADF;
      if (!range(iov, count * 8) || !range(written, 4)) return FAULT;
      let total = 0;
      const view = new DataView(getMemory().buffer);
      for (let n = 0; n < count; n++) {
        const ptr = view.getUint32(iov + n * 8, true), size = view.getUint32(iov + n * 8 + 4, true);
        if (!range(ptr, size) || total + size > 0xffffffff) return FAULT;
        total += size;
      }
      return word(written, total);
    },
    random_get: (ptr: number, size: number) => {
      ptr >>>= 0; size >>>= 0;
      if (!range(ptr, size)) return FAULT;
      if (!globalThis.crypto?.getRandomValues) return NOSYS;
      for (let offset = 0; offset < size; offset += 65536) globalThis.crypto.getRandomValues(new Uint8Array(getMemory().buffer, ptr + offset, Math.min(65536, size - offset)));
      return 0;
    },
    clock_time_get: (clock: number, _precision: bigint, ptr: number) => {
      clock >>>= 0; ptr >>>= 0;
      if (clock !== 0 && clock !== 1) return 28;
      if (!range(ptr, 8)) return FAULT;
      const ms = clock === 0 ? Date.now() : performance.now();
      new DataView(getMemory().buffer).setBigUint64(ptr, BigInt(Math.floor(ms * 1e6)), true);
      return 0;
    },
    proc_exit: (code: number) => { throw new SwiftTermError('WASI_EXIT', `The WASI reactor exited with code ${code}.`); }
  };
}
