package learnvk

import "base:runtime"
import "core:c"
import "core:debug/trace"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
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
		context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(context.logger)

		track: trace.Tracking_Allocator
		trace.tracking_allocator_init(&track, context.allocator)
		defer trace.tracking_allocator_destroy(&track)

		context.allocator = trace.tracking_allocator(&track)
		defer trace.tracking_allocator_print_results(&track)

		context.assertion_failure_proc = trace.assertion_failure_proc
	}

	//
	// Init engine
	//
	engine: Engine
	engine_init(&engine)
	defer engine_destroy(&engine)

	//
	// Main loop
	//
	frame_watch: time.Stopwatch
	for !glfw.WindowShouldClose(engine.window) {
		time.stopwatch_reset(&frame_watch)
		time.stopwatch_start(&frame_watch)
		defer engine.delta_time = f32(f64(time.stopwatch_duration(frame_watch)) * 1e-9)

		glfw.PollEvents()

		if engine.stop_rendering {
			glfw.WaitEvents()
			continue
		}

		frame(&engine)

		free_all(context.temp_allocator)
		time.sleep(4 * time.Millisecond)
	}
}

engine_init :: proc(engine: ^Engine) {
	g_logger = context.logger

	result: vk.Result

	//
	// Setup the default state to generate the uniforms
	//
	engine.camera = {
		speed       = 0.01,
		sensitivity = 0.0005,
		pitch       = 0,
		yaw         = 0,
		pos         = {0, 0, 0},
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

		if res == .Ok {
			engine.model_loaded |= {tag}
		} else {
			log.errorf("Failed to load \"{}\": {}", model_path, res)
		}
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
			&engine.vk_alloc,
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
			&engine.vk_alloc,
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
			&engine.vk_alloc,
			&engine.vk_pipeline_cache,
		)
		ensure(result == .SUCCESS)
	}

	//
	// Initialize the graphics pipelines
	//
	engine_init_graphics_pipeline(engine)
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

	result := vk.CreateInstance(&create_info, &engine.vk_alloc, &engine.vk_instance)
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
			&engine.vk_alloc,
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
		&engine.vk_alloc,
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
		&engine.vk_alloc,
		&engine.vk_render_pipeline,
	)
	ensure(result == .SUCCESS)
}

