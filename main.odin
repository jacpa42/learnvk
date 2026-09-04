package learnvk

import "core:mem"

//
// TODO: Figure out how to use an array of samplers
//

import "base:runtime"
import "core:c"
import "core:debug/trace"
import "core:log"
import "core:math/bits"
import "core:slice"
import "model"
import "vendor:glfw"
import vk "vendor:vulkan"

g_logger: runtime.Logger
physical_device_features: vk.PhysicalDeviceFeatures
physical_device_properties: vk.PhysicalDeviceProperties
physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties

main :: proc() {
	//
	// Setup tracking allocator
	//
	when ODIN_DEBUG {
		track: trace.Tracking_Allocator
		trace.tracking_allocator_init(&track, context.allocator)
		defer trace.tracking_allocator_destroy(&track)

		context.allocator = trace.tracking_allocator(&track)
		defer trace.tracking_allocator_print_results(&track)

		context.assertion_failure_proc = trace.assertion_failure_proc

	}

	g_logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	context.logger = g_logger
	defer log.destroy_console_logger(context.logger)


	//
	// Init engine
	//
	engine: Engine
	engine_init(&engine)
	defer engine_destroy(&engine)

	imgui_init(&engine)
	defer imgui_destroy(&engine)

	MS_PER_FRAME :: 16_666_666
	MS_PER_FRAME_F32 :: MS_PER_FRAME * 1e-9

	//
	// Main loop
	//
	for !glfw.WindowShouldClose(engine.window) {
		glfw.PollEvents()

		if engine.stop_rendering {
			glfw.WaitEvents()
			continue
		}

		frame(&engine)

		free_all(context.temp_allocator)
	}
}

engine_init :: proc(engine: ^Engine) {
	result: vk.Result


	//
	// Initialize GLFW and create our window
	//
	{
		glfw.SetErrorCallback(glfw_error_callback)
		ensure(bool(glfw.Init()), "Failed to initialize GLFW")
		ensure(bool(glfw.VulkanSupported()), "Vulkan is not supported")

		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
		engine.window = glfw.CreateWindow(1280, 678, APP_NAME, nil, nil)
		assert(engine.window != nil, "Failed to create a GLFW window")

		glfw.SetWindowUserPointer(engine.window, engine)
		glfw.SetKeyCallback(engine.window, callback_key)
		glfw.SetScrollCallback(engine.window, callback_scroll)
		glfw.SetCursorPosCallback(engine.window, callback_cursor_move)
		glfw.SetFramebufferSizeCallback(engine.window, callback_framebuffer_size)
		glfw.SetWindowIconifyCallback(engine.window, callback_window_minimize)
		glfw.SetInputMode(engine.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	}

	//
	// initialize the engine arena for all our small allocations
	//
	mem.arena_init(&engine.arena, make([]byte, ENGINE_ARENA_SIZE))

	//
	// Setup the default state to generate the uniforms
	//
	engine.camera = {
		speed       = 0.01,
		sensitivity = 0.0005,
		pitch       = 0,
		yaw         = 0,
		pos         = {0, 0, 0, 0},
		up          = {0, 0, -1},
	}

	//
	// Load the models we want to look at
	//

	for tag in LOAD_MODELS {
		res: model.Result
		m := &engine.models[tag]

		when type_of(engine.models[tag]) == model.Bob {
			model_path := BOB_PATH[tag]
			res = model.bob_load_or_create(
				m,
				model_path,
				OBJ_PATH[tag],
				flipx = FLIP_TEXCOORDS_ON_LOAD[tag].flipx,
				flipy = FLIP_TEXCOORDS_ON_LOAD[tag].flipy,
			)
		} else {
			model_path := OBJ_PATH[tag]
			res = model.obj_load(
				m,
				model_path,
				flipx = FLIP_TEXCOORDS_ON_LOAD[tag].flipx,
				flipy = FLIP_TEXCOORDS_ON_LOAD[tag].flipy,
			)
		}

		if res == .Ok do engine.model_loaded |= {tag}
		if res != .Ok do log.errorf("Failed to load \"{}\": {}", model_path, res)
	}

	assert(card(engine.model_loaded) > 0)
	assert(CURRENT_MODEL in engine.model_loaded)

	//
	// Load all Vulkan global functions (ie without having an instance yet)
	//
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	//
	// Create the Vulkan allocator
	//
	engine.alloc = vk_alloc_init()

	//
	// Create the Vulkan Instance
	//
	engine_init_instance(engine)

	//
	// Create the window surface
	//
	{
		result = glfw.CreateWindowSurface(
			engine.instance,
			engine.window,
			engine.alloc,
			&engine.surface,
		)
		assert(result == .SUCCESS)
		assert(engine.surface != {})
	}

	//
	// Load Vulkan function pointers
	//
	vk.GetInstanceProcAddr = auto_cast glfw.GetInstanceProcAddress
	vk.load_proc_addresses(engine.instance)

	//
	// Create the messenger
	//
	{
		create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING},
			pfnUserCallback = vulkan_validation_callback,
		}
		result = vk.CreateDebugUtilsMessengerEXT(
			engine.instance,
			&create_info,
			engine.alloc,
			&engine.messenger,
		)
		assert(result == .SUCCESS)
	}

	//
	// Choose a physical device
	//
	engine_init_physical_device(engine)

	//
	// Create the logical device
	//
	engine_init_logical_device(engine)

	//
	// Initialize the command buffers
	//
	engine_init_command_buffers(engine)

	//
	// Create the swapchain
	//
	engine_init_swapchain(engine)

	//
	// Define and create the pipeline cache
	//
	{
		cache_create_info := vk.PipelineCacheCreateInfo {
			sType           = .PIPELINE_CACHE_CREATE_INFO,
			initialDataSize = 0,
			pInitialData    = nil,
		}
		result = vk.CreatePipelineCache(
			engine.device,
			&cache_create_info,
			engine.alloc,
			&engine.pipeline_cache,
		)
		assert(result == .SUCCESS)
	}

	//
	// Initialize the graphics pipelines
	//
	engine_init_graphics_pipeline(engine)

	//
	// Assert that all the data has been sent to the gpu
	//
	queue_flush(&engine.transfer_queue, engine.device, engine.queue)

	//
	// We have uploaded all our model data and texture data, free everything
	//
	for tag in engine.model_loaded do model.destroy(&engine.models[tag])
}

