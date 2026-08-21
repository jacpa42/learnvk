package model

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
	corner:       [3]f32,
	dim:          [3]f32,
	// Slices of the data chunk. Offsets are from the start of the file
	mtl_strings:  Slice(byte),
	mtllist:      Slice(Material),
	mesh_strings: Slice(byte),
	meshes:       Slice(Mesh),
	vertices:     Slice(f32),
	normals:      Slice(f32),
	texcoords:    Slice(f32),
	faces:        Slice(Face),
}

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
	bob.data, oserr = os.read_entire_file(path, context.temp_allocator)

	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	bob.header = (^BobHeader)(raw_data(bob.data))^

	if ok != nil do ok^ = true
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
