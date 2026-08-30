package learnvk

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

GpuTransferQueue :: struct {
	buf:        vk.Buffer,
	buf_memory: vk.DeviceMemory,
	buf_mmap:   []byte,

	// how much memory we have copied to the transfer buffer
	reserved:   int,

	// lil command buffer for sending shit over
	recording:  bool,
	cmdbuf:     vk.CommandBuffer,
}

CopyOp :: struct {
	size:    vk.DeviceSize,
	dbuf:    vk.Buffer,
	doffset: vk.DeviceSize,
	soffset: vk.DeviceSize,
}

@(private = "file")
queue_cap :: proc(queue: ^GpuTransferQueue) -> int {
	return max(0, len(queue.buf_mmap) - queue.reserved)
}

queue_allocate_chunk :: proc(
	queue: ^GpuTransferQueue,
	#any_int chunk_size: int,
	loc := #caller_location,
) -> (
	chunk: []byte,
	offset: vk.DeviceSize,
) {
	assert(chunk_size > 0, loc = loc)

	align := physical_device_properties.limits.optimalBufferCopyOffsetAlignment
	if align == 0 do align = 16

	queue.reserved = mem.align_forward_int(queue.reserved, int(align))

	if queue_cap(queue) < chunk_size do return

	chunk = queue.buf_mmap[queue.reserved:queue.reserved + chunk_size]

	// the offset into the buffer is just the offset of the next aligned pointer
	offset = vk.DeviceSize(queue.reserved)

	// the reserved size is the end of the buffer we just allocated minus the
	// start of the mapped memory
	queue.reserved = mem.align_forward_int(queue.reserved + chunk_size, int(align))

	return
}

//
// Basically calls queue_append_buffer until all data is gpu side.
//
queue_append_whole_buffer :: proc(
	queue: ^GpuTransferQueue,
	device: vk.Device,
	vk_queue: vk.Queue,

	// buffer data
	buffer: vk.Buffer,
	initial_offset: vk.DeviceSize,
	data: []byte,
	loc := #caller_location,
) {
	written := 0
	offset := int(initial_offset)

	for written < len(data) {
		write_size, needs_flush := queue_append_buffer(queue, buffer, offset, data[written:], loc)
		if needs_flush do queue_flush(queue, device, vk_queue)

		written += write_size
		offset += write_size
	}
}

queue_append_buffer :: proc(
	queue: ^GpuTransferQueue,
	buffer: vk.Buffer,
	#any_int offset: vk.DeviceSize,
	data: []byte,
	loc := #caller_location,
) -> (
	written: int,
	needs_flush: bool,
) {
	//
	// If we are not recording, we start recording the command buffer
	//
	if !queue.recording {
		cmd_oneshot_begin(queue.cmdbuf, loc = loc)
		queue.recording = true
	}

	written = min(queue_cap(queue), len(data))

	gpu_copy_dest, srcOffset := queue_allocate_chunk(queue, written)
	assert(gpu_copy_dest != nil)

	mem.copy_non_overlapping(raw_data(gpu_copy_dest), raw_data(data[:]), written)

	// TODO: does this work even when the region pointer goes out of scope
	region := vk.BufferCopy {
		srcOffset = srcOffset,
		dstOffset = offset,
		size      = vk.DeviceSize(written),
	}

	vk.CmdCopyBuffer(
		commandBuffer = queue.cmdbuf,
		srcBuffer = queue.buf,
		dstBuffer = buffer,
		regionCount = 1,
		pRegions = &region,
	)

	needs_flush = (written < slice.size(data))
	return
}

AppendImageAction :: enum {
	yes,
	after_flush,
	buffer_too_small,
}

queue_can_append_image :: proc(
	queue: ^GpuTransferQueue,
	#any_int data_size: int,
) -> AppendImageAction {
	if queue_cap(queue) >= data_size {
		return .yes
	} else if slice.size(queue.buf_mmap) >= data_size {
		return .after_flush
	} else {
		return .buffer_too_small
	}
}

queue_append_whole_image :: proc(
	queue: ^GpuTransferQueue,
	device: vk.Device,
	vk_queue: vk.Queue,

	// image data
	image: vk.Image,
	image_extent: vk.Extent3D,
	image_data: []byte,
	loc := #caller_location,
) -> (
	ok: bool,
) {
	switch queue_can_append_image(queue, slice.size(image_data)) {
	case .yes:
		return queue_append_image(queue, image, image_extent, image_data, loc = loc)

	case .after_flush:
		queue_flush(queue, device, vk_queue)
		return queue_append_image(queue, image, image_extent, image_data, loc = loc)

	case .buffer_too_small:
		return false
	}

	unreachable()
}

