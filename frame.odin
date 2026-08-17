package learnvk

import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

frame :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Handle frame buffer resizing early
	//
	if engine.framebuffer_resized {
		engine.framebuffer_resized = false
		engine.vk_image_index = 0
		engine_recreate_swapchain(engine)
	}

	defer engine.vk_frame_index = (engine.vk_frame_index + 1) % FRAMES_IN_FLIGHT

	//
	// Before we begin our frame, we need to wait for the draw fence
	//
	result = vk.WaitForFences(
		engine.vk_device,
		1,
		&engine.vk_draw_fences[engine.vk_frame_index],
		true,
		bits.U64_MAX,
	)
	ensure(result == .SUCCESS)

	//
	// Get the first image in the swapchain for the render loop
	//
	result = vk.AcquireNextImageKHR(
		device = engine.vk_device,
		swapchain = engine.vk_swapchain,
		timeout = bits.U64_MAX,
		semaphore = engine.vk_present_complete_semas[engine.vk_frame_index],
		fence = {},
		pImageIndex = &engine.vk_image_index,
	)
	#partial switch result {
	case .SUCCESS, .SUBOPTIMAL_KHR:

	case .ERROR_OUT_OF_DATE_KHR:
		engine_recreate_swapchain(engine)
		return

	case:
		fmt.panicf("Failed to acquire swap chain image: {}", result)
	}

	//
	// Reset the draw fences. Must happen *after* we are sure we will render to
	// the current image view.
	//
	result = vk.ResetFences(engine.vk_device, 1, &engine.vk_draw_fences[engine.vk_frame_index])
	ensure(result == .SUCCESS)

	//
	// Fill the command buffer
	//
	engine_fill_cmd_buffer(engine)

	engine_submit_and_present_cmd_buffer(engine)
}

engine_fill_cmd_buffer :: proc(engine: ^Engine) {
	//
	// Begin recording the command buffer
	//
	begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		pInheritanceInfo = nil,
	}

	vk.BeginCommandBuffer(engine.vk_cmdbufs[engine.vk_frame_index], &begin_info)
	defer vk.EndCommandBuffer(engine.vk_cmdbufs[engine.vk_frame_index])

	//
	// Make the image optimal to use as a colour attachment (ie render target?)
	//
	image_change_layout(
		cmdbuf = engine.vk_cmdbufs[engine.vk_frame_index],
		image = engine.vk_swapchain_images[engine.vk_image_index],
		old_layout = .UNDEFINED,
		new_layout = .COLOR_ATTACHMENT_OPTIMAL,
		src_access = {},
		dst_access = {.COLOR_ATTACHMENT_WRITE},
		src_stage = {.COLOR_ATTACHMENT_OUTPUT},
		dst_stage = {.COLOR_ATTACHMENT_OUTPUT},
		aspect_mask = {.COLOR},
	)

	image_change_layout(
		cmdbuf = engine.vk_cmdbufs[engine.vk_frame_index],
		image = engine.vk_depth_image,
		old_layout = .UNDEFINED,
		new_layout = .DEPTH_ATTACHMENT_OPTIMAL,
		src_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		dst_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		src_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		dst_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		aspect_mask = {.DEPTH},
	)

	//
	// At the end of the frame, convert the image back so we can present it
	//
	defer image_change_layout(
		cmdbuf = engine.vk_cmdbufs[engine.vk_frame_index],
		image = engine.vk_swapchain_images[engine.vk_image_index],
		old_layout = .COLOR_ATTACHMENT_OPTIMAL,
		new_layout = .PRESENT_SRC_KHR,
		src_access = {.COLOR_ATTACHMENT_WRITE},
		dst_access = {},
		src_stage = {.COLOR_ATTACHMENT_OUTPUT},
		dst_stage = {.BOTTOM_OF_PIPE},
		aspect_mask = {.COLOR},
	)

	//
	// Define a clear pass on the current swapchain image
	//
	color_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.vk_swapchain_image_views[engine.vk_image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue{color = {uint32 = {0x74, 0x16, 0x18, 0xff}}},
	}

	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.vk_depth_image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue{depthStencil = {depth = 10, stencil = 0}},
	}


	render_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		flags                = {},
		renderArea           = {{0, 0}, engine.vk_swapchain_extent},
		layerCount           = 1,
		viewMask             = 0,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_info,
		pDepthAttachment     = &depth_attachment_info,
		pStencilAttachment   = nil,
	}

	//
	// Render to the image_view
	//
	vk.CmdBeginRendering(engine.vk_cmdbufs[engine.vk_frame_index], &render_info)
	defer vk.CmdEndRendering(engine.vk_cmdbufs[engine.vk_frame_index])

	//
	// Bind the uniform buffer
	//

	vk.CmdBindDescriptorSets(
		commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
		pipelineBindPoint = .GRAPHICS,
		layout = engine.vk_pipeline_layout,
		firstSet = 0,
		descriptorSetCount = 1,
		pDescriptorSets = &engine.vk_descriptor_sets[CURRENT_MODEL],
		dynamicOffsetCount = 0,
		pDynamicOffsets = nil,
	)

	//
	// Update the uniform buffer
	//

	engine_handle_input(engine)
	uniforms := engine_make_uniforms(engine)

	mem.copy_non_overlapping(
		dst = engine.vk_uniform_buffers_mmapped[engine.vk_frame_index],
		src = rawptr(&uniforms),
		len = size_of(uniforms),
	)

	//
	// Run the graphics pipeline
	//
	vk.CmdBindPipeline(
		engine.vk_cmdbufs[engine.vk_frame_index],
		.GRAPHICS,
		engine.vk_render_pipeline,
	)
	vk.CmdSetViewport(engine.vk_cmdbufs[engine.vk_frame_index], 0, 1, &engine.vk_viewport)
	vk.CmdSetScissor(engine.vk_cmdbufs[engine.vk_frame_index], 0, 1, &engine.vk_scissor)

	//
	// Bind vertex buffers
	//
	model := engine.models[CURRENT_MODEL]

	pOffsets: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(
		commandBuffer = engine.vk_cmdbufs[engine.vk_frame_index],
		firstBinding = 0,
		bindingCount = 1,
		pBuffers = &engine.vk_model_buffer[CURRENT_MODEL][.model_points],
		pOffsets = &pOffsets,
	)

	vk.CmdDraw(
		engine.vk_cmdbufs[engine.vk_frame_index],
		vertexCount = model_get_num_points(model),
		instanceCount = 1,
		firstVertex = 0,
		firstInstance = 0,
	)
}

