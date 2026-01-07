#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex GlyphOut terminal_text_vertex(uint vid [[vertex_id]],
                                     const device GlyphVertex *vertices [[buffer(0)]],
                                     constant float2 &viewport [[buffer(1)]]) {
    GlyphVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    return out;
}

fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    return float4(tex.rgb * in.color.rgb, tex.a * in.color.a);
}

fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    return float4(in.color.rgb * coverage, in.color.a * coverage);
}

struct ColorVertex {
    float2 position;
    float4 color;
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorOut terminal_color_vertex(uint vid [[vertex_id]],
                                      const device ColorVertex *vertices [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]]) {
    ColorVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 terminal_color_fragment(ColorOut in [[stage_in]]) {
    return in.color;
}
