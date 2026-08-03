package learnvk

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:thread"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

APP_NAME: cstring = "learnvk"

g_logger: runtime.Logger

Engine :: struct {
	// Windowing stuff
	window:             glfw.WindowHandle,
	stop_rendering:     bool,

	// Vulkan stuff
	vk_alloc:           vk.AllocationCallbacks,
	vk_instance:        vk.Instance,
	vk_physical_device: vk.PhysicalDevice,
	vk_surface:         vk.SurfaceKHR,
	vk_device:          vk.Device,
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
	// Init engine
	//
	engine: Engine
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

		render(&engine)
		time.sleep(100 * time.Millisecond)
	}
}

engine_init :: proc(engine: ^Engine) {
	g_logger = context.logger

	result: vk.Result

	//
	// Initialize GLFW
	//
	{
		glfw.SetErrorCallback(glfw_error_callback)
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

		ensure(bool(glfw.Init()), "Failed to initialize GLFW")
		ensure(bool(glfw.VulkanSupported()))
	}

	//
	// Create the Vulkan allocator
	//
	{
		engine.vk_alloc = vk_alloc_init(context.allocator)
	}

	//
	// Create the Vulkan Instance
	//
	{
		app_info := vk.ApplicationInfo {
			sType              = .APPLICATION_INFO,
			pNext              = nil,
			pApplicationName   = APP_NAME,
			applicationVersion = vk.MAKE_VERSION(0, 0, 1),
			pEngineName        = "fatchud",
			engineVersion      = vk.MAKE_VERSION(0, 0, 1),
			apiVersion         = vk.API_VERSION_1_0,
		}

		required_extensions := glfw.GetRequiredInstanceExtensions()
		create_info := vk.InstanceCreateInfo {
			sType                   = .INSTANCE_CREATE_INFO,
			pApplicationInfo        = &app_info,
			enabledExtensionCount   = u32(len(required_extensions)),
			ppEnabledExtensionNames = raw_data(required_extensions),
		}

		vk.CreateInstance = auto_cast glfw.GetInstanceProcAddress(nil, "vkCreateInstance")
		result = vk.CreateInstance(&create_info, &engine.vk_alloc, &engine.vk_instance)
		ensure(result == .SUCCESS)
	}

	//
	// Load Vulkan function pointers
	//
	{
		vk.GetInstanceProcAddr = auto_cast glfw.GetInstanceProcAddress
		vk.load_proc_addresses(engine.vk_instance)
	}

	//
	// Enumerate physical devices
	//
	{
		devices: [4]vk.PhysicalDevice
		count := u32(len(devices))
		result = vk.EnumeratePhysicalDevices(engine.vk_instance, &count, raw_data(&devices))
		ensure(result == .SUCCESS)
		ensure(count >= 1)

		engine.vk_physical_device = devices[0]
		ensure(engine.vk_physical_device != nil)

		if count != 1 {
			log.warnf("Found {} devices, using {}", devices[:count], engine.vk_physical_device)
		}

		//
		// Dump devices features
		//
		{
			features: vk.PhysicalDeviceFeatures
			vk.GetPhysicalDeviceFeatures(engine.vk_physical_device, &features)
			log.infof("%#v", features)
		}
	}

	//
	// Create logical device
	//
	{
		create_info := vk.DeviceCreateInfo {
			sType = .DEVICE_CREATE_INFO,
		}
		result = vk.CreateDevice(
			engine.vk_physical_device,
			&create_info,
			&engine.vk_alloc,
			&engine.vk_device,
		)
		ensure(result == .SUCCESS)
	}

	//
	// Create the window
	//
	{
		engine.window = glfw.CreateWindow(1280, 678, APP_NAME, nil, nil)
		ensure(engine.window != nil, "Failed to create a GLFW window")

		glfw.SetWindowUserPointer(engine.window, engine)
		glfw.SetFramebufferSizeCallback(engine.window, callback_framebuffer_size)
		glfw.SetWindowIconifyCallback(engine.window, callback_window_minimize)
	}

	return
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DestroyInstance(engine.vk_instance, nil)

	glfw.DestroyWindow(engine.window)
	glfw.Terminate()
}


render :: proc(engine: ^Engine) {

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
