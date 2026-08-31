struct Vertex {
    float3 pos;
    float3 normal;
    float2 texcoord;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 normal;
    float3 light_dir;
    float2 texcoord;
    InstanceTextures textures;
};

struct Uniforms {
    float4x4 screen_from_world;

    float4   light_position;
    float4   light_color;
    float4   camera_position;
    float    ambient_light;
};

struct InstanceTransforms {
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float4x4 normal_matrix;
    uint     flags;
}

// -1 means nil
struct InstanceTextures {
    int diffuse_id;
    int emissive_id;
    int bump_id;
    int specular_id;
}

ConstantBuffer<Uniforms> uniforms;

StructuredBuffer<InstanceTransforms> instance_transforms;
StructuredBuffer<InstanceTextures>   instance_textures;
Sampler2D                            textures[];

[shader("vertex")]
VertexOutput vertex(
    Vertex   ivertex,
    uint instance_id: SV_InstanceID
) {
    VertexOutput output;

    InstanceTransforms itransforms = instance_transforms[instance_id];
    InstanceTextures   itextures   = instance_textures[instance_id];

    float4 vertex        = float4(ivertex.pos, 1.0);
    float4 vertex_model  = mul(itransforms.model_from_vertex, vertex);
    float4 vertex_world  = mul(itransforms.world_from_model,  vertex_model);
    float4 vertex_screen = mul(uniforms.screen_from_world, vertex_world);

    output.pos = vertex_screen;

    output.normal    = mul(float3x3(itransforms.normal_matrix), ivertex.normal);
    output.light_dir = normalize(uniforms.light_position.xyz - vertex_world.xyz);
    output.texcoord  = ivertex.texcoord;
    output.textures  = itextures;

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float4 col = uniforms.light_color * float4(
        float3(max(
            dot(input.light_dir, input.normal), 0.1
        )),
        1.0
    );

    col.xyz += uniforms.ambient_light * uniforms.light_color.xyz;

    //
    // diffuse
    //
    if (input.textures.diffuse_id >= 0) {
        col *= textures[input.textures.diffuse_id].Sample(input.texcoord);
    }

    return col;
}
