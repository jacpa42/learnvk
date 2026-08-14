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
    float3   lightdir;
    float    __padding;
};

ConstantBuffer<UniformBuffer> uniforms;

// The buffers which contain our model data
StructuredBuffer<float> buf_pos;
StructuredBuffer<float> buf_normal;
StructuredBuffer<float> buf_texcoord;

[shader("vertex")]
VertexOutput vertex(
    Vertex vertex,
    uint instanceID : SV_InstanceID
) {
    float3 pos = float3(
            buf_pos[vertex.pos * 3],
            buf_pos[vertex.pos * 3 + 1],
            buf_pos[vertex.pos * 3 + 2]
    );
    float3 normal = float3(
            buf_normal[vertex.normal * 3],
            buf_normal[vertex.normal * 3 + 1],
            buf_normal[vertex.normal * 3 + 2]
    );
    float2 texcoord = float2(
            buf_texcoord[vertex.texcoord * 2],
            buf_texcoord[vertex.texcoord * 2 + 1],
    );

    VertexOutput output;
    output.pos = float4(pos, 1.0);
    output.color = float4(float3(max(dot(uniforms.lightdir, normal), 0.01)), 1.0);

    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    return input.color;
}
