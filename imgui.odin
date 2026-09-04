package learnvk

import im "imgui"
import imglfw "imgui/imgui_impl_glfw"
import imvk "imgui/imgui_impl_vulkan"
import "vendor:glfw"
import vk "vendor:vulkan"

@(private = "file")
g_imgui_context: ImguiContext

ImguiContext :: struct #all_or_none {
	allocator:      ^vk.AllocationCallbacks,
	instance:       vk.Instance,
	physicalDevice: vk.PhysicalDevice,
	device:         vk.Device,
	queueFamily:    u32,
	queue:          vk.Queue,
	pipelineCache:  vk.PipelineCache,
	descriptorPool: vk.DescriptorPool,
}


imgui_init :: proc(engine: ^Engine) {
	g_imgui_context = {
		allocator      = engine.alloc,
		instance       = engine.instance,
		physicalDevice = engine.physical_device,
		device         = engine.device,
		queueFamily    = engine.queue_index,
		queue          = engine.queue,
		pipelineCache  = engine.pipeline_cache,
		descriptorPool = engine.descriptor_pool,
	}

	primary_monitor := glfw.GetPrimaryMonitor()
	assert(primary_monitor != nil)

	main_scale := imglfw.GetContentScaleForMonitor(primary_monitor)

	im.CHECKVERSION()
	im.CreateContext()

	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard}

	im.StyleColorsDark()
	style := im.GetStyle()
	im.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale

	init_info := imvk.InitInfo {
		ApiVersion = VULKAN_API_VERSION,
		Instance = engine.instance,
		PhysicalDevice = engine.physical_device,
		Device = engine.device,
		QueueFamily = engine.queue_index,
		Queue = engine.queue,
		DescriptorPoolSize = 64, // Optional: set to create internal ImageView descriptor pool automatically instead of using DescriptorPool.
		MinImageCount = engine.min_image_count, // >= 2
		ImageCount = u32(len(engine.swapchain_images)), // >= MinImageCount
		PipelineCache = engine.pipeline_cache, // Optional
		// Pipeline
		PipelineInfoMain = imvk.PipelineInfo {
			MSAASamples = {._1},
			PipelineRenderingCreateInfo = vk.PipelineRenderingCreateInfo {
				sType = .PIPELINE_RENDERING_CREATE_INFO,
				colorAttachmentCount = 1,
				pColorAttachmentFormats = &engine.swapchain_surface_format.format,
				depthAttachmentFormat = engine.depth_image_format,
			},
		},
		UseDynamicRendering = true,
		Allocator = engine.alloc,
		MinAllocationSize = 1024 * 1024,
	}

	loader_func :: proc "c" (function_name: cstring, user_data: rawptr) -> vk.ProcVoidFunction {
		instance := (vk.Instance)(user_data)
		return vk.GetInstanceProcAddr(instance, function_name)
	}

	ensure(imglfw.InitForVulkan(engine.window, true))
	ensure(imvk.LoadFunctions(init_info.ApiVersion, loader_func, engine.instance))
	ensure(imvk.Init(&init_info))
}

imgui_destroy :: proc(engine: ^Engine) {
	imglfw.Shutdown()
	imvk.Shutdown()
	im.Shutdown()
}

imgui_begin :: proc() {
	imglfw.NewFrame()
	imvk.NewFrame()
	im.NewFrame()
}

imgui_end :: proc(engine: ^Engine, commandBuffer: vk.CommandBuffer) {
	im.Render()
	imvk.RenderDrawData(im.GetDrawData(), commandBuffer)
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

