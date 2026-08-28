struct Vertex {};

struct VertexOutput {
    float4 pos : SV_Position;
};

[shader("vertex")]
VertexOutput vertex(
    Vertex input,
    uint instanceID : SV_InstanceID
) {
    VertexOutput o;
    o.pos = float4(1.0);
    return o;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
   return float4(1.0);
}
