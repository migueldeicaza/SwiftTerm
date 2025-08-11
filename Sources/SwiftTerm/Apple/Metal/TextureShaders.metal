//
// From https://github.com/schwa/MetalTerminal
//
//  Created by Jonathan Wight
//
#include <metal_stdlib>
using namespace metal;

struct InstanceData {
    float2 position;
    uint _padding0;
    uint useDirectColor;
    float4 texCoords;
    float4 foregroundColor;
    float4 backgroundColor;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 foregroundColor;
    float4 backgroundColor;
    uint useDirectColor;
};

vertex VertexOut textVertexShader(uint vertexID [[vertex_id]], uint instanceID [[instance_id]], constant InstanceData* instances [[buffer(0)]], constant float2& charSize [[buffer(1)]], constant float2& screenSize [[buffer(2)]])
{
    VertexOut out;
    InstanceData instance = instances[instanceID];
    float2 positions[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    
    float2 localPos = positions[vertexID];
    float2 vertexPos = instance.position + localPos * charSize;
    out.position = float4(vertexPos, 0.0, 1.0);
    float u = mix(instance.texCoords.x, instance.texCoords.z, localPos.x);
    float v = mix(instance.texCoords.w, instance.texCoords.y, localPos.y);
    out.texCoord = float2(u, v);
    out.foregroundColor = instance.foregroundColor;
    out.backgroundColor = instance.backgroundColor;
    out.useDirectColor = instance.useDirectColor;
    return out;
}

fragment float4 textFragmentShader(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 texColor = atlas.sample(textureSampler, in.texCoord);
    if (in.useDirectColor == 1) {
        return texColor;
    } else {
        float textAlpha = texColor.r;
        float4 finalColor = mix(in.backgroundColor, in.foregroundColor, textAlpha);
        finalColor.a = max(textAlpha * in.foregroundColor.a, in.backgroundColor.a);
        return finalColor;
    }
}
