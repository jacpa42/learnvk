package learnvk

import "base:runtime"
import "core:log"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

device_meets_requirements :: proc(
	gpu: vk.PhysicalDevice,
	properties: vk.PhysicalDeviceProperties,
	features: vk.PhysicalDeviceFeatures,
	required_device_extensions: []cstring,
) -> bool {
	result: vk.Result

	if properties.deviceType != .DISCRETE_GPU {
		log.errorf("We need a discrete gpu, found: {}", properties.deviceType)
		return false
	}

	if !features.geometryShader {
		log.error("We cannot use a gpu without a geometry shader")
		return false
	}

	if properties.apiVersion < VULKAN_API_VERSION {
		log.errorf(
			"Required api version not supported by physical device: needs >= {x}, got {x}",
			VULKAN_API_VERSION,
			properties.apiVersion,
		)
		return false
	}

	//
	// Get the extensions supported by this device
	//
	count: u32
	result = vk.EnumerateDeviceExtensionProperties(gpu, nil, &count, nil)
	ensure(result == .SUCCESS)

	ext_properties := make([]vk.ExtensionProperties, count, context.temp_allocator)
	result = vk.EnumerateDeviceExtensionProperties(gpu, nil, &count, raw_data(ext_properties))
	ensure(result == .SUCCESS)

	//
	// Search the array for each one
	//
	for required in required_device_extensions {
		found := false
		for &enabled in ext_properties {
			enabled_name := transmute(cstring)(&enabled.extensionName)
			found = (enabled_name == required)
			if found {break}
		}

		if !found {
			log.fatalf("Failed to find device extension \"{}\"", required)
			return false
		}
	}

	return true
}

dump_mem_info :: proc(track: mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
		for _, entry in track.allocation_map {
			log.debugf("%v bytes @ %v", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
		for entry in track.bad_free_array {
			log.debugf("%p @ %v", entry.memory, entry.location)
		}
	}
}

glfw_error_callback :: proc "c" (error: i32, description: cstring) {
	context = runtime.default_context()
	context.logger = g_logger
	log.errorf("GLFW [%d]: %s", error, description)
}


callback_framebuffer_size :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	// TODO: Implement later
}

callback_window_minimize :: proc "c" (window: glfw.WindowHandle, iconified: i32) {
	// Get the engine from the window user pointer
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)
	engine.stop_rendering = bool(iconified) // Flag to not draw if we are minimized
}

vulkan_validation_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_type: vk.DebugUtilsMessageTypeFlagsEXT,
	p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	_: rawptr,
) -> b32 {
	if len(p_callback_data.pMessage) == 0 {return false}

	context = runtime.default_context()
	context.logger = g_logger
	MESSAGE_FORMAT := "%v: %s"

	for mt in message_type {
		if .WARNING in message_severity {
			log.warnf(MESSAGE_FORMAT, mt, p_callback_data.pMessage)
			return false
		}

		if .ERROR in message_severity {
			log.errorf(MESSAGE_FORMAT, mt, p_callback_data.pMessage)
			runtime.debug_trap()
		}

		log.infof(MESSAGE_FORMAT, mt, p_callback_data.pMessage)

		return false
	}

	unreachable()
}

