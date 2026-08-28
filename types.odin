package learnvk

import "base:runtime"
import "core:mem"
import "core:slice"
import "model"
import "vendor:glfw"
import vk "vendor:vulkan"

APP_NAME: cstring = "learnvk"
CURRENT_MODEL := ModelTag.bunny
LOAD_MODELS := bit_set[ModelTag] {
	CURRENT_MODEL,
	.bunny,
	.dragon,
	.viking_room,
	.dark_lord,
	.cacodemon,
	.sponza,
}
PIPELINE :: Pipeline.shader

CULL_MODE :: vk.CullModeFlags{.BACK}
MAX_MESH_NAME_LEN :: 64
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

DRAW_FILTER := #partial [ModelTag][]string {
	.viking_room = {"room"},
	.bunny       = {"mesh"},
	.dragon      = {"dragon"},
	.sponza      = {
		"sponza_00",
		"sponza_01",
		"sponza_03",
		"sponza_05",
		"sponza_06",
		"sponza_07",
		"sponza_08",
		"sponza_09",
		"sponza_10",
		"sponza_11",
		"sponza_12",
		"sponza_13",
		"sponza_14",
		"sponza_15",
		"sponza_16",
		"sponza_17",
		"sponza_18",
		"sponza_19",
		"sponza_20",
		"sponza_21",
		"sponza_22",
		"sponza_23",
		"sponza_24",
		"sponza_25",
		"sponza_26",
		"sponza_27",
		"sponza_28",
		"sponza_29",
		"sponza_30",
		"sponza_31",
		"sponza_32",
		"sponza_33",
		"sponza_34",
		"sponza_35",
		"sponza_36",
		"sponza_37",
		"sponza_38",
		"sponza_39",
		"sponza_40",
		"sponza_41",
		"sponza_42",
		"sponza_43",
		"sponza_44",
		"sponza_45",
		"sponza_46",
		"sponza_47",
		"sponza_48",
		"sponza_49",
		"sponza_50",
		"sponza_51",
		"sponza_52",
		"sponza_53",
		"sponza_54",
		"sponza_55",
		"sponza_56",
		"sponza_57",
		"sponza_58",
		"sponza_59",
		"sponza_60",
		"sponza_61",
		"sponza_62",
		"sponza_63",
		"sponza_64",
		"sponza_65",
		"sponza_66",
		"sponza_67",
		"sponza_68",
		"sponza_69",
		"sponza_70",
		"sponza_71",
		"sponza_72",
		"sponza_73",
		"sponza_74",
		"sponza_75",
		"sponza_76",
		"sponza_77",
		"sponza_78",
		"sponza_79",
		"sponza_80",
		"sponza_81",
		"sponza_82",
		"sponza_83",
		"sponza_84",
		"sponza_85",
		"sponza_86",
		"sponza_87",
		"sponza_88",
		"sponza_89",
		"sponza_90",
		"sponza_91",
		"sponza_92",
		"sponza_93",
		"sponza_94",
		"sponza_95",
		"sponza_96",
		"sponza_97",
		"sponza_98",
		"sponza_99",
		"sponza_100",
		"sponza_101",
		"sponza_102",
		"sponza_103",
		"sponza_104",
		"sponza_105",
		"sponza_106",
		"sponza_107",
		"sponza_108",
		"sponza_109",
		"sponza_110",
		"sponza_111",
		"sponza_112",
		"sponza_113",
		"sponza_114",
		"sponza_115",
		"sponza_116",
		"sponza_117",
		"sponza_118",
		"sponza_119",
		"sponza_120",
		"sponza_121",
		"sponza_122",
		"sponza_123",
		"sponza_124",
		"sponza_125",
		"sponza_126",
		"sponza_127",
		"sponza_128",
		"sponza_129",
		"sponza_130",
		"sponza_131",
		"sponza_132",
		"sponza_133",
		"sponza_134",
		"sponza_135",
		"sponza_136",
		"sponza_137",
		"sponza_138",
		"sponza_139",
		"sponza_140",
		"sponza_141",
		"sponza_142",
		"sponza_143",
		"sponza_144",
		"sponza_145",
		"sponza_146",
		"sponza_147",
		"sponza_148",
		"sponza_149",
		"sponza_150",
		"sponza_151",
		"sponza_152",
		"sponza_153",
		"sponza_154",
		"sponza_155",
		"sponza_156",
		"sponza_157",
		"sponza_158",
		"sponza_159",
		"sponza_160",
		"sponza_161",
		"sponza_162",
		"sponza_163",
		"sponza_164",
		"sponza_165",
		"sponza_166",
		"sponza_167",
		"sponza_168",
		"sponza_169",
		"sponza_170",
		"sponza_171",
		"sponza_172",
		"sponza_173",
		"sponza_174",
		"sponza_175",
		"sponza_176",
		"sponza_177",
		"sponza_178",
		"sponza_179",
		"sponza_180",
		"sponza_181",
		"sponza_182",
		"sponza_183",
		"sponza_184",
		"sponza_185",
		"sponza_186",
		"sponza_187",
		"sponza_188",
		"sponza_189",
		"sponza_190",
		"sponza_191",
		"sponza_192",
		"sponza_193",
		"sponza_194",
		"sponza_195",
		"sponza_196",
		"sponza_197",
		"sponza_198",
		"sponza_199",
		"sponza_200",
		"sponza_201",
		"sponza_202",
		"sponza_203",
		"sponza_204",
		"sponza_205",
		"sponza_206",
		"sponza_207",
		"sponza_208",
		"sponza_209",
		"sponza_210",
		"sponza_211",
		"sponza_212",
		"sponza_213",
		"sponza_214",
		"sponza_215",
		"sponza_216",
		"sponza_217",
		"sponza_218",
		"sponza_219",
		"sponza_220",
		"sponza_221",
		"sponza_222",
		"sponza_223",
		"sponza_224",
		"sponza_225",
		"sponza_226",
		"sponza_227",
		"sponza_228",
		"sponza_229",
		"sponza_230",
		"sponza_231",
		"sponza_232",
		"sponza_233",
		"sponza_234",
		"sponza_235",
		"sponza_236",
		"sponza_237",
		"sponza_238",
		"sponza_239",
		"sponza_240",
		"sponza_241",
		"sponza_242",
		"sponza_243",
		"sponza_244",
		"sponza_245",
		"sponza_246",
		"sponza_247",
		"sponza_248",
		"sponza_249",
		"sponza_250",
		"sponza_251",
		"sponza_252",
		"sponza_253",
		"sponza_254",
		"sponza_255",
		"sponza_256",
		"sponza_257",
		"sponza_258",
		"sponza_259",
		"sponza_260",
		"sponza_261",
		"sponza_262",
		"sponza_263",
		"sponza_264",
		"sponza_265",
		"sponza_266",
		"sponza_267",
		"sponza_268",
		"sponza_269",
		"sponza_270",
		"sponza_271",
		"sponza_272",
		"sponza_273",
		"sponza_274",
		"sponza_275",
		"sponza_276",
		"sponza_277",
		"sponza_278",
		"sponza_279",
		"sponza_280",
		"sponza_281",
		"sponza_282",
		"sponza_283",
		"sponza_284",
		"sponza_285",
		"sponza_286",
		"sponza_287",
		"sponza_288",
		"sponza_289",
		"sponza_290",
		"sponza_291",
		"sponza_292",
		"sponza_293",
		"sponza_294",
		"sponza_295",
		"sponza_296",
		"sponza_297",
		"sponza_298",
		"sponza_299",
		"sponza_300",
		"sponza_301",
		"sponza_302",
		"sponza_303",
		"sponza_304",
		"sponza_305",
		"sponza_306",
		"sponza_307",
		"sponza_308",
		"sponza_309",
		"sponza_310",
		"sponza_311",
		"sponza_312",
		"sponza_313",
		"sponza_314",
		"sponza_315",
		"sponza_316",
		"sponza_317",
		"sponza_318",
		"sponza_319",
		"sponza_320",
		"sponza_321",
		"sponza_322",
		"sponza_323",
		"sponza_324",
		"sponza_325",
		"sponza_326",
		"sponza_327",
		"sponza_328",
		"sponza_329",
		"sponza_330",
		"sponza_331",
		"sponza_332",
		"sponza_333",
		"sponza_334",
		"sponza_335",
		"sponza_336",
		"sponza_337",
		"sponza_338",
		"sponza_339",
		"sponza_340",
		"sponza_341",
		"sponza_342",
		"sponza_343",
		"sponza_344",
		"sponza_345",
		"sponza_346",
		"sponza_347",
		"sponza_348",
		"sponza_349",
		"sponza_350",
		"sponza_351",
		"sponza_352",
		"sponza_353",
		"sponza_354",
		"sponza_355",
		"sponza_356",
		"sponza_357",
		"sponza_358",
		"sponza_359",
		"sponza_360",
		"sponza_361",
		"sponza_362",
		"sponza_363",
		"sponza_364",
		"sponza_365",
		"sponza_366",
		"sponza_367",
		"sponza_368",
		"sponza_369",
		"sponza_370",
		"sponza_371",
		"sponza_372",
		"sponza_373",
		"sponza_374",
		"sponza_375",
		"sponza_376",
		"sponza_377",
		"sponza_378",
		"sponza_379",
		"sponza_380",
		"sponza_381",
		"sponza_382",
	},
	.cacodemon   = {
		"cacodemon_armor",
		"cacodemon_arms",
		"cacodemon_body",
		"cacodemon_eye",
		// "cacodemon_wounds",
	},
	.dark_lord   = {
		"darklord_mech_arm",
		// "darklord_mech_arm_rt_wounds",
		"darklord_mech_cannon",
		"darklord_mech_canopy",
		// "darklord_mech_canopy_wounds",
		"darklord_mech_hand",
		// "darklord_mech_hand_rt_wounds",
		"darklord_mech_helmet",
		// "darklord_mech_helmet_wounds",
		"darklord_mech_leg",
		// "darklord_mech_leg_lf_wounds",
		// "darklord_mech_leg_rt_wounds",
		// "darklord_mech_shield",
		// "darklord_mech_shield_buckler",
		"darklord_mech_shoulder",
		// "darklord_mech_shoulder_rt_wounds",
		"darklord_mech_skirt",
		// "darklord_mech_skirt_lf_wounds",
		// "darklord_mech_skirt_rt_wounds",
		// "darklord_mech_sword",
		// "darklord_mech_sword_effect",
		// "darklord_mech_sword_hilt",
		"darklord_mech_torso",
		// "darklord_mech_torso_wounds",
	},
}

FLIP_TEXCOORDS_ON_LOAD := #partial [ModelTag]struct {
	flipx: bool,
	flipy: bool,
} {
	.viking_room = {flipx = false, flipy = true},
	.cacodemon = {flipx = false, flipy = false},
}

Model :: model.Bob

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
	enable_bump,
	enable_specular,
}

ShaderUniforms :: struct #all_or_none #align (16) {
	screen_from_world: matrix[4, 4]f32,
	world_from_model:  matrix[4, 4]f32,
	model_from_vertex: matrix[4, 4]f32,

	//
	light_dir:         [4]f32,
	light_color:       [4]f32,
	camera_position:   [4]f32,
	ambient_light:     f32,
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
	model_data_on_gpu:                      bit_set[ModelTag],
	model_mesh_info:                        [ModelTag][]struct {
		index_start: u32,
		index_count: u32,
		name:        [dynamic; MAX_MESH_NAME_LEN]byte,
	},
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