engine_init_buffer_and_images :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Create the uniform buffers
	//
	for i in 0 ..< len(engine.vk_uniform_buffers) {
		size := vk.DeviceSize(size_of(Uniforms))
		usage := vk.BufferUsageFlags{.UNIFORM_BUFFER}
		desired_properties := vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}

		engine.vk_uniform_buffers[i], engine.vk_uniform_buffers_memory[i] = engine_create_buffer(
			engine,
			size,
			usage,
			desired_properties,
		)

		//
		// Map the uniform buffer so we don't need to remap it every frame
		//
		result = vk.MapMemory(
			engine.vk_device,
			engine.vk_uniform_buffers_memory[i],
			offset = 0,
			size = size_of(Uniforms),
			flags = {},
			ppData = &engine.vk_uniform_buffers_mmapped[i],
		)
		ensure(result == .SUCCESS)
	}

	//
	// Create and map the transfer buffer
	//
	engine.vk_transfer_buffer, engine.vk_transfer_buffer_memory = engine_create_buffer(
		engine,
		STAGING_BUFFER_SIZE,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	result = vk.MapMemory(
		engine.vk_device,
		engine.vk_transfer_buffer_memory,
		offset = 0,
		size = auto_cast vk.WHOLE_SIZE,
		flags = {},
		ppData = &engine.vk_transfer_buffer_mmap,
	)
	ensure(result == .SUCCESS)

	//
	// Fill the vertex buffers with data
	//
	for model_tag in engine.model_loaded {
		m := engine.models[model_tag]

		for buffer_tag in ModelBuffer {
			memory_to_upload: []byte
			size: vk.DeviceSize
			usage: vk.BufferUsageFlags
			desired_properties: vk.MemoryPropertyFlags

			switch buffer_tag {

			case .model_indices:
				memory_to_upload = to_bytes(model.get_all_indices(m))
				size = vk.DeviceSize(len(memory_to_upload))
				usage = {.INDEX_BUFFER, .TRANSFER_DST}
				desired_properties = {.DEVICE_LOCAL}

			case .model_vertices:
				memory_to_upload = to_bytes(model.get_vertices(m))
				size = vk.DeviceSize(len(memory_to_upload))
				usage = {.VERTEX_BUFFER, .TRANSFER_DST}
				desired_properties = {.DEVICE_LOCAL}
			}

			if size == 0 {
				ensure(len(memory_to_upload) == 0)
				log.warnf("Skipping {}.{}", model_tag, buffer_tag)
				continue
			}

			log.infof(
				"Uploading {}.{} ({} Mb)",
				model_tag,
				buffer_tag,
				f32(slice.size(memory_to_upload)) * 1e-6,
			)

			//
			// Create the buffer
			//
			assert(len(memory_to_upload) > 0)
			assert(int(size) == slice.size(memory_to_upload))
			assert(slice.size(memory_to_upload) <= STAGING_BUFFER_SIZE)

			engine.vk_model_buffer[model_tag][buffer_tag], engine.vk_vertex_buffers_memory[model_tag][buffer_tag] =
				engine_create_buffer(engine, size, usage, desired_properties)

			//
			// upload first to the staging buffer
			//
			mem.copy_non_overlapping(
				dst = engine.vk_transfer_buffer_mmap,
				src = raw_data(memory_to_upload),
				len = slice.size(memory_to_upload),
			)

			//
			// The copy into our buffer. This involves submitting command via the
			// command buffer.
			//

			cmd_oneshot_begin(engine.vk_cmdbufs[engine.vk_frame_index])
			defer cmd_oneshot_end(engine.vk_cmdbufs[engine.vk_frame_index], engine.vk_queue)

			region := vk.BufferCopy {
					srcOffset = 0,
					dstOffset = 0,
					size      = auto_cast slice.size(memory_to_upload),
				}

			vk.CmdCopyBuffer(
				commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
				srcBuffer = engine.vk_transfer_buffer,
				dstBuffer = engine.vk_model_buffer[model_tag][buffer_tag],
				regionCount = 1,
				pRegions = &region,
			)
		}
	}

	//
	// Load all the textures we could possibly need
	//
	engine_load_all_textures(engine)

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
			&engine.vk_alloc,
			&engine.vk_image_sampler[tag],
		)
		ensure(result == .SUCCESS)
	}
}

