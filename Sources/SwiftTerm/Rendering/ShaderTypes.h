//
//  ShaderTypes.h
//
//  Shared type definitions used by both Metal shaders and Swift code.
//  These structs define the GPU-side layout for terminal cell rendering.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Matches Swift CellData struct
struct CellData {
    uint16_t glyphIndex;
    uint8_t  fgR, fgG, fgB, fgA;
    uint8_t  bgR, bgG, bgB, bgA;
    uint16_t flags;    // bit 0: bold, 1: italic, 2: underline, 3: strikethrough, 4: inverse, 5: blink, 6: dim
    uint16_t padding;
};

struct Uniforms {
    simd_float2 viewportSize;      // in pixels
    simd_float2 cellSize;          // cell width/height in pixels
    simd_float2 atlasSize;         // atlas texture dimensions
    uint32_t cols;
    uint32_t rows;
    float time;                    // for blink animation
    uint32_t blinkOn;              // blink state (0 or 1)
};

struct GlyphEntry {
    simd_float4 uvRect;            // u0, v0, u1, v1
    simd_float2 bearing;           // bearingX, bearingY
    simd_float2 size;              // glyph width, height in pixels
};

#endif
