package learnvk

import "base:runtime"
import "core:log"
import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "model"
import "vendor:glfw"
import stb_image "vendor:stb/image"
import vk "vendor:vulkan"

cmd_oneshot_begin :: proc(cmdbuf: vk.CommandBuffer) {
	begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		flags            = {.ONE_TIME_SUBMIT},
		pInheritanceInfo = nil,
	}

	result := vk.BeginCommandBuffer(cmdbuf, &begin_info)
	ensure(result == .SUCCESS)
}

cmd_oneshot_end :: proc(cmdbuf: vk.CommandBuffer, queue: vk.Queue) {
	result := vk.EndCommandBuffer(cmdbuf)
	ensure(result == .SUCCESS)

	cmdbuffers := [1]vk.CommandBuffer{cmdbuf}
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = raw_data(&cmdbuffers),
	}

	result = vk.QueueSubmit(queue, 1, &submit_info, fence = 0)
	ensure(result == .SUCCESS)

	result = vk.QueueWaitIdle(queue)
	ensure(result == .SUCCESS)
}

find_format :: proc(
	engine: ^Engine,
	candidates: []vk.Format,
	tiling: vk.ImageTiling,
	features: vk.FormatFeatureFlags,
) -> vk.Format {
	for format in candidates {
		properties: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(engine.vk_physical_device, format, &properties)

		if (tiling == .LINEAR && features <= properties.linearTilingFeatures) ||
		   (tiling == .OPTIMAL && features <= properties.optimalTilingFeatures) {
			return format
		}
	}

	assert(false)
	return .UNDEFINED
}

engine_upload_image_data :: proc(
	engine: ^Engine,
	image: vk.Image,
	data: []u8,
	#any_int width: u32,
	#any_int height: u32,
) {
	//
	// Upload first to the staging buffer
	//
	assert(len(data) <= STAGING_BUFFER_SIZE)
	mem.copy_non_overlapping(
		dst = engine.vk_transfer_buffer_mmap,
		src = raw_data(data),
		len = len(data),
	)

	//
	// Execute the command buffer operations to create our image gpu side
	//
	cmd_oneshot_begin(engine.vk_cmdbufs[engine.vk_frame_index])
	defer cmd_oneshot_end(engine.vk_cmdbufs[engine.vk_frame_index], engine.vk_queue)

	//
	// Setup a memory barrier which syncs the image transition and mem copy
	// of pixel data. the mem copy happens directly after the memory transition.
	//
	image_barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	vk.CmdPipelineBarrier(
		commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
		srcStageMask = {.TOP_OF_PIPE},
		dstStageMask = {.TRANSFER},
		dependencyFlags = {},
		memoryBarrierCount = 0,
		pMemoryBarriers = nil,
		bufferMemoryBarrierCount = 0,
		pBufferMemoryBarriers = nil,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &image_barrier,
	)

	//
	// Add the copy command
	//
	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {width, height, 1},
	}

	vk.CmdCopyBufferToImage(
		commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
		srcBuffer = engine.vk_transfer_buffer,
		dstImage = image,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		regionCount = 1,
		pRegions = &region,
	)

	//
	// Transition the image to be optimal for sampling
	//
	image_barrier = vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_READ},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	vk.CmdPipelineBarrier(
		commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
		srcStageMask = {.TRANSFER},
		dstStageMask = {.FRAGMENT_SHADER},
		dependencyFlags = {},
		memoryBarrierCount = 0,
		pMemoryBarriers = nil,
		bufferMemoryBarrierCount = 0,
		pBufferMemoryBarriers = nil,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &image_barrier,
	)
}

