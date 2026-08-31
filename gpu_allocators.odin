package learnvk

import "core:log"
import "core:mem"
import vk "vendor:vulkan"

// Essentially mem.Arena but the backing buffer is a buffer mapped into ram
MappedGpuArena :: struct {
	backing: GpuArena,
	mmap:    rawptr,
}

GpuArena :: struct #all_or_none {
	gpu_memory: GpuMemory,
	offset:     int,
}

GpuMemory :: struct {
	memory: vk.DeviceMemory,
	size:   int,
}

gpu_malloc :: proc(
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	requirements: vk.MemoryRequirements,
	desired_properties: vk.MemoryPropertyFlags,
) -> (
	memory: GpuMemory,
) {
	log.warnf("Allocating {}Mib of gpu memory", f32(requirements.size) / (1024 * 1024))

	memory_type_index, ok := device_get_memory_type_index(requirements, desired_properties)
	if !ok do return

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = memory_type_index,
	}

	memory.size = int(requirements.size)

	result := vk.AllocateMemory(device, &alloc_info, alloc, &memory.memory)
	ensure(result == .SUCCESS)

	return
}

gpu_free :: proc(device: vk.Device, memory: ^GpuMemory, alloc: ^vk.AllocationCallbacks) {
	defer memory^ = {}
	vk.FreeMemory(device, memory.memory, alloc)
}

gpu_arena_init :: proc(buffer: GpuMemory) -> GpuArena {
	return GpuArena{gpu_memory = buffer, offset = 0}
}

gpu_arena_destroy :: proc(device: vk.Device, arena: GpuArena, alloc: ^vk.AllocationCallbacks) {
	log.infof(
		"Used {}/{}={}%% of arena memory",
		arena.offset,
		arena.gpu_memory.size,
		f32(arena.offset) / f32(arena.gpu_memory.size),
	)
	vk.FreeMemory(device, arena.gpu_memory.memory, alloc)
}

gpu_arena_reset :: proc(a: ^GpuArena) {a.offset = 0}

gpu_arena_alloc :: proc(
	a: ^GpuArena,
	#any_int size: int,
	#any_int alignment: int,
	loc := #caller_location,
) -> (
	memory: vk.DeviceMemory,
	memory_offset: vk.DeviceSize,
	ok: bool,
) {
	assert_contextless(a.gpu_memory.memory != 0, loc = loc)
	assert_contextless(a.gpu_memory.size != 0, loc = loc)
	assert_contextless(alignment > 1, loc = loc)
	assert_contextless(mem.is_power_of_two(uintptr(alignment)), loc = loc)

	aligned_offset := mem.align_forward_int(a.offset, alignment)

	capacity := a.gpu_memory.size - aligned_offset
	if capacity < size {
		log.errorf("{:x} alloc failed (need {} bytes)", rawptr(a), size - capacity, location = loc)
		ok = false
		return
	}

	a.offset = aligned_offset + size

	memory = a.gpu_memory.memory
	memory_offset = vk.DeviceSize(aligned_offset)
	ok = true
	return
}


//
// NOTE: Requires .HOST_VISIBLE and .HOST_COHERENT
//
mapped_gpu_arena_init :: proc(
	device: vk.Device,
	buffer: GpuMemory,
	loc := #caller_location,
) -> (
	ma: MappedGpuArena,
) {
	assert_contextless(buffer.memory != 0, loc = loc)
	assert_contextless(buffer.size != 0, loc = loc)

	result: vk.Result

	ptr: rawptr
	result = vk.MapMemory(device, buffer.memory, 0, vk.DeviceSize(buffer.size), {}, &ptr)
	ensure(result == .SUCCESS, loc = loc)

	ma.backing = gpu_arena_init(buffer)
	ma.mmap = ptr

	return
}

mapped_gpu_arena_init_destroy :: proc(
	device: vk.Device,
	arena: MappedGpuArena,
	alloc: ^vk.AllocationCallbacks,
) {
	vk.UnmapMemory(device, arena.backing.gpu_memory.memory)
	gpu_arena_destroy(device, arena.backing, alloc)
}

mapped_gpu_arena_alloc :: proc(
	a: ^MappedGpuArena,
	#any_int size: int,
	#any_int alignment: int,
	loc := #caller_location,
) -> (
	memory: vk.DeviceMemory,
	memory_offset: vk.DeviceSize,
	data: []byte,
	ok: bool,
) {
	assert_contextless(a.backing.gpu_memory.memory != 0, loc = loc)
	assert_contextless(a.mmap != nil, loc = loc)
	assert_contextless(alignment > 1, loc = loc)
	assert_contextless(mem.is_power_of_two(uintptr(alignment)), loc = loc)

	memory, memory_offset = gpu_arena_alloc(&a.backing, size, alignment, loc = loc) or_return
	data = ([^]byte)(a.mmap)[int(memory_offset):int(memory_offset) + size]
	ok = true

	return
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