//
// When we dont have enough data to copy to our transfer buffer, we return a
// flag which says please flush :)
//
queue_append_image :: proc(
	queue: ^GpuTransferQueue,
	image: vk.Image,
	image_extent: vk.Extent3D,
	image_data: []byte,
	loc := #caller_location,
) -> (
	ok: bool,
) {
	assert(
		slice.size(queue.buf_mmap) >= slice.size(image_data),
		"Transfer buffer is too small to upload this image",
		loc = loc,
	)

	if slice.size(image_data) > queue_cap(queue) {
		ok = false
		return
	}

	//
	// If we are not recording, we start recording the command buffer
	//
	if !queue.recording {
		cmd_oneshot_begin(queue.cmdbuf)
		queue.recording = true
	}

	gpu_copy_dest, bufferOffset := queue_allocate_chunk(queue, len(image_data))
	assert(gpu_copy_dest != nil)

	mem.copy_non_overlapping(raw_data(gpu_copy_dest), raw_data(image_data[:]), len(image_data))

	//
	// Image barrier to make it optimal for copying
	//
	{
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
			commandBuffer = queue.cmdbuf,
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
	}


	//
	// Add the copy command
	//
	region := vk.BufferImageCopy {
		imageExtent = image_extent,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		bufferOffset = bufferOffset,
	}
	vk.CmdCopyBufferToImage(
		commandBuffer = queue.cmdbuf,
		srcBuffer = queue.buf,
		dstImage = image,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		regionCount = 1,
		pRegions = &region,
	)

	//
	// Transition the image to be optimal for sampling
	//
	{
		image_barrier := vk.ImageMemoryBarrier {
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
			commandBuffer = queue.cmdbuf,
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


	ok = true
	return
}

//
// Submits the command buffer with all the data. Also can wait for the previous
// flush to finish.
//
queue_flush :: proc(queue: ^GpuTransferQueue, device: vk.Device, vk_queue: vk.Queue) {
	if !queue.recording do return

	result: vk.Result

	//
	// Reset the queue
	//
	assert(queue.recording)
	queue.recording = false
	queue.reserved = 0

	//
	// Submit the command buffer
	//
	result = vk.EndCommandBuffer(queue.cmdbuf)
	ensure(result == .SUCCESS)

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &queue.cmdbuf,
	}

	result = vk.QueueSubmit(vk_queue, submitCount = 1, pSubmits = &submit_info, fence = 0)
	ensure(result == .SUCCESS)

	result = vk.DeviceWaitIdle(device)
	ensure(result == .SUCCESS)
}

queue_init :: proc(
	queue: ^GpuTransferQueue,
	device: vk.Device,
	alloc: ^vk.AllocationCallbacks,
	#any_int transfer_buf_size: vk.DeviceSize,
	cmdpool: vk.CommandPool,
) {
	//
	// Create and map the transfer buffer
	//
	queue.buf, queue.buf_memory = engine_create_buffer(
		device,
		alloc,
		transfer_buf_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT, .DEVICE_LOCAL},
	)

	data: rawptr

	result := vk.MapMemory(
		device,
		queue.buf_memory,
		offset = 0,
		size = auto_cast vk.WHOLE_SIZE,
		flags = {},
		ppData = &data,
	)
	ensure(result == .SUCCESS)

	queue.buf_mmap = ([^]byte)(data)[:transfer_buf_size]

	//
	// Create the command buffer
	//

	cmdbuf_alloc_create_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = cmdpool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	result = vk.AllocateCommandBuffers(device, &cmdbuf_alloc_create_info, &queue.cmdbuf)
	ensure(result == .SUCCESS)

	return
}

queue_destroy :: proc(
	device: vk.Device,
	queue: ^GpuTransferQueue,
	alloc: ^vk.AllocationCallbacks,
) {
	defer queue^ = {}

	assert(queue.reserved == 0)

	vk.UnmapMemory(device, queue.buf_memory)
	vk.FreeMemory(device, queue.buf_memory, alloc)
	vk.DestroyBuffer(device, queue.buf, alloc)

}

