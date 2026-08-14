struct Vertex {
    uint pos;
    uint texcoord;
    uint normal;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float4 color;
};

struct UniformBuffer {
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float    __padding;
    float3   lightdir;
};

ConstantBuffer<UniformBuffer> uniforms;

// The buffers which contain our model data
StructuredBuffer<float3> buf_pos;
StructuredBuffer<float3> buf_normal;
StructuredBuffer<float2> buf_texcoord;

[shader("vertex")]
VertexOutput vertex(
    Vertex vertex,
    uint instanceID : SV_InstanceID
) {
    float3 pos = buf_pos[vertex.pos];
    float3 normal = buf_normal[vertex.normal];
    float2 texcoord = buf_texcoord[vertex.texcoord];

    VertexOutput output;
    output.pos = float4(pos, 1.0);
    // output.color = float4(float3(dot(normal, uniforms.lightdir)), 1.0);
    output.color = output.pos;

    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    return input.color;
}
