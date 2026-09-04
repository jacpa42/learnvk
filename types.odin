package learnvk

import "base:runtime"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "model"
import "vendor:glfw"
import vk "vendor:vulkan"

APP_NAME: cstring = "learnvk"
CURRENT_MODEL := ModelTag.bunny
LOAD_MODELS := bit_set[ModelTag] {
	CURRENT_MODEL,
	.viking_room,
	.bunny,
	// .cacodemon,
	// .dragon,
	// .dark_lord,
	// .sponza,
}
PIPELINE :: Pipeline.shader

MAX_DRAW_COMMANDS :: 1024
MAX_INSTANCES :: bits.U16_MAX
ENGINE_ARENA_SIZE :: 1 * mem.Megabyte

CULL_MODE :: vk.CullModeFlags{.BACK}
MAX_MESH_NAME_LEN :: 32
ENABLE_DEPTH_TEST :: true
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG
FRONT_FACE :: vk.FrontFace.CLOCKWISE
LINE_WIDTH: f32 : 1
MAX_DYNAMIC_STATE :: 90
MAX_MESH_TEXTURES :: 64
MAX_SWAPCHAIN_IMAGES :: 8
NUM_MODELS :: len(ModelTag)
POLYGON_MODE :: vk.PolygonMode.FILL
PRIMITIVE_TOPOLOGY :: vk.PrimitiveTopology.TRIANGLE_LIST
STAGING_BUFFER_SIZE :: 24 * mem.Megabyte

NO_TEXTURE: TextureID : -1
NO_MATERIAL :: Material{NO_TEXTURE, NO_TEXTURE, NO_TEXTURE, NO_TEXTURE}

VULKAN_API_VERSION :: vk.API_VERSION_1_3
REQUIRED_PHYSICAL_DEVICE_EXTENSIONS := [5]cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
	vk.KHR_SHADER_DRAW_PARAMETERS_EXTENSION_NAME,
	vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
}

to_bytes :: slice.to_bytes

OBJ_PATH := [ModelTag]string {
	.bunny       = "assets/bunny/bunny.obj",
	.dark_lord   = "assets/darklord/darklord.obj",
	.dragon      = "assets/dragon/dragon.obj",
	.viking_room = "assets/viking_room/viking_room.obj",
	.sponza      = "assets/sponza/sponza.obj",
	.cacodemon   = "assets/doom-eternal-cacodemon/cacodemon_LOD0.obj",
	.dancersword = "assets/dancersword/dancer-swords.obj",
}

BOB_PATH := [ModelTag]string {
	.bunny       = "assets/bunny/bunny.bob",
	.dark_lord   = "assets/darklord/darklord.bob",
	.dragon      = "assets/dragon/dragon.bob",
	.viking_room = "assets/viking_room/viking_room.bob",
	.sponza      = "assets/sponza/sponza.bob",
	.cacodemon   = "assets/doom-eternal-cacodemon/cacodemon_LOD0.bob",
	.dancersword = "assets/dancersword/dancer-swords.bob",
}

FLIP_TEXCOORDS_ON_LOAD := #partial [ModelTag]struct {
	flipx: bool,
	flipy: bool,
} {
	.viking_room = {flipx = false, flipy = true},
	.cacodemon = {flipx = false, flipy = false},
	.dark_lord = {flipx = false, flipy = true},
}

Model :: type_of(Engine{}.models[ModelTag(0)])

Image :: struct {
	image: vk.Image,
	view:  vk.ImageView,
}

MaterialType :: enum {
	diffuse,
	emissive,
	bump,
	specular,
}

Texture :: struct #all_or_none {
	// This is the index into the shader's texture list where this texture is
	image: vk.Image,
	view:  vk.ImageView,
}

// odinfmt: disable
#assert(len(MemoryTypeIndex) == 32)
MemoryTypeIndex :: enum {
    _00, _01, _02, _03, _04, _05, _06, _07,
    _08, _09, _0A, _0B, _0C, _0D, _0E, _0F,
    _10, _11, _12, _13, _14, _15, _16, _17,
    _18, _19, _1A, _1B, _1C, _1D, _1E, _1F,
}
// odinfmt: enable

ModelTag :: enum {
	viking_room,
	bunny,
	dragon,
	cacodemon,
	dark_lord,
	dancersword,
	sponza,
}

ImageViewTag :: enum {
	swapchain,
	model_texture,
	depth_buffer,
}

UniformFlag :: enum {
	enable_diffuse,
	enable_emissive,
	enable_bump,
	enable_specular,
}

FrameBufferData :: struct #align (16) {
	uniforms:            ShaderUniforms,
	draw_commands:       [MAX_DRAW_COMMANDS]vk.DrawIndexedIndirectCommand,
	instance_textures:   [MAX_INSTANCES]ShaderInstanceTextures,
	instance_transforms: [MAX_INSTANCES]ShaderInstanceTransforms,
}

