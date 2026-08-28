package learnvk

import "core:math"

Camera :: struct {
	speed:       f32,
	sensitivity: f32,
	pitch:       f32,
	yaw:         f32,
	pos:         [4]f32,
	up:          [3]f32,
}

camera_view_dir :: proc "contextless" (cam: ^Camera) -> [3]f32 {
	sinyaw := math.sin(cam.yaw)
	cosyaw := math.cos(cam.yaw)
	sinpitch := math.sin(cam.pitch)
	cospitch := math.cos(cam.pitch)

	return {cosyaw * cospitch, sinyaw * cospitch, -sinpitch}
}

