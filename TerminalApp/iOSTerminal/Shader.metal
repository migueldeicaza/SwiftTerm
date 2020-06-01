//
// This is the header from Shadertweak: github.com/warrenm/Shadertweak
// followed by a sample from Shadertweak, contacatenated into this file
//
// Original licenses:
//
// MIT License
//
// Copyright (c) 2017 Warren Moore
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
#include <metal_stdlib>

using namespace metal;

struct Vertex2D
{
    float2 position [[attribute(0)]];
    float2 texCoords [[attribute(1)]];
};

struct ProjectedVertex {
    float4 position [[position]];
    float2 texCoords;
};

struct Uniforms {
    float2    resolution;
    float     time;
    float     deltaTime;
    int       frameIndex;
};

vertex ProjectedVertex vertex_reshape(Vertex2D currentVertex [[stage_in]])
{
    ProjectedVertex out;
    out.position = float4(currentVertex.position, 0.0, 1.0);
    out.texCoords = currentVertex.texCoords;
    return out;
}

#define iGlobalTime (uniforms.time)
#define iResolution (uniforms.resolution)
#define iTimeDelta (uniforms.deltaTime)
#define iTouches (uniforms.touches)

#define iterations 17
#define formuparam 0.53

#define volsteps 9
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850
#define speed  0.0010

#define brightness 0.005
#define darkmatter 0.150
#define distfading 0.630
#define saturation 0.850

fragment half4 fragment_texture(ProjectedVertex in [[stage_in]],
                      constant Uniforms &uniforms [[buffer(0)]])
{
    //get coords and direction
   float2 uv=in.texCoords;//fragCoord.xy/iResolution.xy-.5;
    uv.y*=iResolution.y/iResolution.x;
    float3 dir=float3(uv*zoom,1.);
    float time=iGlobalTime*speed+.25;

    //mouse rotation
    float a1=0;
    float a2=0;
    float2x2 rot1=float2x2(float2(cos(a1),sin(a1)),float2(-sin(a1),cos(a1)));
    float2x2 rot2=float2x2(float2(cos(a2),sin(a2)),float2(-sin(a2),cos(a2)));
    dir.xz=dir.xz*rot1;
    dir.xy=dir.xy*rot2;
    float3 from=float3(1.,.5,0.5);
    from+=float3(time*2.,time,-2.);
    from.xz=from.xz*rot1;
    from.xy=from.xy*rot2;
    
    //volumetric rendering
    float s=.01,fade=2;
    float3 v=float3(0.);
    for (int r=0; r<volsteps; r++) {
        float3 p=from+s*dir*.5;
        p = abs(float3(tile)-fmod(p,float3(tile*2.))); // tiling fold
        float pa,a=pa=0.;
        for (int i=0; i<iterations; i++) {
            p=abs(p)/dot(p,p)-formuparam; // the magic formula
            a+=abs(length(p)-pa); // absolute sum of average change
            pa=length(p);
        }
        float dm=max(0.,darkmatter-a*a*.001); //dark matter
        a*=a*a; // add contrast
        if (r>6) fade*=1.-dm; // dark matter, don't render near
        //v+=vec3(dm,dm*.5,0.);
        v+=fade;
        v+=float3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
        fade*=distfading; // distance fading
        s+=stepsize;
    }
    v=mix(float3(length(v)),v,saturation); //color adjust
    return half4(float4(v*.01,1.));
}
