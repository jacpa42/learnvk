// The buffers which contain our model data
StructuredBuffer<float3> buf_pos;
StructuredBuffer<float3> buf_normal;
StructuredBuffer<float3> buf_texcoord;

struct Vertex {
    uint pos;
    uint normal;
    uint texcoord;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 color;
};

static float3 lightdir = float3(1.0, 0.0, 0.0);

[shader("vertex")]
VertexOutput vertex(
    Vertex vertex,
    uint instanceID : SV_InstanceID
) {

    float3 pos = buf_pos[vertex.pos];
    float3 normal = buf_normal[vertex.normal];
    float3 texcoord = buf_texcoord[vertex.texcoord];

    VertexOutput output;
    output.pos = float4(pos, 1.0);
    output.color = dot(lightdir, normal);
    output.color.xy *= texcoord.xy;
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    return float4(input.color, 1.0);
}
