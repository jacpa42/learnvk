package learnvk

import "core:mem"
import "core:strings"

//
// TODO: Figure out how to use an array of samplers
//

import "base:runtime"
import "core:c"
import "core:debug/trace"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:os"
import "core:slice"
import "core:thread"
import "core:time"
import "model"
import "vendor:glfw"
import stb_image "vendor:stb/image"
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

	MS_PER_FRAME :: 16_666_666
	MS_PER_FRAME_F32 :: MS_PER_FRAME * 1e-9

	//
	// Main loop
	//
	frame_watch: time.Stopwatch
	for !glfw.WindowShouldClose(engine.window) {
		time.stopwatch_reset(&frame_watch)
		time.stopwatch_start(&frame_watch)

		glfw.PollEvents()

		if engine.stop_rendering {
			glfw.WaitEvents()
			continue
		}

		frame(&engine)

		free_all(context.temp_allocator)

		elapsed := time.stopwatch_duration(frame_watch)
		engine.delta_time = max(f32(elapsed) * 1e-9, MS_PER_FRAME_F32)
		time.sleep(max(0, elapsed - MS_PER_FRAME))
	}
}

engine_init :: proc(engine: ^Engine) {
	result: vk.Result

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
	// Initialize GLFW and create our window
	//
	{
		glfw.SetErrorCallback(glfw_error_callback)
		ensure(bool(glfw.Init()), "Failed to initialize GLFW")
		ensure(bool(glfw.VulkanSupported()))

		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
		engine.window = glfw.CreateWindow(1280, 678, APP_NAME, nil, nil)
		ensure(engine.window != nil, "Failed to create a GLFW window")

		glfw.SetWindowUserPointer(engine.window, engine)
		glfw.SetKeyCallback(engine.window, callback_key)
		glfw.SetScrollCallback(engine.window, callback_scroll)
		glfw.SetCursorPosCallback(engine.window, callback_cursor_move)
		glfw.SetFramebufferSizeCallback(engine.window, callback_framebuffer_size)
		glfw.SetWindowIconifyCallback(engine.window, callback_window_minimize)
		glfw.SetInputMode(engine.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	}

	//
	// Load all Vulkan global functions (ie without having an instance yet)
	//
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	//
	// Create the Vulkan allocator
	//
	engine.vk_alloc = vk_alloc_init()

	//
	// Create the Vulkan Instance
	//
	engine_init_instance(engine)

	//
	// Create the window surface
	//
	{
		result = glfw.CreateWindowSurface(
			engine.vk_instance,
			engine.window,
			engine.vk_alloc,
			&engine.vk_surface,
		)
		ensure(result == .SUCCESS)
		ensure(engine.vk_surface != {})
	}

	//
	// Load Vulkan function pointers
	//
	vk.GetInstanceProcAddr = auto_cast glfw.GetInstanceProcAddress
	vk.load_proc_addresses(engine.vk_instance)

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
			engine.vk_instance,
			&create_info,
			engine.vk_alloc,
			&engine.vk_messenger,
		)
		ensure(result == .SUCCESS)
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
			engine.vk_device,
			&cache_create_info,
			engine.vk_alloc,
			&engine.vk_pipeline_cache,
		)
		ensure(result == .SUCCESS)
	}

	//
	// Initialize the graphics pipelines
	//
	engine_init_graphics_pipeline(engine)

	//
	// Ensure that all the data has been sent to the gpu
	//
	queue_flush(&engine.transfer_queue, engine.vk_device, engine.vk_queue)
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
		append(&desired_layers, "VK_LAYER_KHRONOS_validation")

		count: u32
		ensure(vk.EnumerateInstanceLayerProperties(&count, nil) == .SUCCESS)
		assert(count > 0)

		supported_layers := make([]vk.LayerProperties, count, context.temp_allocator)
		ensure(vk.EnumerateInstanceLayerProperties(&count, raw_data(supported_layers)) == .SUCCESS)

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

	result := vk.CreateInstance(&create_info, engine.vk_alloc, &engine.vk_instance)
	ensure(result == .SUCCESS)
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
			engine.vk_device,
			&shader_module_create_info,
			engine.vk_alloc,
			&engine.vk_pipeline_shader,
		)
		ensure(result == .SUCCESS)
	}

	//
	// For each stage that the shader defines, define the stage creation info
	//
	ensure(len(PIPELINE_STAGES) == len(PIPELINE_STAGE_NAMES))
	shader_stage_create_info: [dynamic; PIPELINE_MAX_STAGES]vk.PipelineShaderStageCreateInfo

	for shader_stages, stage_index in PIPELINE_STAGES[PIPELINE] {
		append(
			&shader_stage_create_info,
			vk.PipelineShaderStageCreateInfo {
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				flags = {},
				stage = {shader_stages},
				module = engine.vk_pipeline_shader,
				pName = PIPELINE_STAGE_NAMES[PIPELINE][stage_index],
				pSpecializationInfo = nil,
			},
		)
	}

	//
	// Setup dynamic state for the pipeline. At the moment, just viewport and scissor.
	//
	append(&engine.vk_pipeline_dynamic_state, ..[]vk.DynamicState{.VIEWPORT, .SCISSOR})

	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(engine.vk_pipeline_dynamic_state)),
		pDynamicStates    = raw_data(engine.vk_pipeline_dynamic_state[:]),
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
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = POLYGON_MODE,
		cullMode                = CULL_MODE,
		frontFace               = FRONT_FACE,
		depthBiasEnable         = false,
		lineWidth               = LINE_WIDTH,
		depthBiasConstantFactor = {},
		depthBiasClamp          = {},
		depthBiasSlopeFactor    = {},
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
	engine.vk_color_attachment = {
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
		pAttachments    = &engine.vk_color_attachment,
	}

	//
	// Create the vertex/uniform/images buffers
	// Basically everything which requires the staging buffer mapped into memory
	//
	engine_init_buffer_and_images(engine)

	//
	// Load all the textures we could possibly need
	//
	engine_load_all_textures(engine)

	//
	// We have uploaded all our model data and texture data, free everything
	//
	for tag in engine.model_loaded {
		model.destroy(&engine.models[tag])
	}

	//
	// Create the samplers
	//
	for tag in MaterialType {

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
			engine.vk_device,
			&sampler_create_info,
			engine.vk_alloc,
			&engine.vk_image_sampler[tag],
		)
		ensure(result == .SUCCESS)
	}

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
		pSetLayouts            = &engine.vk_set_layout,

		// push constants
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	result = vk.CreatePipelineLayout(
		engine.vk_device,
		&pipeline_layout_create_info,
		engine.vk_alloc,
		&engine.vk_pipeline_layout,
	)
	ensure(result == .SUCCESS)
	ensure(engine.vk_pipeline_layout != {})

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
		pColorAttachmentFormats = &engine.vk_swapchain_surface_format.format,
		depthAttachmentFormat   = engine.vk_depth_image_format,
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
		//      stencilAttachmentFormat are VK_FORMAT_UNDEFINED. If a graphics
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
		layout              = engine.vk_pipeline_layout,

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
		engine.vk_device,
		engine.vk_pipeline_cache,
		1,
		&pipeline_create_info,
		engine.vk_alloc,
		&engine.vk_render_pipeline,
	)
	ensure(result == .SUCCESS)
}

