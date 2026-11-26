export const Capability = Object.freeze({ fullRuntime: 1, embeddedRuntime: 2, dirtyRange: 4, scrollInvariantRange: 8, hostEvents: 16, keyEncoding: 32, mouseEncoding: 64, inputModes: 128, paste: 256, clipboard: 512, kittyGraphics: 1024, sixel: 2048, iTermImages: 4096, poll: 8192, textInput: 16384, selection: 32768 });
export const CellStyle = Object.freeze({ bold: 1, underline: 2, blink: 4, inverse: 8, invisible: 16, dim: 32, italic: 64, crossedOut: 128 });
export const CellFlag = Object.freeze({ selected: 1, protected: 2, wideTail: 4, explicitUnderlineColor: 8, softWrapSpacer: 16, defaultBackground: 32, kittyPlaceholder: 64 });
export const KeyModifier = Object.freeze({ shift: 1, alt: 2, control: 4, super: 8, hyper: 16, meta: 32, capsLock: 64, numLock: 128 });
export const KeyEventType = Object.freeze({ press: 1, repeat: 2, release: 3 });
export const ClipboardStatus = Object.freeze({ ok: 0, denied: 1, unsupported: 2, busy: 3, invalid: 4, ioError: 5, tooLarge: 6 });
