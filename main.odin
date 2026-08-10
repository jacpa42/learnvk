package learnvk

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:thread"
import "vendor:glfw"
import vk "vendor:vulkan"

VULKAN_API_VERSION :: vk.API_VERSION_1_3
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG
MAX_PHYSICAL_DEVICE_EXTENSIONS :: 4
MAX_SWAPCHAIN_IMAGES :: 8
FRAMES_IN_FLIGHT :: 2
MAX_DYNAMIC_STATE :: 90
APP_NAME: cstring = "learnvk"

g_logger: runtime.Logger
g_trace: trace.Context

Engine :: struct {
	// Windowing stuff
	window:                                 glfw.WindowHandle,
	stop_rendering:                         bool,
	framebuffer_resized:                    bool,
	models:                                 [ModelTag]Model,

	//
	// Vulkan stuff
	//
	vk_alloc:                               vk.AllocationCallbacks,
	vk_messenger:                           vk.DebugUtilsMessengerEXT,
	vk_instance:                            vk.Instance,

	//
	// Physical and Logical device
	//
	vk_physical_device:                     vk.PhysicalDevice,
	vk_physical_device_features:            vk.PhysicalDeviceFeatures,
	vk_physical_device_properties:          vk.PhysicalDeviceProperties,
	vk_physical_device_required_extensions: [dynamic; MAX_PHYSICAL_DEVICE_EXTENSIONS]cstring,
	vk_device:                              vk.Device,
	vk_queue:                               vk.Queue,
	vk_render_queue_index:                  u32,
	vk_surface:                             vk.SurfaceKHR,

	//
	// Swapchain
	//
	vk_swapchain:                           vk.SwapchainKHR,
	vk_swapchain_surface_format:            vk.SurfaceFormatKHR,
	vk_swapchain_extent:                    vk.Extent2D,
	vk_image_index:                         u32,
	vk_swapchain_images:                    [dynamic; MAX_SWAPCHAIN_IMAGES]vk.Image,
	vk_swapchain_image_views:               [dynamic; MAX_SWAPCHAIN_IMAGES]vk.ImageView,

	//
	// Pipeline
	//
	vk_pipeline_cache:                      vk.PipelineCache,
	vk_pipeline:                            Pipeline,
	vk_render_pipeline:                     [Pipeline]vk.Pipeline,
	vk_viewport:                            [Pipeline]vk.Viewport,
	vk_scissor:                             [Pipeline]vk.Rect2D,
	vk_color_attachment:                    [Pipeline]vk.PipelineColorBlendAttachmentState,
	vk_pipeline_dynamic_state:              [Pipeline][dynamic; MAX_DYNAMIC_STATE]vk.DynamicState,
	vk_pipeline_shader:                     [Pipeline]vk.ShaderModule,
	vk_pipeline_layout:                     [Pipeline]vk.PipelineLayout,

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

main :: proc() {
	//
	// Setup tracking allocator
	//
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(context.logger)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			dump_mem_info(track)
			mem.tracking_allocator_destroy(&track)
		}
	}

	//
	// Setup stack trace
	//
	when ODIN_DEBUG {
		context.assertion_failure_proc = assertion_failure_proc
		assert(trace.init(&g_trace))
	}

	//
	// Init engine
	//
	engine: Engine

	for &model, tag in engine.models {model.tag = tag}

	load_model_thread := thread.create_and_start_with_poly_data2(
		arg1 = (([^]Model)(&engine.models))[:NUM_MODELS],
		arg2 = (^bool)(nil),
		fn = load_all_models,
		init_context = context,
	)

	engine_init(&engine)
	defer engine_destroy(&engine)

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

	thread.destroy(load_model_thread)
	for model, tag in engine.models {
		fmt.eprintfln("{} vertexes = {}", tag, len(model.vertexes))
		fmt.eprintfln("{} normals = {}", tag, len(model.normals))
		fmt.eprintfln("{} texcoords = {}", tag, len(model.texcoords))
		fmt.eprintfln("{} triangles = {}", tag, len(model.mesh_triangles))
	}
}