engine_init_instance :: proc(engine: ^Engine) {
	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pNext              = nil,
		pApplicationName   = APP_NAME,
		applicationVersion = vk.MAKE_VERSION(0, 0, 1),
		pEngineName        = "no engine",
		engineVersion      = vk.MAKE_VERSION(0, 0, 1),
		apiVersion         = VULKAN_API_VERSION,
	}

	//
	// Find all desired & supported layers
	//
	desired_layers: [dynamic; 16]cstring
	when ENABLE_VALIDATION_LAYERS {
		append(&desired_layers, "LAYER_KHRONOS_validation")

		count: u32
		assert(vk.EnumerateInstanceLayerProperties(&count, nil) == .SUCCESS)
		assert(count > 0)

		supported_layers := make([]vk.LayerProperties, count, context.temp_allocator)
		assert(vk.EnumerateInstanceLayerProperties(&count, raw_data(supported_layers)) == .SUCCESS)

		i := 0
		for i < len(desired_layers) {
			// Check if the layer is supported
			is_supported := false
			support_check: for &supported in supported_layers {
				if desired_layers[i] == transmute(cstring)(&supported.layerName) {
					is_supported = true
					break support_check
				}
			}

			if !is_supported {
				log.warnf("VK :: Validation Layer \"{}\" is not supported.", desired_layers[i])
				unordered_remove(&desired_layers, i)
			} else {
				i += 1
			}
		}
	}

	//
	// Find all the desired+required extensions
	//
	my_extensions := []cstring{vk.EXT_DEBUG_UTILS_EXTENSION_NAME}
	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	required_extensions := slice.concatenate(
		[][]cstring{glfw_extensions, my_extensions},
		allocator = context.temp_allocator,
	)

	//
	// Create the instance
	//
	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,

		// validation layers
		enabledLayerCount       = u32(len(desired_layers)),
		ppEnabledLayerNames     = raw_data(desired_layers[:]),

		// extensions
		enabledExtensionCount   = u32(len(required_extensions)),
		ppEnabledExtensionNames = raw_data(required_extensions),
	}

	result := vk.CreateInstance(&create_info, engine.alloc, &engine.instance)
	assert(result == .SUCCESS)
}

