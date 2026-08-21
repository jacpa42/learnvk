package model

import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:simd"
import "core:slice"
import "core:strconv"
import "core:strings"

// TODO: Make material loading part of the obj loading process!

MAX_POINTS_PER_FACE :: 8
ENABLE_DEBUG_PRINTING :: false
DEFAULT_SLICE_ALIGNMENT :: align_of(u32)
PADDING_BYTES: [8]u8

PointIndex :: enum {
	vertex,
	texcoord,
	normal,
}

UnsignedPoint :: [PointIndex]u32
SignedPoint :: [PointIndex]i32
Face :: distinct [3]UnsignedPoint
Vertex :: distinct [3]f32
Normal :: distinct [3]f32
TexCoord :: distinct [2]f32

Obj :: struct {
	// Raw data
	vertices:  [dynamic]f32, // 3 bytes per vertex
	normals:   [dynamic]f32, // 3 bytes per vertex
	texcoords: [dynamic]f32, // 2 bytes per vertex

	// The triangles
	faces:     [dynamic]Face,

	// Mesh
	strings:   [dynamic]byte,
	meshes:    [dynamic]Mesh,
}

Mesh :: struct {
	material:                 Slice(byte),
	name:                     Slice(byte),
	faces_start, faces_count: u32,
}

@(private = "file")
ParsedFace :: struct {
	points_len: u32,
	points:     struct #raw_union {
		unsigned: [MAX_POINTS_PER_FACE]UnsignedPoint,
		signed:   [MAX_POINTS_PER_FACE]SignedPoint,
	},
}

obj_init_or_clear :: proc(m: ^Obj) {
	assert(m != nil)
	make_or_clear(&m.vertices)
	make_or_clear(&m.normals)
	make_or_clear(&m.texcoords)
	make_or_clear(&m.strings)
	make_or_clear(&m.faces)
	make_or_clear(&m.meshes)
}

obj_destroy :: proc(m: ^Obj) {
	defer m^ = {}
	delete(m.meshes)
	delete(m.vertices)
	delete(m.normals)
	delete(m.texcoords)
	delete(m.faces)
	delete(m.strings)
}

obj_load :: proc(m: ^Obj, path: string, ok: ^bool = nil) {
	assert(path != {})

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", path, f32(len(raw)) / (1024 * 1024))

	obj_load_obj_memory_ok := obj_load_obj_memory(m, raw)

	if ok != nil do ok^ = obj_load_obj_memory_ok

	return
}

obj_get_bounding_box :: proc(m: Obj) -> (corner, size: [3]f32) {
	i: int
	min, max: #simd[4]f32

	for i < len(m.vertices) {
		defer i += 3

		vec := #simd[4]f32{m.vertices[i + 0], m.vertices[i + 1], m.vertices[i + 2], 0}

		min = simd.min(min, vec)
		max = simd.max(max, vec)
	}

	corner = simd.to_array(min).xyz
	size = simd.to_array(max - min).xyz
	return
}

// odinfmt: disable
obj_load_obj_memory :: proc(m: ^Obj, data: []byte) -> (ok: bool) {

    // Always append some default values
    obj_append(m, Vertex{})
    obj_append(m, Normal{})
    obj_append(m, TexCoord{})

    current_material: string

	line_iter := string(data)
	for line in strings.split_lines_iterator(&line_iter) {
		if len(line) < 2 { continue }

        prefix := (u16(line[0])<<8) | u16(line[1])

        noprefix := line[strings.index_byte(line, ' ') + 1:]

        VERTEX   :: ('v' << 8) | ' '
        NORMAL   :: ('v' << 8) | 'n'
        TEXCOORD :: ('v' << 8) | 't'
        FACE     :: ('f' << 8) | ' '
        MESH     :: ('g' << 8) | ' '
        NEW_MAT  :: ('u' << 8) | 's'

		switch prefix {
		case VERTEX:   obj_append(m, parse_vertex_pos(noprefix) or_return)
		case NORMAL:   obj_append(m, parse_vertex_normal(noprefix) or_return)
		case TEXCOORD: obj_append(m, parse_vertex_texcoord(noprefix) or_return)
		case FACE:     obj_append(m, parse_face(noprefix) or_return)
		case MESH:     obj_append(m, noprefix, current_material)
		case NEW_MAT:  current_material = noprefix
		case:          continue
		}
	}

	ok = true
	return
}
// odinfmt: enable

obj_get_all_points :: proc(m: Obj) -> []UnsignedPoint {
	len := len(m.faces) / len(Face)
	return ([^]UnsignedPoint)(raw_data(m.faces[:]))[:len]
}

obj_append :: proc {
	obj_append_vertex,
	obj_append_parsed_face,
	obj_append_normal,
	obj_append_texcoord,
	obj_append_mesh,
}

obj_append_mesh :: proc(m: ^Obj, mesh_name: string, material_name: string) {
	assert(len(m.strings) + len(mesh_name) < bits.U32_MAX)

	append(
		&m.meshes,
		Mesh {
			name = {u32(len(m.strings[:])), u32(len(mesh_name))},
			material = {u32(len(m.strings[:]) + len(mesh_name)), u32(len(material_name))},
			faces_start = u32(len(m.faces[:])),
			faces_count = 0,
		},
	)

	// Must be after the above append call and order matters
	append(&m.strings, mesh_name)
	append(&m.strings, material_name)
}