engine_init_buffer_and_images :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Create the per-frame mapped buffer
	//
	result = mapped_buffer_init(
		device = engine.vk_device,
		mbuf = &engine.frame_data,
		alloc = engine.vk_alloc,
		usage = {.UNIFORM_BUFFER, .INDIRECT_BUFFER, .STORAGE_BUFFER},
		required_properties = {.DEVICE_LOCAL, .HOST_VISIBLE, .HOST_COHERENT},
	)
	ensure(result == .SUCCESS)

	//
	// Initialize the upload queue
	//
	queue_init(
		queue = &engine.transfer_queue,
		device = engine.vk_device,
		alloc = engine.vk_alloc,
		transfer_buf_size = STAGING_BUFFER_SIZE,
		cmdpool = engine.vk_cmdpool,
	)

	//
	// Create the model buffers.
	//

	for buffer_type in ModelBuffer {

		//
		// Compute the total required size for the model buffer
		//
		buffer_size := 0
		for model_tag in engine.model_loaded do switch buffer_type {
		case .index:
			buffer_size += slice.size(model.get_all_indices(engine.models[model_tag]))
		case .vertex:
			buffer_size += slice.size(model.get_vertices(engine.models[model_tag]))
		}


		//
		// Get the usage flags for the buffer type
		//
		usage: vk.BufferUsageFlags
		switch buffer_type {
		case .vertex:
			usage = {.VERTEX_BUFFER, .TRANSFER_DST}
		case .index:
			usage = {.INDEX_BUFFER, .TRANSFER_DST}
		}

		//
		// Create the buffer along with its memory
		//
		engine.vk_model_buffer[buffer_type], result = buffer_init(
			device = engine.vk_device,
			alloc = engine.vk_alloc,
			size = buffer_size,
			usage = usage,
			required_properties = {.DEVICE_LOCAL},
		)
		ensure(result == .SUCCESS)
	}

	//
	// Copy over the data for the mesh names
	//
	for model_tag in engine.model_loaded {
		m := engine.models[model_tag]
		arena_alloc := mem.arena_allocator(&engine.arena)

		engine.mesh_names[model_tag] = make([]string, len(model.get_meshes(m)), arena_alloc)

		//
		// Copy the name data
		//
		for &name, mesh_index in engine.mesh_names[model_tag] {
			mesh_name := model.get_mesh_name(m, mesh_index)
			name = strings.clone(mesh_name, arena_alloc)
		}
	}

	//
	// Define the mesh draw commands
	//
	model_index_offset: u32 = 0
	for model_tag in engine.model_loaded {
		m := engine.models[model_tag]
		arena_alloc := mem.arena_allocator(&engine.arena)

		defer model_index_offset += u32(len(model.get_all_indices(m)))

		engine.mesh_draw_command[model_tag] = make(
			[]DrawInstancesCommand,
			len(model.get_meshes(m)),
			arena_alloc,
		)

		//
		// Define the vk draw commands
		//
		mesh_index_offset: u32 = model_index_offset
		for &cmd, mesh_index in engine.mesh_draw_command[model_tag] {

			num_mesh_indices := u32(len(model.get_mesh_indices(m, mesh_index)))
			defer mesh_index_offset += num_mesh_indices

			cmd = DrawInstancesCommand {
				vk_cmd = vk.DrawIndexedIndirectCommand {
					indexCount    = num_mesh_indices,
					firstIndex    = mesh_index_offset,

					// TODO: offset into the vertex buffer should be zero?
					// we are indexing into a full buffer so its okay.
					vertexOffset  = 0,

					// defined at rendertime
					instanceCount = 0,
					firstInstance = 0,
				},
			}
		}
	}

	//
	// Append all the memory uploads to the queue
	//
	for buffer_tag in ModelBuffer {
		upload_buffer := engine.vk_model_buffer[buffer_tag].buffer
		upload_buffer_offset: vk.DeviceSize = 0

		for model_tag in engine.model_loaded {
			m := engine.models[model_tag]

			data: []byte
			defer upload_buffer_offset += vk.DeviceSize(len(data))

			switch buffer_tag {
			case .vertex:
				data = to_bytes(model.get_vertices(m))
			case .index:
				data = to_bytes(model.get_all_indices(m))
			}

			//
			// Queue the copying of the data to the gpu
			//
			assert(data != nil)
			assert(len(data) > 0)
			queue_append_whole_buffer(
				&engine.transfer_queue,
				engine.vk_device,
				engine.vk_queue,
				upload_buffer,
				upload_buffer_offset,
				data,
			)
		}
	}
}