engine_init_graphics_pipeline :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Create the shader module
	//
	{
		shader_module_create_info := vk.ShaderModuleCreateInfo {
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = slice.size(PIPELINE_BYTE_CODE[PIPELINE]),
			pCode    = raw_data(PIPELINE_BYTE_CODE[PIPELINE]),
		}

		result = vk.CreateShaderModule(
			engine.device,
			&shader_module_create_info,
			engine.alloc,
			&engine.pipeline_shader,
		)
		assert(result == .SUCCESS)
	}

	//
	// For each stage that the shader defines, define the stage creation info
	//
	assert(len(PIPELINE_STAGES) == len(PIPELINE_STAGE_NAMES))
	shader_stage_create_info: [dynamic; PIPELINE_MAX_STAGES]vk.PipelineShaderStageCreateInfo

	for shader_stages, stage_index in PIPELINE_STAGES[PIPELINE] {
		append(
			&shader_stage_create_info,
			vk.PipelineShaderStageCreateInfo {
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				flags = {},
				stage = {shader_stages},
				module = engine.pipeline_shader,
				pName = PIPELINE_STAGE_NAMES[PIPELINE][stage_index],
				pSpecializationInfo = nil,
			},
		)
	}

	//
	// Setup dynamic state for the pipeline. At the moment, just viewport and scissor.
	//
	append(&engine.pipeline_dynamic_state, ..[]vk.DynamicState{.VIEWPORT, .SCISSOR})

	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(engine.pipeline_dynamic_state)),
		pDynamicStates    = raw_data(engine.pipeline_dynamic_state[:]),
	}

	//
	// Setup the vertex data for the pipeline
	//

	vertex_create_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,

		// vertex bindings
		vertexBindingDescriptionCount   = u32(len(PIPELINE_VERTEX_BINDING[PIPELINE])),
		pVertexBindingDescriptions      = raw_data(PIPELINE_VERTEX_BINDING[PIPELINE]),

		// vertex attribute
		vertexAttributeDescriptionCount = u32(len(PIPELINE_VERTEX_ATTRIBUTE[PIPELINE])),
		pVertexAttributeDescriptions    = raw_data(PIPELINE_VERTEX_ATTRIBUTE[PIPELINE]),
	}

	//
	// Define the `shape` (kinda) of the vertices
	//
	input_assembly_create_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = PRIMITIVE_TOPOLOGY,
		primitiveRestartEnable = false,
	}

	viewport_create_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = nil, // Set at drawing time via dynamic state
		scissorCount  = 1,
		pScissors     = nil, // Set at drawing time via dynamic state
	}

	//
	// Setup the pasteuriser struct
	//
	raster_create_info := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = POLYGON_MODE,
		cullMode    = CULL_MODE,
		frontFace   = FRONT_FACE,
		lineWidth   = LINE_WIDTH,
	}

	//
	// Define Multi-sampling state
	//

	// TODO: Actually use multisampling. At the moment, it is disabled
	multisample_create_info := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	//
	// Define colour blending state
	//

	// Only one color attachment for now
	engine.color_attachment = {
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}

	color_blend_create_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &engine.color_attachment,
	}

	//
	// Load all our textures into memory. This is needed before we allocate gpu
	// memory.
	//
	load_tasks := engine_define_load_tasks(engine)
	engine_process_load_tasks(engine, load_tasks[:])
	defer destroy_load_tasks(&load_tasks)

	//
	// Initialize the upload queue
	//
	queue_init(
		queue = &engine.transfer_queue,
		device = engine.device,
		alloc = engine.alloc,
		transfer_buf_size = STAGING_BUFFER_SIZE,
		cmdpool = engine.cmdpool,
	)

	// TODO: Maybe this is not always possible? to get device local , host
	// visible and host coherent?

	//
	// Create the per-frame mapped buffer
	//
	result = mapped_buffer_init(
		device = engine.device,
		mbuf = &engine.frame_data,
		alloc = engine.alloc,
		usage = {.UNIFORM_BUFFER, .INDIRECT_BUFFER, .STORAGE_BUFFER},
		required_properties = {.DEVICE_LOCAL, .HOST_VISIBLE, .HOST_COHERENT},
	)
	assert(result == .SUCCESS)

	//
	// Initialize the textures
	//
	engine_init_textures(engine, load_tasks)

	//
	// Initialize the model buffers
	//
	result = engine_init_model_buffers(engine)
	assert(result == .SUCCESS)

	//
	// Create the sampler
	//
	sampler_create_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		flags                   = {},
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .LINEAR, // SamplerMipmapMode,
		addressModeU            = .REPEAT, // SamplerAddressMode,
		addressModeV            = .REPEAT, // SamplerAddressMode,
		addressModeW            = .REPEAT, // SamplerAddressMode,
		mipLodBias              = 0, // f32,
		anisotropyEnable        = true, // b32,
		maxAnisotropy           = physical_device_properties.limits.maxSamplerAnisotropy, // f32,
		compareEnable           = false, // b32,
		compareOp               = .ALWAYS, // CompareOp,
		minLod                  = 0, // f32,
		maxLod                  = 0, // f32,
		borderColor             = .INT_OPAQUE_BLACK, // BorderColor,
		unnormalizedCoordinates = false, // b32,
	}

	result = vk.CreateSampler(
		engine.device,
		&sampler_create_info,
		engine.alloc,
		&engine.image_sampler,
	)
	assert(result == .SUCCESS)


	//
	// Create the descriptor sets/set_layouts for all the models and the uniform
	// buffer.
	//
	engine_init_descriptor_set_layouts(engine)

	//
	// Define and create the pipeline layout
	//
	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,

		// set layouts
		setLayoutCount         = 1,
		pSetLayouts            = &engine.set_layout,

		// push constants
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	result = vk.CreatePipelineLayout(
		engine.device,
		&pipeline_layout_create_info,
		engine.alloc,
		&engine.pipeline_layout,
	)
	assert(result == .SUCCESS)
	assert(engine.pipeline_layout != {})

	//
	// Define the depth stencil state for the pipeline
	//
	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		flags            = {},
		depthTestEnable  = ENABLE_DEPTH_TEST,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,

		// stencilTestEnable     = false,
		// front:                 StencilOpState,
		// back:                  StencilOpState,

		// depthBoundsTestEnable = true,
		// minDepthBounds        = 0,
		// maxDepthBounds        = 10,
	}

	//
	// Define the rendering pipeline
	//
	render_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,

		// We are using 1 color attachment with the same format as our
		// surface.
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &engine.swapchain_surface_format.format,
		depthAttachmentFormat   = engine.depth_image_format,
		viewMask                = {}, // unused 2026-08-07
		stencilAttachmentFormat = {}, // unused 2026-08-07
	}

	//
	// Define the graphics pipeline layout struct
	//
	pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,

		// Define pnext because according to the docs:
		//
		// ```
		//      When a pipeline is created without a RenderPass, if the pNext
		//      chain of GraphicsPipelineCreateInfo includes this structure,
		//      it specifies the view mask and format of attachments used for
		//      rendering. If this structure is not specified, and the pipeline
		//      does not include a RenderPass, viewMask and
		//      colorAttachmentCount are 0, and depthAttachmentFormat and
		//      stencilAttachmentFormat are FORMAT_UNDEFINED. If a graphics
		//      pipeline is created with a valid RenderPass, parameters of
		//      this structure are ignored.
		// ```
		//
		pNext               = &render_create_info,
		renderPass          = {},
		subpass             = {},

		// Actually a lot of flags here
		flags               = {},
		stageCount          = u32(len(PIPELINE_STAGES)),
		pStages             = &shader_stage_create_info[0],
		pVertexInputState   = &vertex_create_info,
		pInputAssemblyState = &input_assembly_create_info,
		pTessellationState  = nil,
		pViewportState      = &viewport_create_info,
		pRasterizationState = &raster_create_info,
		pMultisampleState   = &multisample_create_info,
		pDepthStencilState  = &depth_stencil_state,
		pColorBlendState    = &color_blend_create_info,
		pDynamicState       = &dynamic_state_create_info,
		layout              = engine.pipeline_layout,

		// NOTE: Used to derive a pipeline from another with
		// PipelineCreateFlag.DERIVATIVE. Leaving nil at the moment
		//
		basePipelineHandle  = {},
		basePipelineIndex   = {},
	}

	//
	// Create the graphics pipelines
	//
	result = vk.CreateGraphicsPipelines(
		engine.device,
		engine.pipeline_cache,
		1,
		&pipeline_create_info,
		engine.alloc,
		&engine.render_pipeline,
	)
	assert(result == .SUCCESS)
}

