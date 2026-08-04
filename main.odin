package learnvk

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

VULKAN_API_VERSION :: vk.API_VERSION_1_0
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG
MAX_PHYSICAL_DEVICE_EXTENSIONS :: 8
MAX_SWAPCHAIN_IMAGES :: 16
APP_NAME: cstring = "learnvk"

g_logger: runtime.Logger

Engine :: struct {
	// Windowing stuff
	window:                                 glfw.WindowHandle,
	stop_rendering:                         bool,

	// Vulkan stuff
	vk_alloc:                               vk.AllocationCallbacks,
	vk_messenger:                           vk.DebugUtilsMessengerEXT,
	vk_instance:                            vk.Instance,
	vk_physical_device:                     vk.PhysicalDevice,
	vk_physical_device_features:            vk.PhysicalDeviceFeatures,
	vk_physical_device_properties:          vk.PhysicalDeviceProperties,
	vk_physical_device_required_extensions: [dynamic; MAX_PHYSICAL_DEVICE_EXTENSIONS]cstring,
	vk_device:                              vk.Device,
	vk_queue:                               vk.Queue,
	vk_surface:                             vk.SurfaceKHR,
	vk_swapchain:                           vk.SwapchainKHR,
	vk_swapchain_surface_format:            vk.SurfaceFormatKHR,
	vk_swapchain_extent:                    vk.Extent2D,
	vk_swapchain_images:                    [dynamic; MAX_SWAPCHAIN_IMAGES]vk.Image,
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

	fmt.eprintfln("%#v", engine)

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
		free_all(context.temp_allocator)
		time.sleep(100 * time.Millisecond)
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
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
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
		engine.vk_alloc = vk_alloc_init(context.allocator)
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
		ensure(engine.vk_surface != 0)
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
	// Create the swapchain
	//
	engine_init_swapchain(engine)
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

	engine.vk_physical_device_required_extensions = {vk.KHR_SWAPCHAIN_EXTENSION_NAME}
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
	render_queue_index: u32 = bits.U32_MAX
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
			render_queue_index = u32(index)
			break
		}
	}

	ensure(render_queue_index != bits.U32_MAX, "We need a queue with graphics capabilities")

	queue_priority := []f32{0.5} // Doesn't really matter for 1 queue?
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = render_queue_index,
		queueCount       = u32(len(queue_priority)),
		pQueuePriorities = raw_data(queue_priority),
	}

	//
	// Logical device create info
	//
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,

		// queue
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,

		// NOTE: Apparently this is ignored? (sauce: https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/00_Setup/04_Logical_device_and_queues.html)
		// layers
		enabledLayerCount       = 0,
		ppEnabledLayerNames     = nil, // [^]cstring,

		// extensions
		enabledExtensionCount   = u32(len(engine.vk_physical_device_required_extensions)),
		ppEnabledExtensionNames = raw_data(&engine.vk_physical_device_required_extensions), // [^]cstring,

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
	vk.GetDeviceQueue(engine.vk_device, render_queue_index, 0, &engine.vk_queue)
	ensure(engine.vk_queue != nil)
}

// NOTE: Can be called multiple times in a loop / whenever the window is resized
engine_init_swapchain :: proc(engine: ^Engine) {
	result: vk.Result

	ensure(engine.vk_swapchain == 0)

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
		// Set the min image count
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
		oldSwapchain     = 0, // TODO: Implement swap chain recreation
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
	ensure(engine.vk_swapchain != 0)

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
}

engine_destroy :: proc(engine: ^Engine) {
	vk.DestroySurfaceKHR(engine.vk_instance, engine.vk_surface, &engine.vk_alloc)
	vk.DestroyInstance(engine.vk_instance, &engine.vk_alloc)

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