ShaderUniforms :: struct #all_or_none #align (16) {
	screen_from_world: matrix[4, 4]f32,

	//
	light_position:    [4]f32,
	light_color:       [4]f32,
	camera_position:   [4]f32,
	ambient_light:     f32,
	flags:             bit_set[UniformFlag;u32],
}

IndexRange :: struct {
	start, count: u32,
}

MeshInfo :: struct #all_or_none {
	model_from_vertex: matrix[4, 4]f32,
	name:              string,
	index_start:       u32,
	index_count:       u32,
	vertex_offset:     i32,
	// indexes into the material list
	material_id:       MaterialID,
}

TextureID :: distinct i32

MaterialID :: distinct i32

Material :: struct #all_or_none {
	diffuse_id:  TextureID,
	emissive_id: TextureID,
	bump_id:     TextureID,
	specular_id: TextureID,
}

TextureList :: []Texture

ShaderInstanceTransforms :: struct #all_or_none {
	world_from_model:  matrix[4, 4]f32,
	model_from_vertex: matrix[4, 4]f32,
	normal_matrix:     matrix[4, 4]f32,
}

ShaderInstanceTextures :: struct #all_or_none {
	diffuse_id:  TextureID,
	emissive_id: TextureID,
	bump_id:     TextureID,
	specular_id: TextureID,
}
#assert(size_of(ShaderInstanceTextures) == 4 * size_of(TextureID))

DataBufferTag :: enum {
	// model data buffers
	vertex,
	index,
}

Action :: enum {
	up,
	down,
	forward,
	backward,
	left,
	right,
}

Engine :: struct {
	//
	// Windowing stuff
	//
	window:                   glfw.WindowHandle,
	stop_rendering:           bool,
	framebuffer_resized:      bool,
	model_loaded:             bit_set[ModelTag],
	models:                   [ModelTag]model.Bob,

	// used for all small allocations
	arena:                    mem.Arena,

	//
	// Vulkan stuff
	//
	alloc:                    ^vk.AllocationCallbacks,
	messenger:                vk.DebugUtilsMessengerEXT,
	instance:                 vk.Instance,

	//
	// Stuff for eye position
	//
	actions:                  bit_set[Action],
	disable_rotate:           bool,
	model_rotation:           f32,
	delta_time:               f32,
	camera:                   Camera,
	shader_flags:             bit_set[UniformFlag;u32],

	//
	// Physical and Logical device
	//
	physical_device:          vk.PhysicalDevice,
	device:                   vk.Device,
	queue:                    vk.Queue,
	queue_index:              u32,
	surface:                  vk.SurfaceKHR,

	//
	// Swapchain
	//
	min_image_count:          u32,
	swapchain:                vk.SwapchainKHR,
	swapchain_surface_format: vk.SurfaceFormatKHR,
	swapchain_extent:         vk.Extent2D,
	image_index:              u32,
	swapchain_images:         [dynamic; MAX_SWAPCHAIN_IMAGES]vk.Image,
	swapchain_image_views:    [dynamic; MAX_SWAPCHAIN_IMAGES]vk.ImageView,

	//
	// Descriptor sets
	//
	descriptor_pool:          vk.DescriptorPool,
	set_layout:               vk.DescriptorSetLayout,
	descriptor_set:           vk.DescriptorSet,

	//
	// All our gpu memory is here
	//
	transfer_queue:           GpuTransferQueue,
	frame_data:               MappedBuffer(FrameBufferData),
	model_arena:              GpuArena,
	texture_arena:            GpuArena,

	//
	// Transfer queue
	//

	//
	// Mesh data
	//
	data_buffer:              [DataBufferTag]vk.Buffer,
	image_sampler:            vk.Sampler,
	model_mesh_ranges:        [ModelTag]IndexRange,
	mesh_data:                [dynamic]MeshInfo,
	material_list:            [dynamic]Material,
	texture_list:             [dynamic]Texture,

	//
	// Depth image
	//
	depth_image_format:       vk.Format,
	depth_image:              vk.Image,
	depth_image_memory:       vk.DeviceMemory,
	depth_image_view:         vk.ImageView,

	//
	// Pipeline
	//
	pipeline_cache:           vk.PipelineCache,
	render_pipeline:          vk.Pipeline,
	viewport:                 vk.Viewport,
	scissor:                  vk.Rect2D,
	color_attachment:         vk.PipelineColorBlendAttachmentState,
	pipeline_dynamic_state:   [dynamic; MAX_DYNAMIC_STATE]vk.DynamicState,
	pipeline_shader:          vk.ShaderModule,
	pipeline_layout:          vk.PipelineLayout,

	//
	// Command buffer
	//
	cmdpool:                  vk.CommandPool,
	cmdbuf:                   vk.CommandBuffer,
	swapchain_semas:          [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	present_complete_sema:    vk.Semaphore,
	draw_fence:               vk.Fence,
}

