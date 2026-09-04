package learnvk

import "base:runtime"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

GpuArena :: struct #all_or_none {
	memory: vk.DeviceMemory,
	size:   int,
	offset: int,
}

Buffer :: struct #all_or_none {
	memory: vk.DeviceMemory,
	buffer: vk.Buffer,
}

MappedBuffer :: struct($T: typeid) #all_or_none {
	ptr:    ^T,
	memory: vk.DeviceMemory,
	buffer: vk.Buffer,
}

mapped_buffer_get_offset :: proc(buffer: MappedBuffer($T), $member: string) -> vk.DeviceSize {
	return vk.DeviceSize(offset_of_by_string(T, member))
}

// The returned buffer is always EXCLUSIVE access
@(require_results)
mapped_buffer_init :: proc(
	device: vk.Device,
	mbuf: ^MappedBuffer($T),
	alloc: ^vk.AllocationCallbacks,
	usage: vk.BufferUsageFlags,
	required_properties: vk.MemoryPropertyFlags,
) -> (
	result: vk.Result,
) {
	//
	// First we need a buffer
	//
	create_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size_of(T),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	vk.CreateBuffer(device, &create_info, alloc, &mbuf.buffer) or_return

	//
	// Allocate the memory for the buffer
	//
	mbuf.memory = gpu_malloc_buffer(
		device,
		alloc,
		mbuf.buffer,
		required_properties,
		ptr = (^rawptr)(&mbuf.ptr),
	) or_return

	result = .SUCCESS
	return
}

mapped_buffer_destroy :: proc(
	device: vk.Device,
	mbuf: ^MappedBuffer($T),
	alloc: ^vk.AllocationCallbacks,
) {
	defer mbuf^ = {}

	vk.UnmapMemory(device, mbuf.memory)
	vk.FreeMemory(device, mbuf.memory, alloc)
	vk.DestroyBuffer(device, mbuf.buffer, alloc)
}

// The returned buffer is always EXCLUSIVE access
@(require_results)
buffer_init :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	#any_int size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	required_properties: vk.MemoryPropertyFlags,
) -> (
	buffer: Buffer,
	result: vk.Result,
) {
	//
	// First we need a buffer
	//
	create_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	vk.CreateBuffer(device, &create_info, alloc, &buffer.buffer) or_return

	//
	// Allocate the memory for the buffer
	//
	buffer.memory = gpu_malloc_buffer(device, alloc, buffer.buffer, required_properties) or_return

	result = .SUCCESS
	return
}

buffer_destroy :: proc(device: vk.Device, mbuf: ^MappedBuffer, alloc: ^vk.AllocationCallbacks) {
	vk.FreeMemory(device, mbuf.memory, alloc)
	vk.DestroyBuffer(device, mbuf.buffer, alloc)
}

// If `ptr!=nil` then the pointer is mapped into memory.
@(require_results)
gpu_malloc_buffer :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	buffer: vk.Buffer,
	required_properties: vk.MemoryPropertyFlags,
	ptr: ^rawptr = nil,
	loc := #caller_location,
) -> (
	memory: vk.DeviceMemory,
	result: vk.Result,
) {
	assert_contextless(buffer != 0)
	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &requirements)

	memory = gpu_malloc(device, alloc, requirements, required_properties, ptr, loc = loc) or_return

	vk.BindBufferMemory(device, buffer, memory, 0) or_return

	result = .SUCCESS
	return
}

//
// To free use `vulkan.FreeMemory`
//
@(require_results)
gpu_malloc :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	requirements: vk.MemoryRequirements,
	required_properties: vk.MemoryPropertyFlags,
	ptr: ^rawptr = nil,
	loc := #caller_location,
) -> (
	memory: vk.DeviceMemory,
	result: vk.Result,
) {
	assert(device != nil, loc = loc)
	assert(requirements.size > 0, loc = loc)
	assert(requirements.alignment > 0, loc = loc)
	assert(requirements.memoryTypeBits > 0, loc = loc)

	log.warnf("Allocating {}Mib of gpu memory", f32(requirements.size) / (1024 * 1024))

	memory_type_index := find_memory_type_index(requirements, required_properties) or_return

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = memory_type_index,
	}

	vk.AllocateMemory(device, &alloc_info, alloc, &memory) or_return

	if ptr != nil do vk.MapMemory(device, memory, 0, requirements.size, {}, ptr) or_return

	result = .SUCCESS
	return
}