//
// At the end of this procedure, all my textures are defined in their proper
// location.
//
engine_init_textures :: proc(engine: ^Engine, texture_load_tasks: [dynamic]LoadTaskData) {
	result: vk.Result

	texture_arena_requirements := vk.MemoryRequirements {
		memoryTypeBits = bits.U32_MAX,
	}

	// Add the requirements for allocating all the textures
	for task in texture_load_tasks do if task.output.ok {
		USAGE :: vk.ImageUsageFlags{.SAMPLED, .TRANSFER_DST}
		FORMAT :: vk.Format.R8G8B8A8_SRGB
		w := u32(task.output.width)
		h := u32(task.output.height)

		req := get_memory_requirements_image(engine.device, FORMAT, USAGE, w, h)
		refine_memory_requirement(&texture_arena_requirements, req)
	}

	//
	// If we didn't need any texture space, just return
	//
	if texture_arena_requirements.size == 0 do return

	engine.texture_arena, result = gpu_arena_init(
		device = engine.device,
		alloc = engine.alloc,
		requirements = texture_arena_requirements,
		required_properties = {.DEVICE_LOCAL},
	); assert(result == .SUCCESS)

	//
	// Create the images
	//
	for t in texture_load_tasks do if t.output.ok {
		texture := &engine.texture_list[t.input.texture_id]

		image_create_info := vk.ImageCreateInfo {
			sType = .IMAGE_CREATE_INFO,
			imageType = .D2,
			format = .R8G8B8A8_SRGB,
			extent = {width = u32(t.output.width), height = u32(t.output.height), depth = 1},
			mipLevels = 1,
			arrayLayers = 1,
			samples = {._1},
			tiling = .OPTIMAL,
			usage = {.SAMPLED},
			sharingMode = .EXCLUSIVE,
		}
		result = vk.CreateImage(engine.device, &image_create_info, engine.alloc, &texture.image)
		assert(result == .SUCCESS)

		//
		// Allocate the image and bind the memory to it
		//
		_, result = gpu_arena_alloc_image(&engine.texture_arena, engine.device, texture.image)
		assert(result == .SUCCESS)

		//
		// Create the image view (after binding the memory)
		//
		image_view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = texture.image,
			viewType = .D2,
			format = image_create_info.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		result = vk.CreateImageView(engine.device, &image_view_create_info, engine.alloc, &texture.view)
		assert(result == .SUCCESS)

		//
		// Append the upload task to the queue
		//
		result = queue_append_whole_image(&engine.transfer_queue, engine.device, engine.queue, texture.image, image_create_info.extent, t.output.data)
		assert(result == .SUCCESS)
	}

	result = .SUCCESS
	return
}

//
// Create the model data arena and model buffers
//
engine_init_model_buffers :: proc(engine: ^Engine) -> (result: vk.Result) {
	model_arena_requirements := vk.MemoryRequirements {
		memoryTypeBits = bits.U32_MAX,
	}

	//
	// Combine the model data buffers into one massive buffer
	//
	buffer_info: [DataBufferTag]struct {
		size:  vk.DeviceSize,
		usage: vk.BufferUsageFlags,
	}
	for &info, tag in buffer_info {
		//
		// Get the memory requirements for the buffer
		//

		for model_tag in engine.model_loaded do switch tag {
		case .vertex:
			info.size += vk.DeviceSize(slice.size(model.get_vertices(engine.models[model_tag])))
			info.usage += {.VERTEX_BUFFER, .TRANSFER_DST}
		case .index:
			info.size += vk.DeviceSize(slice.size(model.get_all_indices(engine.models[model_tag])))
			info.usage += {.INDEX_BUFFER, .TRANSFER_DST}
		}

		requirements := get_memory_requirements_buffer(engine.device, info.size, info.usage)

		//
		// Refine the requirements for the model arena
		//
		refine_memory_requirement(&model_arena_requirements, requirements)
	}

	engine.model_arena = gpu_arena_init(
		device = engine.device,
		alloc = engine.alloc,
		requirements = model_arena_requirements,
		required_properties = {.DEVICE_LOCAL},
	) or_return

	//
	// Create the buffers and allocate them on the model arena
	//
	for info, buffer_tag in buffer_info {
		engine.data_buffer[buffer_tag] = engine_create_buffer(
			engine.device,
			engine.alloc,
			info.size,
			info.usage,
		) or_return

		//
		// Allocate all our model buffers in the arena
		//
		_ = gpu_arena_alloc_buffer(
			&engine.model_arena,
			engine.device,
			engine.data_buffer[buffer_tag],
		) or_return


		// Upload all the data to them
		upload_dest := engine.data_buffer[buffer_tag]
		upload_dest_offset: vk.DeviceSize

		for model_tag in engine.model_loaded {
			data: []byte
			defer upload_dest_offset += vk.DeviceSize(slice.size(data))

			switch buffer_tag {
			case .vertex:
				data = to_bytes(model.get_vertices(engine.models[model_tag]))
			case .index:
				data = to_bytes(model.get_all_indices(engine.models[model_tag]))
			}

			log.infof(
				"Uploading model data {}.{} (size {}Mib) -> {:x}[{}:{}]",
				model_tag,
				buffer_tag,
				f32(len(data)) / mem.Megabyte,
				upload_dest,
				upload_dest_offset,
				upload_dest_offset + vk.DeviceSize(slice.size(data)),
			)

			queue_append_whole_buffer(
				&engine.transfer_queue,
				engine.device,
				engine.queue,
				upload_dest,
				upload_dest_offset,
				data,
			)
		}
	}

	result = .SUCCESS
	return
}

