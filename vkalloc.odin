package learnvk

import "base:runtime"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

@(private = "file")
alloc: mem.Allocator

// TODO: is this thread safe?
vk_alloc_tracker: struct {
	num_alloc, num_free, num_realloc: int,
	total_alloc, total_free:          int,
	current_memory_size:              int,
	allocations:                      map[rawptr]struct {
		size, alignment: int,
	},
}

vk_alloc_init :: proc() -> vk.AllocationCallbacks {
	alloc = context.allocator
	vk_alloc_tracker.allocations = make(type_of(vk_alloc_tracker.allocations), 128)

	return {
		pUserData = nil,
		pfnAllocation = Allocation,
		pfnReallocation = Reallocation,
		pfnFree = Free,
		pfnInternalAllocation = InternalAllocationNotification,
		pfnInternalFree = InternalFreeNotification,
	}
}

vk_alloc_cleanup :: proc() {
	delete(vk_alloc_tracker.allocations)
}

@(private = "file")
Allocation :: proc "system" (
	pUserData: rawptr,
	size: int,
	alignment: int,
	allocationScope: vk.SystemAllocationScope,
) -> rawptr {
	context = {
		allocator = alloc,
		logger    = g_logger,
	}

	ptr, err := mem.alloc(size, alignment)
	if err == .None {
		vk_alloc_tracker.num_alloc += 1
		vk_alloc_tracker.total_alloc += size
		vk_alloc_tracker.current_memory_size += size
		vk_alloc_tracker.allocations[ptr] = {size, alignment}
	} else {
		log.errorf("VK :: alloc failed {}", err)
	}

	return ptr
}

@(private = "file")
Reallocation :: proc "system" (
	pUserData: rawptr,
	pOriginal: rawptr,
	size: int,
	alignment: int,
	allocationScope: vk.SystemAllocationScope,
) -> rawptr {
	context = {
		allocator = alloc,
		logger    = g_logger,
	}

	old_size := vk_alloc_tracker.allocations[pOriginal].size

	ptr, err := mem.resize(pOriginal, old_size, size, alignment)
	if err == .None {
		vk_alloc_tracker.num_realloc += 1
		vk_alloc_tracker.total_alloc += size
		vk_alloc_tracker.total_free += old_size
		vk_alloc_tracker.current_memory_size += size - old_size
		vk_alloc_tracker.allocations[ptr] = {size, alignment}
	} else {
		log.errorf("VK :: resize failed {}", err)
	}

	return ptr
}

@(private = "file")
Free :: proc "system" (pUserData: rawptr, pMemory: rawptr) {
	context = {
		allocator = alloc,
		logger    = g_logger,
	}

	old_size := vk_alloc_tracker.allocations[pMemory].size

	vk_alloc_tracker.num_free += 1
	vk_alloc_tracker.total_free += old_size
	vk_alloc_tracker.current_memory_size -= old_size
	delete_key(&vk_alloc_tracker.allocations, pMemory)

	mem.free(pMemory)
}

@(private = "file")
InternalAllocationNotification :: proc "system" (
	pUserData: rawptr,
	size: int,
	allocationType: vk.InternalAllocationType,
	allocationScope: vk.SystemAllocationScope,
) {
	context = {
		allocator = alloc,
		logger    = g_logger,
	}

	log.infof("VK :: {} {} allocated 0x{x}", allocationType, allocationScope, size)
}

@(private = "file")
InternalFreeNotification :: proc "system" (
	pUserData: rawptr,
	size: int,
	allocationType: vk.InternalAllocationType,
	allocationScope: vk.SystemAllocationScope,
) {
	context = {
		allocator = alloc,
		logger    = g_logger,
	}

	log.infof("VK :: {} {} free 0x{x}", allocationType, allocationScope, size)
}

