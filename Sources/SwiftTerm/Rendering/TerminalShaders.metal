//
//  TerminalShaders.metal
//
//  Metal shaders for GPU-accelerated terminal rendering.
//  Uses instanced drawing: one instance per terminal cell.
//
//  Note: SPM does not compile .metal files. The shader source is embedded
//  as a Swift string in MetalTerminalRenderer and compiled at runtime via
//  device.makeLibrary(source:options:). This file serves as the canonical
//  reference and for Xcode project builds.
//

#include <metal_stdlib>
using namespace metal;

// Structs duplicated here because .metal files cannot include .h in SPM builds.

struct CellData {
    uint16_t glyphIndex;
    uint8_t  fgR, fgG, fgB, fgA;
    uint8_t  bgR, bgG, bgB, bgA;
    uint16_t flags;
    uint16_t padding;
};

struct Uniforms {
    float2 viewportSize;
    float2 cellSize;
    float2 atlasSize;
    uint32_t cols;
    uint32_t rows;
    float time;
    uint32_t blinkOn;
};

struct GlyphEntry {
    float4 uvRect;      // u0, v0, u1, v1
    float2 bearing;     // bearingX, bearingY
    float2 size;        // glyph width, height in pixels
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
    uint flags [[flat]];
};

// ---- Background Pass ----

vertex VertexOut bgVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    uint col = instanceID % uniforms.cols;
    uint row = instanceID / uniforms.cols;

    // 6 vertices per quad (2 triangles)
    float2 positions[6] = {
        {0, 0}, {1, 0}, {0, 1},
        {1, 0}, {1, 1}, {0, 1}
    };

    float2 pos = positions[vertexID];
    float2 cellOrigin = float2(col, row) * uniforms.cellSize;
    float2 pixelPos = cellOrigin + pos * uniforms.cellSize;

    // Convert to clip space (-1..1)
    float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;  // Flip Y

    CellData cell = cells[instanceID];
    float4 bg = float4(cell.bgR, cell.bgG, cell.bgB, cell.bgA) / 255.0;

    VertexOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.bgColor = bg;
    out.texCoord = float2(0);
    out.fgColor = float4(0);
    out.flags = 0;
    return out;
}

fragment float4 bgFragment(VertexOut in [[stage_in]]) {
    return in.bgColor;
}

// ---- Text Pass ----

vertex VertexOut textVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    constant GlyphEntry* glyphs [[buffer(2)]]
) {
    uint col = instanceID % uniforms.cols;
    uint row = instanceID / uniforms.cols;

    CellData cell = cells[instanceID];
    GlyphEntry glyph = glyphs[cell.glyphIndex];

    float2 positions[6] = {
        {0, 0}, {1, 0}, {0, 1},
        {1, 0}, {1, 1}, {0, 1}
    };
    float2 texCoords[6] = {
        {glyph.uvRect.x, glyph.uvRect.y},
        {glyph.uvRect.z, glyph.uvRect.y},
        {glyph.uvRect.x, glyph.uvRect.w},
        {glyph.uvRect.z, glyph.uvRect.y},
        {glyph.uvRect.z, glyph.uvRect.w},
        {glyph.uvRect.x, glyph.uvRect.w}
    };

    float2 pos = positions[vertexID];
    float2 cellOrigin = float2(col, row) * uniforms.cellSize;
    float2 glyphOrigin = cellOrigin + float2(glyph.bearing.x, glyph.bearing.y);
    float2 pixelPos = glyphOrigin + pos * glyph.size;

    float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;

    float4 fg = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA) / 255.0;

    VertexOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.fgColor = fg;
    out.bgColor = float4(0);
    out.flags = cell.flags;
    return out;
}

fragment float4 textFragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(filter::linear);
    float alpha = atlas.sample(s, in.texCoord).r;

    // Skip empty glyphs
    if (alpha < 0.01) discard_fragment();

    return float4(in.fgColor.rgb, in.fgColor.a * alpha);
}

// ---- Decoration Pass (underline, strikethrough) ----

vertex VertexOut decoVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    uint col = instanceID % uniforms.cols;
    uint row = instanceID / uniforms.cols;

    float2 positions[6] = {
        {0, 0}, {1, 0}, {0, 1},
        {1, 0}, {1, 1}, {0, 1}
    };

    float2 pos = positions[vertexID];
    float2 cellOrigin = float2(col, row) * uniforms.cellSize;
    float2 pixelPos = cellOrigin + pos * uniforms.cellSize;

    float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;

    CellData cell = cells[instanceID];
    float4 fg = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA) / 255.0;

    VertexOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.texCoord = pos;  // cell-local position (0..1)
    out.fgColor = fg;
    out.bgColor = float4(0);
    out.flags = cell.flags;
    return out;
}

fragment float4 decoFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]]
) {
    uint flags = in.flags;
    bool hasUnderline = (flags & (1u << 2)) != 0;
    bool hasStrikethrough = (flags & (1u << 3)) != 0;

    if (!hasUnderline && !hasStrikethrough) discard_fragment();

    float y = in.texCoord.y;
    float pixelH = 1.0 / uniforms.cellSize.y;

    bool draw = false;

    // Underline: 1px line 3 pixels from bottom of cell
    if (hasUnderline) {
        float underlineY = 1.0 - 3.0 * pixelH;
        if (y >= underlineY && y < underlineY + pixelH) draw = true;
    }

    // Strikethrough: 1px line at vertical center
    if (hasStrikethrough) {
        float strikeY = 0.5 - 0.5 * pixelH;
        if (y >= strikeY && y < strikeY + pixelH) draw = true;
    }

    if (!draw) discard_fragment();

    return in.fgColor;
}
