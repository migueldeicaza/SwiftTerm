# Kitty Graphics Protocol

SwiftTerm implements the Kitty graphics protocol in the terminal core. This
document records the behavior of Ghostty commit
`683d8db643b95cf229bfb5fe9fab9ae677920343`. That commit is the parity
baseline. The published Kitty protocol remains the wire-format reference.

## Framing and limits

A command uses APC framing:

```text
ESC _ G <control-data> ; <base64-data> ESC \
```

The C1 APC and ST bytes are also accepted. The parser limits one APC to 65
MiB. It drops an APC that exceeds this limit. It does not send a response for
the dropped APC. Decoded image data must not exceed 400 MiB. Each image
dimension must be from 1 through 10,000 pixels.

Control keys are one ASCII letter. A value is one ASCII character or a
decimal 32-bit integer. The `z`, `H`, and `V` keys accept signed 32-bit
integers. The parser ignores unknown keys, keys that have more than one
character, and values that have more than 11 bytes. It rejects numeric
overflow. Later copies of a key replace earlier copies.

Base64 is strict. Whitespace, non-alphabet bytes, bad padding, and incomplete
quartets are invalid. The implementation does not use an
"ignore unknown characters" decoder.

## Actions and validation order

The supported actions are:

| `a` | Operation |
| --- | --- |
| `q` | Validate a transmission without storing it |
| `t` | Transmit an image |
| `T` | Transmit and place an image |
| `p` | Place a stored image |
| `d` | Delete placements, images, or frames |
| `f` | Transmit or edit an animation frame |
| `a` | Control animation playback |
| `c` | Compose animation frames |

For every action, `i` and `I` are mutually exclusive. SwiftTerm performs this
check before it mutates storage. The exact error is
`EINVAL: image ID and number are mutually exclusive`.

A query requires `i`. It fully loads and decodes the image, but it does not
store the image or change a previous image. A missing ID produces
`EINVAL: image ID required`.

A placement requires `i` or `I`. A virtual placement that also names a parent
fails before image lookup. The exact error is
`EINVAL: virtual placement cannot refer to a parent`. Parent failures use
`ENOPARENT: parent image not found` and
`ENOPARENT: parent placement not found`. Self-parent, cycle, and chain-depth
failures use `EINVAL: placement cannot be its own parent`,
`ECYCLE: parent chain creates a cycle`, and
`ETOODEEP: parent chain too deep`.

## Formats, compression, and media

`f=24` is packed RGB. `f=32` and `f=0` are packed RGBA. Omitted `f` is RGBA.
`f=100` is PNG. All decoded images enter core storage as row-major,
straight-alpha RGBA8. Apple systems use ImageIO and Compression. Other
SwiftPM hosts use the `PNG` and `LZ77` products from SwiftPNG.

`o=z` selects zlib DEFLATE. Other compression values are invalid. The exact
errors used for load failures include:

- `ENODATA: insufficient data`
- `EINVAL: invalid data`
- `EINVAL: decompression failed`
- `EINVAL: unsupported format`
- `EINVAL: unsupported medium`
- `EINVAL: dimensions required`
- `EINVAL: dimensions too large`

Direct payloads (`t=d`) are always eligible. A host must opt in to regular
files (`t=f`), temporary files (`t=t`), and POSIX shared memory (`t=s`). The
default policy permits direct payloads only. Temporary files also require a
trusted temporary directory. The opened file handle must describe a regular
file in that directory, and the base name must start with
`tty-graphics-protocol`. SwiftTerm validates the opened handle and uses exact
`O` and `S` bounds. This prevents path substitution and time-of-check to
time-of-use errors. It unlinks accepted temporary files and shared-memory
objects after use.

## IDs, responses, and quiet mode

An explicit `i` replaces that image and removes its placements when the new
transmission starts. `I` asks the terminal to allocate the smallest free
positive image ID. A transmission without `i` or `I` gets an ID from the
terminal's high ID range. An implicit-ID transmission does not send a
response. Reusing an image number makes number lookup select the most recent
transmission.

A response is exact APC data:

```text
ESC _ G i=<id>,I=<number>,p=<placement>,r=<frame>;<message> ESC \
```

Only present, nonzero fields appear. The field order is `i`, `I`, `p`, `r`.
A response without `i` or `I` is not sent. `OK` is the success message.

Quiet mode follows Ghostty and Kitty coercion:

- `q=0` or omitted sends success and error responses.
- `q=1` suppresses success responses but sends errors.
- `q>=2` suppresses all responses.

For a chunked transfer, later `q=0` inherits the first chunk's setting. A
later `q>=1` replaces it. Success and error responses use the identifiers from
the first chunk. Deletes abort an incomplete transfer and never respond on
success.

## Chunking

