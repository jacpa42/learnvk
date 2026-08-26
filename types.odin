package learnvk

import "base:runtime"
import "core:mem"
import "core:slice"
import "model"
import "vendor:glfw"
import vk "vendor:vulkan"

APP_NAME: cstring = "learnvk"
CURRENT_MODEL := ModelTag.cacodemon
LOAD_MODELS := bit_set[ModelTag]{CURRENT_MODEL}
PIPELINE :: Pipeline.shader

CULL_MODE :: vk.CullModeFlags{.BACK}
ENABLE_DEPTH_TEST :: true
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG
FRAMES_IN_FLIGHT :: 2
FRONT_FACE :: vk.FrontFace.CLOCKWISE
LINE_WIDTH: f32 : 1
MAX_DYNAMIC_STATE :: 90
MAX_MESH_TEXTURES :: 64
MAX_PHYSICAL_DEVICE_EXTENSIONS :: 4
MAX_SWAPCHAIN_IMAGES :: 8
NUM_MODELS :: len(ModelTag)
POLYGON_MODE :: vk.PolygonMode.FILL
PRIMITIVE_TOPOLOGY :: vk.PrimitiveTopology.TRIANGLE_LIST
STAGING_BUFFER_SIZE :: 128 * mem.Megabyte
VULKAN_API_VERSION :: vk.API_VERSION_1_3

to_bytes :: slice.to_bytes

OBJ_PATH := [ModelTag]string {
	.bunny       = "assets/bunny/bunny.obj",
	.dark_lord   = "assets/darklord/darklord.obj",
	.dragon      = "assets/dragon/dragon.obj",
	.viking_room = "assets/viking_room/viking_room.obj",
	.sponza      = "assets/sponza/sponza.obj",
	.cacodemon   = "assets/doom-eternal-cacodemon/cacodemon_LOD0.obj",
}

BOB_PATH := [ModelTag]string {
	.bunny       = "assets/bunny/bunny.bob",
	.dark_lord   = "assets/darklord/darklord.bob",
	.dragon      = "assets/dragon/dragon.bob",
	.viking_room = "assets/viking_room/viking_room.bob",
	.sponza      = "assets/sponza/sponza.bob",
	.cacodemon   = "assets/doom-eternal-cacodemon/cacodemon_LOD0.bob",
}

FLIP_TEXCOORDS_ON_LOAD := #partial [ModelTag]struct {
	flipx: bool,
	flipy: bool,
} {
	.viking_room = {flipx = false, flipy = true},
	.cacodemon = {flipx = false, flipy = true},
}

Model :: model.Bob

Image :: struct {
	image: vk.Image,
	view:  vk.ImageView,
}

MaterialType :: enum {
	diffuse,
	emissive,
	normal,
	specular,
}

Texture :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	memory: vk.DeviceMemory,
}

ModelTag :: enum {
	bunny,
	dragon,
	viking_room,
	dark_lord,
	cacodemon,
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
	enable_height,
	enable_specular,
}

Uniforms :: struct #all_or_none #align (16) {
	screen_from_world: matrix[4, 4]f32,
	world_from_model:  matrix[4, 4]f32,
	model_from_vertex: matrix[4, 4]f32,
	light_dir:         [4]f32,
	light_color:       [4]f32,
	camera_position:   [4]f32,
	flags:             bit_set[UniformFlag;u32],
}