engine_create_image :: proc(
	engine: ^Engine,
	#any_int width: u32,
	#any_int height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	desired_properties: vk.MemoryPropertyFlags,
) -> (
	image: vk.Image,
	view: vk.ImageView,
	memory: vk.DeviceMemory,
) {
	create_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}

	result := vk.CreateImage(engine.vk_device, &create_info, &engine.vk_alloc, &image)
	ensure(result == .SUCCESS)

	//
	// Allocate memory for the image
	//
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(engine.vk_device, image, &requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = device_get_memory_type_index(
			&engine.vk_physical_device_memory_properties,
			requirements,
			desired_properties,
		),
	}

	result = vk.AllocateMemory(engine.vk_device, &alloc_info, &engine.vk_alloc, &memory)
	ensure(result == .SUCCESS)

	result = vk.BindImageMemory(
		device = engine.vk_device,
		image = image,
		memory = memory,
		memoryOffset = 0, // TODO: What is this about?
	)
	ensure(result == .SUCCESS)


	view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	result = vk.CreateImageView(engine.vk_device, &view_create_info, &engine.vk_alloc, &view)
	ensure(result == .SUCCESS)

	return
}

engine_create_buffer :: proc(
	engine: ^Engine,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	desired_properties: vk.MemoryPropertyFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
) {
	create_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	result := vk.CreateBuffer(engine.vk_device, &create_info, &engine.vk_alloc, &buffer)
	ensure(result == .SUCCESS)

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(engine.vk_device, buffer, &requirements)

	memory_type_index := device_get_memory_type_index(
		&engine.vk_physical_device_memory_properties,
		requirements,
		desired_properties,
	)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = memory_type_index,
	}

	result = vk.AllocateMemory(engine.vk_device, &alloc_info, &engine.vk_alloc, &memory)
	ensure(result == .SUCCESS)

	result = vk.BindBufferMemory(
		engine.vk_device,
		buffer = buffer,
		memory = memory,
		memoryOffset = 0, // TODO: What is this about?
	)
	ensure(result == .SUCCESS)

	return
}

//
// Given the properties of the currently bound physical device, find the memory
// type we will use for the buffer given the memory requirements.
//
device_get_memory_type_index :: proc(
	properties: ^vk.PhysicalDeviceMemoryProperties,
	requirements: vk.MemoryRequirements,
	desired_properties: vk.MemoryPropertyFlags,
) -> (
	memory_type_index: u32,
) {
	for ; memory_type_index < properties.memoryTypeCount; memory_type_index += 1 {
		is_compatible := requirements.memoryTypeBits & (u32(1) << memory_type_index) > 0
		has_desired_properties :=
			(desired_properties & properties.memoryTypes[memory_type_index].propertyFlags) ==
			desired_properties

		if is_compatible && has_desired_properties {
			return
		}
	}

	assert(false)
	return 0
}

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
	aspect_mask: vk.ImageAspectFlags,
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
			aspectMask = aspect_mask,
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

	if !features.samplerAnisotropy {
		log.error("We cannot use a gpu without a anisotropy")
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
			log.errorf("Failed to find device extension \"{}\"", required)
			return false
		}
	}

	return true
}

glfw_error_callback :: proc "c" (error: i32, description: cstring) {
	context = runtime.default_context()
	context.logger = g_logger
	log.errorf("GLFW [%d]: %s", error, description)
}

// odinfmt: disable
callback_key :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)

    activate := action != glfw.RELEASE
	switch key {

	case glfw.KEY_ESCAPE:
		glfw.SetWindowShouldClose(window, true)

	case glfw.KEY_R:
        if activate do engine.disable_rotate = !engine.disable_rotate

	case glfw.KEY_Q:
        if activate {
            CURRENT_MODEL = ModelTag((int(CURRENT_MODEL)+1)%NUM_MODELS)
            for (CURRENT_MODEL not_in engine.model_loaded) {
                CURRENT_MODEL = ModelTag((int(CURRENT_MODEL)+1)%NUM_MODELS)
            }
        }

	case glfw.KEY_W:
		if  activate do engine.actions += {.forward}
		if !activate do engine.actions -= {.forward}

	case glfw.KEY_S:
		if  activate do engine.actions += {.backward}
		if !activate do engine.actions -= {.backward}

	case glfw.KEY_A:
		if  activate do engine.actions += {.left}
		if !activate do engine.actions -= {.left}

	case glfw.KEY_D:
		if  activate do engine.actions += {.right}
		if !activate do engine.actions -= {.right}

	case glfw.KEY_K:
		if  activate do engine.actions += {.up}
		if !activate do engine.actions -= {.up}

	case glfw.KEY_J:
		if  activate do engine.actions += {.down}
		if !activate do engine.actions -= {.down}
	}
}
// odinfmt: enable