engine_load_all_textures :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Define all the texture load tasks
	//
	tasks := make([dynamic]LoadTaskData, 0, 64, context.temp_allocator)

	defer for t in tasks {
		if t.output.data_needs_free {
			stb_image.image_free(raw_data(t.output.data))
		}
	}

	for tag in engine.model_loaded {
		meshes := model.get_meshes(engine.models[tag])
		model := engine.models[tag]

		engine.vk_mesh_textures[tag] = make([][MaterialType]Texture, len(meshes))

		for mesh, mesh_index in meshes {
			mesh_textures_ptr := &engine.vk_mesh_textures[tag][mesh_index]
			engine_define_texture_load_task(&tasks, mesh_textures_ptr, model, tag, mesh)
		}
	}

	//
	// Divy up the tasks
	//
	threads := make([]^thread.Thread, os.get_processor_core_count(), context.temp_allocator)
	chunk_size := math.floor_div(len(tasks), len(threads) + 1)
	num_tasks_consumed := 0

	thread_index := 0
	for num_tasks_consumed + chunk_size < len(tasks) && thread_index < len(threads) {
		task_slice := tasks[num_tasks_consumed:num_tasks_consumed + chunk_size]
		threads[thread_index] = thread.create_and_start_with_poly_data(
			data = task_slice,
			fn = eat_load_task,
		)

		thread_index += 1
		num_tasks_consumed += len(task_slice)
	}

	//
	// Eat the remainder on main thread
	//
	eat_load_task(tasks[num_tasks_consumed:])
	for t in threads[:thread_index] do thread.destroy(t)

	//
	// Initialize the mesh arena
	//
	expected_num_allocations: vk.DeviceSize
	texture_arena_memory_requirements := vk.MemoryRequirements {
		size           = 0,
		alignment      = 0,
		memoryTypeBits = max(u32),
	}

	for task in tasks do if task.output.ok {
		create_info := vk.ImageCreateInfo {
			sType         = .IMAGE_CREATE_INFO,
			imageType     = .D2,
			format        = task.input.format,
			extent        = {u32(task.output.width), u32(task.output.height), 1},
			mipLevels     = 1,
			arrayLayers   = 1,
			samples       = {._1},
			tiling        = .OPTIMAL,
			usage         = {.SAMPLED, .TRANSFER_DST},
			sharingMode   = .EXCLUSIVE,
			initialLayout = .UNDEFINED,
		}

		result = vk.CreateImage(engine.vk_device, &create_info, engine.vk_alloc, &task.input.texture.image)
		ensure(result == .SUCCESS)

		requirements: vk.MemoryRequirements
		vk.GetImageMemoryRequirements(engine.vk_device, task.input.texture.image, &requirements)

		// refine our requirements for the arena
		expected_num_allocations += 1
		texture_arena_memory_requirements.size += requirements.size
		texture_arena_memory_requirements.alignment = max(texture_arena_memory_requirements.alignment, requirements.alignment)
		texture_arena_memory_requirements.memoryTypeBits &= requirements.memoryTypeBits
	}

	//
	// Then allocate the mesh arena
	//
	texture_arena_memory_requirements.size +=
		expected_num_allocations * texture_arena_memory_requirements.alignment

	engine.texture_arena, result = gpu_arena_init(
		device = engine.vk_device,
		alloc = engine.vk_alloc,
		requirements = texture_arena_memory_requirements,
		required_properties = {.DEVICE_LOCAL},
	)
	ensure(result == .SUCCESS)

	//
	// Add the upload task for each image
	//

	for task in tasks {
		if task.output.ok {

			// map the memory to the image
			requirements: vk.MemoryRequirements
			vk.GetImageMemoryRequirements(
				engine.vk_device,
				task.input.texture.image,
				&requirements,
			)

			memory_offset: vk.DeviceSize
			memory_offset, result = gpu_arena_alloc(
				&engine.texture_arena,
				requirements.size,
				requirements.alignment,
			)
			ensure(result == .SUCCESS)

			result = vk.BindImageMemory(
				device = engine.vk_device,
				image = task.input.texture.image,
				memory = engine.texture_arena.memory,
				memoryOffset = memory_offset,
			)
			ensure_contextless(result == .SUCCESS)

			//
			// we need to create the view *after* we bind the memory!
			//
			view_create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = task.input.texture.image,
				viewType = .D2,
				format = task.input.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			result = vk.CreateImageView(
				engine.vk_device,
				&view_create_info,
				engine.vk_alloc,
				&task.input.texture.view,
			)
			ensure(result == .SUCCESS)

			ok := queue_append_whole_image(
				&engine.transfer_queue,
				engine.vk_device,
				engine.vk_queue,
				task.input.texture.image,
				{u32(task.output.width), u32(task.output.height), 1},
				task.output.data,
			)
			ensure(ok)

		} else {
			log.warnf("Didn't succeed in the task load for \"{}\"", task.input.texture_cpath)
		}
	}

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
		texture_num: u32
		for model_tag in engine.model_loaded do for mesh_texture in engine.vk_mesh_textures[model_tag] {
			for t in mesh_texture {
				if t.image != 0 && t.view != 0 do texture_num += 1
			}
		}

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
		engine.vk_device,
		&pool_create_info,
		engine.vk_alloc,
		&engine.vk_descriptor_pool,
	)
	ensure(result == .SUCCESS)

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
			engine.vk_device,
			&create_info,
			engine.vk_alloc,
			&engine.vk_set_layout,
		)
		ensure(result == .SUCCESS)
	}


	//
	// Allocate the descriptor set. We only have 1 because indirect rendering :)
	//

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = engine.vk_descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &engine.vk_set_layout,
	}

	result = vk.AllocateDescriptorSets(engine.vk_device, &alloc_info, &engine.vk_descriptor_set)
	ensure(result == .SUCCESS)


	//
	// Configure the descriptor set.
	//

	ThingThatMakesThisEasierToRead :: struct {
		set:     vk.DescriptorSet,
		binding: u32,
		type:    vk.DescriptorType,
	}

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
		image_info := make([]vk.DescriptorImageInfo, num_images, context.temp_allocator)

		image_info_len: u32
		for tag in engine.model_loaded do for &mesh_textures in engine.vk_mesh_textures[tag] {
			for &tex, type in mesh_textures {

				if (tex.image == 0 || tex.view == 0) {
					tex.shader_array_index = -1
					continue
				}

				tex.shader_array_index = i32(image_info_len)

				image_info[image_info_len] = vk.DescriptorImageInfo {
					sampler     = engine.vk_image_sampler[type],
					imageView   = tex.view,
					imageLayout = .SHADER_READ_ONLY_OPTIMAL,
				}
				image_info_len += 1
			}
		}

		assert(num_images == image_info_len)

		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = set,
			dstBinding      = binding,
			descriptorType  = type,

			//
			descriptorCount = image_info_len,
			pImageInfo      = raw_data(image_info),
		}

		vk.UpdateDescriptorSets(engine.vk_device, 1, &write, 0, nil)
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

		configure_single_buffer(engine.vk_device, &buffer_info, engine.vk_descriptor_set, binding.binding, binding.descriptorType)

	case .instance_transforms:
		assert(binding.descriptorCount == 1)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.frame_data.buffer,
			offset = mapped_buffer_get_offset(engine.frame_data, "instance_transforms"),
			range  = size_of(engine.frame_data.ptr.instance_transforms),
		}

		configure_single_buffer(engine.vk_device, &buffer_info, engine.vk_descriptor_set, binding.binding, binding.descriptorType)

	case .instance_textures:
		assert(binding.descriptorCount == 1)

		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.frame_data.buffer,
			offset = mapped_buffer_get_offset(engine.frame_data, "instance_textures"),
			range  = size_of(engine.frame_data.ptr.instance_textures),
		}

		configure_single_buffer(engine.vk_device, &buffer_info, engine.vk_descriptor_set, binding.binding, binding.descriptorType)

	case .textures:
		configure_image_array(engine, binding.descriptorCount, engine.vk_descriptor_set, binding.binding, binding.descriptorType)

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
		queueFamilyIndex = engine.vk_queue_index,
	}

	result = vk.CreateCommandPool(
		engine.vk_device,
		&cmd_pool_create_info,
		engine.vk_alloc,
		&engine.vk_cmdpool,
	)
	ensure(result == .SUCCESS)


	//
	// Allocate the command buffers
	//
	cmdbuf_alloc_create_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = engine.vk_cmdpool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	result = vk.AllocateCommandBuffers(
		engine.vk_device,
		&cmdbuf_alloc_create_info,
		&engine.vk_cmdbuf,
	)
	ensure(result == .SUCCESS)

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
		for &sema in engine.vk_swapchain_semas {
			result = vk.CreateSemaphore(
				engine.vk_device,
				&sema_create_info,
				engine.vk_alloc,
				&sema,
			)
			ensure(result == .SUCCESS)
		}

		//
		// Create the semaphores for the frame presentation completion
		//
		result = vk.CreateSemaphore(
			engine.vk_device,
			&sema_create_info,
			engine.vk_alloc,
			&engine.vk_present_complete_sema,
		)
		ensure(result == .SUCCESS)

		//
		// Create the fences
		//
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		result = vk.CreateFence(
			engine.vk_device,
			&fence_create_info,
			engine.vk_alloc,
			&engine.vk_draw_fence,
		)
		ensure(result == .SUCCESS)
	}
}