obj_append_parsed_face :: proc(m: ^Obj, parsed_face: ParsedFace) {
	assert(m != nil)

	if len(m.meshes) > 0 {
		m.meshes[len(m.meshes) - 1].faces_count += parsed_face.points_len - 2
	}

	//
	// Triangulate the parsed face
	//
	for i: u32 = 2; i < parsed_face.points_len; i += 1 {
		append(
			&m.faces,
			Face {
				parsed_face.points.unsigned[0],
				parsed_face.points.unsigned[i - 1],
				parsed_face.points.unsigned[i],
			},
		)
	}
}

obj_append_vertex :: proc(m: ^Obj, v: Vertex) {append(&m.vertices, v[0], v[1], v[2])}
obj_append_normal :: proc(m: ^Obj, n: Normal) {append(&m.normals, n[0], n[1], n[2])}
obj_append_texcoord :: proc(m: ^Obj, t: TexCoord) {append(&m.texcoords, t[0], t[1])}

parse_vertex_pos :: #force_inline proc(line: string) -> (v: Vertex, ok: bool) {
	return parse_vector(Vertex, line)
}

parse_vertex_normal :: #force_inline proc(line: string) -> (v: Normal, ok: bool) {
	return parse_vector(Normal, line)
}

parse_vertex_texcoord :: #force_inline proc(line: string) -> (v: TexCoord, ok: bool) {
	return parse_vector(TexCoord, line)
}

@(private = "file")
parse_vector :: proc($T: typeid, line: string) -> (vertex: T, ok: bool) {
	assert(len(line) >= 5)

	i := 0
	s := line

	for part in strings.split_by_byte_iterator(&s, ' ') {
		defer i += 1
		if i == len(T) do break
		vertex[i], ok = strconv.parse_f32(part)
		if !ok {
			when ODIN_DEBUG {
				fmt.eprintfln("Failed to parse line \"{}\" {}", line, vertex)
			}
			return
		}
	}

	when ENABLE_DEBUG_PRINTING {
		fmt.eprintfln("\"{}\" -> {}", line, vertex)
	}

	ok = true
	return
}

parse_face :: proc(line: string) -> (face: ParsedFace, ok: bool) {
	assert(len(line) > 4)

	s := transmute([]byte)(line)
	sign: i32 = 1

	idx: PointIndex
	for b in s {
		switch b {
		case '-':
			sign = -1
		case '0' ..= '9':
			face.points.signed[face.points_len][idx] =
				(face.points.signed[face.points_len][idx] * 10) + sign * i32(b - '0')
		case '/':
			idx += PointIndex(1)
			sign = 1
		case ' ':
			idx = PointIndex(0)
			sign = 1
			face.points_len += 1
		case:
			unreachable()
		}
	}

	face.points_len += 1

	when ENABLE_DEBUG_PRINTING {
		indices := (([^]i32)(&face.points.signed[0]))[:face.points_len * 3]
		fmt.eprintfln("\"{}\"->{}", line, indices)
	}

	ok = true
	return

}

BobCreateContext :: struct {
	// specify this field to make sure that all slices are aligned to this value
	align: int,
	size:  int,
	data:  [dynamic; 32][]byte,
}

bobctx_add :: proc(ctx: ^BobCreateContext, data: []$T) -> (slc: Slice(T)) {

	slc.start = u32(ctx.size)
	slc.size = u32(slice.size(data))

	ctx.size += slice.size(data)
	append(&ctx.data, slice.to_bytes(data))

	//
	// Make sure that the slice is aligned
	//
	if ctx.align == 0 do ctx.align = DEFAULT_SLICE_ALIGNMENT

	padding := ctx.size % ctx.align; if padding > 0 {
		ctx.size += padding
		append(&ctx.data, PADDING_BYTES[:padding])
	}

	assert(ctx.size < bits.U32_MAX)

	return
}

bobctx_make :: proc(header: ^BobHeader, obj: ^Obj, mtl: ^Mtl) -> (ctx: BobCreateContext) {
	ctx.align = align_of(u32)

	_ = bobctx_add(&ctx, mem.ptr_to_bytes(header))


	//
	// Materials
	//
	header.mtl_strings = bobctx_add(&ctx, mtl.strings[:])

	// offset the strings so it points to the data in our bob
	for &material in mtl.materials[:] {
		for &mat in material.strings {
			mat.start += header.mtl_strings.start
		}
	}
	header.mtllist = bobctx_add(&ctx, mtl.materials[:])

	//
	// Meshes
	//
	header.mesh_strings = bobctx_add(&ctx, obj.strings[:])

	// offset the strings so it points to the data in our bob
	for &mesh in obj.meshes[:] {
		mesh.material.start += header.mesh_strings.start
		mesh.name.start += header.mesh_strings.start
	}
	header.meshes = bobctx_add(&ctx, obj.meshes[:])

	//
	// Model data
	//
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
bob_create_file :: proc(obj: ^Obj, mtl: ^Mtl, output_path: string) -> (err: os.Error) {
	corner, dim := obj_get_bounding_box(obj^)

	header := BobHeader {
		corner = corner,
		dim    = dim,
	}

	ctx := bobctx_make(&header, obj, mtl)

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

