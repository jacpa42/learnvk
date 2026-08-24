#define ENABLE_DIFFUSE
// #define ENABLE_EMISSIVE
// #define ENABLE_NORMAL
// #define ENABLE_SPECULAR

struct Vertex {
    float3 pos;
    float3 norm;
    float2 texcoord;
};

struct VertexOutput {
    float4 pos : SV_Position;
    float3 view_dir;
    float3 color;
    float2 texcoord;
};

struct UniformBuffer {
    float3   camera_position;
    float3   lightdir;
    float4x4 screen_from_world;
    float4x4 world_from_model;
    float4x4 model_from_vertex;
};

// The buffers which contain our model/texture data
ConstantBuffer<UniformBuffer> uniforms;

// All the material textures we can bind for our fragment shader
Sampler2D tex_diffuse;
Sampler2D tex_emmisive;
Sampler2D tex_normal;
Sampler2D tex_specular;

[shader("vertex")]
VertexOutput vertex(
    Vertex input,
    uint instanceID : SV_InstanceID
) {
    VertexOutput output;

    float4 vertex        = float4(input.pos, 1.0);
    float4 vertex_model  = mul(uniforms.model_from_vertex, vertex); // model space
    float4 vertex_world  = mul(uniforms.world_from_model,  vertex_model); // world space
    float4 vertex_screen = mul(uniforms.screen_from_world, vertex_world); // screen space
    output.pos = vertex_screen;

    output.view_dir = uniforms.camera_position - vertex_world.xyz;

    output.color = float3(max(dot(uniforms.lightdir, input.norm), 0.01));

    output.texcoord = input.texcoord;

    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_TARGET {
    float2 coords = float2(input.texcoord.x, 1.0 - input.texcoord.y);
    float4 col = float4(1.0);

#ifdef ENABLE_DIFFUSE
    col *= tex_diffuse.Sample(coords);
#endif

#ifdef ENABLE_EMISSIVE
    float4 emissive = tex_emmisive.Sample(coords);
    col += emissive;
#endif

#ifdef ENABLE_NORMAL
    float3 normal = tex_normal.Sample(input.texcoord).xyz;
    col.xyz += float3(dot(uniforms.lightdir, normal));
#else
    float3 normal = uniforms.lightdir;
#endif

#ifdef ENABLE_SPECULAR
    float3 reflected = reflect(-uniforms.lightdir, normal);
    float spec = pow(max(dot(reflected, input.view_dir), 0.0), 32.0);
    col.xyz += tex_specular.Sample(input.texcoord).xyz * spec;
#endif

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
