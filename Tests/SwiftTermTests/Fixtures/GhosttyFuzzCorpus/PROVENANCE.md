# Ghostty fuzz corpus provenance

The `.stfuzz` archives contain exact copies of tracked raw inputs in the
corpus directories under `test/fuzz-libghostty/corpus` at Ghostty commit
`683d8db643b95cf229bfb5fe9fab9ae677920343`.

The archives include the hand-written `initial` corpora and the AFL++
coverage-minimized `cmin` corpora for the OSC parser and full terminal stream
targets. The VT parser `cmin` archive is omitted to keep the fixture size and
test runtime small. It can be regenerated locally with
`Tools/import-ghostty-fuzz-corpus.swift`, which creates the archives from a
local Ghostty checkout.

The Swift tests adapt the targets as follows:

- The parser test gives each input byte to `EscapeSequenceParser` separately.
- The stream test keeps Ghostty's first-byte selector. It uses this byte to
  select full-slice input or one-byte input.
- SwiftTerm has no separate OSC parser. The OSC test adds `ESC ]` before the
  payload. Selector 0 adds BEL, and selector 1 adds C1 ST. Selector 2 leaves
  the sequence open. Ghostty calls `end(null)` for selector 2, so this case is
  a robustness test for an incomplete SwiftTerm OSC sequence. It is not a
  command-result comparison.

Ghostty is licensed under the MIT License:

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