engine_load_all_textures :: proc(engine: ^Engine) {
	//
	// Setup a single pixel fallback buffer
	//
	{
		engine.fallback_texture = {
			engine_create_image(
				device = engine.vk_device,
				alloc = &engine.vk_alloc,
				width = 1,
				height = 1,
				format = .R8G8B8A8_SNORM,
				usage = {.SAMPLED, .TRANSFER_DST},
				desired_properties = {.DEVICE_LOCAL},
			),
		}

		pixel_data := []u8{0x00, 0xff, 0x00, 0x00}
		engine_upload_image_data(
			engine,
			engine.fallback_texture.image,
			pixel_data,
			width = 1,
			height = 1,
		)
	}

	//
	// Define all the texture load tasks
	//
	tasks := make([dynamic]LoadTaskData, 0, 64, context.temp_allocator)
	defer for t in tasks {
		if t.output.data != nil {
			stb_image.image_free(raw_data(t.output.data))
		}
	}

	for tag in engine.model_loaded {

		meshes := model.get_meshes(engine.models[tag])
		model := engine.models[tag]

		engine.vk_mesh_images[tag] = make([][MaterialType]Texture, len(meshes))

		for mesh, mesh_index in meshes {
			mesh_textures_ptr := &engine.vk_mesh_images[tag][mesh_index]
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
		threads[thread_index] = thread.create_and_start_with_poly_data3(
			arg1 = engine.vk_device,
			arg2 = &engine.vk_alloc,
			arg3 = task_slice,
			fn = eat_load_task,
		)

		thread_index += 1
		num_tasks_consumed += len(task_slice)
	}

	//
	// Eat the remainder on main thread
	//
	eat_load_task(engine.vk_device, &engine.vk_alloc, tasks[num_tasks_consumed:])
	for t in threads[:thread_index] do thread.destroy(t)

	for task in tasks {
		if task.output.ok {
			log.infof("Loaded {} <-> %#v", task.input.texture_cpath, task.input.texture)
			engine_upload_image_data(
				engine,
				task.input.texture.image,
				task.output.data,
				task.output.width,
				task.output.height,
			)
		} else {
			log.warnf("Didn't succeed in the task load for \"{}\"", task.input.texture_cpath)
		}
	}
}

engine_init_descriptor_set_layouts :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Specify and create the descriptor pool for all buffers
	//
	assert(card(engine.model_loaded) > 0)
	total_meshes: u32
	for tag in engine.model_loaded {
		total_meshes += u32(len(model.get_meshes(engine.models[tag])))
	}

	maxSets: u32
	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = 0},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 0},
	}
	for layout in SHADER_PIPELINE_SET_LAYOUTS {
		if layout.descriptorType == .UNIFORM_BUFFER do pool_sizes[0].descriptorCount += total_meshes
		if layout.descriptorType == .COMBINED_IMAGE_SAMPLER do pool_sizes[1].descriptorCount += total_meshes

		maxSets += total_meshes
	}

	pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = maxSets,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = raw_data(&pool_sizes),
	}

	result = vk.CreateDescriptorPool(
		engine.vk_device,
		&pool_create_info,
		&engine.vk_alloc,
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
			&engine.vk_alloc,
			&engine.vk_set_layout,
		)
		ensure(result == .SUCCESS)
	}

	//
	// Temporarily dupe the layouts
	//

	for model_tag in engine.model_loaded {
		num_meshes := len(model.get_meshes(engine.models[model_tag]))
		engine.vk_descriptor_sets[model_tag] = make([]vk.DescriptorSet, num_meshes)

		for &descriptor_set in engine.vk_descriptor_sets[model_tag] {

			//
			// Allocate the descriptor sets
			//

			alloc_info := vk.DescriptorSetAllocateInfo {
				sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool     = engine.vk_descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts        = &engine.vk_set_layout,
			}

			result = vk.AllocateDescriptorSets(engine.vk_device, &alloc_info, &descriptor_set)
			ensure(result == .SUCCESS)
		}
	}

	//
	// Configure the descriptor sets for the uniform buffers
	//
	for descriptor_sets, tag in engine.vk_descriptor_sets {
		for set, i in descriptor_sets {
			engine_configure_descriptor_set(
				engine = engine,
				model_tag = tag,
				mesh_index = i,
				descriptor_set = set,
			)
		}
	}
}

