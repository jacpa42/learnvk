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

	info("{} strings  : len={} size={}\n", rawptr(bob), slice_len(bob.header.strings),  bob.header.strings.size)
	info("{} mtllist  : len={} size={}\n", rawptr(bob), slice_len(bob.header.mtllist),  bob.header.mtllist.size)
	info("{} vertices : len={} size={}\n", rawptr(bob), slice_len(bob.header.vertices), bob.header.vertices.size)
	info("{} indices : len={} size={}\n", rawptr(bob), slice_len(bob.header.indices), bob.header.indices.size)

	for mesh, i in get_meshes(bob^) {
		name := get_slice_string(mesh.name, bob.data)
		material := get_slice_string(mesh.material, bob.data)
		info(
			"{} mesh {} : name={} material={} num_indices={}\n",
			rawptr(bob),
			i,
			name,
			material,
			mesh.index_count,
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
}
// odinfmt: enable

bob_destroy :: proc(bob: ^Bob) {
	delete(bob.data)
	bob.data = nil
}

bob_load :: proc(bob: ^Bob, path: string) -> (result: Result) {
	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	defer if result == .Ok {
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
		log.errorf("Failed to load bob file \"{}\": {}", path, oserr)
		return .Bob_Load_Error
	}

	bob.header = (^BobHeader)(raw_data(bob.data))^

	when ENABLE_DEBUG_PRINTING do bob_dump_info(bob)

	result = .Ok
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

	header.mtl_path = obj.mtl_path
	header.mtl_path.start += header.strings.start

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
	header.indices = bobctx_add(&ctx, obj.indices[:])

	return
}

bobctx_write :: proc(ctx: BobCreateContext, f: ^os.File) -> (result: Result) {
	written_size: int
	for data in ctx.data {
		n, err := os.write(f, data)
		if err != nil do return .Bob_File_Write_Error
		written_size += n
	}

	assert(written_size == ctx.size)

	result = .Ok
	return
}


// Modifies the strings in the mtl and obj, thus we need a pointer to each
bob_create_file :: proc(obj: ^Obj, output_path: string) -> (result: Result) {
	// TODO: rewrite to new format

	header := BobHeader {
		corner = obj.header.corner,
		dim    = obj.header.dim,
	}

	ctx := bobctx_make(&header, obj)

	ofile, err := os.create(output_path)
	if err != nil {
		log.errorf("Failed to create bob file \"{}\": {}", output_path, err)
		result = .Bob_File_Create_Error
		return
	}

	defer os.close(ofile)

	bobctx_write(ctx, ofile) or_return

	result = .Ok
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