engine_init_descriptor_set_layouts :: proc(engine: ^Engine) {
	result: vk.Result

	maxSets: u32
	pool_sizes: [ShaderBinding]vk.DescriptorPoolSize

	outer: for layout, tag in SHADER_PIPELINE_SET_LAYOUTS do switch tag {

	case .uniforms:
		pool_sizes[tag] = {layout.descriptorType, 1}
		maxSets += 1

	case .instance_transforms:
		pool_sizes[tag] = {layout.descriptorType, 1}
		maxSets += 1

	case .instance_textures:
		pool_sizes[tag] = {layout.descriptorType, 1}
		maxSets += 1

	//
	// this one is special its an array of textures
	//
	case .textures:
		texture_num := u32(len(engine.texture_list))
		pool_sizes[tag] = {layout.descriptorType, texture_num}
		maxSets += texture_num

		// WARN: I update the global variable here. I would define it in the
		// shader parser, but the count is dynamic so I don't.
		SHADER_PIPELINE_SET_LAYOUTS[.textures].descriptorCount = texture_num
	}

	//
	// Update the descriptor count to be equal to the
	//

	pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = maxSets,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = &pool_sizes[ShaderBinding(0)],
	}

	result = vk.CreateDescriptorPool(
		engine.device,
		&pool_create_info,
		engine.alloc,
		&engine.descriptor_pool,
	)
	assert(result == .SUCCESS)

	//
	// Specify and create the set layout
	//
	{
		//
		// Get the bindings from our handy shader processing tool
		//
		#assert(PIPELINE == .shader)
		create_info := vk.DescriptorSetLayoutCreateInfo {
			sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			flags        = {},
			bindingCount = len(SHADER_PIPELINE_SET_LAYOUTS),
			pBindings    = &SHADER_PIPELINE_SET_LAYOUTS[ShaderBinding(0)],
		}

		result = vk.CreateDescriptorSetLayout(
			engine.device,
			&create_info,
			engine.alloc,
			&engine.set_layout,
		)
		assert(result == .SUCCESS)
	}


	//
	// Allocate the descriptor set. We only have 1 because indirect rendering :)
	//

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = engine.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &engine.set_layout,
	}

	result = vk.AllocateDescriptorSets(engine.device, &alloc_info, &engine.descriptor_set)
	assert(result == .SUCCESS)


	//
	// Configure the descriptor set.
	//

	configure_single_buffer :: proc(
		device: vk.Device,
		buffer_info: ^vk.DescriptorBufferInfo,
		set: vk.DescriptorSet,
		binding: u32,
		type: vk.DescriptorType,
	) {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = set,
			dstBinding      = binding,
			descriptorType  = type,
			descriptorCount = 1,
			pBufferInfo     = buffer_info,
		}

		#partial switch type {
		case .STORAGE_IMAGE:
			align := physical_device_properties.limits.minStorageBufferOffsetAlignment
			assert(mem.is_aligned(transmute(rawptr)(buffer_info.offset), int(align)))
		case .UNIFORM_BUFFER:
			align := physical_device_properties.limits.minUniformBufferOffsetAlignment
			assert(mem.is_aligned(transmute(rawptr)(buffer_info.offset), int(align)))
		}

		vk.UpdateDescriptorSets(device, 1, &write, 0, nil)
	}

	configure_image_array :: proc(
		engine: ^Engine,
		num_images: u32,

		//
		set: vk.DescriptorSet,
		binding: u32,
		type: vk.DescriptorType,
	) {
		assert(int(num_images) == len(engine.texture_list))

		image_info := make([]vk.DescriptorImageInfo, num_images, context.temp_allocator)

		for tex, i in engine.texture_list {
			assert(tex.image > 0 && tex.view > 0)

			image_info[i] = vk.DescriptorImageInfo {
				sampler     = engine.image_sampler,
				imageView   = tex.view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}
		}

		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = set,
			dstBinding      = binding,
			descriptorType  = type,

			//
			descriptorCount = u32(len(image_info)),
			pImageInfo      = raw_data(image_info),
		}

		vk.UpdateDescriptorSets(engine.device, 1, &write, 0, nil)
	}

	#assert(PIPELINE == .shader)
	for binding, binding_tag in SHADER_PIPELINE_SET_LAYOUTS do switch binding_tag {

	case .uniforms:
		assert(binding.descriptorCount == 1)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.frame_data.buffer,
			offset = mapped_buffer_get_offset(engine.frame_data, "uniforms"),
			range  = size_of(engine.frame_data.ptr.uniforms),
		}
		configure_single_buffer(engine.device, &buffer_info, engine.descriptor_set, binding.binding, binding.descriptorType)

	case .instance_transforms:
		assert(binding.descriptorCount == 1)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.frame_data.buffer,
			offset = mapped_buffer_get_offset(engine.frame_data, "instance_transforms"),
			range  = size_of(engine.frame_data.ptr.instance_transforms),
		}

		configure_single_buffer(engine.device, &buffer_info, engine.descriptor_set, binding.binding, binding.descriptorType)

	case .instance_textures:
		assert(binding.descriptorCount == 1)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.frame_data.buffer,
			offset = mapped_buffer_get_offset(engine.frame_data, "instance_textures"),
			range  = size_of(engine.frame_data.ptr.instance_textures),
		}

		configure_single_buffer(engine.device, &buffer_info, engine.descriptor_set, binding.binding, binding.descriptorType)

	case .textures:
		configure_image_array(engine, binding.descriptorCount, engine.descriptor_set, binding.binding, binding.descriptorType)

	}
}