Only direct transmission uses `m`. Any nonzero `m` means that more chunks
follow. Local media ignore `m`. Continuation commands contribute payload only.
The first command supplies the action, format, dimensions, IDs, placement,
and animation-frame fields. A continuation can omit `a=f`; it still belongs
to an in-progress frame transmission. The total encoded APC data remains
bounded by 65 MiB.

## Storage and eviction

The primary and alternate screens have independent stores. Each store uses
`storageLimitBytesPerScreen`. The default is 10,000,000 bytes. A zero limit
disables the complete protocol, including queries and responses.

Storage and image-content generations are monotonic. Renderers use the image
ID plus content generation as their cache key. Replacement gets a fresh
generation. Eviction selects transient (`N=1`) images first, then unplaced
images, then the least recently used remaining image. Eviction removes the
selected image's placements and relative descendants. The limit includes all
full animation frames.

## Placements, scrolling, and resize

The terminal core owns placements. Render delegates do not create Kitty
images. Each placement has a stable internal token. A client placement ID of
zero means anonymous and does not prevent multiple placements for one image.

Source keys `x`, `y`, `w`, and `h` select a pixel rectangle. SwiftTerm
intersects this rectangle with the decoded image before it computes the
destination. Keys `c` and `r` request destination columns and rows. If only
one is present, the other dimension keeps the source aspect ratio. `X` and
`Y` are cell pixel offsets and clamp to the cell bounds. `z` is a signed
z-index.

Pinned placements start at the cursor. Relative placements use `P`, `Q`, `H`,
and `V` and never move the cursor. `C=1` prevents movement. Every other `C`
value moves the cursor. Movement uses Index operations, honors scroll
regions, bounds work for untrusted dimensions, and wraps once at the right
edge.

Placements inside a scrolling region move and clip with that region. A
placement that straddles a region boundary does not move. Full-screen normal
scrolling can move placements into scrollback. Resize keeps stable tokens and
recomputes visible geometry. The immutable render snapshot expresses rows
relative to the current viewport.

## Unicode placeholders

`U` is true for every nonzero value. A virtual placement does not draw by
itself. U+10EEEE cells select regions of it. Foreground color supplies the
low 24 bits of the image ID. Underline color supplies the placement ID.
Combining diacritics provide row, column, and high ID components. Continuation
runs stop on incompatible placeholder metadata. Placeholder rendering clips
each cell to its corresponding source region.

## Deletion

The `d` key selects deletion by visible area (`a`), image ID (`i`), newest
image number (`n`), cursor (`c`), cell (`p`), cell and z-index (`q`), ID range
(`r`), column (`x`), row (`y`), z-index (`z`), or animation frame (`f`).
Lowercase selectors delete placements or frames. Uppercase selectors also
free selected image data when it is unused. An uppercase ID delete with a
placement ID does not free the image if that placement does not match. Range
selection does not reorder bounds. A zero upper bound or an inverted range
selects nothing. A zero lower bound includes every nonzero ID through the
upper bound.

Deleting frame zero selects the root. A frame number past the end selects the
last frame. Deleting the root promotes frame two. Lowercase `f` does nothing
to a non-animated image. Uppercase `F` removes that image and its placements.

## Animation

The root image is frame one and starts with a zero gap. `a=f` transmits a rectangle for a new or existing
frame. `r` selects an edit. Zero or a value past the next frame appends one.
The response returns the resolved frame number in `r`. `c` selects a base
frame for a new canvas. `Y` is a `0xRRGGBBAA` background. `X=1` overwrites;
other values use straight-alpha source-over composition. New frames use a
40 ms gap when `z=0`, a zero gap when `z<0`, or the stated millisecond gap.

`a=a` controls playback. `s=1` stops, `s=2` runs and waits, and `s=3` runs.
Other values do not change state. `r` and `z` edit a frame gap. `c` selects
the current frame. `v=1` loops forever. Larger `v` values play `v-1` more
loops. `a=c` composes a validated source rectangle into a destination frame.
Overlapping source and destination rectangles in one frame are invalid.

All transition logic is in a deterministic core method that accepts a
monotonic nanosecond timestamp. Production scheduling uses SwiftTerm's I/O
timer queue and takes the terminal lock. Tests use synthetic time.

## Rendering and security

``Terminal/kittyGraphicsRenderSnapshot()`` returns immutable, `Sendable`
renderer input. The caller holds the terminal lock while it calls the method.
CPU and Metal renderers draw negative z-index placements below text and other
placements above text. They cache decoded image resources by image ID and
content generation.

Hosts should keep local media disabled for untrusted sessions. The decoder
checks encoded, decoded, dimension, multiplication, file-range, and storage
limits before allocation when the backend exposes that information. It does
not follow a local-media path after validation. Protocol errors do not include
host paths or file contents.
