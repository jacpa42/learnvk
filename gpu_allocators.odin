package learnvk

import "core:mem"
import vk "vendor:vulkan"

GpuArena :: struct #all_or_none {
	using gpu_memory: GpuMemory,
	offset:           int,
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

gpu_arena_free_all :: gpu_arena_reset
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
	assert_contextless(a.memory != 0, loc = loc)
	assert_contextless(a.size != 0, loc = loc)
	assert_contextless(alignment > 1, loc = loc)

	aligned_offset := mem.align_forward_int(a.offset, alignment)

	capacity := a.size - aligned_offset
	if capacity < size {
		ok = false
		return
	}

	a.offset = aligned_offset + size

	memory = a.memory
	memory_offset = vk.DeviceSize(aligned_offset)
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
