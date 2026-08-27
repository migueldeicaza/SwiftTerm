# Kitty Graphics Parity Matrix

This matrix inventories every Kitty graphics test in Ghostty commit
`683d8db643b95cf229bfb5fe9fab9ae677920343`. Test names and source lines come directly from that commit.
The Ghostty repository and copied fixtures use the MIT license.

`Covered` means that an iiSwiftTerm semantic suite asserts the same wire,
storage, placement, animation, Unicode, or render-snapshot behavior. Several
Ghostty unit tests can map to one data-driven iiSwiftTerm test. `API-equivalent`
means that the behavior is tested through iiSwiftTerm's immutable Swift snapshot
API because iiSwiftTerm does not provide libghostty's C graphics ABI.

## Summary

| Status | Count |
| --- | ---: |
| Covered | 226 |
| API-equivalent | 42 |
| Total pinned tests | 268 |
| Missing portable cases | 0 |

## Test mapping

| Ghostty source test | Status | iiSwiftTerm mapping |
| --- | --- | --- |
| `src/terminal/c/kitty_graphics.zig:671` — placement_iterator new/free | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:683` — placement_iterator free null | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:687` — placement_iterator next on empty storage | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:717` — placement_iterator get before next returns invalid | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:749` — placement_iterator with transmit and display | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:803` — placement_iterator with multiple placements | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:861` — placement_iterator_set layer filter | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:952` — image_get_handle returns null for missing id | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:974` — image_get_handle and image_get with transmitted image | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1025` — image_get exposes pending metadata without a data pointer | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1076` — placement_rect with transmit and display | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1131` — placement_rect null args return invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1138` — placement_pixel_size with transmit and display | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1186` — placement_pixel_size null args return invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1194` — placement_grid_size with transmit and display | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1241` — placement_grid_size null args return invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1249` — placement_viewport_pos with transmit and display | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1295` — placement_viewport_pos fully off-screen above | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1335` — placement_viewport_pos top off-screen | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1379` — placement_viewport_pos bottom off-screen | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1420` — placement_viewport_pos top and bottom off-screen | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1464` — placement_viewport_pos null args return invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1472` — placement_source_rect defaults to full image | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1512` — placement_source_rect with explicit source rect | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1557` — placement_source_rect clamps to image bounds | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1611` — placement_source_rect null args return invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1621` — image_get on null returns invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1628` — placement_render_info returns all fields | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1682` — placement_render_info handles maximum grid dimensions | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1715` — placement_render_info off-screen sets viewport_visible false | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1758` — placement_render_info null returns invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1765` — image_get_multi success | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1800` — image_get_multi error sets out_written | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1812` — image_get_multi null keys returns invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1820` — placement_get_multi success | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1859` — placement_get_multi error sets out_written | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1871` — placement_get_multi null keys returns invalid_value | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1879` — storage generation via get | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1932` — image generation detects same-sized retransmission | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:1994` — image generation via image_get_multi | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:2031` — image compression and format always report decoded data | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/c/kitty_graphics.zig:2078` — generation never recurs across resets and screen switches | API-equivalent | `kittyGraphicsRenderSnapshot()` and Apple renderer tests; iiSwiftTerm does not expose libghostty's C iterator ABI |
| `src/terminal/kitty/graphics.zig:34` — (unnamed test block) | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_animation.zig:128` — animation gap helpers | Covered | `KittyGraphicsParityTests` deterministic animation cases |
| `src/terminal/kitty/graphics_command.zig:1226` — transmission command | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1245` — transmission command with transient hint | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1264` — feedSlice matches per-byte feed | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1287` — feedSlice across slice boundaries | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1305` — feedSlice respects max_bytes | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1315` — transmission ignores 'm' if medium is not direct | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1332` — transmission respects 'm' if medium is direct | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1349` — query command | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1369` — display command | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1387` — delete command | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1407` — no control data | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1422` — ignore unknown keys (long) | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1440` — ignore unknown keys (non-letter) | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1458` — ignore very long values | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1476` — ensure very large negative values don't get skipped | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1493` — ensure proper overflow error for u32 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1504` — ensure proper overflow error for i32 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1515` — all i32 values | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1565` — response: encode nothing without ID or image number | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1575` — response: encode with only image id | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1585` — response: encode with only image number | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1595` — response: encode with image ID and number | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1605` — delete range command 1 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1625` — delete range command 2 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1645` — delete range command 3 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1668` — delete range command 4 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1690` — delete range command 5 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1710` — delete range command 6 | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1736` — unknown format value is deferred to execution | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1748` — zero format value is rgba | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1761` — known format values are not unknown | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1779` — quiet value above two suppresses all responses | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1789` — cursor movement value above one moves the cursor | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1803` — virtual placement value above one is virtual | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1814` — animation frame composition value above one alpha blends | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1828` — animation compose value above one overwrites | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1842` — animation control action above three is ignored | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_command.zig:1856` — unknown flag key values still fail parsing | Covered | `KittyGraphicsParityTests`, `KittyTransmissionTests` |
| `src/terminal/kitty/graphics_exec.zig:1095` — kittygfx query validates image data | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1125` — kittygfx valid query does not replace or store image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1166` — kittygfx image id and number are mutually exclusive for every action | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1212` — kittygfx conflicting identifiers are rejected before mutation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1279` — kittygfx chunked success response uses initial identifiers | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1316` — kittygfx chunked error response uses initial identifiers | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1345` — kittygfx more chunks with q=1 | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1376` — kittygfx more chunks with q=0 | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1407` — kittygfx more chunks with chunk increasing q | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1438` — kittygfx delete aborts chunked image load | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1482` — kittygfx uppercase id delete preserves image when placement does not match | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1514` — kittygfx default format is rgba | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1535` — kittygfx test valid u32 (expect invalid image ID) | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1553` — kittygfx test valid i32 (expect invalid image ID) | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1571` — kittygfx no response with no image ID or number | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1590` — kittygfx no response with no image ID or number load and display | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1609` — kittygfx retransmit same id gets fresh image generation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1649` — kittygfx retransmit same id removes existing placements | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1729` — kittygfx retransmit same id removes image on first chunk | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1771` — kittygfx delete then retransmit same id gets fresh generation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1817` — kittygfx display clamps cell offsets | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1847` — kittygfx placement bounds cursor movement for untrusted dimensions | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1869` — kittygfx placement moves cursor past a tall image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1939` — kittygfx unknown format responds with EINVAL | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1963` — kittygfx unknown format on query responds with EINVAL | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:1983` — kittygfx zero format is rgba | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2005` — kittygfx unknown format with q=3 has no response | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2024` — kittygfx out of range display keys are tolerated | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2051` — kittygfx number-based transmission assigns smallest free id | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2116` — kittygfx number-based id assignment does not replace client image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2163` — kittygfx implicit id assignment does not replace client image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2211` — kittygfx relative placement with missing parent image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2252` — kittygfx relative placement with missing parent placement | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2302` — kittygfx relative placement cannot parent itself | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2344` — kittygfx relative placement cycle | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2385` — kittygfx relative placement chain depth limit | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2430` — kittygfx relative placement does not move cursor | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2467` — kittygfx virtual placement with parent rejected before image lookup | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2487` — kittygfx deleting a parent deletes relative placements transitively | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2533` — kittygfx retransmitting parent image deletes relative placements | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2572` — kittygfx relative placement parent fallback picks lowest external id | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2603` — kittygfx placements created after a full reset are retained | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2631` — kittygfx relative placement with pruned parent is ENOPARENT | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2671` — kittygfx uppercase delete frees image of cascaded placements | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2706` — kittygfx animation: new frame with default gap responds with frame number | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2756` — kittygfx animation: frame gap normalization on create | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2787` — kittygfx animation: background fill and offset composition | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2825` — kittygfx animation: create from base frame with overwrite | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2859` — kittygfx animation: alpha blend composes over base frame | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2903` — kittygfx animation: edit root frame bumps generation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2937` — kittygfx animation: edit frame gap without data change | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:2986` — kittygfx animation: frame errors | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3043` — kittygfx animation: excess frame data is truncated | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3072` — kittygfx animation: chunked frame transmission | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3122` — kittygfx animation: chunked frame continuation without a=f | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3163` — kittygfx animation: control command sets gap current state and loops | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3212` — kittygfx animation: control command ignores invalid values | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3243` — kittygfx animation: control command missing image responds ENOENT | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3258` — kittygfx animation: compose frames | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3309` — kittygfx animation: compose current frame bumps generation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3341` — kittygfx animation: compose errors | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3397` — kittygfx animation: delete frame promotes root and fixes current | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3457` — kittygfx animation: uppercase frame delete removes non-animated image | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3488` — kittygfx animation: deleting current frame refreshes display | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3531` — kittygfx animation: retransmitting base image resets animation | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_exec.zig:3572` — kittygfx animation: control negative gap makes frame gapless | Covered | `KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites |
| `src/terminal/kitty/graphics_image.zig:842` — temporary file path must be inside directory | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:855` — shared memory range with offset and size | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:882` — shared memory range rejects out of bounds offset | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:899` — shared memory range validates dimensions before multiplication | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:918` — image load with invalid RGB data | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:938` — image load with image too wide | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:958` — image load with image too tall | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:978` — image load: rgb, zlib compressed, direct | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1007` — image load: rgb, not compressed, direct | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1036` — image load: rgb, zlib compressed, direct, chunked | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1074` — image load: rgb, zlib compressed, direct, chunked with zero initial chunk | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1111` — image load: temporary file without correct path | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1151` — image load: temporary file outside directory prefix is rejected | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1199` — image load: rgb, not compressed, temporary file | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1243` — image load: rgb, not compressed, regular file | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1285` — image load: regular file size reads exactly requested bytes | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1339` — image load: regular file size rejects short data | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1380` — image load: rgb, not compressed, relative regular file | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1420` — image load: blocklist applies to opened file after symlink swap | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1453` — image load: png, not compressed, regular file | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1498` — image load: png rejects oversized decoder allocation | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1537` — image load: png rejects oversized Wuffs image before allocation | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1564` — limits: direct medium always allowed | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1586` — limits: file medium blocked by limits | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1617` — limits: file medium allowed by limits | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1653` — limits: temporary file medium blocked by limits | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_image.zig:1691` — limits: temporary file medium allowed by limits | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:125` — rgba conversion | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:158` — fill background | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:167` — compose rect overwrite with clipping | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:182` — compose rect entirely out of bounds | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:190` — alpha blend source-over semantics | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_pixel.zig:226` — compose canvas rect | Covered | `KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures |
| `src/terminal/kitty/graphics_storage.zig:2126` — storage: add placement with zero placement id | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2156` — storage: replacing placement releases tracked pin | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2194` — storage: adding placement reclaims garbage placements | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2231` — storage: placement count limit permits replacement | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2253` — storage: delete all visible placements and matching images | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2278` — storage: delete all placements and images preserves limit | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2305` — storage: delete all visible placements preserves scrollback | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2346` — storage: delete all includes placements spanning into active area | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2390` — storage: delete all placements | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2414` — storage: delete all placements by image id | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2438` — storage: delete all placements by image id and unused images | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2462` — storage: delete placement by specific id | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2491` — storage: uppercase id delete preserves image when placement does not match | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2515` — storage: uppercase id delete frees image after placement matches | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2543` — storage: uppercase id delete without placement frees unplaced image | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2564` — storage: delete intersecting cursor | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2597` — storage: delete intersecting cursor checks interior row column | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2624` — storage: delete intersecting cell checks interior row column | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2652` — storage: delete intersecting cursor plus unused | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2685` — storage: delete intersecting cursor hits multiple | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2712` — storage: delete by column | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2746` — storage: delete by column 1x1 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2780` — storage: delete by row | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2814` — storage: delete by row 1x1 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2848` — storage: delete images by range 1 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2874` — storage: delete images by range 2 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2900` — storage: delete images by range 3 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2935` — storage: delete images by range 4 | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2970` — storage: uppercase range deletes unplaced image data | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:2995` — storage: delete images by empty range | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3031` — storage: erase display preserves scrollback and reclaims unplaced images | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3075` — storage: cell offsets stay within explicit destination rectangle | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3101` — storage: cell offsets clamp to cell bounds | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3128` — storage: aspect ratio calculation when only columns or rows specified | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3175` — storage: default source rectangle is intersected before sizing | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3193` — storage: explicit source rectangle is intersected before sizing | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3219` — storage: placement geometry handles untrusted dimensions | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3326` — storage: generation stamps on image add and replace | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3364` — storage: generation bumps on placement and delete | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3389` — storage: generation bumps when setLimit evicts or disables | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3423` — storage: imageByNumber returns most recently transmitted | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3444` — storage: nextGeneration is unique and monotonic | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3452` — storage: no-op delete does not mark a mutation | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3483` — storage: evicts images in priority order | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3528` — storage: eviction releases placement pins | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3572` — storage: pending image completes once and preserves age | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3620` — storage: stale pending completion loses to delete replacement and eviction | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3669` — storage: replacement reuses pending reservation and removes placements | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3733` — storage: pending images share exact eviction ordering | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3770` — storage: nextImageId number matches Kitty get_free_client_id | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3799` — storage: nextImageId implicit skips in-use ids and zero | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3821` — storage: scroll margins placement inside region scrolls and clips at top | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3875` — storage: scroll margins placement straddling region does not move | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3910` — storage: scroll margins placement below region does not move | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3943` — storage: scroll margins reverse index clips at bottom | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:3983` — storage: scroll margins scaled placement clips proportionally | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4020` — storage: scroll margins left/right margins respect columns | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4069` — storage: scroll margins insert/delete lines do not move placements | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4112` — storage: scroll without margins moves placement into scrollback | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4147` — storage: scroll margins large scroll deletes inside placement | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4171` — storage: scroll margins straddling placement pin inside region restored | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4206` — storage: scroll margins multi-line scroll up with scrollback | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4244` — storage: resolveChain accumulates offsets to the pin root | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4292` — storage: resolveChain finds virtual roots | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4329` — storage: eviction removes orphaned relative placements | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4374` — storage: placeholderTarget lookup | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4426` — storage: animation tick advances and schedules | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4485` — storage: animation tick loading state parks on last frame | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4534` — storage: animation tick exhausts loop budget | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4581` — storage: animation tick ignores ineligible animations | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_storage.zig:4623` — storage: animation tick re-anchors a restarted clock | Covered | `KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests` |
| `src/terminal/kitty/graphics_unicode.zig:858` — unicode diacritic sorted | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:868` — unicode diacritic | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:874` — unicode placement: none | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:890` — unicode placement: single row/col | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:915` — unicode placement: continuation break | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:950` — unicode placement: continuation with diacritics set | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:978` — unicode placement: continuation with no col | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1006` — unicode placement: continuation with no diacritics | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1034` — unicode placement: run ending | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1062` — unicode placement: run starting in the middle | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1090` — unicode placement: specifying image id as palette | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1116` — unicode placement: specifying image id with high bits | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1142` — unicode placement: specifying placement id as palette | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1174` — unicode render placement: dog 4x2 | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1242` — unicode render placement: dog 2x2 with blank cells | Covered | `KittyUnicodeTests` |
| `src/terminal/kitty/graphics_unicode.zig:1309` — unicode render placement: dog 1x1 | Covered | `KittyUnicodeTests` |
