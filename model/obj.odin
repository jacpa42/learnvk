package model

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:simd"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// odinfmt: disable
obj_dump_info :: proc(obj: ^Obj) {
	info :: fmt.eprintf

	info("{} vertices : len={} size={}\n", rawptr(obj), len(obj.vertices), slice.size(obj.vertices[:]))
	info("{} indices  : len={} size={}\n", rawptr(obj), len(obj.indices), slice.size(obj.indices[:]))
	info("{} strings  : {}\n", rawptr(obj), string(obj.strings[:]))

	for mesh, i in obj.meshes {
		name := get_slice_string(mesh.name, obj.strings[:])
		material := get_slice_string(mesh.material, obj.strings[:])
		info(
			"{} mesh {} : name={} material={} num_indices={}\n",
			rawptr(obj),
			i,
			name,
			material,
			mesh.index_count,
		)
	}

	for m, i in obj.materials {
		info("{} material {} : ", rawptr(obj), i)
		for slc, tag in m.strings {
			value := get_slice_string(slc, obj.strings[:])
			if len(value) > 0 {
				info("{}={} ", tag, get_slice_string(slc, obj.strings[:]))
			}
		}
		info("\n")
	}
}
// odinfmt: enable

obj_init_or_clear :: proc(m: ^Obj) {
	assert(m != nil)

	make_or_clear(&m.strings)
	make_or_clear(&m.meshes)
	make_or_clear(&m.materials)
	make_or_clear(&m.vertices)
	make_or_clear(&m.indices)
}

obj_destroy :: proc(m: ^Obj) {
	assert(m != nil)

	defer m^ = {}
	delete(m.strings)
	delete(m.meshes)
	delete(m.materials)
	delete(m.vertices)
	delete(m.indices)
}

obj_load :: proc(obj: ^Obj, path: string, flipx, flipy: bool) -> (result: Result) {
	assert(path != {})

	timer: time.Stopwatch
	time.stopwatch_start(&timer)

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		log.errorf("Failed to load obj file \"{}\": {}", path, oserr)
		return .Obj_Load_Error
	}

	result = obj_load_memory(obj, path, raw, flipx = flipx, flipy = flipy)
	if result != .Ok do return result

	if result == .Ok {
		time.stopwatch_stop(&timer)
		fmt.eprintfln(
			"Loaded \"{}\" ({} Mib) in {}",
			path,
			f32(len(raw)) / (1024 * 1024),
			time.stopwatch_duration(timer),
		)
	}

	when ENABLE_DEBUG_PRINTING do obj_dump_info(obj)

	result = .Ok
	return
}

//
// Constructs a (deduplicated) array of vertices and indices
//
obj_make_vertices :: proc(
	vertices: ^[dynamic]Vertex,
	indices: ^[dynamic]u32,
	faces: []Face,
	positions, normals, texcoords: []f32,
	flipy, flipx: bool,
) {

	max_num_unique_points := len(faces) * 3

	seen := make(map[Vertex]int, max_num_unique_points)
	defer delete(seen)

	clear(vertices)
	non_zero_reserve(vertices, max_num_unique_points)

	clear(indices)
	non_zero_reserve(indices, max_num_unique_points)

	for face in faces do for point in face {

		new_point := Vertex {

			// vertex
			positions[point[.vertex] * 3 + 0],
			positions[point[.vertex] * 3 + 1],
			positions[point[.vertex] * 3 + 2],

			// normal
			normals[point[.normal] * 3 + 0],
			normals[point[.normal] * 3 + 1],
			normals[point[.normal] * 3 + 2],

			// texcoord
			texcoords[point[.texcoord] * 2 + 0],
			texcoords[point[.texcoord] * 2 + 1],
		}

		if flipx do new_point[6] = 1 - new_point[6]
		if flipy do new_point[7] = 1 - new_point[7]

		//
		// normalize the normal
		//
		length := linalg.length([3]f32{new_point[3], new_point[4], new_point[5]})
		new_point[3] /= length
		new_point[4] /= length
		new_point[5] /= length

		new_point_index, found := seen[new_point]
		if !found {
			new_point_index = len(vertices)
			seen[new_point] = new_point_index
			append(vertices, new_point)
		}

		append(indices, u32(new_point_index))
	}

	return
}

