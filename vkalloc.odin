package learnvk

import "base:runtime"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

@(private = "file")
alloc: mem.Allocator

@(private = "file")
alloc_tracker: map[rawptr]struct {
	size, alignment: int,
}

@(private = "file")
total_alloc_size :: proc() -> (total: int) {
	for _, k in alloc_tracker {
		total += k.size
	}
	return
}

vk_alloc_init :: proc(allocator: mem.Allocator) -> vk.AllocationCallbacks {
	alloc = allocator
	alloc_tracker = make(type_of(alloc_tracker), allocator)

	return {
		pUserData = nil,
		pfnAllocation = Allocation,
		pfnReallocation = Reallocation,
		pfnFree = Free,
		pfnInternalAllocation = InternalAllocationNotification,
		pfnInternalFree = InternalFreeNotification,
	}
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
		alloc_tracker[ptr] = {size, alignment}
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

	old_size := alloc_tracker[pOriginal].size

	ptr, err := mem.resize(pOriginal, old_size, size, alignment)
	if err == .None {
		alloc_tracker[ptr] = {size, alignment}
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

