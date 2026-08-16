package learnvk

import "core:math"
Camera :: struct {
	speed:       f32,
	sensitivity: f32,
	pitch:       f32,
	yaw:         f32,
	pos:         [3]f32,
	up:          [3]f32,
}

camera_view_dir :: proc "contextless" (cam: ^Camera) -> [3]f32 {
	sy := math.sin(cam.yaw)
	cy := math.cos(cam.yaw)
	sp := math.sin(cam.pitch)
	cp := math.cos(cam.pitch)

	return {cy * cp, sp, sy * cp}
}