obj_cache_mesh_indices :: proc(
	meshes: []Mesh,
	strings: ^[dynamic]byte,
	mttlist: ^[dynamic]Material,
) {
	fallback: ^Material

	if len(mttlist) == 0 {
		log.warnf("Appending a default (stub) material as this thing has no textures")
		fallback = mtl_new_material({strings, mttlist})
		fallback.strings[.name] = mtl_new_string({strings, mttlist}, "stub")

		fallback.Ns = 250
		fallback.Ka = 1
		fallback.Kd = 0.8
		fallback.Ks = 0.5
		fallback.Ni = 1.5
		fallback.d = 1
		fallback.illum = .Highlight_on
	} else {
		fallback = &mttlist[0]
	}

	assert(fallback != nil)

	outer: for &mesh in meshes {
		mesh_material_name := get_slice_string(mesh.material, strings[:])

		for material, material_index in mttlist[:] {

			material_name := get_slice_string(material.strings[.name], strings[:])

			if mesh_material_name == material_name {
				mesh.materal_index = u32(material_index)
				continue outer
			}
		}

		//
		// If we didn't find one, we put just use stub
		//
		if len(mesh_material_name) == 0 {
			mesh.material = fallback.strings[.name]
			mesh.materal_index = 0
		}
	}
}

obj_get_bounding_box :: proc(positions: []f32) -> (corner, dim: [3]f32) {
	assert(len(positions) % FLOATS_PER_POSITION == 0)

	i: int
	min, max: #simd[4]f32

	for i < len(positions) {
		defer i += 3

		vec := #simd[4]f32{positions[i + 0], positions[i + 1], positions[i + 2], 0}

		min = simd.min(min, vec)
		max = simd.max(max, vec)
	}

	corner = simd.to_array(min).xyz
	dim = simd.to_array(max - min).xyz
	return
}

// odinfmt: disable
obj_load_memory :: proc(
	m: ^Obj,
	obj_path: string,
	data: []byte,
    flipx, flipy: bool,
) -> (
	result: Result,
) {
	temp_positions := make([dynamic]f32, len = FLOATS_PER_POSITION)
	temp_normals   := make([dynamic]f32, len = FLOATS_PER_NORMAL)
	temp_texcoords := make([dynamic]f32, len = FLOATS_PER_TEXCOORD)
	temp_faces     := make([dynamic]Face)

	defer delete(temp_positions)
	defer delete(temp_normals)
	defer delete(temp_texcoords)
	defer delete(temp_faces)

	meshes := &m.meshes
	string_data := &m.strings
	materials := &m.materials
	vertices := &m.vertices
	indices := &m.indices

	current_material: string

	line_iter := string(data)
	for line in strings.split_lines_iterator(&line_iter) {
		if len(line) < 2 || line[0] == '#' {
			continue
		}

		prefix := (u16(line[0]) << 8) | u16(line[1])

		noprefix := line[strings.index_byte(line, ' ') + 1:]
		noprefix = strings.trim(noprefix, " ")

		when ENABLE_DEBUG_PRINTING {
			fmt.eprintfln("with pref :: \"{}\"", line)
			fmt.eprintfln("no prefix :: \"{}\"", noprefix)
		}


		POSITION :: ('v' << 8) | ' '
		NORMAL   :: ('v' << 8) | 'n'
		TEXCOORD :: ('v' << 8) | 't'
		FACE     :: ('f' << 8) | ' '
		OBJECT   :: ('o' << 8) | ' '
		GROUP    :: ('g' << 8) | ' '
		MTLLIB   :: ('m' << 8) | 't'
		NEW_MAT  :: ('u' << 8) | 's'

		switch prefix {

		case POSITION: append(&temp_positions, parse_v3(noprefix) or_return)
		case NORMAL: append(&temp_normals, parse_v3(noprefix) or_return)
		case TEXCOORD: append(&temp_texcoords, parse_v2(noprefix) or_return)
		case FACE: obj_append_face(meshes, &temp_faces, parse_face(noprefix) or_return)

		case OBJECT: obj_append_mesh(string_data, meshes, &temp_faces, noprefix, current_material)
		case GROUP: obj_append_mesh(string_data, meshes, &temp_faces, noprefix, current_material)

		case MTLLIB: obj_load_mtl(string_data, materials, &m.mtl_path, obj_path, noprefix) or_return
		case NEW_MAT: current_material = noprefix

		case: continue
		}
	}

	m.header.corner, m.header.dim = obj_get_bounding_box(temp_positions[:])

	obj_make_vertices(
		vertices  = vertices,
		indices   = indices,
		faces     = temp_faces[:],
		positions = temp_positions[:],
		normals   = temp_normals[:],
		texcoords = temp_texcoords[:],
        flipx     = flipx,
        flipy     = flipy,
	)

	obj_cache_mesh_indices(m.meshes[:], &m.strings, &m.materials)

	result = .Ok
	return
}
// odinfmt: enable