engine_init_physical_device :: proc(engine: ^Engine) {
	result: vk.Result
	devices: []vk.PhysicalDevice

	{
		count: u32
		result = vk.EnumeratePhysicalDevices(engine.vk_instance, &count, nil)
		ensure(result == .SUCCESS)

		devices = make([]vk.PhysicalDevice, count, context.temp_allocator)

		result = vk.EnumeratePhysicalDevices(engine.vk_instance, &count, raw_data(devices))
		ensure(result == .SUCCESS)
	}

	switch len(devices) {
	case 0:
		log.errorf("No gpu found. Cannot continue.")
		ensure(false)

	case 1:
	// nothing

	case:
		log.info("Found a bunch of gpus, using first one that meets the requirements")
	}

	search_device: for physical_device in devices {
		ensure(physical_device != nil)

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
			engine.vk_physical_device = physical_device
			break search_device
		}
	}
	ensure(engine.vk_physical_device != nil)

	vk.GetPhysicalDeviceMemoryProperties(
		engine.vk_physical_device,
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
	vk.GetPhysicalDeviceQueueFamilyProperties(engine.vk_physical_device, &queue_count, nil)

	queue_properties = make([]vk.QueueFamilyProperties, queue_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		engine.vk_physical_device,
		&queue_count,
		raw_data(queue_properties),
	)

	//
	// Grab the first queue with graphics capabilities
	//

	engine.vk_queue_index = bits.U32_MAX

	for properties, index in queue_properties {
		has_graphics := .GRAPHICS in properties.queueFlags
		has_transfer := .TRANSFER in properties.queueFlags

		has_presentation: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(
			engine.vk_physical_device,
			u32(index),
			engine.vk_surface,
			&has_presentation,
		)

		if has_graphics && has_transfer && has_presentation {
			engine.vk_queue_index = u32(index)
			break
		}
	}

	ensure(engine.vk_queue_index != bits.U32_MAX, "Failed to find queue index for graphics queue")

	queue_priority := f32(0.5)
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = engine.vk_queue_index,
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

	result = vk.CreateDevice(
		engine.vk_physical_device,
		&create_info,
		engine.vk_alloc,
		&engine.vk_device,
	)
	ensure(result == .SUCCESS)
	ensure(engine.vk_device != nil)

	//
	// Get the render/graphics queue
	//
	vk.GetDeviceQueue(engine.vk_device, engine.vk_queue_index, 0, &engine.vk_queue)
	ensure(engine.vk_queue != nil)
}

