struct UniformBuffer {
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float3   lightdir;
    float    __padding;
};

ConstantBuffer<UniformBuffer> uniforms;

struct VertexInput {
    float3 pos;
};

struct VertexOutput {
    float4 color;
    float4 pos : SV_Position;
};

[shader("vertex")]
VertexOutput vertMain(VertexInput input, uint vid : SV_VertexID) {
    VertexOutput output;
    output.pos = float4(input.pos, 1.0);
    output.color = float4(1.0, input.pos.yz, 1.0);

    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput inVert) : SV_Target {
    return inVert.color;
}