engine_configure_descriptor_set :: proc(
	engine: ^Engine,
	model_tag: ModelTag,
	mesh_index: int,
	descriptor_set: vk.DescriptorSet,
) {

	LOG :: true

	when LOG do log.infof(
		"DescriptorSet({}) {}.{}",
		descriptor_set,
		model_tag,
		model.get_mesh_name(engine.models[model_tag], mesh_index),
	)
	when LOG do defer fmt.eprintln()

	#assert(PIPELINE == .shader)
	for binding, binding_tag in SHADER_PIPELINE_SET_LAYOUTS {

		write_ds := vk.WriteDescriptorSet {
			sType            = .WRITE_DESCRIPTOR_SET,
			dstSet           = descriptor_set,
			dstBinding       = binding.binding,
			dstArrayElement  = 0,
			descriptorCount  = binding.descriptorCount,
			descriptorType   = binding.descriptorType,
			pBufferInfo      = nil,
			pImageInfo       = nil,
			pTexelBufferView = nil,
		}
		buffer_info: vk.DescriptorBufferInfo
		image_info: vk.DescriptorImageInfo

		//
		// Define which buffer to bind to this descriptor set
		//


		switch binding_tag {

		case .uniforms:
			// TODO: Maybe we want a descriptor set per FRAME_IN_FLIGHT?
			buffer_info = vk.DescriptorBufferInfo {
				buffer = engine.vk_uniform_buffers[0],
				range  = vk.DeviceSize(vk.WHOLE_SIZE),
			}

			write_ds.pBufferInfo = &buffer_info

			when LOG do fmt.eprintfln("{}", buffer_info)

		case .tex_diffuse:
			mtype := MaterialType.diffuse

			image_info = vk.DescriptorImageInfo {
				sampler     = engine.vk_image_sampler[mtype],
				imageView   = engine.vk_mesh_images[model_tag][mesh_index][mtype].view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}

			//
			// If the image view is nil, then this thing probably doesn't have a
			// diffuse texture, in which case we use the fallback texture
			//
			if image_info.imageView == 0 {
				image_info.imageView = engine.fallback_texture.view
			}

			write_ds.pImageInfo = &image_info

			when LOG do fmt.eprintfln("{}", image_info)

		case .tex_emissive:
			mtype := MaterialType.emissive

			image_info = vk.DescriptorImageInfo {
				sampler     = engine.vk_image_sampler[mtype],
				imageView   = engine.vk_mesh_images[model_tag][mesh_index][mtype].view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}

			//
			// If the image view is nil, then this thing probably doesn't have a
			// diffuse texture, in which case we use the fallback texture
			//
			if image_info.imageView == 0 {
				image_info.imageView = engine.fallback_texture.view
			}

			write_ds.pImageInfo = &image_info

			when LOG do fmt.eprintfln("{}", image_info)

		case .tex_normal:
			mtype := MaterialType.normal

			image_info = vk.DescriptorImageInfo {
				sampler     = engine.vk_image_sampler[mtype],
				imageView   = engine.vk_mesh_images[model_tag][mesh_index][mtype].view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}

			//
			// If the image view is nil, then this thing probably doesn't have a
			// diffuse texture, in which case we use the fallback texture
			//
			if image_info.imageView == 0 {
				image_info.imageView = engine.fallback_texture.view
			}

			write_ds.pImageInfo = &image_info

			when LOG do fmt.eprintfln("{}", image_info)

		case .tex_specular:
			mtype := MaterialType.specular

			image_info = vk.DescriptorImageInfo {
				sampler     = engine.vk_image_sampler[mtype],
				imageView   = engine.vk_mesh_images[model_tag][mesh_index][mtype].view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}

			//
			// If the image view is nil, then this thing probably doesn't have a
			// diffuse texture, in which case we use the fallback texture
			//
			if image_info.imageView == 0 {
				image_info.imageView = engine.fallback_texture.view
			}

			write_ds.pImageInfo = &image_info

			when LOG do fmt.eprintfln("{}", image_info)
		}

		vk.UpdateDescriptorSets(engine.vk_device, 1, &write_ds, 0, nil)

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
		queueFamilyIndex = engine.vk_render_queue_index,
	}

	result = vk.CreateCommandPool(
		engine.vk_device,
		&cmd_pool_create_info,
		&engine.vk_alloc,
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
		commandBufferCount = u32(len(engine.vk_cmdbufs)),
	}

	result = vk.AllocateCommandBuffers(
		engine.vk_device,
		&cmdbuf_alloc_create_info,
		raw_data(engine.vk_cmdbufs[:]),
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
				&engine.vk_alloc,
				&sema,
			)
			ensure(result == .SUCCESS)
		}

		//
		// Create the semaphores for the frame presentation completion
		//
		for &sema in engine.vk_present_complete_semas {
			result = vk.CreateSemaphore(
				engine.vk_device,
				&sema_create_info,
				&engine.vk_alloc,
				&sema,
			)
			ensure(result == .SUCCESS)
		}

		//
		// Create the fences
		//
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		for &fence in engine.vk_draw_fences {
			result = vk.CreateFence(engine.vk_device, &fence_create_info, &engine.vk_alloc, &fence)
			ensure(result == .SUCCESS)
		}
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
		exts := &engine.vk_physical_device_required_extensions
		append(exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
		append(exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)
		append(exts, vk.KHR_SHADER_DRAW_PARAMETERS_EXTENSION_NAME)
		append(exts, vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME)
		append(exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)

		if device_meets_requirements(
			physical_device,
			physical_device_properties,
			physical_device_features,
			engine.vk_physical_device_required_extensions[:],
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
	engine.vk_render_queue_index = bits.U32_MAX
	for properties, index in queue_properties {

		has_graphics := .GRAPHICS in properties.queueFlags

		has_presentation: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(
			engine.vk_physical_device,
			u32(index),
			engine.vk_surface,
			&has_presentation,
		)

		if has_graphics && has_presentation {
			engine.vk_render_queue_index = u32(index)
			break
		}
	}

	ensure(
		engine.vk_render_queue_index != bits.U32_MAX,
		"We need a queue with graphics capabilities",
	)

	queue_priority: f32 = 0.5 // Doesn't really matter for 1 queue?
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = engine.vk_render_queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	//
	// Enable dynamic local read
	//
	render_local_read := vk.PhysicalDeviceDynamicRenderingLocalReadFeatures {
		sType                     = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES,
		pNext                     = nil,
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
		enabledExtensionCount   = u32(len(engine.vk_physical_device_required_extensions)),
		ppEnabledExtensionNames = raw_data(&engine.vk_physical_device_required_extensions),

		// features
		pEnabledFeatures        = &physical_device_features,
	}

	result = vk.CreateDevice(
		engine.vk_physical_device,
		&create_info,
		&engine.vk_alloc,
		&engine.vk_device,
	)
	ensure(result == .SUCCESS)
	ensure(engine.vk_device != nil)

	//
	// Get the render/graphics queue
	//
	vk.GetDeviceQueue(engine.vk_device, engine.vk_render_queue_index, 0, &engine.vk_queue)
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
		if max_images == 0 {max_images = bits.U32_MAX}

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
		&engine.vk_alloc,
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
			&engine.vk_alloc,
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
		&engine.vk_alloc,
		&engine.vk_depth_image,
	)
	ensure(result == .SUCCESS)

	memory_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(engine.vk_device, engine.vk_depth_image, &memory_requirements)

	memory_type_index := device_get_memory_type_index(memory_requirements, {.DEVICE_LOCAL})

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = memory_requirements.size,
		memoryTypeIndex = memory_type_index,
	}
	result = vk.AllocateMemory(
		engine.vk_device,
		&alloc_info,
		&engine.vk_alloc,
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
		&engine.vk_alloc,
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

	vk.DestroySwapchainKHR(engine.vk_device, engine.vk_swapchain, &engine.vk_alloc)
	engine.vk_swapchain = 0

	for image_view in engine.vk_swapchain_image_views {
		vk.DestroyImageView(engine.vk_device, image_view, &engine.vk_alloc)
	}
	clear(&engine.vk_swapchain_image_views)

	vk.FreeMemory(engine.vk_device, engine.vk_depth_image_memory, &engine.vk_alloc)
	vk.DestroyImageView(engine.vk_device, engine.vk_depth_image_view, &engine.vk_alloc)
	vk.DestroyImage(engine.vk_device, engine.vk_depth_image, &engine.vk_alloc)

	engine_init_swapchain(engine)
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DeviceWaitIdle(engine.vk_device)

	for dset in engine.vk_descriptor_sets {
		delete(dset)
	}

	for sampler in engine.vk_image_sampler {
		vk.DestroySampler(engine.vk_device, sampler, &engine.vk_alloc)
	}

	vk.FreeMemory(engine.vk_device, engine.fallback_texture.memory, &engine.vk_alloc)
	vk.DestroyImageView(engine.vk_device, engine.fallback_texture.view, &engine.vk_alloc)
	vk.DestroyImage(engine.vk_device, engine.fallback_texture.image, &engine.vk_alloc)

	for image_list in engine.vk_mesh_images {
		defer delete(image_list)

		for image_by_material in image_list {
			for image in image_by_material {
				vk.FreeMemory(engine.vk_device, image.memory, &engine.vk_alloc)
				vk.DestroyImageView(engine.vk_device, image.view, &engine.vk_alloc)
				vk.DestroyImage(engine.vk_device, image.image, &engine.vk_alloc)
			}
		}
	}


	vk.FreeMemory(engine.vk_device, engine.vk_transfer_buffer_memory, &engine.vk_alloc)
	vk.DestroyBuffer(engine.vk_device, engine.vk_transfer_buffer, &engine.vk_alloc)

	vk.DestroyDescriptorPool(engine.vk_device, engine.vk_descriptor_pool, &engine.vk_alloc)

	vk.FreeMemory(engine.vk_device, engine.vk_depth_image_memory, &engine.vk_alloc)
	vk.DestroyImageView(engine.vk_device, engine.vk_depth_image_view, &engine.vk_alloc)
	vk.DestroyImage(engine.vk_device, engine.vk_depth_image, &engine.vk_alloc)

	vk.DestroyDescriptorSetLayout(engine.vk_device, engine.vk_set_layout, &engine.vk_alloc)

	for mem in engine.vk_uniform_buffers_memory {
		vk.FreeMemory(engine.vk_device, mem, &engine.vk_alloc)
	}
	for buffer_mem_slice in engine.vk_vertex_buffers_memory {
		for mem in buffer_mem_slice {
			vk.FreeMemory(engine.vk_device, mem, &engine.vk_alloc)
		}
	}

	for buffer in engine.vk_uniform_buffers {
		vk.DestroyBuffer(engine.vk_device, buffer, &engine.vk_alloc)
	}
	for model_buffers in engine.vk_model_buffer {
		for buffer in model_buffers {
			vk.DestroyBuffer(engine.vk_device, buffer, &engine.vk_alloc)
		}
	}

	for tag in engine.model_loaded {
		model.destroy(&engine.models[tag])
	}

	for sema in engine.vk_swapchain_semas {
		vk.DestroySemaphore(engine.vk_device, sema, &engine.vk_alloc)
	}

	for sema in engine.vk_present_complete_semas {
		vk.DestroySemaphore(engine.vk_device, sema, &engine.vk_alloc)
	}

	for fence in engine.vk_draw_fences {
		vk.DestroyFence(engine.vk_device, fence, &engine.vk_alloc)
	}

	// cmd buffer is destroyed when we destroy the pool (I think)
	vk.DestroyCommandPool(engine.vk_device, engine.vk_cmdpool, &engine.vk_alloc)
	engine.vk_cmdbufs = {}

	vk.DestroyPipelineCache(engine.vk_device, engine.vk_pipeline_cache, &engine.vk_alloc)
	vk.DestroyPipelineLayout(engine.vk_device, engine.vk_pipeline_layout, &engine.vk_alloc)
	vk.DestroyPipeline(engine.vk_device, engine.vk_render_pipeline, &engine.vk_alloc)
	vk.DestroyShaderModule(engine.vk_device, engine.vk_pipeline_shader, &engine.vk_alloc)
	for image_view in engine.vk_swapchain_image_views {
		vk.DestroyImageView(engine.vk_device, image_view, &engine.vk_alloc)
	}
	vk.DestroySwapchainKHR(engine.vk_device, engine.vk_swapchain, &engine.vk_alloc)
	vk.DestroySurfaceKHR(engine.vk_instance, engine.vk_surface, &engine.vk_alloc)
	vk.DestroyDevice(engine.vk_device, &engine.vk_alloc)
	vk.DestroyDebugUtilsMessengerEXT(engine.vk_instance, engine.vk_messenger, &engine.vk_alloc)
	vk.DestroyInstance(engine.vk_instance, &engine.vk_alloc)

	vk_alloc_cleanup()

	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}
