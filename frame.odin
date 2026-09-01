package learnvk

import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "model"
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

	//
	// Before we begin our frame, we need to wait for the draw fence
	//
	result = vk.WaitForFences(engine.vk_device, 1, &engine.vk_draw_fence, true, bits.U64_MAX)
	ensure(result == .SUCCESS)

	//
	// Get the first image in the swapchain for the render loop
	//
	result = vk.AcquireNextImageKHR(
		device = engine.vk_device,
		swapchain = engine.vk_swapchain,
		timeout = bits.U64_MAX,
		semaphore = engine.vk_present_complete_sema,
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
	result = vk.ResetFences(engine.vk_device, 1, &engine.vk_draw_fence)
	ensure(result == .SUCCESS)

	//
	// Fill the command buffer
	//
	engine_fill_cmd_buffer(engine)

	//
	// Submit the commands to the gpu
	//
	engine_submit_and_present_cmd_buffer(engine)
}

engine_fill_cmd_buffer :: proc(engine: ^Engine) {
	commandBuffer := engine.vk_cmdbuf

	//
	// Begin recording the command buffer
	//
	begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		pInheritanceInfo = nil,
	}

	vk.BeginCommandBuffer(commandBuffer, &begin_info)
	defer vk.EndCommandBuffer(commandBuffer)

	//
	// Make the image optimal to use as a colour attachment (ie render target?)
	//
	image_change_layout(
		cmdbuf = commandBuffer,
		image = engine.vk_swapchain_images[engine.vk_image_index],
		old_layout = .UNDEFINED,
		new_layout = .COLOR_ATTACHMENT_OPTIMAL,
		src_access = {},
		dst_access = {.COLOR_ATTACHMENT_WRITE},
		src_stage = {.TOP_OF_PIPE},
		dst_stage = {.COLOR_ATTACHMENT_OUTPUT},
		aspect_mask = {.COLOR},
	)

	defer image_change_layout(
		cmdbuf = commandBuffer,
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
	// Change the depth buffer to be optimal for a depth attachment
	//
	// TODO: Do I need to do this each frame?
	//
	image_change_layout(
		cmdbuf = commandBuffer,
		image = engine.vk_depth_image,
		old_layout = .UNDEFINED,
		new_layout = .DEPTH_ATTACHMENT_OPTIMAL,
		src_access = {},
		dst_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		src_stage = {.TOP_OF_PIPE},
		dst_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		aspect_mask = {.DEPTH},
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
		clearValue = vk.ClearValue{color = {float32 = [4]f32{0x02, 0x02, 0x02, 0xff} / 255}},
	}

	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.vk_depth_image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue{depthStencil = {depth = 1, stencil = 0}},
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
	vk.CmdBeginRendering(commandBuffer, &render_info)
	defer vk.CmdEndRendering(commandBuffer)

	//
	// Update the uniform buffer
	//

	engine_handle_input(engine)
	num_draw_commands := engine_make_framedata(engine, engine.frame_data.ptr)

	//
	// Run the graphics pipeline
	//
	vk.CmdBindPipeline(commandBuffer, .GRAPHICS, engine.vk_render_pipeline)
	vk.CmdSetViewport(commandBuffer, 0, 1, &engine.vk_viewport)
	vk.CmdSetScissor(commandBuffer, 0, 1, &engine.vk_scissor)

	//
	// Bind vertex buffers
	//
	assert(CURRENT_MODEL in engine.model_loaded)

	//
	// Draw all our meshes
	//
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(
		commandBuffer = commandBuffer,
		firstBinding = 0,
		bindingCount = 1,
		pBuffers = &engine.vk_model_buffer[.vertex].buffer,
		pOffsets = &offset,
	)
	vk.CmdBindIndexBuffer(
		commandBuffer = commandBuffer,
		buffer = engine.vk_model_buffer[.index].buffer,
		offset = 0,
		indexType = .UINT32,
	)

	vk.CmdBindDescriptorSets(
		commandBuffer = commandBuffer,
		pipelineBindPoint = .GRAPHICS,
		layout = engine.vk_pipeline_layout,
		firstSet = 0,
		descriptorSetCount = 1,
		pDescriptorSets = &engine.vk_descriptor_set,
		dynamicOffsetCount = 0,
		pDynamicOffsets = nil,
	)

	vk.CmdDrawIndexedIndirect(
		commandBuffer = commandBuffer,
		buffer = engine.frame_data.buffer,
		offset = mapped_buffer_get_offset(engine.frame_data, "draw_commands"),
		drawCount = num_draw_commands,
		stride = size_of(DrawInstancesCommand),
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
		pWaitSemaphores      = &engine.vk_present_complete_sema,
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},

		//
		// The command buffers to execute
		//
		commandBufferCount   = 1,
		pCommandBuffers      = &engine.vk_cmdbuf,

		//
		// These mutexs are locked for the duration of the submission/execution
		// of the command buffers.
		//
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &engine.vk_swapchain_semas[engine.vk_image_index],
	}

	result = vk.QueueSubmit(engine.vk_queue, 1, &submit_info, engine.vk_draw_fence)
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

	case .forward:  cam.pos.xyz += forward
	case .backward: cam.pos.xyz -= forward

    case .right: cam.pos.xyz += right
	case .left:  cam.pos.xyz -= right

	case .down: cam.pos.xyz += up
	case .up:   cam.pos.xyz -= up

	}
}
// odinfmt: enable

