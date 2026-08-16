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
};

static float3 BASE_COLOR = float3(
    0.37254901960784315,
    0.47843137254901963,
    0.58431372549019611,
);

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
            buf_pos[vertex.pos * 3 + 2],
    );
    float4 normal = float4(
            buf_normal[vertex.normal * 3],
            buf_normal[vertex.normal * 3 + 1],
            buf_normal[vertex.normal * 3 + 2],
            1.0,
    );
    float2 texcoord = float2(
            buf_texcoord[vertex.texcoord * 2],
            buf_texcoord[vertex.texcoord * 2 + 1],
    );

    VertexOutput output;

    output.pos = float4(pos, 1.0);
    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    // normal = mul(uniforms.model_from_vertex, normal);
    // normal = mul(uniforms.world_from_model,  normal);
    // normal = mul(uniforms.screen_from_world, normal);

    output.color = float4(BASE_COLOR * max(dot(uniforms.lightdir, normal.xyz), 0.05), 1.0);

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    return input.color;
}