engine_init_command_buffers :: proc(engine: ^Engine) {
	result: vk.Result
	//
	// First create the command pool
	//
	cmd_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = engine.queue_index,
	}

	result = vk.CreateCommandPool(
		engine.device,
		&cmd_pool_create_info,
		engine.alloc,
		&engine.cmdpool,
	)
	assert(result == .SUCCESS)


	//
	// Allocate the command buffers
	//
	cmdbuf_alloc_create_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = engine.cmdpool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	result = vk.AllocateCommandBuffers(engine.device, &cmdbuf_alloc_create_info, &engine.cmdbuf)
	assert(result == .SUCCESS)

	//
	// Create the semaphores and fences for the command buffer
	//
	{
		sema_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}

		//
		// Create the semaphores for the render completion
		//
		for &sema in engine.swapchain_semas {
			result = vk.CreateSemaphore(engine.device, &sema_create_info, engine.alloc, &sema)
			assert(result == .SUCCESS)
		}

		//
		// Create the semaphores for the frame presentation completion
		//
		result = vk.CreateSemaphore(
			engine.device,
			&sema_create_info,
			engine.alloc,
			&engine.present_complete_sema,
		)
		assert(result == .SUCCESS)

		//
		// Create the fences
		//
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		result = vk.CreateFence(
			engine.device,
			&fence_create_info,
			engine.alloc,
			&engine.draw_fence,
		)
		assert(result == .SUCCESS)
	}
}

engine_init_physical_device :: proc(engine: ^Engine) {
	result: vk.Result
	devices: []vk.PhysicalDevice

	{
		count: u32
		result = vk.EnumeratePhysicalDevices(engine.instance, &count, nil)
		assert(result == .SUCCESS)

		devices = make([]vk.PhysicalDevice, count, context.temp_allocator)

		result = vk.EnumeratePhysicalDevices(engine.instance, &count, raw_data(devices))
		assert(result == .SUCCESS)
	}

	switch len(devices) {
	case 0:
		log.errorf("No gpu found. Cannot continue.")
		assert(false)

	case 1:
	// nothing

	case:
		log.info("Found a bunch of gpus, using first one that meets the requirements")
	}

	search_device: for physical_device in devices {
		assert(physical_device != nil)

		vk.GetPhysicalDeviceProperties(physical_device, &physical_device_properties)
		vk.GetPhysicalDeviceFeatures(physical_device, &physical_device_features)

		log.info("Checking", transmute(cstring)(&physical_device_properties.deviceName))

		//
		// Define the features we need for our application to run
		//

		if device_meets_requirements(
			physical_device,
			physical_device_properties,
			physical_device_features,
			REQUIRED_PHYSICAL_DEVICE_EXTENSIONS[:],
		) {
			log.info("Using", transmute(cstring)(&physical_device_properties.deviceName))
			engine.physical_device = physical_device
			break search_device
		}
	}
	assert(engine.physical_device != nil)

	vk.GetPhysicalDeviceMemoryProperties(
		engine.physical_device,
		&physical_device_memory_properties,
	)
}

engine_init_logical_device :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Create the logical device queue create info
	//
	queue_properties: []vk.QueueFamilyProperties
	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(engine.physical_device, &queue_count, nil)

	queue_properties = make([]vk.QueueFamilyProperties, queue_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		engine.physical_device,
		&queue_count,
		raw_data(queue_properties),
	)

	//
	// Grab the first queue with graphics capabilities
	//

	engine.queue_index = bits.U32_MAX

	for properties, index in queue_properties {
		has_graphics := .GRAPHICS in properties.queueFlags
		has_transfer := .TRANSFER in properties.queueFlags

		has_presentation: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(
			engine.physical_device,
			u32(index),
			engine.surface,
			&has_presentation,
		)

		if has_graphics && has_transfer && has_presentation {
			engine.queue_index = u32(index)
			break
		}
	}

	assert(engine.queue_index != bits.U32_MAX, "Failed to find queue index for graphics queue")

	queue_priority := f32(0.5)
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = engine.queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	//
	// Enable runtime-sized shader arrays
	//
	descriptor_indexing := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType                                     = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
		pNext                                     = nil,
		shaderSampledImageArrayNonUniformIndexing = true,
		runtimeDescriptorArray                    = true,
		descriptorBindingVariableDescriptorCount  = true,
	}

	//
	// Enable dynamic local read
	//
	render_local_read := vk.PhysicalDeviceDynamicRenderingLocalReadFeatures {
		sType                     = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES,
		pNext                     = &descriptor_indexing,
		dynamicRenderingLocalRead = true,
	}

	//
	// Enable Synchronization 2
	//
	sync_two := vk.PhysicalDeviceSynchronization2Features {
		sType            = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		pNext            = &render_local_read,
		synchronization2 = true,
	}

	//
	// Enable dynamic rendering
	//
	dynamic_rendering := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		pNext            = &sync_two,
		dynamicRendering = true,
	}

	//
	// Logical device create info
	//
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &dynamic_rendering,

		// queue
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,

		// NOTE: Apparently this is ignored? (sauce:
		// https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/00_Setup/04_Logical_device_and_queues.html)
		enabledLayerCount       = 0,
		ppEnabledLayerNames     = nil,

		// extensions
		enabledExtensionCount   = len(REQUIRED_PHYSICAL_DEVICE_EXTENSIONS),
		ppEnabledExtensionNames = raw_data(REQUIRED_PHYSICAL_DEVICE_EXTENSIONS[:]),

		// features
		pEnabledFeatures        = &physical_device_features,
	}

	result = vk.CreateDevice(engine.physical_device, &create_info, engine.alloc, &engine.device)
	assert(result == .SUCCESS)
	assert(engine.device != nil)

	//
	// Get the render/graphics queue
	//
	vk.GetDeviceQueue(engine.device, engine.queue_index, 0, &engine.queue)
	assert(engine.queue != nil)
}