#assert(PIPELINE == .shader)
engine_make_uniforms :: proc(engine: ^Engine, uniforms: ^ShaderUniforms) {
	//
	// Engine setup uniforms
	//

	if !engine.disable_rotate {
		engine.model_rotation = math.remainder(engine.model_rotation + engine.delta_time, math.TAU)
	}

	aspect :=
		f32(engine.vk_swapchain_extent.width) / f32(max(engine.vk_swapchain_extent.height, 1))

	view_direction := camera_view_dir(&engine.camera)

	screen_from_world :=
		linalg.matrix4_perspective_f32(
			fovy = math.to_radians_f32(45),
			aspect = aspect,
			far = 10,
			near = 0.01,
		) *
		linalg.matrix4_look_at_f32(
			eye = engine.camera.pos.xyz,
			centre = engine.camera.pos.xyz + view_direction,
			up = engine.camera.up,
		)

	uniforms^ = {
		screen_from_world = screen_from_world,

		//
		camera_position   = engine.camera.pos,
		light_position    = {0, 0, 100, 0},
		light_color       = [4]f32{0xff, 0xff, 0xff, 0xff} / 0xff,
		ambient_light     = 0.1,
		flags             = engine.shader_flags,
	}

	return
}

@(require_results)
engine_make_framedata :: proc(
	engine: ^Engine,
	frame_data: ^FrameBufferData,
) -> (
	num_draw_commands: u32,
) {
	//
	// Engine setup uniforms
	//

	if !engine.disable_rotate {
		engine.model_rotation = math.remainder(engine.model_rotation + engine.delta_time, math.TAU)
	}

	aspect :=
		f32(engine.vk_swapchain_extent.width) / f32(max(engine.vk_swapchain_extent.height, 1))

	view_direction := camera_view_dir(&engine.camera)

	screen_from_world :=
		linalg.matrix4_perspective_f32(
			fovy = math.to_radians_f32(45),
			aspect = aspect,
			far = 10,
			near = 0.01,
		) *
		linalg.matrix4_look_at_f32(
			eye = engine.camera.pos.xyz,
			centre = engine.camera.pos.xyz + view_direction,
			up = engine.camera.up,
		)

	frame_data.uniforms = {
		screen_from_world = screen_from_world,

		//
		camera_position   = engine.camera.pos,
		light_position    = {0, 0, 100, 0},
		light_color       = [4]f32{0xff, 0xff, 0xff, 0xff} / 0xff,
		ambient_light     = 0.1,
		flags             = engine.shader_flags,
	}

	//
	// setup the instance data and draw commands
	//
	t := f32(glfw.GetTime() * 0.1)

	instance_index: u32
	for model_tag in (LOAD_MODELS & engine.model_loaded & {CURRENT_MODEL}) {
		y := 0
		x := 0

		world_from_model := linalg.matrix4_translate_f32({f32(x) * 1.1, f32(y) * 1.1, 0})

		corner := engine.models[model_tag].header.corner
		dim := engine.models[model_tag].header.dim
		model_from_vertex := linalg.matrix4_scale_f32(1.0 / max(dim.x, dim.y, dim.z, 0.001))
		model_from_vertex *= linalg.matrix4_translate_f32({-corner.x, -corner.y, -corner.z})
		model_from_vertex *= linalg.matrix4_rotate_f32((f32(y) / 10 + t) * math.PI, {0, 1, 0})
		model_from_vertex *= linalg.matrix4_rotate_f32((f32(x) / 10 + t) * math.PI, {1, 0, 0})

		frame_data.instance_transforms[instance_index] = InstanceTransforms {
			world_from_model  = world_from_model,
			model_from_vertex = model_from_vertex,
		}

		// TODO: Maintian a list of entities which we can copy mesh data from.
		frame_data.instance_textures[instance_index] = InstanceTextures {
			diffuse  = 0,
			emissive = -1,
			bump     = -1,
			specular = -1,
		}


		// TODO: I want to filter out the meshes based on some rule. Not sure
		// how to do that best.

		//
		// Set the instance number and instance count for the draw command
		// in the mesh_draw_info thingie
		//
		for &cmd in engine.mesh_draw_command[model_tag] {
			//
			// Set the instance start and instance count
			//
			cmd.vk_cmd.firstInstance = 0
			cmd.vk_cmd.instanceCount = 1
		}
	}


	// TODO: We don't actually need to write all the commands each frame, we can
	// just write to specific draw commands in our memory mapped command list
	// rather. Could be better? i have no idea how to reason about that

	//
	// copy over the draw commands the draw commands
	//
	for model_tag in (LOAD_MODELS & engine.model_loaded) {

		for cmd, mesh_index in engine.mesh_draw_command[model_tag] {
			fmt.eprintfln("draw mesh({}) model({}): %#v", mesh_index, model_tag, cmd)
			frame_data.draw_commands[num_draw_commands] = cmd
			num_draw_commands += 1
		}

	}

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
