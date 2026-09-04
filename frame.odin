package learnvk

import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "vendor:glfw"
import vk "vendor:vulkan"

import im "imgui"

frame :: proc(engine: ^Engine) {
	result: vk.Result

	//
	// Handle frame buffer resizing early
	//
	if engine.framebuffer_resized {
		engine.framebuffer_resized = false
		engine.image_index = 0
		engine_recreate_swapchain(engine)
	}

	//
	// Before we begin our frame, we need to wait for the draw fence
	//
	result = vk.WaitForFences(engine.device, 1, &engine.draw_fence, true, bits.U64_MAX)
	ensure(result == .SUCCESS)

	//
	// Get the first image in the swapchain for the render loop
	//
	result = vk.AcquireNextImageKHR(
		device = engine.device,
		swapchain = engine.swapchain,
		timeout = bits.U64_MAX,
		semaphore = engine.present_complete_sema,
		fence = {},
		pImageIndex = &engine.image_index,
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
	result = vk.ResetFences(engine.device, 1, &engine.draw_fence)
	ensure(result == .SUCCESS)

	//
	// Fill the command buffer with our main scene render calls
	//
	engine_fill_cmd_buffer(engine)

	//
	// Submit the commands to the gpu
	//
	engine_submit_and_present_cmd_buffer(engine)

}

engine_fill_cmd_buffer :: proc(engine: ^Engine) {
	commandBuffer := engine.cmdbuf

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
		image = engine.swapchain_images[engine.image_index],
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
		image = engine.swapchain_images[engine.image_index],
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
		image = engine.depth_image,
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
		imageView = engine.swapchain_image_views[engine.image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue{color = {float32 = [4]f32{0.01, 0.01, 0.01, 0.1}}},
	}

	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.depth_image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = vk.ClearValue{depthStencil = {depth = 1, stencil = 0}},
	}

	render_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		flags                = {},
		renderArea           = {{0, 0}, engine.swapchain_extent},
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
	vk.CmdBindPipeline(commandBuffer, .GRAPHICS, engine.render_pipeline)
	vk.CmdSetViewport(commandBuffer, 0, 1, &engine.viewport)
	vk.CmdSetScissor(commandBuffer, 0, 1, &engine.scissor)

	//
	// Bind vertex buffers
	//
	assert(CURRENT_MODEL in engine.model_loaded)

	//
	// Draw all our meshes
	//

	vk.CmdBindDescriptorSets(
		commandBuffer = commandBuffer,
		pipelineBindPoint = .GRAPHICS,
		layout = engine.pipeline_layout,
		firstSet = 0,
		descriptorSetCount = 1,
		pDescriptorSets = &engine.descriptor_set,
		dynamicOffsetCount = 0,
		pDynamicOffsets = nil,
	)

	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(
		commandBuffer = commandBuffer,
		firstBinding = 0,
		bindingCount = 1,
		pBuffers = &engine.data_buffer[.vertex],
		pOffsets = &offset,
	)
	vk.CmdBindIndexBuffer(
		commandBuffer = commandBuffer,
		buffer = engine.data_buffer[.index],
		offset = 0,
		indexType = .UINT32,
	)

	vk.CmdDrawIndexedIndirect(
		commandBuffer = commandBuffer,
		buffer = engine.frame_data.buffer,
		offset = mapped_buffer_get_offset(engine.frame_data, "draw_commands"),
		drawCount = num_draw_commands,
		stride = size_of(vk.DrawIndexedIndirectCommand),
	)


	//
	// Render imgui overlay
	//
	imgui_begin(engine)
	im.ShowDemoWindow()
	imgui_end(engine, commandBuffer)
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
		pWaitSemaphores      = &engine.present_complete_sema,
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},

		//
		// The command buffers to execute
		//
		commandBufferCount   = 1,
		pCommandBuffers      = &engine.cmdbuf,

		//
		// These mutexs are locked for the duration of the submission/execution
		// of the command buffers.
		//
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &engine.swapchain_semas[engine.image_index],
	}

	result = vk.QueueSubmit(engine.queue, 1, &submit_info, engine.draw_fence)
	ensure(result == .SUCCESS)

	//
	// Present the frame on the screen
	//
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		swapchainCount     = 1,
		pSwapchains        = &engine.swapchain,
		pImageIndices      = &engine.image_index,
		pResults           = nil,

		//
		// Wait on the render finished mutex which is signalled once the command
		// buffer finishes execution.
		//
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &engine.swapchain_semas[engine.image_index],
	}

	result = vk.QueuePresentKHR(engine.queue, &present_info)
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

	aspect := f32(engine.swapchain_extent.width) / f32(max(engine.swapchain_extent.height, 1))

	view_direction := camera_view_dir(&engine.camera)

	screen_from_world :=
		linalg.matrix4_perspective_f32(
			fovy = math.to_radians_f32(45),
			aspect = aspect,
			far = 1000,
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
		light_color       = [4]f32{0x50, 0x60, 0x70, 0xff} / 0xff,
		ambient_light     = 0.1,
		flags             = engine.shader_flags,
	}

	add_draw_cmd :: proc(
		cmd: ^vk.DrawIndexedIndirectCommand,
		instances: IndexRange,
		index_start: u32,
		index_count: u32,
		vertex_offset: i32,
	) {
		cmd.firstInstance = instances.start
		cmd.instanceCount = instances.count

		cmd.firstIndex = index_start
		cmd.indexCount = index_count
		cmd.vertexOffset = vertex_offset
	}

	add_instance_material :: proc(material: Material, textures: ^ShaderInstanceTextures) {
		textures^ = ShaderInstanceTextures {
			diffuse_id  = material.diffuse_id,
			emissive_id = material.emissive_id,
			bump_id     = material.bump_id,
			specular_id = material.specular_id,
		}
	}

	add_instance_transforms :: proc(
		t: f32,
		pos: [3]f32,
		imodel_from_vertex: matrix[4, 4]f32,
		transform: ^ShaderInstanceTransforms,
	) {

		world_from_model: matrix[4, 4]f32 = 1
		world_from_model *= linalg.matrix4_translate_f32(pos)

		model_from_vertex: matrix[4, 4]f32 = 1
		model_from_vertex *= imodel_from_vertex
		// model_from_vertex *= linalg.matrix4_rotate_f32((pos.y + t) / 10 * math.PI, {pos.x, 1, 1})
		// model_from_vertex *= linalg.matrix4_rotate_f32((pos.x + t) / 10 * math.PI, {pos.y, 1, 1})

		normal_matrix := linalg.transpose(linalg.inverse(world_from_model * model_from_vertex))

		transform^ = ShaderInstanceTransforms {
			world_from_model  = world_from_model,
			model_from_vertex = model_from_vertex,
			normal_matrix     = normal_matrix,
		}

		return
	}

	//
	// setup the instance data and draw commands
	//
	t := f32(glfw.GetTime())

	num_instances: u32
	loc: [3]i32 = 0

	for mesh in engine.mesh_data {
		defer num_instances += 1

		defer add_draw_cmd(
			&frame_data.draw_commands[num_draw_commands],
			instances = IndexRange{num_instances, 1},
			index_start = mesh.index_start,
			index_count = mesh.index_count,
			vertex_offset = mesh.vertex_offset,
		); num_draw_commands += 1

		add_instance_transforms(
			t,
			{f32(loc.x), f32(loc.y), f32(loc.z)},
			mesh.model_from_vertex,
			&frame_data.instance_transforms[num_instances],
		)

		add_instance_material(
			engine.material_list[mesh.material_id],
			&frame_data.instance_textures[num_instances],
		)

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
