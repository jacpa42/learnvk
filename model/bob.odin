package model

import "core:log"
import "core:os"
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

bob_load :: proc(path: string, allocator := context.allocator) -> (bob: Bob, err: os.Error) {
	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	defer {
		time.stopwatch_stop(&sw)
		log.infof("Loaded \"{}\" in {}", path, time.stopwatch_duration(sw))
	}

	bob.data = os.read_entire_file(path, allocator) or_return
	bob.header = (^BobHeader)(raw_data(bob.data))^

	err = nil
	return
}

bob_get_slice :: proc(bob: Bob, slc: Slice($T)) -> (data: []T) {
	assert(slc.size % size_of(T) == 0)
	data = ([^]T)(&bob.data[slc.start])[:slc.size / size_of(T)]
	return
}
