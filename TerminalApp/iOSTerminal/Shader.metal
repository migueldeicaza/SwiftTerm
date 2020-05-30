#include <metal_stdlib>
using namespace metal;

struct Vertex {
    // [[position]] attribute is used to signify to Metal which value should be regarded as the clip-space position of the vertex returned by the vertex shader.
    // When returning a custom struct from a vertex shader, exactly one member of the struct must have this attribute. Alternatively, you may return a `float4` from your vertex function, which is implicitly assumed to be the vertex's position.
    float4 position [[position]];
    float4 color;
};

// The definition of Metal shader functions must be prefixed with a function qualifier: vertex, fragment, or kernel.
vertex Vertex main_vertex(device Vertex const* const vertices [[buffer(0)]], uint vid [[vertex_id]]) {
    return vertices[vid];
}

// [[stage_in]] attribute identifies it as per-fragment data rather than data that is constant accross a draw call.
// The Vertex here is an interpolated value.
fragment float4 main_fragment(Vertex interpolatedVertex [[stage_in]]) {
    return interpolatedVertex.color;
}