engine_init_swapchain :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Set the swapchain surface format
	//
	{
		count: u32
		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			engine.physical_device,
			engine.surface,
			&count,
			nil,
		)
		assert(result == .SUCCESS)

		formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			engine.physical_device,
			engine.surface,
			&count,
			raw_data(formats),
		)
		assert(result == .SUCCESS)

		desired_format := vk.SurfaceFormatKHR {
			colorSpace = .SRGB_NONLINEAR,
			format     = .R8G8B8A8_SRGB,
		}

		if slice.contains(formats, desired_format) {
			engine.swapchain_surface_format = desired_format
		} else {
			engine.swapchain_surface_format = formats[0]
		}
	}

	//
	// Get available present modes
	//
	// **IMMEDIATE**: Images submitted by your application are
	// transferred to the screen right away, which may result in tearing.
	//
	// **FIFO**: The swap chain is a queue where the display takes an
	// image from the front of the queue when the display is refreshed, and the program
	// inserts rendered images at the back of the queue. If the queue is full, then the
	// program has to wait. This is most similar to vertical sync as found in modern
	// games. The moment that the display is refreshed is known as "vertical blank".
	//
	// **FIFO_RELAXED**: This mode only differs from the previous one
	// if the application is late and the queue was empty at the last vertical blank.
	// Instead of waiting for the next vertical blank, the image is transferred right
	// away when it finally arrives. This may result in visible tearing.
	//
	// **MAILBOX**: This is another variation of the second mode.
	// Instead of blocking the application when the queue is full, the images that are
	// already queued are simply replaced with the newer ones. This mode can be used to
	// render frames as fast as possible while still avoiding tearing, resulting in
	// fewer latency issues than standard vertical sync. This is commonly known as
	// "triple buffering," although the existence of three buffers alone does not
	// necessarily mean that the framerate is unlocked.
	//
	present_mode: vk.PresentModeKHR = .FIFO
	{
		count: u32
		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
			engine.physical_device,
			engine.surface,
			&count,
			nil,
		)
		assert(result == .SUCCESS)

		present_modes := make([]vk.PresentModeKHR, count, context.temp_allocator)

		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
			engine.physical_device,
			engine.surface,
			&count,
			raw_data(present_modes),
		)
		assert(result == .SUCCESS)

		// if slice.contains(present_modes, vk.PresentModeKHR.MAILBOX) {
		// 	present_mode = .MAILBOX
		// }
	}

	//
	// Set the a bunch of stuff based of the capabilities of the surface
	//
	pre_transform: vk.SurfaceTransformFlagsKHR
	{
		capabilities: vk.SurfaceCapabilitiesKHR
		result = vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			engine.physical_device,
			engine.surface,
			&capabilities,
		)
		assert(result == .SUCCESS)

		//
		// Set the pre transform for the images
		//
		pre_transform = capabilities.currentTransform

		//
		// Set the minimum number of images we want to create for the swapchain.
		//

		// Zero is a special value meaning there is no maximum here
		min_images := capabilities.minImageCount + 1
		max_images := capabilities.maxImageCount
		if max_images == 0 do max_images = bits.U32_MAX

		if present_mode == .FIFO {
			engine.min_image_count = 2
		} else if present_mode == .MAILBOX {
			engine.min_image_count = 3
		}

		engine.min_image_count = clamp(engine.min_image_count, min_images, max_images)

		//
		// Set the extent to the framebuffer size
		//
		w, h := glfw.GetFramebufferSize(engine.window)
		engine.swapchain_extent.width = clamp(
			u32(w),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		)
		engine.swapchain_extent.height = clamp(
			u32(h),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		)
	}


	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		flags            = {},
		surface          = engine.surface,
		minImageCount    = engine.min_image_count,
		imageFormat      = engine.swapchain_surface_format.format,
		imageColorSpace  = engine.swapchain_surface_format.colorSpace,
		imageExtent      = engine.swapchain_extent,
		imageArrayLayers = 1,
		imageSharingMode = .EXCLUSIVE,
		// queueFamilyIndexCount: u32,
		// pQueueFamilyIndices:   [^]u32,
		presentMode      = present_mode,
		clipped          = true,
		oldSwapchain     = {}, // TODO: Implement swap chain recreation
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = pre_transform,
		compositeAlpha   = {.OPAQUE},
	}

	result = vk.CreateSwapchainKHR(engine.device, &create_info, engine.alloc, &engine.swapchain)
	assert(result == .SUCCESS)
	assert(engine.swapchain != {})

	//
	// Retrieve swapchain images
	//
	{
		count: u32
		result = vk.GetSwapchainImagesKHR(engine.device, engine.swapchain, &count, nil)
		assert(result == .SUCCESS)

		resize(&engine.swapchain_images, count)
		resize(&engine.swapchain_image_views, count)

		result = vk.GetSwapchainImagesKHR(
			engine.device,
			engine.swapchain,
			&count,
			raw_data(engine.swapchain_images[:]),
		)
		assert(result == .SUCCESS)
	}

	for image, i in engine.swapchain_images {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = engine.swapchain_surface_format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		result = vk.CreateImageView(
			engine.device,
			&create_info,
			engine.alloc,
			&engine.swapchain_image_views[i],
		)
		assert(result == .SUCCESS)
	}

	//
	// Create viewport and scissor
	//
	engine.viewport = vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(engine.swapchain_extent.width),
		height   = f32(engine.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}

	engine.scissor = vk.Rect2D {
		offset = {},
		extent = engine.swapchain_extent,
	}

	//
	// Create the depth image
	//

	engine.depth_image_format = find_format(
		engine,
		candidates = {.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
		tiling = .OPTIMAL,
		features = {.DEPTH_STENCIL_ATTACHMENT},
	)

	image_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = engine.depth_image_format,
		extent = {
			width = engine.swapchain_extent.width,
			height = engine.swapchain_extent.height,
			depth = 1,
		},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}

	result = vk.CreateImage(engine.device, &image_create_info, engine.alloc, &engine.depth_image)
	assert(result == .SUCCESS)

	engine.depth_image_memory, result = gpu_malloc_image(
		engine.device,
		engine.depth_image,
		engine.alloc,
		{.DEVICE_LOCAL},
	)
	assert(result == .SUCCESS)

	//
	// Create the depth image view
	//
	create_view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = engine.depth_image,
		viewType = .D2,
		format = engine.depth_image_format,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}
	result = vk.CreateImageView(
		engine.device,
		&create_view_info,
		engine.alloc,
		&engine.depth_image_view,
	)
	assert(result == .SUCCESS)
}

