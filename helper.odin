package learnvk

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "model"
import "vendor:glfw"
import stb_image "vendor:stb/image"
import vk "vendor:vulkan"

engine_new_texture :: proc(
	engine: ^Engine,
	material_id: MaterialID,
	tag: MaterialType,
) -> (
	texture_id: TextureID,
) {
	texture_id = TextureID(len(engine.texture_list))

	switch tag {
	case .diffuse:
		engine.material_list[material_id].diffuse_id = texture_id
	case .emissive:
		engine.material_list[material_id].emissive_id = texture_id
	case .bump:
		engine.material_list[material_id].bump_id = texture_id
	case .specular:
		engine.material_list[material_id].specular_id = texture_id
	}

	// we allocate the image after we load the texture data
	append(&engine.texture_list, Texture{image = 0, view = 0, tag = tag})

	return
}

engine_new_material :: proc(engine: ^Engine) -> (material_id: MaterialID) {
	material_id = MaterialID(len(engine.material_list))
	append(&engine.material_list, NO_MATERIAL)

	return
}

// NOTE: Name is copied!
engine_append_mesh :: proc(
	engine: ^Engine,
	name: string,
	#any_int index_count: u32,
	material_id: MaterialID,
) {
	index_start: u32
	if len(engine.mesh_data) > 0 {
		last_appended := engine.mesh_data.indicies[len(engine.mesh_data) - 1]
		index_start = last_appended.count + last_appended.count
	}
	append(
		&engine.mesh_data,
		MeshInfo {
			name = name,
			// into the index buffer
			indicies = IndexRange{start = index_start, count = index_count},
			// indexes into the material list
			material_id = material_id,
		},
	)
}

@(require_results)
engine_create_buffer :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	#any_int size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	buffer: vk.Buffer,
	result: vk.Result,
) {
	info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = size,
		usage = usage,
	}

	result = vk.CreateBuffer(device, &info, alloc, &buffer)
	return
}


cmd_oneshot_begin :: proc(cmdbuf: vk.CommandBuffer, loc := #caller_location) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
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
		vk.GetPhysicalDeviceFormatProperties(engine.physical_device, format, &properties)

		if (tiling == .LINEAR && features <= properties.linearTilingFeatures) ||
		   (tiling == .OPTIMAL && features <= properties.optimalTilingFeatures) {
			return format
		}
	}

	assert(false)
	return .UNDEFINED
}

//
// Given the properties of the currently bound physical device, find the memory
// type we will use for the buffer given the memory requirements.
//
find_memory_type_index :: proc "contextless" (
	requirements: vk.MemoryRequirements,
	desired_properties: vk.MemoryPropertyFlags,
) -> (
	type_index: u32,
	result: vk.Result,
) {
	properties := physical_device_memory_properties
	compatible_bits := transmute(bit_set[MemoryTypeIndex;u32])(requirements.memoryTypeBits)

	for index in compatible_bits {
		if (desired_properties <= properties.memoryTypes[index].propertyFlags) {
			type_index = u32(index)
			result = .SUCCESS
			return
		}
	}

	type_index = bits.U32_MAX
	result = vk.Result.ERROR_NOT_PERMITTED
	return
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

    ctrl    := (mods & glfw.MOD_CONTROL) > 0
    down    := action != glfw.RELEASE
    pressed := action == glfw.PRESS

	if key == glfw.KEY_ESCAPE do glfw.SetWindowShouldClose(window, true)

	if key == glfw.KEY_R && pressed do engine.disable_rotate = !engine.disable_rotate

	if key == glfw.KEY_Q && pressed && card(engine.model_loaded) > 0 {
        CURRENT_MODEL = ModelTag((int(CURRENT_MODEL)+1) % NUM_MODELS)
        for (CURRENT_MODEL not_in engine.model_loaded) {
            CURRENT_MODEL = ModelTag((int(CURRENT_MODEL)+1) % NUM_MODELS)
        }
    }

	if key == glfw.KEY_W && down  do engine.actions += {.forward}
	if key == glfw.KEY_W && !down do engine.actions -= {.forward}

	if key == glfw.KEY_A && down  do engine.actions += {.left}
	if key == glfw.KEY_A && !down do engine.actions -= {.left}

	if key == glfw.KEY_S && down  do engine.actions += {.backward}
	if key == glfw.KEY_S && !down do engine.actions -= {.backward}

	if key == glfw.KEY_D && down  do engine.actions += {.right}
	if key == glfw.KEY_D && !down do engine.actions -= {.right}

	if key == glfw.KEY_K && down  do engine.actions += {.up}
	if key == glfw.KEY_K && !down do engine.actions -= {.up}

	if key == glfw.KEY_J && down  do engine.actions += {.down}
	if key == glfw.KEY_J && !down do engine.actions -= {.down}

    //
    // Flag toggling
    //

    if key == glfw.KEY_D && ctrl && pressed {
        if .enable_diffuse in engine.shader_flags {
            engine.shader_flags -= {.enable_diffuse}
        } else {
            engine.shader_flags += {.enable_diffuse}
        }
    }

    if key == glfw.KEY_E && ctrl && pressed {
        if .enable_emissive in engine.shader_flags {
            engine.shader_flags -= {.enable_emissive}
        } else {
            engine.shader_flags += {.enable_emissive}
        }
    }

    if key == glfw.KEY_H && ctrl && pressed {
        if .enable_bump in engine.shader_flags {
            engine.shader_flags -= {.enable_bump}
        } else {
            engine.shader_flags += {.enable_bump}
        }
    }

    if key == glfw.KEY_S && ctrl && pressed {
        if .enable_specular in engine.shader_flags {
            engine.shader_flags -= {.enable_specular}
        } else {
            engine.shader_flags += {.enable_specular}
        }
    }
}
// odinfmt: enable

