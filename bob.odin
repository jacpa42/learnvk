package learnvk

import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:time"

Bob :: []u32

Slice :: struct {
	start, count: u32,
}

BobHeader :: struct #all_or_none #align (4) {
	corner:    [3]f32,
	size:      [3]f32,
	// Slices of the data chunk. Offsets are from the start of the file
	vertices:  Slice,
	normals:   Slice,
	texcoords: Slice,
	faces:     Slice,
}

bob_destroy :: proc(bob: ^Bob) {
	delete(bob^)
	bob^ = {}
}

bob_from_path :: proc(name: string, allocator := context.allocator) -> (bob: Bob, err: os.Error) {
	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	defer {
		time.stopwatch_stop(&sw)
		log.infof("Loaded \"{}\" in {}", name, time.stopwatch_duration(sw))
	}

	data := os.read_entire_file(name, allocator) or_return

	err = nil
	bob = ([^]u32)(raw_data(data))[:len(data) / size_of(u32)]

	return
}

bob_write_from_model :: proc(m: ^Model, output_path: string) -> (err: os.Error) {

	corner, size := model_get_bounding_box(m)

	o := os.create(output_path) or_return
	defer os.close(o)

	v_num := u32(slice.size(m.vertices[:]) / size_of(u32))
	vn_num := u32(slice.size(m.normals[:]) / size_of(u32))
	vt_num := u32(slice.size(m.texcoords[:]) / size_of(u32))
	f_num := u32(slice.size(m.faces[:]) / size_of(u32))

	v := Slice{size_of(BobHeader) / size_of(u32), v_num}
	vn := Slice{v.start + v.count, vn_num}
	vt := Slice{vn.start + vn.count, vt_num}
	f := Slice{vt.start + vt.count, f_num}

	header := BobHeader {
		corner    = corner,
		size      = size,
		vertices  = v,
		normals   = vn,
		texcoords = vt,
		faces     = f,
	}

	//
	// write the data to the file
	//
	n: int
	n += os.write(o, mem.ptr_to_bytes(&header)) or_return
	n += os.write(o, slice.to_bytes(m.vertices[:])) or_return
	n += os.write(o, slice.to_bytes(m.normals[:])) or_return
	n += os.write(o, slice.to_bytes(m.texcoords[:])) or_return
	n += os.write(o, slice.to_bytes(m.faces[:])) or_return

	assert(
		n ==
		size_of(BobHeader) +
			slice.size(m.vertices[:]) +
			slice.size(m.normals[:]) +
			slice.size(m.texcoords[:]) +
			slice.size(m.faces[:]),
	)

	err = nil
	return
}

bob_header :: proc "contextless" (bob: Bob) -> ^BobHeader {
	return (^BobHeader)(raw_data(bob))
}

bob_vertices :: proc "contextless" (bob: Bob) -> []f32 {
	data := bob_vertex_bytes(bob)
	return ([^]f32)(raw_data(data))[:len(data) / size_of(f32)]
}

bob_normals :: proc "contextless" (bob: Bob) -> []f32 {
	data := bob_normal_bytes(bob)
	return ([^]f32)(raw_data(data))[:len(data) / size_of(f32)]
}

bob_texcoords :: proc "contextless" (bob: Bob) -> []f32 {
	data := bob_texcoord_bytes(bob)
	return ([^]f32)(raw_data(data))[:len(data) / size_of(f32)]
}

bob_faces :: proc "contextless" (bob: Bob) -> []Face {
	data := bob_face_bytes(bob)
	return ([^]Face)(raw_data(data))[:len(data) / size_of(Face)]
}

bob_vertex_bytes :: proc "contextless" (bob: Bob) -> []byte {
	s := bob_header(bob).vertices
	data := bob[s.start:s.start + s.count]
	return slice.to_bytes(data)
}

bob_normal_bytes :: proc "contextless" (bob: Bob) -> []byte {
	s := bob_header(bob).normals
	data := bob[s.start:s.start + s.count]
	return slice.to_bytes(data)
}

bob_texcoord_bytes :: proc "contextless" (bob: Bob) -> []byte {
	s := bob_header(bob).texcoords
	data := bob[s.start:s.start + s.count]
	return slice.to_bytes(data)
}

bob_face_bytes :: proc "contextless" (bob: Bob) -> []byte {
	s := bob_header(bob).faces
	data := bob[s.start:s.start + s.count]
	return slice.to_bytes(data)
}
