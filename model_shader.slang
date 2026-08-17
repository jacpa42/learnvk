struct Vertex {
    uint pos;
    uint texcoord;
    uint normal;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 color;
    uint texcoord;
};

struct UniformBuffer {
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float3   lightdir;
};

ConstantBuffer<UniformBuffer> uniforms;

// The buffers which contain our model/texture data
Sampler2D texture;
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
        buf_pos[vertex.pos * 3 + 2],
    );
    float3 normal = float3(
        buf_normal[vertex.normal * 3],
        buf_normal[vertex.normal * 3 + 1],
        buf_normal[vertex.normal * 3 + 2],
    );

    VertexOutput output;

    output.pos = float4(pos, 1.0);
    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    // normal = mul(uniforms.model_from_vertex, normal);
    // normal = mul(uniforms.world_from_model,  normal);
    // normal = mul(uniforms.screen_from_world, normal);

    output.color = max(dot(uniforms.lightdir, normal), 0.05);
    output.texcoord = vertex.texcoord;

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float2 texcoord = float2(
        buf_texcoord[input.texcoord * 2],
        buf_texcoord[input.texcoord * 2 + 1],
    );

    return float4(input.color * texture.Sample(texcoord).xyz, 1.0);
}

//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