callback_scroll :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {}

callback_cursor_move :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	engine := cast(^Engine)glfw.GetWindowUserPointer(window)

	w, h := glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 do return

	delta := engine.camera.sensitivity * [2]f32{f32(-xpos), f32(ypos)}
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
	context = runtime.default_context()
	log.warnf("Framebuffer resize {}x{}", width, height)
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
		texture_rel_path = model.get_material_string(m, mtl, .diffuse)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .emissive:
		texture_rel_path = model.get_material_string(m, mtl, .emissive)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .bump:
		texture_rel_path = model.get_material_string(m, mtl, .bump)
		desired_channels = 4
		texture_format = .R8G8B8A8_SRGB

	case .specular:
		texture_rel_path = model.get_material_string(m, mtl, .specular)
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
		// This is so we know where to put this thing
		material_id:      MaterialID,
		texture_id:       TextureID,

		//
		texture_cpath:    cstring,
		desired_channels: i32,
		format:           vk.Format,
	},

	//
	// output
	//
	output: struct #all_or_none {
		width:           i32,
		height:          i32,
		channels:        i32,
		data_needs_free: bool,
		data:            []u8,
		ok:              bool,
	},
}

eat_load_task :: proc(task_array: []LoadTaskData) {
	for &t in task_array {
		if t.input.texture_cpath == nil do continue
		if t.input.desired_channels == 0 do continue
		if t.input.format == .UNDEFINED do continue

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
			continue
		}

		data_len := int(width) * int(height) * int(t.input.desired_channels)

		t.output = {
			width           = width,
			height          = height,
			channels        = channels,
			data_needs_free = true,
			data            = data[:data_len],
			ok              = true,
		}

		t.output.ok = true
	}
}


//
// TODO: rewrite this because it's unreadable garbage:
//
// 1. We need to load all the textures
// 2. Figure out which textures go to what materials
// 3. Allow for the same texture to be mapped to different material types in
//    different materials
// 4. Define all the meshes in the model with their names and indicies.
//
TexturePath :: cstring
MaterialName :: string
engine_append_material_load_task :: proc(
	engine: ^Engine,
	load_tasks: ^[dynamic]LoadTaskData,

	// Used to deduplicate load tasks
	texture_id_map: ^map[TexturePath]TextureID,
	material_id_map: ^map[MaterialName]MaterialID,

	// input
	model_tag: ModelTag,
	mesh_index: int,
) {
	this_model := engine.models[model_tag]

	//
	// Append the new mesh
	//
	mesh_name := model.get_mesh_name(this_model, mesh_index)
	mesh_indices := model.get_mesh_indices(this_model, mesh_index)
	engine_append_mesh(engine, mesh_name, len(mesh_indices), -1)

	//
	// Try to find the material type for this mesh
	//

	{
		material_name: MaterialName = model.get_mesh_material_name(this_model, mesh_index)
		material_id, ok := &material_id_map[material_name]

		if ok {
			engine.mesh_data[mesh_index].material_id = material_id^
			return
		}
	}


	//
	// Otherwise load the material
	//

	material, ok := model.find_material_by_mesh(this_model, mesh_index)

	if !ok {
		log.warnf(
			"Failed to find material for \"{}.{}\"",
			model_tag,
			model.get_mesh_name(this_model, mesh_index),
		)

		return
	}

	//
	// We found a new material. Add it to our material list
	//
	material_name: MaterialName = model.get_mesh_material_name(this_model, mesh_index)
	material_id := engine_new_material(engine)
	material_id_map[material_name] = material_id

	engine.mesh_data[mesh_index].material_id = material_id

	//
	// Load all the material textures onto the gpu
	//
	for texture_type in MaterialType {
		texture_path, desired_channels, texture_format := get_texture_details(
			this_model,
			material,
			texture_type,
		) or_continue

		//
		// Check if we have already loaded this texture
		//
		texture_id: ^TextureID
		texture_id, ok = &texture_id_map[texture_path]
		if ok {
			switch texture_type {
			case .diffuse:
				engine.material_list[material_id].diffuse_id = texture_id^
			case .emissive:
				engine.material_list[material_id].emissive_id = texture_id^
			case .bump:
				engine.material_list[material_id].bump_id = texture_id^
			case .specular:
				engine.material_list[material_id].specular_id = texture_id^
			}

			continue

		} else {
		}

		new_texture_id := engine_new_texture(engine, material_id, texture_type)
		texture_id_map[texture_path] = new_texture_id

		//
		// We found a texture we haven't loaded yet
		//

		// TODO: continue setting up the texture loader to not be so shit

		task: LoadTaskData
		task.input = {
			material_id      = material_id,
			texture_id       = new_texture_id,
			texture_cpath    = texture_path,
			desired_channels = desired_channels,
			format           = texture_format,
		}

		append(load_tasks, task)
	}
}