engine_recreate_swapchain :: proc(engine: ^Engine) {
	//
	// Handle the case when the application is minimized
	//
	w, h: i32
	for w == 0 || h == 0 {
		w, h = glfw.GetFramebufferSize(engine.window)
		glfw.WaitEvents()
	}

	//
	// We want to destroy the current swapchain before creating a new one
	//
	assert(engine.swapchain != 0)
	vk.DeviceWaitIdle(engine.device)

	vk.DestroySwapchainKHR(engine.device, engine.swapchain, engine.alloc)
	engine.swapchain = 0

	for image_view in engine.swapchain_image_views {
		vk.DestroyImageView(engine.device, image_view, engine.alloc)
	}
	clear(&engine.swapchain_image_views)

	vk.FreeMemory(engine.device, engine.depth_image_memory, engine.alloc)
	vk.DestroyImageView(engine.device, engine.depth_image_view, engine.alloc)
	vk.DestroyImage(engine.device, engine.depth_image, engine.alloc)

	engine_init_swapchain(engine)
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DeviceWaitIdle(engine.device)

	gpu_arena_destroy(engine.device, engine.model_arena, engine.alloc)
	gpu_arena_destroy(engine.device, engine.texture_arena, engine.alloc)

	for buffer in engine.data_buffer do vk.DestroyBuffer(engine.device, buffer, engine.alloc)

	vk.DestroySampler(engine.device, engine.image_sampler, engine.alloc)

	for texture in engine.texture_list {
		vk.DestroyImageView(engine.device, texture.view, engine.alloc)
		vk.DestroyImage(engine.device, texture.image, engine.alloc)
	}

	vk.DestroyDescriptorPool(engine.device, engine.descriptor_pool, engine.alloc)

	vk.FreeMemory(engine.device, engine.depth_image_memory, engine.alloc)
	vk.DestroyImageView(engine.device, engine.depth_image_view, engine.alloc)
	vk.DestroyImage(engine.device, engine.depth_image, engine.alloc)

	vk.DestroyDescriptorSetLayout(engine.device, engine.set_layout, engine.alloc)

	mapped_buffer_destroy(engine.device, &engine.frame_data, engine.alloc)

	for tag in ModelTag do model.destroy(&engine.models[tag])

	for sema in engine.swapchain_semas {
		vk.DestroySemaphore(engine.device, sema, engine.alloc)
	}

	vk.DestroySemaphore(engine.device, engine.present_complete_sema, engine.alloc)
	vk.DestroyFence(engine.device, engine.draw_fence, engine.alloc)

	queue_destroy(engine.device, &engine.transfer_queue, engine.alloc)

	// cmd buffer is destroyed when we destroy the pool (I think)
	vk.DestroyCommandPool(engine.device, engine.cmdpool, engine.alloc)
	engine.cmdbuf = {}

	vk.DestroyPipelineCache(engine.device, engine.pipeline_cache, engine.alloc)
	vk.DestroyPipelineLayout(engine.device, engine.pipeline_layout, engine.alloc)
	vk.DestroyPipeline(engine.device, engine.render_pipeline, engine.alloc)
	vk.DestroyShaderModule(engine.device, engine.pipeline_shader, engine.alloc)
	for image_view in engine.swapchain_image_views do vk.DestroyImageView(engine.device, image_view, engine.alloc)
	vk.DestroySwapchainKHR(engine.device, engine.swapchain, engine.alloc)
	vk.DestroySurfaceKHR(engine.instance, engine.surface, engine.alloc)
	vk.DestroyDevice(engine.device, engine.alloc)
	vk.DestroyDebugUtilsMessengerEXT(engine.instance, engine.messenger, engine.alloc)
	vk.DestroyInstance(engine.instance, engine.alloc)

	delete(engine.arena.data)

	vk_alloc_cleanup()

	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}
