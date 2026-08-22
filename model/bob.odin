package model

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:time"

Bob :: struct {
	header: BobHeader,
	data:   []u8,
}

Slice :: struct($T: typeid) {
	start, size: u32,
}

BobHeader :: struct #align (4) {
	corner:    [3]f32,
	dim:       [3]f32,
	// Slices of the data chunk. Offsets are from the start of the file
	strings:   Slice(byte),
	mtllist:   Slice(Material),
	meshes:    Slice(Mesh),
	vertices:  Slice(f32),
	normals:   Slice(f32),
	texcoords: Slice(f32),
	faces:     Slice(Face),
}

// odinfmt: disable
bob_dump_info :: proc(bob: ^Bob) {
	info :: fmt.eprintf

	info("{} faces     : len={} size={}\n", rawptr(bob), slice_len(bob.header.faces), bob.header.faces.size)
	info("{} vertices  : len={} size={}\n", rawptr(bob), slice_len(bob.header.vertices), bob.header.vertices.size)
	info("{} normals   : len={} size={}\n", rawptr(bob), slice_len(bob.header.normals), bob.header.normals.size)
	info("{} texcoords : len={} size={}\n", rawptr(bob), slice_len(bob.header.texcoords), bob.header.texcoords.size)
	info("{} strings   : {}\n", rawptr(bob), get_slice_string(bob.header.strings, bob.data))

	for mesh, i in get_meshes(bob^) {
		name := get_slice_string(mesh.name, bob.data)
		material := get_slice_string(mesh.material, bob.data)
		num_faces := mesh.faces_count
		info(
			"{} mesh {} : name={} material={} num_faces={}\n",
			rawptr(bob),
			i,
			name,
			material,
			num_faces,
		)
	}

	for m, i in get_material_list(bob^) {
		info("{} material {} : ", rawptr(bob), i)
		for slc, tag in m.strings {
			value := get_slice_string(slc, bob.data)
			if len(value) > 0 {
				info("{}={} ", tag, get_slice_string(slc, bob.data))
			}
		}
		info("\n")
	}
}
// odinfmt: enable

bob_destroy :: proc(bob: ^Bob) {
	delete(bob.data)
	bob.data = nil
}

bob_load :: proc(bob: ^Bob, path: string, ok: ^bool = nil) {

	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	defer {
		time.stopwatch_stop(&sw)
		log.infof("Loaded \"{}\" in {}", path, time.stopwatch_duration(sw))
	}

	oserr: os.Error
	bob.data, oserr = os.read_entire_file(path, context.allocator)

	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	bob.header = (^BobHeader)(raw_data(bob.data))^

	if ok != nil do ok^ = true

	when ODIN_DEBUG do bob_dump_info(bob)

	return
}

//
// Gets the slice data from the source buffer
//
get_slice_data :: proc "contextless" (slc: Slice($T), source: []$E) -> (data: []T) {
	assert_contextless(int(slc.start + slc.size) <= slice.size(source))

	bytes := slice.to_bytes(source)
	data = ([^]T)(&bytes[slc.start])[:slc.size / size_of(T)]
	return
}

get_slice_string :: proc "contextless" (slc: Slice(byte), source: []byte) -> (data: string) {
	assert_contextless(int(slc.start + slc.size) <= slice.size(source))

	data = string(source[slc.start:slc.start + slc.size])
	return
}

slice_len :: proc "contextless" (slc: Slice($T)) -> int {
	when size_of(T) > 0 {
		return int(slc.size) / size_of(T)
	} else {
		return 0
	}
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
