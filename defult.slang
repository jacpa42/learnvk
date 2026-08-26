enum Flag : uint {
    has_diffuse  = 1,
    has_emissive = 2,
    has_normal   = 4,
    has_specular = 8,
}

struct Vertex {
    float3 pos;
    float3 norm;
    float2 texcoord;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 color;
    float2 texcoord;
};

struct UniformBuffer {
    Flag     flags; // Bit set of Flag
    float3   lightdir;
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
};

// The buffers which contain our model/texture data
ConstantBuffer<UniformBuffer> uniforms;

// All the material textures we can bind for our fragment shader
Sampler2D tex_diffuse;
// Sampler2D tex_emissive;
// Sampler2D tex_normal;
// Sampler2D tex_specular;

[shader("vertex")]
VertexOutput vertex(
    Vertex vertex,
    uint instanceID : SV_InstanceID
) {
    VertexOutput output;

    output.pos = float4(vertex.pos, 1.0);
    output.pos = mul(uniforms.model_from_vertex, output.pos);
    output.pos = mul(uniforms.world_from_model,  output.pos);
    output.pos = mul(uniforms.screen_from_world, output.pos);

    output.color = float3(max(dot(uniforms.lightdir, vertex.norm), 0.05));
    output.texcoord = vertex.texcoord;

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float4 col = float4(input.color, 1.0);

    //
    // Diffuse texture sampling
    //
    if ((uniforms.flags & Flag.has_diffuse) > 0) {
        float2 coords = float2(input.texcoord.x, 1.0 - input.texcoord.y);
        col.xyz *= tex_diffuse.Sample(coords).xyz;
    }

    return col;
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
