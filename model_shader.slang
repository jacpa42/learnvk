struct Vertex {
    float3 pos;
    float3 normal;
    float3 texcoord;
};

struct Instance {
    float4x4 transform;
    float4 color;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 color;
};

static float3 lightdir = float3(1.0, 0.0, 0.0);

[shader("vertex")]
VertexOutput vertex(
    Vertex vertex,
    Instance instance,
    uint instanceID : SV_InstanceID
) {
    VertexOutput output;
    output.pos = float4(vertex.pos, 1.0);
    output.color = dot(lightdir, vertex.normal);
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    return float4(input.color, 1.0);
}