obj_load_mtl :: proc(
	strings: ^[dynamic]byte,
	materials: ^[dynamic]Material,
	mtl_path_slice: ^Slice(byte),
	obj_path, mtl_rel_path: string,
) -> (
	result: Result,
) {
	mtl_path, err := filepath.join(
		[]string{filepath.dir(obj_path), mtl_rel_path},
		context.temp_allocator,
	)
	assert(err == nil)
	assert(mtl_path_slice^ == {}) // must be first time we are calling this function

	mtl_path_slice.start = u32(len(strings))
	mtl_path_slice.size = u32(len(mtl_path))
	append(strings, mtl_path)

	result = mtl_load({strings, materials}, mtl_path)
	return
}

obj_append_mesh :: proc(
	strings: ^[dynamic]byte,
	meshes: ^[dynamic]Mesh,
	faces: ^[dynamic]Face,
	mesh_name: string,
	material_name: string,
) {
	append(
		meshes,
		Mesh {
			name = {u32(len(strings[:])), u32(len(mesh_name))},
			material = {u32(len(strings[:]) + len(mesh_name)), u32(len(material_name))},
			index_start = u32(VERTICES_PER_FACE * len(faces[:])),
			index_count = 0,
		},
	)

	// Must be after the above append call and order matters
	append(strings, mesh_name)
	append(strings, material_name)

}

obj_append_face :: proc(meshes: ^[dynamic]Mesh, faces: ^[dynamic]Face, parsed_face: ParsedFace) {
	if len(meshes) > 0 {
		num_faces := parsed_face.points_len - 2
		meshes[len(meshes) - 1].index_count += VERTICES_PER_FACE * num_faces
	}

	//
	// Triangulate the parsed face
	//
	for i: u32 = 2; i < parsed_face.points_len; i += 1 {
		append(
			faces,
			Face {
				parsed_face.points.unsigned[0],
				parsed_face.points.unsigned[i - 1],
				parsed_face.points.unsigned[i],
			},
		)
	}
}

@(private)
parse_v3 :: proc(noprefix: string) -> (x, y, z: f32, result: Result) {
	assert(len(noprefix) >= 5)

	space0 := strings.index_byte(noprefix, ' ')
	space1 := space0 + 1 + strings.index_byte(noprefix[space0 + 1:], ' ')

	if space0 < 0 || space1 < 0 {
		result = .Missing_Separator
		return
	}


	ok: bool

	x, ok = strconv.parse_f32(noprefix[:space0])
	if !ok {result = .Float3_Invalid_Char; return}

	y, ok = strconv.parse_f32(noprefix[space0 + 1:space1])
	if !ok {result = .Float3_Invalid_Char; return}

	z, ok = strconv.parse_f32(noprefix[space1 + 1:])
	if !ok {result = .Float3_Invalid_Char; return}

	when ENABLE_DEBUG_PRINTING {
		fmt.eprintfln("\"{}\" -> {}", noprefix, [3]f32{x, y, z})
	}

	ok = true
	return
}

@(private)
parse_v2 :: proc(noprefix: string) -> (x, y: f32, result: Result) {
	assert(len(noprefix) >= 3)

	space0 := strings.index_byte(noprefix, ' ')

	if space0 < 0 {
		result = .Missing_Separator
		return
	}


	ok: bool

	x, ok = strconv.parse_f32(noprefix[:space0])
	if !ok {result = .Float2_Invalid_Char; return}

	y, ok = strconv.parse_f32(noprefix[space0 + 1:])
	if !ok {result = .Float2_Invalid_Char; return}

	when ENABLE_DEBUG_PRINTING {
		fmt.eprintfln("\"{}\" -> {}", noprefix, [2]f32{x, y})
	}

	ok = true
	return
}

parse_face :: proc(line: string) -> (face: ParsedFace, result: Result) {
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
			result = .Face_Invalid_Char
			return
		}
	}

	face.points_len += 1

	when ENABLE_DEBUG_PRINTING {
		indices := (([^]i32)(&face.points.signed[0]))[:face.points_len * VERTICES_PER_FACE]
		fmt.eprintfln("\"{}\"->{}", line, indices)
	}

	result = .Ok
	return
}

