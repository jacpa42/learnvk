package model

import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:path/filepath"
import "core:simd"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

starts_with := strings.starts_with

// odinfmt: disable
obj_dump_info :: proc(obj: ^Obj) {
	info :: fmt.eprintf

	info("{} points  : len={} size={}\n", rawptr(obj), len(obj.points), slice.size(obj.points[:]))
	info("{} indices : len={} size={}\n", rawptr(obj), len(obj.indices), slice.size(obj.indices[:]))
	info("{} strings   : {}\n", rawptr(obj), string(obj.strings[:]))

	for mesh, i in obj.meshes {
		name := get_slice_string(mesh.name, obj.strings[:])
		material := get_slice_string(mesh.material, obj.strings[:])
		num_faces := mesh.faces_count
		info(
			"{} mesh {} : name={} material={} num_faces={}\n",
			rawptr(obj),
			i,
			name,
			material,
			num_faces,
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
	make_or_clear(&m.points)
	make_or_clear(&m.indices)
}

obj_destroy :: proc(m: ^Obj) {
	assert(m != nil)

	defer m^ = {}
	delete(m.strings)
	delete(m.meshes)
	delete(m.materials)
	delete(m.points)
	delete(m.indices)
}

obj_load :: proc(obj: ^Obj, path: string, ok: ^bool = nil) {
	assert(path != {})

	timer: time.Stopwatch
	time.stopwatch_start(&timer)

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	obj_load_obj_memory_ok := obj_load_memory(obj, path, raw)
	if !obj_load_obj_memory_ok {
		if ok != nil do ok^ = false
		return
	}

	time.stopwatch_stop(&timer)
	fmt.eprintfln(
		"Loaded \"{}\" ({} Mib) in {}",
		path,
		f32(len(raw)) / (1024 * 1024),
		time.stopwatch_duration(timer),
	)

	if ok != nil do ok^ = true

	when ODIN_DEBUG do obj_dump_info(obj)

	return
}

//
// Constructs a (deduplicated) array of points and indicies
//
obj_points_make :: proc(
	points: ^[dynamic]Point,
	indices: ^[dynamic]u32,
	faces: []Face,
	vertices, normals, texcoords: []f32,
	deduplicate_vertex_data := true,
) {
	point_compare :: proc "contextless" (p0, p1: Point, eps: f32 = 1e-1) -> bool {
		diff := simd.abs(simd.sub(simd.from_array(p0), simd.from_array(p1)))
		return simd.reduce_add_bisect(diff) < eps
	}

	find :: proc(point: Point, points: []Point) -> int {
		for seen, index in points {
			if point_compare(seen, point) do return index
		}
		return -1
	}


	max_num_unique_points := len(faces) * 3

	clear(points)
	non_zero_reserve(points, max_num_unique_points)

	clear(indices)
	non_zero_reserve(indices, max_num_unique_points)

	for face in faces do for point in face {
		new_point := Point {

			// vertex
			vertices[point[.vertex] * 3 + 0],
			vertices[point[.vertex] * 3 + 1],
			vertices[point[.vertex] * 3 + 2],

			// normal
			normals[point[.normal] * 3 + 0],
			normals[point[.normal] * 3 + 1],
			normals[point[.normal] * 3 + 2],

			// texcoord
			texcoords[point[.texcoord] * 2 + 0],
			texcoords[point[.texcoord] * 2 + 1],
		}

		new_point_index: int

		if deduplicate_vertex_data {
			new_point_index = find(new_point, points[:])
			if new_point_index == -1 {
				new_point_index = len(points)
				append(points, new_point)
			}
		} else {
			new_point_index := len(points)
			append(points, new_point)
		}

		append(indices, u32(new_point_index))
	}

	return
}

obj_get_bounding_box :: proc(m: Obj) -> (corner, dim: [3]f32) {
	i: int
	min, max: #simd[4]f32

	for i < len(m.vertices) {
		defer i += 3

		vec := #simd[4]f32{m.vertices[i + 0], m.vertices[i + 1], m.vertices[i + 2], 0}

		min = simd.min(min, vec)
		max = simd.max(max, vec)
	}

	corner = simd.to_array(min).xyz
	dim = simd.to_array(max - min).xyz
	return
}

// odinfmt: disable
obj_load_memory :: proc(m: ^Obj, obj_path: string, data: []byte) -> (ok: bool) {

    temp_vertices  := make([dynamic]f32, len = FLOATS_PER_VERTEX)
    temp_normals   := make([dynamic]f32, len = FLOATS_PER_NORMAL)
    temp_texcoords := make([dynamic]f32, len = FLOATS_PER_TEXCOORD)
    temp_faces     := make([dynamic]Face)

    defer delete(temp_vertices)
    defer delete(temp_normals)
    defer delete(temp_texcoords)
    defer delete(temp_faces)

    meshes      := &m.meshes
    string_data := &m.strings
    materials   := &m.materials
    points      := &m.points
    indices     := &m.indices

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
        OBJECT   :: ('o' << 8) | ' '
        GROUP    :: ('g' << 8) | ' '
        MTLLIB   :: ('m' << 8) | 't'
        NEW_MAT  :: ('u' << 8) | 's'

		switch prefix {

		case VERTEX:   obj_append_vertex(&temp_vertices,    parse_vertex_pos(noprefix) or_return)
		case NORMAL:   obj_append_normal(&temp_normals,     parse_vertex_normal(noprefix) or_return)
		case TEXCOORD: obj_append_texcoord(&temp_texcoords, parse_vertex_texcoord(noprefix) or_return)
		case FACE:     obj_append_face(meshes, &temp_faces, parse_face(noprefix) or_return)

		case OBJECT:   obj_append_mesh(string_data, meshes, &temp_faces, noprefix, current_material)
		case GROUP:    obj_append_mesh(string_data, meshes, &temp_faces, noprefix, current_material)

		case MTLLIB:   obj_load_mtl(string_data, materials, obj_path, noprefix) or_return
		case NEW_MAT:  current_material = noprefix

		case:          continue
		}
	}

    m.header.corner, m.header.dim = obj_get_bounding_box(m^)

    obj_points_make(
        points  = &m.points,
        indices = &m.indices,

        faces     = temp_faces[:],
        vertices  = temp_vertices[:],
        normals   = temp_normals[:],
        texcoords = temp_texcoords[:],
    )

	ok = true
	return
}
// odinfmt: enable

obj_load_mtl :: proc(
	strings: ^[dynamic]byte,
	materials: ^[dynamic]Material,
	obj_path, mtl_rel_path: string,
) -> (
	ok: bool,
) {
	mtl_path, err := filepath.join(
		[]string{filepath.dir(obj_path), mtl_rel_path},
		context.temp_allocator,
	)
	if err != nil do return false

	mtl_load({strings, materials}, mtl_path, &ok)
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
			faces_start = u32(len(faces[:])),
			faces_count = 0,
		},
	)

	// Must be after the above append call and order matters
	append(strings, mesh_name, material_name)
}

obj_append_face :: proc(meshes: ^[dynamic]Mesh, faces: ^[dynamic]Face, parsed_face: ParsedFace) {
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

obj_append_vertex :: proc(vertices: ^[dynamic]f32, v: Vertex) {append(vertices, v[0], v[1], v[2])}
obj_append_normal :: proc(normals: ^[dynamic]f32, n: Normal) {append(normals, n[0], n[1], n[2])}
obj_append_texcoord :: proc(texcoords: ^[dynamic]f32, t: TexCoord) {append(texcoords, t[0], t[1])}

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