callback_scroll :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {}

callback_cursor_move :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)

	w, h := glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 do return

	delta := engine.camera.sensitivity * [2]f32{f32(ypos), f32(xpos)}
	glfw.SetCursorPos(window, 0, 0)

	engine.camera.yaw -= delta.x
	engine.camera.pitch = clamp(
		engine.camera.pitch + delta.y,
		math.to_radians_f32(-89.0),
		math.to_radians_f32(89.0),
	)
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
			assert(false)
		}

		log.infof(MESSAGE_FORMAT, mt, p_callback_data.pMessage)

		return false
	}

	return false
}

make_or_clear :: proc(item: ^[dynamic]$T) {
	if item^ == nil {
		item^ = make([dynamic]T)
	} else {
		clear(item)
	}
}

get_texture_details :: proc(
	m: Model,
	mtl: model.Material,
	material_type: MaterialType,
) -> (
	texture_path: cstring,
	desired_channels: i32,
	texture_format: vk.Format,
	ok: bool,
) {
	texture_rel_path: string

	switch material_type {
	case .diffuse:
		texture_rel_path = model.get_material_string(m, mtl, .map_Kd)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .emmisive:
		texture_rel_path = model.get_material_string(m, mtl, .map_Ke)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .normal:
		texture_rel_path = model.get_material_string(m, mtl, .map_bump)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .specular:
		texture_rel_path = model.get_material_string(m, mtl, .map_Ks)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB
	}


	if len(texture_rel_path) == 0 {
		ok = false
		return
	}

	//
	// Resolve the true path
	//
	path, alloc_err := filepath.join(
		[]string{filepath.dir(model.get_mtl_path(m)), texture_rel_path},
		context.temp_allocator,
	)
	assert(alloc_err == nil)

	texture_path = strings.clone_to_cstring(path, context.temp_allocator)

	ok = true
	return
}

LoadTaskData :: struct {
	//
	// input
	//
	input:  struct #all_or_none {
		texture_cpath:    cstring,
		desired_channels: i32,
		format:           vk.Format,
	},

	//
	// output
	//
	output: struct #all_or_none {
		width:    i32,
		height:   i32,
		channels: i32,
		data:     []u8,
		ok:       bool,
	},
}

eat_load_task :: proc(t: ^LoadTaskData) {
	assert(t.input.texture_cpath != nil)
	assert(t.input.desired_channels != 0)
	assert(t.input.format != .UNDEFINED)


	//
	// Load pixels into RAM
	//
	width, height, channels: i32
	data := stb_image.load(
		t.input.texture_cpath,
		&width,
		&height,
		&channels,
		t.input.desired_channels,
	)

	if data == nil {
		t.output.ok = false
		return
	}

	data_len := int(width) * int(height) * int(t.input.desired_channels)

	t.output = {
		width    = width,
		height   = height,
		channels = channels,
		data     = data[:data_len],
		ok       = true,
	}

	return
}

engine_load_material_texture_data :: proc(
	load_tasks: ^[dynamic]LoadTaskData,

	// input
	this_model: Model,
	model_tag: ModelTag,
	mesh: model.Mesh,
) {
	//
	// Try to find the material type for this mesh
	//

	material, found := model.find_material_by_mesh(this_model, mesh)
	if !found {
		log.warnf(
			"Failed to find material for \"{}.{}\"",
			model_tag,
			model.get_mesh_name(this_model, mesh),
		)
		return
	}

	//
	// Load all the material textures onto the gpu
	//
	for material_type in MaterialType {

		//
		// Get the details for the texure
		//
		task: LoadTaskData

		task.input = {get_texture_details(this_model, material, material_type) or_continue}

		append(load_tasks, task)
	}
}