//
// To free use `vulkan.FreeMemory`
//
@(require_results)
gpu_malloc_image :: proc(
	device: vk.Device,
	image: vk.Image,
	alloc: ^vk.AllocationCallbacks,
	required_properties: vk.MemoryPropertyFlags,
	loc := #caller_location,
) -> (
	memory: vk.DeviceMemory,
	result: vk.Result,
) {
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, image, &requirements)
	memory = gpu_malloc(device, alloc, requirements, required_properties, loc = loc) or_return

	vk.BindImageMemory(device, image, memory, 0) or_return

	result = .SUCCESS
	return
}

@(require_results)
gpu_arena_init_memory :: proc(memory: vk.DeviceMemory, #any_int size: int) -> (arena: GpuArena) {
	return GpuArena{memory = memory, size = size, offset = 0}
}

@(require_results)
gpu_arena_init :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	requirements: vk.MemoryRequirements,
	required_properties: vk.MemoryPropertyFlags,
	loc := #caller_location,
) -> (
	arena: GpuArena,
	result: vk.Result,
) {
	memory := gpu_malloc(device, alloc, requirements, required_properties, loc = loc) or_return
	arena = gpu_arena_init_memory(memory, requirements.size)
	result = .SUCCESS
	return
}

gpu_arena_destroy :: proc(device: vk.Device, arena: GpuArena, alloc: ^vk.AllocationCallbacks) {
	log.infof(
		"Used {}/{}={}%% of arena memory",
		arena.offset,
		arena.size,
		100 * f32(arena.offset) / f32(arena.size),
	)
	vk.FreeMemory(device, arena.memory, alloc)
}

//
// Allocates a memory region.
//
// When `ptr!=nil && device!=nil`, I map the allocation into memory via `vulkan.MapMemory`.
//
@(require_results)
gpu_arena_alloc :: proc(
	arena: ^GpuArena,
	#any_int size: int,
	#any_int alignment: int,
	device: vk.Device = nil,
	ptr: ^rawptr = nil,
	loc := #caller_location,
) -> (
	memory_offset: vk.DeviceSize,
	result: vk.Result,
) {
	assert_contextless(arena.memory != 0, loc = loc)
	assert_contextless(arena.size != 0, loc = loc)
	assert_contextless(alignment > 1, loc = loc)
	assert_contextless(mem.is_power_of_two(uintptr(alignment)), loc = loc)

	old_offset := arena.offset
	defer if result != .SUCCESS do arena.offset = old_offset

	aligned_offset := mem.align_forward_int(arena.offset, alignment)

	capacity := arena.size - aligned_offset
	if capacity < size {
		log.errorf(
			"{} :: {:x} arena alloc failed: need {} bytes",
			loc,
			rawptr(arena),
			size - capacity,
		)
		result = .ERROR_OUT_OF_DEVICE_MEMORY
		return
	}

	if ptr != nil {
		assert_contextless(device != nil)

		vk.MapMemory(
			device = device,
			memory = arena.memory,
			offset = memory_offset,
			size = vk.DeviceSize(size),
			flags = {},
			ppData = ptr,
		) or_return
	}

	arena.offset = aligned_offset + size

	memory_offset = vk.DeviceSize(aligned_offset)
	result = .SUCCESS
	return
}

//
// Allocates memory for a buffer and binds it.
//
// The `ptr` argument is for optionally mapping the allocation into memory.
//
@(require_results)
gpu_arena_alloc_buffer :: proc(
	arena: ^GpuArena,
	device: vk.Device,
	buffer: vk.Buffer,
	ptr: ^rawptr = nil,
	loc := #caller_location,
) -> (
	memory_offset: vk.DeviceSize,
	result: vk.Result,
) {
	assert_contextless(buffer != 0)

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &requirements)

	memory_offset = gpu_arena_alloc(
		arena,
		requirements.size,
		requirements.alignment,
		device = device,
		ptr = ptr,
		loc = loc,
	) or_return

	vk.BindBufferMemory(device, buffer, arena.memory, memory_offset) or_return

	result = .SUCCESS
	return
}

//
// Allocates memory for an image and binds it.
//
@(require_results)
gpu_arena_alloc_image :: proc(
	arena: ^GpuArena,
	device: vk.Device,
	image: vk.Image,
	loc := #caller_location,
) -> (
	memory_offset: vk.DeviceSize,
	result: vk.Result,
) {
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, image, &requirements)

	memory_offset = gpu_arena_alloc(
		arena,
		requirements.size,
		requirements.alignment,
		loc = loc,
	) or_return

	vk.BindImageMemory(device, image, arena.memory, memory_offset) or_return

	result = .SUCCESS
	return
}