frame :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Handle frame buffer resizing early
	//
	if engine.framebuffer_resized {
		engine.framebuffer_resized = false
		engine_recreate_swapchain(engine)
	}

	defer engine.vk_frame_index = (engine.vk_frame_index + 1) % FRAMES_IN_FLIGHT

	//
	// Before we begin our frame, we need to wait for the draw fence
	//
	result = vk.WaitForFences(
		engine.vk_device,
		1,
		&engine.vk_draw_fences[engine.vk_frame_index],
		true,
		bits.U64_MAX,
	)
	ensure(result == .SUCCESS)

	//
	// Get the first image in the swapchain for the render loop
	//
	result = vk.AcquireNextImageKHR(
		device = engine.vk_device,
		swapchain = engine.vk_swapchain,
		timeout = bits.U64_MAX,
		semaphore = engine.vk_present_complete_semas[engine.vk_frame_index],
		fence = {},
		pImageIndex = &engine.vk_image_index,
	)
	#partial switch result {
	case .SUCCESS, .SUBOPTIMAL_KHR:

	case .ERROR_OUT_OF_DATE_KHR:
		engine_recreate_swapchain(engine)
		return

	case:
		fmt.panicf("Failed to acquire swap chain image: {}", result)
	}

	//
	// Reset the draw fences. Must happen *after* we are sure we will render to
	// the current image view.
	//
	result = vk.ResetFences(engine.vk_device, 1, &engine.vk_draw_fences[engine.vk_frame_index])
	ensure(result == .SUCCESS)


	//
	// Fill the command buffer
	//
	{
		//
		// Begin recording the command buffer
		//
		begin_info := vk.CommandBufferBeginInfo {
			sType            = .COMMAND_BUFFER_BEGIN_INFO,
			pInheritanceInfo = nil,
		}

		vk.BeginCommandBuffer(engine.vk_cmdbufs[engine.vk_frame_index], &begin_info)
		defer vk.EndCommandBuffer(engine.vk_cmdbufs[engine.vk_frame_index])

		//
		// Make the image optimal to use as a colour attachment (ie render target?)
		//
		image_change_layout(
			cmdbuf = engine.vk_cmdbufs[engine.vk_frame_index],
			image = engine.vk_swapchain_images[engine.vk_image_index],
			old_layout = .UNDEFINED,
			new_layout = .COLOR_ATTACHMENT_OPTIMAL,
			src_access = {},
			dst_access = {.COLOR_ATTACHMENT_WRITE},
			src_stage = {.COLOR_ATTACHMENT_OUTPUT},
			dst_stage = {.COLOR_ATTACHMENT_OUTPUT},
		)

		//
		// At the end of the frame, convert the image back so we can present it
		//
		defer image_change_layout(
			cmdbuf = engine.vk_cmdbufs[engine.vk_frame_index],
			image = engine.vk_swapchain_images[engine.vk_image_index],
			old_layout = .COLOR_ATTACHMENT_OPTIMAL,
			new_layout = .PRESENT_SRC_KHR,
			src_access = {.COLOR_ATTACHMENT_WRITE},
			dst_access = {},
			src_stage = {.COLOR_ATTACHMENT_OUTPUT},
			dst_stage = {.BOTTOM_OF_PIPE},
		)

		//
		// Define a clear pass on the current swapchain image
		//
		attachment_info := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = engine.vk_swapchain_image_views[engine.vk_image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = vk.ClearValue{color = {uint32 = {0x74, 0x16, 0x18, 0xff}}},
		}

		render_info := vk.RenderingInfo {
			sType                = .RENDERING_INFO,
			flags                = {},
			renderArea           = {{0, 0}, engine.vk_swapchain_extent},
			layerCount           = 1,
			viewMask             = 0,
			colorAttachmentCount = 1,
			pColorAttachments    = &attachment_info,
			pDepthAttachment     = nil,
			pStencilAttachment   = nil,
		}

		//
		// Render to the image_view
		//
		{
			vk.CmdBeginRendering(engine.vk_cmdbufs[engine.vk_frame_index], &render_info)
			defer vk.CmdEndRendering(engine.vk_cmdbufs[engine.vk_frame_index])

			//
			// Run the graphics pipeline
			//
			vk.CmdBindPipeline(
				engine.vk_cmdbufs[engine.vk_frame_index],
				.GRAPHICS,
				engine.vk_render_pipeline[engine.vk_pipeline],
			)
			vk.CmdSetViewport(
				engine.vk_cmdbufs[engine.vk_frame_index],
				0,
				1,
				&engine.vk_viewport[engine.vk_pipeline],
			)
			vk.CmdSetScissor(
				engine.vk_cmdbufs[engine.vk_frame_index],
				0,
				1,
				&engine.vk_scissor[engine.vk_pipeline],
			)
			vk.CmdDraw(
				engine.vk_cmdbufs[engine.vk_frame_index],
				vertexCount = 3,
				instanceCount = 1,
				firstVertex = 0,
				firstInstance = 0,
			)
		}
	}


	//
	// Submit the command buffer
	//
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,

		//
		// Waits for these mutexs to be unlocked before we begin executing the
		// command buffer.
		//
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &engine.vk_present_complete_semas[engine.vk_frame_index],
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},

		//
		// The command buffers to execute
		//
		commandBufferCount   = 1,
		pCommandBuffers      = &engine.vk_cmdbufs[engine.vk_frame_index],

		//
		// These mutexs are locked for the duration of the submission/execution
		// of the command buffers.
		//
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &engine.vk_swapchain_semas[engine.vk_image_index],
	}

	result = vk.QueueSubmit(
		engine.vk_queue,
		1,
		&submit_info,
		engine.vk_draw_fences[engine.vk_frame_index],
	)
	ensure(result == .SUCCESS)

	//
	// Present the frame on the screen
	//
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		swapchainCount     = 1,
		pSwapchains        = &engine.vk_swapchain,
		pImageIndices      = &engine.vk_image_index,
		pResults           = nil,

		//
		// Wait on the render finished mutex which is signalled once the command
		// buffer finishes execution.
		//
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &engine.vk_swapchain_semas[engine.vk_image_index],
	}

	result = vk.QueuePresentKHR(engine.vk_queue, &present_info)
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		engine_recreate_swapchain(engine)
	} else {
		ensure(result == .SUCCESS)
	}
}

