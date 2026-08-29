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
};

enum Flags : uint {
	enable_diffuse  = 1,
	enable_emissive = 2,
	enable_bump     = 4,
	enable_specular = 8,
}

struct Uniforms {
    float4x4 screen_from_world;

    float4   light_position;
    float4   light_color;
    float4   camera_position;
    float    ambient_light;
    uint     flags;
};

struct Instance {
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float4x4 normal_matrix;
}

StructuredBuffer<Instance> instance_data;

// The buffers which contain our model/texture data
ConstantBuffer<Uniforms> uniforms;

// All the material textures we can bind for our fragment shader
Sampler2D tex_diffuse;
Sampler2D tex_emissive;
Sampler2D tex_bump;
Sampler2D tex_specular;


[shader("vertex")]
VertexOutput vertex(
    Vertex   ivertex,
    uint instance_id: SV_InstanceID
) {
    VertexOutput output;

    Instance idata = instance_data[instance_id];

    float4 vertex        = float4(ivertex.pos, 1.0);
    float4 vertex_model  = mul(idata.model_from_vertex, vertex);
    float4 vertex_world  = mul(idata.world_from_model,  vertex_model);
    float4 vertex_screen = mul(uniforms.screen_from_world, vertex_world);

    output.pos = vertex_screen;

    output.normal = mul(float3x3(idata.normal_matrix), ivertex.normal);
    output.light_dir = normalize(uniforms.light_position.xyz - vertex_world.xyz);
    output.texcoord = ivertex.texcoord;

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
    if ((uniforms.flags & 1) > 0) {
        col *= tex_diffuse.Sample(input.texcoord);
    }

    return col;
}