engine_init_swapchain :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Set the swapchain surface format
	//
	{
		count: u32
		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			engine.vk_physical_device,
			engine.vk_surface,
			&count,
			nil,
		)
		ensure(result == .SUCCESS)

		formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
		result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			engine.vk_physical_device,
			engine.vk_surface,
			&count,
			raw_data(formats),
		)
		ensure(result == .SUCCESS)

		desired_format := vk.SurfaceFormatKHR {
			colorSpace = .SRGB_NONLINEAR,
			format     = .R8G8B8A8_SRGB,
		}

		if slice.contains(formats, desired_format) {
			engine.vk_swapchain_surface_format = desired_format
		} else {
			engine.vk_swapchain_surface_format = formats[0]
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
			engine.vk_physical_device,
			engine.vk_surface,
			&count,
			nil,
		)
		ensure(result == .SUCCESS)

		present_modes := make([]vk.PresentModeKHR, count, context.temp_allocator)

		result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
			engine.vk_physical_device,
			engine.vk_surface,
			&count,
			raw_data(present_modes),
		)
		ensure(result == .SUCCESS)

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
			engine.vk_physical_device,
			engine.vk_surface,
			&capabilities,
		)
		ensure(result == .SUCCESS)

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
			engine.vk_min_image_count = 2
		} else if present_mode == .MAILBOX {
			engine.vk_min_image_count = 3
		}

		engine.vk_min_image_count = clamp(engine.vk_min_image_count, min_images, max_images)

		//
		// Set the extent to the framebuffer size
		//
		w, h := glfw.GetFramebufferSize(engine.window)
		engine.vk_swapchain_extent.width = clamp(
			u32(w),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		)
		engine.vk_swapchain_extent.height = clamp(
			u32(h),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		)
	}


	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		flags            = {},
		surface          = engine.vk_surface,
		minImageCount    = engine.vk_min_image_count,
		imageFormat      = engine.vk_swapchain_surface_format.format,
		imageColorSpace  = engine.vk_swapchain_surface_format.colorSpace,
		imageExtent      = engine.vk_swapchain_extent,
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

	result = vk.CreateSwapchainKHR(
		engine.vk_device,
		&create_info,
		engine.vk_alloc,
		&engine.vk_swapchain,
	)
	ensure(result == .SUCCESS)
	ensure(engine.vk_swapchain != {})

	//
	// Retrieve swapchain images
	//
	{
		count: u32
		result = vk.GetSwapchainImagesKHR(engine.vk_device, engine.vk_swapchain, &count, nil)
		ensure(result == .SUCCESS)

		resize(&engine.vk_swapchain_images, count)
		resize(&engine.vk_swapchain_image_views, count)

		result = vk.GetSwapchainImagesKHR(
			engine.vk_device,
			engine.vk_swapchain,
			&count,
			raw_data(engine.vk_swapchain_images[:]),
		)
		ensure(result == .SUCCESS)
	}

	for image, i in engine.vk_swapchain_images {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = engine.vk_swapchain_surface_format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		result = vk.CreateImageView(
			engine.vk_device,
			&create_info,
			engine.vk_alloc,
			&engine.vk_swapchain_image_views[i],
		)
		ensure(result == .SUCCESS)
	}

	//
	// Create viewport and scissor
	//
	engine.vk_viewport = vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(engine.vk_swapchain_extent.width),
		height   = f32(engine.vk_swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}

	engine.vk_scissor = vk.Rect2D {
		offset = {},
		extent = engine.vk_swapchain_extent,
	}

	//
	// Create the depth image
	//

	engine.vk_depth_image_format = find_format(
		engine,
		candidates = {.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
		tiling = .OPTIMAL,
		features = {.DEPTH_STENCIL_ATTACHMENT},
	)

	image_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		flags = {},
		imageType = .D2,
		format = engine.vk_depth_image_format,
		extent = {
			width = engine.vk_swapchain_extent.width,
			height = engine.vk_swapchain_extent.height,
			depth = 1,
		},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode = .EXCLUSIVE,
		queueFamilyIndexCount = 0,
		pQueueFamilyIndices = nil,
		initialLayout = .UNDEFINED,
	}

	result = vk.CreateImage(
		engine.vk_device,
		&image_create_info,
		engine.vk_alloc,
		&engine.vk_depth_image,
	)
	ensure(result == .SUCCESS)

	memory_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(engine.vk_device, engine.vk_depth_image, &memory_requirements)

	memory_type_index: u32
	memory_type_index, result = device_get_memory_type_index(memory_requirements, {.DEVICE_LOCAL})
	ensure(result == .SUCCESS)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = memory_requirements.size,
		memoryTypeIndex = memory_type_index,
	}
	result = vk.AllocateMemory(
		engine.vk_device,
		&alloc_info,
		engine.vk_alloc,
		&engine.vk_depth_image_memory,
	)
	ensure(result == .SUCCESS)

	//
	// Bind the image to the memory
	//
	result = vk.BindImageMemory(
		engine.vk_device,
		engine.vk_depth_image,
		engine.vk_depth_image_memory,
		0,
	)
	ensure(result == .SUCCESS)

	//
	// Create the depth image view
	//
	create_view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		flags = {},
		image = engine.vk_depth_image,
		viewType = .D2,
		format = engine.vk_depth_image_format,
		components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
		subresourceRange = {
			aspectMask = {.DEPTH},
			baseMipLevel = 0,
			baseArrayLayer = 0,
			levelCount = 1,
			layerCount = 1,
		},
	}
	result = vk.CreateImageView(
		engine.vk_device,
		&create_view_info,
		engine.vk_alloc,
		&engine.vk_depth_image_view,
	)
	ensure(result == .SUCCESS)
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
	assert(engine.vk_swapchain != 0)
	vk.DeviceWaitIdle(engine.vk_device)

	vk.DestroySwapchainKHR(engine.vk_device, engine.vk_swapchain, engine.vk_alloc)
	engine.vk_swapchain = 0

	for image_view in engine.vk_swapchain_image_views {
		vk.DestroyImageView(engine.vk_device, image_view, engine.vk_alloc)
	}
	clear(&engine.vk_swapchain_image_views)

	vk.FreeMemory(engine.vk_device, engine.vk_depth_image_memory, engine.vk_alloc)
	vk.DestroyImageView(engine.vk_device, engine.vk_depth_image_view, engine.vk_alloc)
	vk.DestroyImage(engine.vk_device, engine.vk_depth_image, engine.vk_alloc)

	engine_init_swapchain(engine)
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DeviceWaitIdle(engine.vk_device)

	for buffer in engine.vk_model_buffer {
		vk.DestroyBuffer(engine.vk_device, buffer.buffer, engine.vk_alloc)
		vk.FreeMemory(engine.vk_device, buffer.memory, engine.vk_alloc)
	}

	for sampler in engine.vk_image_sampler {
		vk.DestroySampler(engine.vk_device, sampler, engine.vk_alloc)
	}

	gpu_arena_destroy(engine.vk_device, engine.texture_arena, engine.vk_alloc)

	for texture_list in engine.vk_mesh_textures {
		defer delete(texture_list)

		for image_by_material in texture_list {
			for image in image_by_material {
				vk.DestroyImageView(engine.vk_device, image.view, engine.vk_alloc)
				vk.DestroyImage(engine.vk_device, image.image, engine.vk_alloc)
			}
		}
	}

	vk.DestroyDescriptorPool(engine.vk_device, engine.vk_descriptor_pool, engine.vk_alloc)

	vk.FreeMemory(engine.vk_device, engine.vk_depth_image_memory, engine.vk_alloc)
	vk.DestroyImageView(engine.vk_device, engine.vk_depth_image_view, engine.vk_alloc)
	vk.DestroyImage(engine.vk_device, engine.vk_depth_image, engine.vk_alloc)

	vk.DestroyDescriptorSetLayout(engine.vk_device, engine.vk_set_layout, engine.vk_alloc)

	mapped_buffer_destroy(engine.vk_device, &engine.frame_data, engine.vk_alloc)

	for tag in ModelTag do model.destroy(&engine.models[tag])

	for sema in engine.vk_swapchain_semas {
		vk.DestroySemaphore(engine.vk_device, sema, engine.vk_alloc)
	}

	vk.DestroySemaphore(engine.vk_device, engine.vk_present_complete_sema, engine.vk_alloc)
	vk.DestroyFence(engine.vk_device, engine.vk_draw_fence, engine.vk_alloc)

	queue_destroy(engine.vk_device, &engine.transfer_queue, engine.vk_alloc)

	// cmd buffer is destroyed when we destroy the pool (I think)
	vk.DestroyCommandPool(engine.vk_device, engine.vk_cmdpool, engine.vk_alloc)
	engine.vk_cmdbuf = {}

	vk.DestroyPipelineCache(engine.vk_device, engine.vk_pipeline_cache, engine.vk_alloc)
	vk.DestroyPipelineLayout(engine.vk_device, engine.vk_pipeline_layout, engine.vk_alloc)
	vk.DestroyPipeline(engine.vk_device, engine.vk_render_pipeline, engine.vk_alloc)
	vk.DestroyShaderModule(engine.vk_device, engine.vk_pipeline_shader, engine.vk_alloc)
	for image_view in engine.vk_swapchain_image_views {
		vk.DestroyImageView(engine.vk_device, image_view, engine.vk_alloc)
	}
	vk.DestroySwapchainKHR(engine.vk_device, engine.vk_swapchain, engine.vk_alloc)
	vk.DestroySurfaceKHR(engine.vk_instance, engine.vk_surface, engine.vk_alloc)
	vk.DestroyDevice(engine.vk_device, engine.vk_alloc)
	vk.DestroyDebugUtilsMessengerEXT(engine.vk_instance, engine.vk_messenger, engine.vk_alloc)
	vk.DestroyInstance(engine.vk_instance, engine.vk_alloc)

	delete(engine.arena.data)

	vk_alloc_cleanup()

	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}