engine_init :: proc(engine: ^Engine) {
	g_logger = context.logger

	result: vk.Result

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
		glfw.SetFramebufferSizeCallback(engine.window, callback_framebuffer_size)
		glfw.SetWindowIconifyCallback(engine.window, callback_window_minimize)
	}

	//
	// Load all Vulkan global functions (ie without having an instance yet)
	//
	{
		vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	}

	//
	// Create the Vulkan allocator
	//
	{
		engine.vk_alloc = vk_alloc_init()
	}

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
	{
		vk.GetInstanceProcAddr = auto_cast glfw.GetInstanceProcAddress
		vk.load_proc_addresses(engine.vk_instance)
	}

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
		ensure(
			vk.CreateDebugUtilsMessengerEXT(
				engine.vk_instance,
				&create_info,
				&engine.vk_alloc,
				&engine.vk_messenger,
			) ==
			.SUCCESS,
		)
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
	engine.vk_pipeline = .model_shader

	//
	// Create the shader module
	//
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = slice.size(PIPELINE_BYTE_CODE[engine.vk_pipeline]),
		pCode    = raw_data(PIPELINE_BYTE_CODE[engine.vk_pipeline]),
	}

	result = vk.CreateShaderModule(
		engine.vk_device,
		&shader_module_create_info,
		&engine.vk_alloc,
		&engine.vk_pipeline_shader[engine.vk_pipeline],
	)
	ensure(result == .SUCCESS)

	//
	// For each stage that the shader defines, define the stage creation info
	//
	ensure(
		len(PIPELINE_STAGES[engine.vk_pipeline]) == len(PIPELINE_STAGE_NAMES[engine.vk_pipeline]),
	)
	shader_stage_create_info: [dynamic; PIPELINE_MAX_STAGES]vk.PipelineShaderStageCreateInfo

	for shader_stage, stage_index in PIPELINE_STAGES[engine.vk_pipeline] {
		append(
			&shader_stage_create_info,
			vk.PipelineShaderStageCreateInfo {
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				flags = {},
				stage = {shader_stage},
				module = engine.vk_pipeline_shader[engine.vk_pipeline],
				pName = PIPELINE_STAGE_NAMES[engine.vk_pipeline][stage_index],
				pSpecializationInfo = nil,
			},
		)
	}

	//
	// Setup dynamic state for the pipeline. At the moment, just viewport and scissor.
	//
	append(
		&engine.vk_pipeline_dynamic_state[engine.vk_pipeline],
		..[]vk.DynamicState{.VIEWPORT, .SCISSOR},
	)

	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(engine.vk_pipeline_dynamic_state[engine.vk_pipeline])),
		pDynamicStates    = raw_data(engine.vk_pipeline_dynamic_state[engine.vk_pipeline][:]),
	}

	//
	// Setup the vertex data for the pipeline
	//

	vertex_create_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,

		// vertex bindings
		vertexBindingDescriptionCount   = u32(len(PIPELINE_VERTEX_BINDING[engine.vk_pipeline])),
		pVertexBindingDescriptions      = raw_data(PIPELINE_VERTEX_BINDING[engine.vk_pipeline]),

		// vertex attribute
		vertexAttributeDescriptionCount = u32(len(PIPELINE_VERTEX_ATTRIBUTE[engine.vk_pipeline])),
		pVertexAttributeDescriptions    = raw_data(PIPELINE_VERTEX_ATTRIBUTE[engine.vk_pipeline]),
	}

	//
	// Define the `shape` (kinda) of the vertices
	//
	input_assembly_create_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	//
	// Do the viewport creation
	//
	engine.vk_viewport[engine.vk_pipeline] = vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(engine.vk_swapchain_extent.width),
		height   = f32(engine.vk_swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}

	engine.vk_scissor[engine.vk_pipeline] = vk.Rect2D {
		offset = {},
		extent = engine.vk_swapchain_extent,
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
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1,
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
	engine.vk_color_attachment[engine.vk_pipeline] = {
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
		pAttachments    = &engine.vk_color_attachment[engine.vk_pipeline],
	}

	//
	// Define and create the pipeline layout
	//
	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,

		// TODO: Parse the json reflect information on the shader provided by
		// slangc to define these structures automatically

		// set layouts
		setLayoutCount         = 0,
		pSetLayouts            = nil,

		// push constants
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	result = vk.CreatePipelineLayout(
		engine.vk_device,
		&pipeline_layout_create_info,
		&engine.vk_alloc,
		&engine.vk_pipeline_layout[engine.vk_pipeline],
	)
	ensure(result == .SUCCESS)
	ensure(engine.vk_pipeline_layout[engine.vk_pipeline] != {})

	//
	// Define the rendering pipeline
	//
	render_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,

		// We are using 1 color attachment with the same format as our
		// surface.
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &engine.vk_swapchain_surface_format.format,
		viewMask                = {}, // unused 2026-08-07
		depthAttachmentFormat   = {}, // unused 2026-08-07
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
		stageCount          = u32(len(PIPELINE_STAGES[engine.vk_pipeline])),
		pStages             = &shader_stage_create_info[0],
		pVertexInputState   = &vertex_create_info,
		pInputAssemblyState = &input_assembly_create_info,
		pTessellationState  = nil,
		pViewportState      = &viewport_create_info,
		pRasterizationState = &raster_create_info,
		pMultisampleState   = &multisample_create_info,
		pDepthStencilState  = nil,
		pColorBlendState    = &color_blend_create_info,
		pDynamicState       = &dynamic_state_create_info,
		layout              = engine.vk_pipeline_layout[engine.vk_pipeline],

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
		&engine.vk_render_pipeline[engine.vk_pipeline],
	)
	ensure(result == .SUCCESS)
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

	case:
		log.infof("Found a bunch ({}) of gpus, using first one.", len(devices))
		fallthrough
	case 1:
		engine.vk_physical_device = devices[0]
	}

	ensure(engine.vk_physical_device != nil)
	vk.GetPhysicalDeviceProperties(
		engine.vk_physical_device,
		&engine.vk_physical_device_properties,
	)
	vk.GetPhysicalDeviceFeatures(engine.vk_physical_device, &engine.vk_physical_device_features)

	//
	// Define the features we need for our application to run
	//
	exts := &engine.vk_physical_device_required_extensions
	append(exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	append(exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)
	append(exts, vk.KHR_SHADER_DRAW_PARAMETERS_EXTENSION_NAME)
	append(exts, vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME)
	append(exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)


	ensure(
		device_meets_requirements(
			engine.vk_physical_device,
			engine.vk_physical_device_properties,
			engine.vk_physical_device_features,
			engine.vk_physical_device_required_extensions[:],
		),
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
		pEnabledFeatures        = &engine.vk_physical_device_features,
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

	engine_init_swapchain(engine)
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
	present_mode: vk.PresentModeKHR
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

		if slice.contains(present_modes, vk.PresentModeKHR.MAILBOX) {
			present_mode = .MAILBOX
			present_mode = .FIFO
		} else {
			present_mode = .FIFO
		}
	}

	//
	// Set the a bunch of stuff based of the capabilities of the surface
	//
	min_image_count: u32
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
			min_image_count = 2
		} else if present_mode == .MAILBOX {
			min_image_count = 3
		}

		min_image_count = clamp(min_image_count, min_images, max_images)

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
		minImageCount    = min_image_count,
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

		result = vk.GetSwapchainImagesKHR(
			engine.vk_device,
			engine.vk_swapchain,
			&count,
			raw_data(engine.vk_swapchain_images[:]),
		)
		ensure(result == .SUCCESS)
	}

	//
	// Create the image views for the swap chain
	//
	resize(&engine.vk_swapchain_image_views, len(engine.vk_swapchain_images))

	for image, i in engine.vk_swapchain_images {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			flags = {},
			image = image,
			viewType = .D2,
			format = engine.vk_swapchain_surface_format.format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		result = vk.CreateImageView(
			engine.vk_device,
			&create_info,
			&engine.vk_alloc,
			&engine.vk_swapchain_image_views[i],
		)
		ensure(result == .SUCCESS)
	}
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DeviceWaitIdle(engine.vk_device)

	for &model in engine.models {
		model_destroy(&model)
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
	for p in Pipeline {
		vk.DestroyPipelineLayout(engine.vk_device, engine.vk_pipeline_layout[p], &engine.vk_alloc)
		vk.DestroyPipeline(engine.vk_device, engine.vk_render_pipeline[p], &engine.vk_alloc)
	}
	for shader in engine.vk_pipeline_shader {
		vk.DestroyShaderModule(engine.vk_device, shader, &engine.vk_alloc)
	}
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
