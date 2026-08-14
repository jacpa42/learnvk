package learnvk

import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

MAX_POINTS_PER_FACE :: 8
ENABLE_DEBUG_PRINTING :: false

#assert(size_of(UnsignedPoint) == size_of(ModelShaderVertex))

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

Model :: struct {
	// Raw data
	vertices:       [dynamic]f32, // 3 bytes per vertex
	normals:        [dynamic]f32, // 3 bytes per vertex
	texcoords:      [dynamic]f32, // 2 bytes per vertex

	// The triangles
	faces:          [dynamic]Face,

	// Mesh
	mesh_name_data: [dynamic]byte,
	meshes:         [dynamic]Mesh,
}

Mesh :: struct {
	name_start, name_end: u16,
	face_start, face_end: u32,
}

@(private = "file")
ParsedFace :: struct {
	points_len: u32,
	points:     struct #raw_union {
		unsigned: [MAX_POINTS_PER_FACE]UnsignedPoint,
		signed:   [MAX_POINTS_PER_FACE]SignedPoint,
	},
}

model_init :: proc(m: ^Model) {
	assert(m != nil)
	make_or_clear(&m.vertices)
	make_or_clear(&m.normals)
	make_or_clear(&m.texcoords)
	make_or_clear(&m.mesh_name_data)
	make_or_clear(&m.faces)
	make_or_clear(&m.meshes)
}

model_destroy :: proc(m: ^Model) {
	defer m^ = {}
	delete(m.meshes)
	delete(m.vertices)
	delete(m.normals)
	delete(m.texcoords)
	delete(m.faces)
	delete(m.mesh_name_data)
}

model_load :: model_load_obj_path

model_load_obj_path :: proc(m: ^Model, path: string, ok: ^bool = nil) {
	when true {
		timer: time.Stopwatch
		time.stopwatch_start(&timer)
		defer {
			time.stopwatch_stop(&timer)
			fmt.eprintfln(
				"Loaded obj from file \"{}\" in {}",
				filepath.base(path),
				time.stopwatch_duration(timer),
			)
		}
	}

	assert(path != {})

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", path, f32(len(raw)) / (1024 * 1024))

	model_load_obj_memory_ok := model_load_obj_memory(m, raw)

	if ok != nil do ok^ = model_load_obj_memory_ok

	return
}

// TODO: simd this bitch should go
model_normalize_indicies :: proc(m: ^Model) {
	for &face in m.faces {
		for &point in face {
			for &index, tag in point {

				count: u32
				switch tag {
				case .vertex:
					count = u32(len(m.vertices))
				case .texcoord:
					count = u32(len(m.texcoords))
				case .normal:
					count = u32(len(m.normals))
				}

				if transmute(i32)(transmute(f32)(index)) < 0 {
					index += count
				}
			}
		}
	}
}

// odinfmt: disable
model_load_obj_memory :: proc(m: ^Model, data: []byte) -> (ok: bool) {
    // Always append some default values
    model_append(m, Vertex{})
    model_append(m, Normal{})
    model_append(m, TexCoord{})

	line_iter := string(data)
	for line in strings.split_lines_iterator(&line_iter) {
		if len(line) < 2 { continue }

        prefix := (u16(line[0])<<8) | u16(line[1])

        VERTEX   :: ('v' << 8) | ' '
        NORMAL   :: ('v' << 8) | 'n'
        TEXCOORD :: ('v' << 8) | 't'
        FACE     :: ('f' << 8) | ' '
        MESH     :: ('g' << 8) | ' '

		switch prefix {
		case VERTEX:   model_append(m, parse_vertex_pos(line) or_return)
		case NORMAL:   model_append(m, parse_vertex_normal(line) or_return)
		case TEXCOORD: model_append(m, parse_vertex_texcoord(line) or_return)
		case FACE:     model_append(m, parse_face(line) or_return)
		case MESH:     model_append(m, line[2:])
		case:          continue
		}
	}

    model_normalize_indicies(m)

	ok = true
	return
}
// odinfmt: enable

model_get_num_points :: proc(m: Model) -> u32 {
	return u32(slice.size(m.faces[:]) / size_of(UnsignedPoint))
}

model_get_all_points :: proc(m: Model) -> []UnsignedPoint {
	len := len(m.faces) / len(Face)
	return ([^]UnsignedPoint)(raw_data(m.faces[:]))[:len]
}

model_get_mesh_name :: proc(m: Model, mesh_index: int) -> string {
	mesh := m.meshes[mesh_index]
	return string(m.mesh_name_data[mesh.name_start:mesh.name_end])
}

model_get_mesh_faces :: proc(m: Model, mesh_index: int) -> []Face {
	mesh := m.meshes[mesh_index]
	return m.faces[mesh.face_start:mesh.face_end]
}

model_append :: proc {
	model_append_vertex,
	model_append_parsed_face,
	model_append_normal,
	model_append_texcoord,
	model_append_mesh,
}

model_append_mesh :: proc(m: ^Model, mesh_name: string) {
	assert(len(m.mesh_name_data) + len(mesh_name) < bits.U16_MAX)

	append(
		&m.meshes,
		Mesh {
			name_start = u16(len(m.mesh_name_data)),
			name_end = u16(len(m.mesh_name_data) + len(mesh_name)),
			face_start = u32(len(m.faces)),
			face_end = u32(len(m.faces)),
		},
	)

	// Must be after the above append call
	append(&m.mesh_name_data, mesh_name)
}

model_append_parsed_face :: proc(m: ^Model, parsed_face: ParsedFace) {
	assert(m != nil)

	if len(m.meshes) > 0 {
		m.meshes[len(m.meshes) - 1].face_end += parsed_face.points_len - 2
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

model_append_vertex :: proc(m: ^Model, v: Vertex) {append(&m.vertices, v[0], v[1], v[2])}
model_append_normal :: proc(m: ^Model, n: Normal) {append(&m.normals, n[0], n[1], n[2])}
model_append_texcoord :: proc(m: ^Model, t: TexCoord) {append(&m.texcoords, t[0], t[1])}

parse_vertex_pos :: #force_inline proc(line: string) -> (v: Vertex, ok: bool) {
	assert(strings.starts_with(line, "v  "))
	return parse_vector(Vertex, line)
}

parse_vertex_normal :: #force_inline proc(line: string) -> (v: Normal, ok: bool) {
	assert(strings.starts_with(line, "vn "))
	return parse_vector(Normal, line)
}

parse_vertex_texcoord :: #force_inline proc(line: string) -> (v: TexCoord, ok: bool) {
	assert(strings.starts_with(line, "vt "))
	return parse_vector(TexCoord, line)
}

@(private = "file")
parse_vector :: proc($T: typeid, line: string) -> (vertex: T, ok: bool) {
	assert(len(line) > 3)

	i := 0
	s := line[3:]

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

	s := transmute([]byte)(line[2:])
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
		fmt.eprintfln("took in \"{}\"->{}", line, indices)
	}

	ok = true
	return
}