//
// Allocates load tasks with context.temp_allocator
//
engine_load_material_textures :: proc(engine: ^Engine) -> (tasks: [dynamic]LoadTaskData) {

	//
	// Initialize our mesh metadata arrays
	//
	arena := mem.arena_allocator(&engine.arena)
	engine.mesh_data = make(#soa[dynamic]MeshInfo, length = 0, capacity = 64, allocator = arena)
	engine.material_list = make([dynamic]Material, len = 0, cap = 128, allocator = arena)
	engine.texture_list = make([dynamic]Texture, len = 0, cap = 512, allocator = arena)

	//
	// Define all the texture load tasks
	//
	{
		tasks = make([dynamic]LoadTaskData, 0, 64, context.temp_allocator)

		texture_id_map := make(map[TexturePath]TextureID)
		defer delete(texture_id_map)
		material_id_map := make(map[MaterialName]MaterialID)
		defer delete(material_id_map)

		for tag in engine.model_loaded {
			num_meshes := len(model.get_meshes(engine.models[tag]))

			for mesh_index in 0 ..< num_meshes do engine_append_material_load_task(engine, &tasks, &texture_id_map, &material_id_map, tag, mesh_index)
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

	return
}

destroy_load_tasks :: proc(load_tasks: ^[dynamic]LoadTaskData) {
	assert(load_tasks.allocator == context.temp_allocator)

	defer load_tasks^ = {}

	for t in load_tasks do if t.output.data_needs_free {
		stb_image.image_free(raw_data(t.output.data))
	}
}

//
// Useful when you want to create an arena which needs to support a lot of
// different memory types
//
refine_memory_requirement :: proc(req: ^vk.MemoryRequirements, new_req: vk.MemoryRequirements) {
	req.alignment = max(req.alignment, new_req.alignment)
	req.size += vk.DeviceSize(mem.align_forward_uint(uint(new_req.size), uint(req.alignment)))
	req.memoryTypeBits &= new_req.memoryTypeBits
}

//
// Gets the requirements for a buffer without actually creating one
//
get_memory_requirements_buffer :: proc(
	device: vk.Device,
	#any_int size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> vk.MemoryRequirements {

	create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = size,
		usage = usage,
	}

	dbmr := vk.DeviceBufferMemoryRequirements {
		sType       = .DEVICE_BUFFER_MEMORY_REQUIREMENTS,
		pCreateInfo = &create_info,
	}

	req2: vk.MemoryRequirements2
	vk.GetDeviceBufferMemoryRequirements(device, &dbmr, &req2)

	return req2.memoryRequirements
}

//
// Gets the requirements for an image without actually creating one
//
get_memory_requirements_image :: proc(
	device: vk.Device,
	format: vk.Format,
	usage: vk.ImageUsageFlags,

	//
	width: u32,
	height: u32,
	depth: u32 = 1,
	image_type := vk.ImageType.D2,

	//
	mipLevels: u32 = 1,
	arrayLayers: u32 = 1,

	//
	samples := vk.SampleCountFlags{._1},
	tiling := vk.ImageTiling.OPTIMAL,
) -> vk.MemoryRequirements {

	create_info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		imageType   = image_type,
		format      = format,
		extent      = {width, height, depth},
		mipLevels   = mipLevels,
		arrayLayers = arrayLayers,
		samples     = samples,
		tiling      = tiling,
		usage       = usage,
	}

	dbmr := vk.DeviceImageMemoryRequirements {
		sType       = .DEVICE_IMAGE_MEMORY_REQUIREMENTS,
		pCreateInfo = &create_info,
	}

	req2: vk.MemoryRequirements2
	vk.GetDeviceImageMemoryRequirements(device, &dbmr, &req2)

	return req2.memoryRequirements
}
