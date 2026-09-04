package learnvk

import vk "vendor:vulkan"

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

	// float main_scale = ImGui_ImplGlfw_GetContentScaleForMonitor(glfwGetPrimaryMonitor()); // Valid on GLFW 3.3+ only
}

