#define ENABLE_DIFFUSE
// #define ENABLE_EMISSIVE
// #define ENABLE_HEIGHT
// #define ENABLE_SPECULAR

struct Vertex {
    float3 pos;
    float3 normal;
    float2 texcoord;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 normal;
    float3 view_dir;
    float2 texcoord;
};

struct UniformBuffer {
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
    float4   light_dir;
    float4   light_color;
    float4   camera_position;
    uint     flags;
};

// The buffers which contain our model/texture data
ConstantBuffer<UniformBuffer> uniforms;

// All the material textures we can bind for our fragment shader
Sampler2D tex_diffuse;
Sampler2D tex_emissive;
Sampler2D tex_normal;
Sampler2D tex_specular;

[shader("vertex")]
VertexOutput vertex(
    Vertex input,
    uint instanceID : SV_InstanceID
) {
    VertexOutput output;

    float4 vertex        = float4(input.pos, 1.0);
    float4 vertex_model  = mul(uniforms.model_from_vertex, vertex);
    float4 vertex_world  = mul(uniforms.world_from_model,  vertex_model);
    float4 vertex_screen = mul(uniforms.screen_from_world, vertex_world);

    output.pos = vertex_screen;
    output.normal = normalize(mul(uniforms.model_from_vertex, float4(input.normal, 1.0)).xyz);
    output.view_dir = normalize(uniforms.camera_position.xyz - vertex_world.xyz);
    output.texcoord = input.texcoord;

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float2 coords = float2(input.texcoord.x, input.texcoord.y);
    float4 col = float4(
        uniforms.light_color.xyz * float3(max(
            dot(uniforms.light_dir.xyz, input.normal), 0.1
        )),
        1.0
    );

    //
    // diffuse
    //
    if ((uniforms.flags & 1) > 0) {
        col *= tex_diffuse.Sample(coords);
    }

    return col;
}