ModelBuffer :: enum {
	// model data buffers
	model_vertices,
	model_indices,
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
	window:                                 glfw.WindowHandle,
	stop_rendering:                         bool,
	framebuffer_resized:                    bool,
	model_loaded:                           bit_set[ModelTag],
	models:                                 [ModelTag]Model,

	//
	// Vulkan stuff
	//
	vk_alloc:                               vk.AllocationCallbacks,
	vk_messenger:                           vk.DebugUtilsMessengerEXT,
	vk_instance:                            vk.Instance,

	//
	// Stuff for eye position
	//
	actions:                                bit_set[Action],
	disable_rotate:                         bool,
	model_rotation:                         f32,
	delta_time:                             f32,
	camera:                                 Camera,
	shader_flags:                           bit_set[UniformFlag;u32],

	//
	// Physical and Logical device
	//
	vk_physical_device:                     vk.PhysicalDevice,
	vk_physical_device_required_extensions: [dynamic; MAX_PHYSICAL_DEVICE_EXTENSIONS]cstring,
	vk_device:                              vk.Device,
	vk_queue:                               vk.Queue,
	vk_render_queue_index:                  u32,
	vk_surface:                             vk.SurfaceKHR,

	//
	// Swapchain
	//
	vk_min_image_count:                     u32,
	vk_swapchain:                           vk.SwapchainKHR,
	vk_swapchain_surface_format:            vk.SurfaceFormatKHR,
	vk_swapchain_extent:                    vk.Extent2D,
	vk_image_index:                         u32,
	vk_swapchain_images:                    [dynamic; MAX_SWAPCHAIN_IMAGES]vk.Image,
	vk_swapchain_image_views:               [dynamic; MAX_SWAPCHAIN_IMAGES]vk.ImageView,

	//
	// Descriptor sets
	//
	vk_descriptor_pool:                     vk.DescriptorPool,
	vk_set_layout:                          vk.DescriptorSetLayout,
	// one per mesh
	vk_descriptor_sets:                     [ModelTag][]vk.DescriptorSet,

	//
	// Uniform Buffers
	//
	vk_uniform_buffers:                     [FRAMES_IN_FLIGHT]vk.Buffer,
	vk_uniform_buffers_memory:              [FRAMES_IN_FLIGHT]vk.DeviceMemory,
	vk_uniform_buffers_mmapped:             [FRAMES_IN_FLIGHT]rawptr,

	//
	// Vertex Buffers
	//
	vk_transfer_buffer_mmap:                rawptr,
	vk_transfer_buffer:                     vk.Buffer,
	vk_transfer_buffer_memory:              vk.DeviceMemory,
	vk_model_buffer:                        [ModelTag][ModelBuffer]vk.Buffer,
	vk_vertex_buffers_memory:               [ModelTag][ModelBuffer]vk.DeviceMemory,

	//
	// mesh textures
	//
	fallback_texture:                       Texture,

	// One for each mesh in each model
	vk_mesh_images:                         [ModelTag][][MaterialType]Texture,

	// one allocation for all images
	vk_image_sampler:                       [MaterialType]vk.Sampler,

	//
	// Depth image
	//
	vk_depth_image_format:                  vk.Format,
	vk_depth_image:                         vk.Image,
	vk_depth_image_view:                    vk.ImageView,
	vk_depth_image_memory:                  vk.DeviceMemory,

	//
	// Pipeline
	//
	vk_pipeline_cache:                      vk.PipelineCache,
	vk_render_pipeline:                     vk.Pipeline,
	vk_viewport:                            vk.Viewport,
	vk_scissor:                             vk.Rect2D,
	vk_color_attachment:                    vk.PipelineColorBlendAttachmentState,
	vk_pipeline_dynamic_state:              [dynamic; MAX_DYNAMIC_STATE]vk.DynamicState,
	vk_pipeline_shader:                     vk.ShaderModule,
	vk_pipeline_layout:                     vk.PipelineLayout,

	//
	// Command buffer
	//
	vk_cmdpool:                             vk.CommandPool,
	vk_frame_index:                         u32,
	vk_cmdbufs:                             [FRAMES_IN_FLIGHT]vk.CommandBuffer,
	vk_swapchain_semas:                     [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	vk_present_complete_semas:              [FRAMES_IN_FLIGHT]vk.Semaphore,
	vk_draw_fences:                         [FRAMES_IN_FLIGHT]vk.Fence,
}

