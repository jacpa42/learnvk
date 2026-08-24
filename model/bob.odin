package model

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:slice"
import "core:time"

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

    ptr: rawptr

    ptr = raw_data(get_slice_data(bob.header.strings, bob.data))
    fmt.eprintln("strings :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.mtllist, bob.data))
    fmt.eprintln("mtllist :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.meshes, bob.data))
    fmt.eprintln("meshes :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.vertices, bob.data))
    fmt.eprintln("vertices :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.normals, bob.data))
    fmt.eprintln("normals :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.texcoords, bob.data))
    fmt.eprintln("texcoords :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))

    ptr = raw_data(get_slice_data(bob.header.faces, bob.data))
    fmt.eprintln("faces :", ptr)
	assert(mem.is_aligned(ptr, BOB_ALIGN))
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

	bob_alloc :: proc(
		userdata: rawptr,
		mode: runtime.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		loc: runtime.Source_Code_Location = #caller_location,
	) -> (
		[]byte,
		runtime.Allocator_Error,
	) {
		new_alignment := max(alignment, BOB_ALIGN)
		log.warnf("overriding alignment {}, using {}", alignment, new_alignment)

		default_allocator := (^runtime.Allocator)(userdata)

		return default_allocator.procedure(
			default_allocator.data,
			mode,
			size,
			new_alignment,
			old_memory,
			old_size,
			loc,
		)
	}

	bob_alloc_data := context.allocator

	oserr: os.Error
	bob.data, oserr = os.read_entire_file(path, {bob_alloc, &bob_alloc_data})

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
	len := slice_len(slc)

	data = ([^]T)(&bytes[slc.start])[:len]
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

bobctx_add :: proc(ctx: ^BobCreateContext, data: []$T) -> (slc: Slice(T)) {
	slc.start = u32(ctx.size)
	slc.size = u32(slice.size(data))

	ctx.size += slice.size(data)
	append(&ctx.data, slice.to_bytes(data))

	padding := ctx.size % BOB_ALIGN; if padding > 0 {
		padding = BOB_ALIGN - padding
		log.warnf("Adding {} padding bytes to bob", padding)
		ctx.size += padding
		append(&ctx.data, PADDING_BYTES[:padding])
	}

	assert(ctx.size < bits.U32_MAX)
	assert(ctx.size % BOB_ALIGN == 0)

	return
}

bobctx_make :: proc(header: ^BobHeader, obj: ^Obj) -> (ctx: BobCreateContext) {
	_ = bobctx_add(&ctx, mem.ptr_to_bytes(header))

	//
	// We need to be careful with our strings
	//
	header.strings = bobctx_add(&ctx, obj.strings[:])

	for &material in obj.materials[:] {
		for &mat in material.strings {
			mat.start += header.strings.start
		}
	}

	for &mesh in obj.meshes[:] {
		mesh.material.start += header.strings.start
		mesh.name.start += header.strings.start
	}

	//
	// everything else (plain old data)
	//
	header.mtllist = bobctx_add(&ctx, obj.materials[:])
	header.meshes = bobctx_add(&ctx, obj.meshes[:])
	header.vertices = bobctx_add(&ctx, obj.vertices[:])
	header.normals = bobctx_add(&ctx, obj.normals[:])
	header.texcoords = bobctx_add(&ctx, obj.texcoords[:])
	header.faces = bobctx_add(&ctx, obj.faces[:])

	return
}

bobctx_write :: proc(ctx: BobCreateContext, f: ^os.File) -> (err: os.Error) {
	written_size: int
	for data in ctx.data {
		written_size += os.write(f, data) or_return
	}

	assert(written_size == ctx.size)

	err = nil
	return
}


// Modifies the strings in the mtl and obj, thus we need a pointer to each
bob_create_file :: proc(obj: ^Obj, output_path: string) -> (err: os.Error) {
	corner, dim := obj_get_bounding_box(obj^)

	// TODO: rewrite to new format

	header := BobHeader {
		corner = corner,
		dim    = dim,
	}

	ctx := bobctx_make(&header, obj)

	ofile := os.create(output_path) or_return
	defer os.close(ofile)

	bobctx_write(ctx, ofile) or_return

	err = nil
	return
}

make_or_clear :: proc(item: ^[dynamic]$T, cap := 0) {
	if item^ == nil {
		item^ = make([dynamic]T, 0, cap)
	} else {
		clear(item)
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
//
