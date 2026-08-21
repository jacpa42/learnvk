enum Flag : uint {
    has_diffuse,
    has_emmisive,
    has_normal,
    has_specular,
}

struct Vertex {
    uint pos;
    uint texcoord;
    uint normal;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 color;
    uint   texcoord;
};

struct UniformBuffer {
    uint     flags; // Bit set of Flag
    float3   lightdir;
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
};

// The buffers which contain our model/texture data
ConstantBuffer<UniformBuffer> uniforms;
StructuredBuffer<float> buf_pos;
StructuredBuffer<float> buf_normal;
StructuredBuffer<float> buf_texcoord;

// All the material textures we can bind for our fragment shader
Sampler2D tex_diffuse;
Sampler2D tex_emmisive;
Sampler2D tex_normal;
Sampler2D tex_specular;

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

    output.color = float3(max(dot(uniforms.lightdir, normal), 0.05));
    output.texcoord = vertex.texcoord;

    return output;
}

[ForceInline]
bool contains(uint flags, Flag f) {
    return (flags & (1 << uint(f))) > 0;
}


[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float4 col = float4(input.color, 1.0);

    //
    // Diffuse texture sampling
    //
    if (contains(uniforms.flags, Flag.has_diffuse)) {
        float2 texcoord = float2(
            buf_texcoord[input.texcoord * 2],
            buf_texcoord[input.texcoord * 2 + 1],
        );
        col.xyz *= tex_diffuse.Sample(texcoord).xyz;
    }

    // TODO:
    // has_emmisive,
    // has_gloss,
    // has_normal,
    // has_specular,

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
