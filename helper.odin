package learnvk

import "base:runtime"
import "core:debug/trace"
import "core:log"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

//
// Used for converting the memory format of an image to be more suitable for
// different tasks such as rendering and displaying to the screen.
//
image_change_layout :: proc(
	cmdbuf: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
) {
	image_memory_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcAccessMask = src_access,
		srcStageMask = src_stage,
		dstAccessMask = dst_access,
		dstStageMask = dst_stage,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dependancy_info := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		dependencyFlags          = {},

		// mem barrier
		memoryBarrierCount       = 0,
		pMemoryBarriers          = nil,

		// buf mem barrier
		bufferMemoryBarrierCount = 0,
		pBufferMemoryBarriers    = nil,

		// image mem barrier
		imageMemoryBarrierCount  = 1,
		pImageMemoryBarriers     = &image_memory_barrier,
	}

	vk.CmdPipelineBarrier2(cmdbuf, &dependancy_info)
}

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
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)
	engine.framebuffer_resized = true
}

callback_window_minimize :: proc "c" (window: glfw.WindowHandle, iconified: i32) {
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)
	engine.stop_rendering = bool(iconified)
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
			unreachable()
		}

		log.infof(MESSAGE_FORMAT, mt, p_callback_data.pMessage)

		return false
	}

	return false
}

assertion_failure_proc :: proc(prefix, message: string, loc := #caller_location) -> ! {
	runtime.print_caller_location(loc)
	runtime.print_string(" ")
	runtime.print_string(prefix)
	if len(message) > 0 {
		runtime.print_string(": ")
		runtime.print_string(message)
	}
	runtime.print_byte('\n')

	ctx := &g_trace
	if !trace.in_resolve(ctx) {
		buf: [64]trace.Frame
		runtime.print_string("Debug Trace:\n")
		frames := trace.frames(ctx, 1, buf[:])
		for f, i in frames {
			fl := trace.resolve(ctx, f, context.temp_allocator)
			if fl.loc.file_path == "" && fl.loc.line == 0 {
				continue
			}
			runtime.print_caller_location(fl.loc)
			runtime.print_string(" - frame ")
			runtime.print_int(i)
			runtime.print_byte('\n')
		}
	}
	runtime.trap()
}

make_or_clear :: proc(item: ^[dynamic]$T) {
	if item^ == nil {
		item^ = make([dynamic]T)
	} else {
		clear(item)
	}
}