engine_submit_and_present_cmd_buffer :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Submit the command buffer
	//
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,

		//
		// Waits for these mutexs to be unlocked before we begin executing the
		// command buffer.
		//
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &engine.vk_present_complete_semas[engine.vk_frame_index],
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},

		//
		// The command buffers to execute
		//
		commandBufferCount   = 1,
		pCommandBuffers      = &engine.vk_cmdbufs[engine.vk_frame_index],

		//
		// These mutexs are locked for the duration of the submission/execution
		// of the command buffers.
		//
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &engine.vk_swapchain_semas[engine.vk_image_index],
	}

	result = vk.QueueSubmit(
		engine.vk_queue,
		1,
		&submit_info,
		engine.vk_draw_fences[engine.vk_frame_index],
	)
	ensure(result == .SUCCESS)

	//
	// Present the frame on the screen
	//
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		swapchainCount     = 1,
		pSwapchains        = &engine.vk_swapchain,
		pImageIndices      = &engine.vk_image_index,
		pResults           = nil,

		//
		// Wait on the render finished mutex which is signalled once the command
		// buffer finishes execution.
		//
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &engine.vk_swapchain_semas[engine.vk_image_index],
	}

	result = vk.QueuePresentKHR(engine.vk_queue, &present_info)
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		engine_recreate_swapchain(engine)
	} else {
		ensure(result == .SUCCESS)
	}
}

// odinfmt: disable
engine_handle_input :: proc(engine: ^Engine) {
	assert(linalg.length(engine.camera.up) == 1)

    cam := &engine.camera

    view_dir := camera_view_dir(cam)

	forward := cam.speed * view_dir
	right   := cam.speed * linalg.normalize(linalg.cross(view_dir, cam.up))
    up      := cam.speed * cam.up

	for action in engine.actions do switch action {

	case .forward:  cam.pos += forward
	case .backward: cam.pos -= forward

    case .right: cam.pos += right
	case .left:  cam.pos -= right

	case .down: cam.pos += up
	case .up:   cam.pos -= up

	}
}
// odinfmt: enable

engine_make_uniforms :: proc(engine: ^Engine) -> (u: Uniforms) {
	//
	// Engine setup uniforms
	//

	t := f32(glfw.GetTime())

	aspect :=
		f32(engine.vk_swapchain_extent.width) / f32(max(engine.vk_swapchain_extent.height, 1))

	view_direction := camera_view_dir(&engine.camera)

	corner := engine.models[CURRENT_MODEL].header.corner
	size := engine.models[CURRENT_MODEL].header.size

	model_from_vertex :=
		linalg.matrix4_scale_f32(1.0 / max(size.x, size.y, size.z, 0.001)) *
		linalg.matrix4_translate_f32({-corner.x, -corner.y, -corner.z}) *
		linalg.matrix4_rotate_f32(t, {1, 1, 0})


	u = Uniforms {
		screen_from_world = linalg.matrix4_perspective_f32(
			fovy = math.to_radians_f32(45),
			aspect = aspect,
			far = 100,
			near = 0.1,
		),
		world_from_model  = linalg.matrix4_look_at_f32(
			eye = engine.camera.pos,
			centre = engine.camera.pos + view_direction,
			up = engine.camera.up,
		),
		model_from_vertex = model_from_vertex,
		lightdir          = linalg.normalize([3]f32{1, 1, 1}),
	}

	return
}

