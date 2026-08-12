package learnvk

import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

MAX_TRIANGLES_PER_FACE :: 4
NIL_INDEX: index : bits.I32_MIN
NUM_MODELS :: len([ModelTag]byte)

MODEL_PATH := [ModelTag]string {
	.test   = "assets/test.obj",
	.bmw    = "assets/bmw/bmw.obj",
	.bunny  = "assets/bunny/bunny.obj",
	.dragon = "assets/dragon/dragon.obj",
	.sponza = "assets/sponza/sponza.obj",
}

vertex :: distinct [3]f32
normal :: distinct [3]f32
texcoord :: distinct [3]f32
triangle :: distinct [3]index

index :: distinct i32

ModelTag :: enum {
	test,
	bunny,
	bmw,
	dragon,
	sponza,
}

Model :: struct {
	tag:            ModelTag,

	// Raw data
	vertexes:       [dynamic]vertex,
	normals:        [dynamic]normal,
	texcoords:      [dynamic]texcoord,

	// Mesh
	mesh_name_data: [dynamic]byte,
	mesh_triangles: [dynamic]triangle,
	mesh_faces:     [dynamic]Face,
	meshes:         [dynamic]Mesh,
}

Mesh :: struct {
	name_start, name_end: u16,
	face_start, face_end: u32,
	trgl_start, trgl_end: u32,
}

Face :: struct {
	triangle_start, triangle_end: u32,
}

@(private = "file")
ParsedFace :: struct {
	triangle_len: u32,
	triangle:     [MAX_TRIANGLES_PER_FACE]triangle,
}

model_init :: proc(m: ^Model) {
	assert(m != nil)
	make_or_clear(&m.vertexes)
	make_or_clear(&m.normals)
	make_or_clear(&m.texcoords)
	make_or_clear(&m.mesh_name_data)
	make_or_clear(&m.mesh_triangles)
	make_or_clear(&m.mesh_faces)
	make_or_clear(&m.meshes)
}

model_destroy :: proc(m: ^Model) {
	defer m^ = {}
	delete(m.meshes)
	delete(m.vertexes)
	delete(m.normals)
	delete(m.texcoords)
	delete(m.mesh_triangles)
	delete(m.mesh_faces)
	delete(m.mesh_name_data)
}

model_load_all :: proc(models: []Model, ok: ^bool = nil) {
	threads := make([]^thread.Thread, len(models), context.temp_allocator)
	thread_ok := make([]bool, len(models), context.temp_allocator)

	for &model, i in models {
		model_init(&model)

		threads[i] = thread.create_and_start_with_poly_data3(
			arg1 = &model,
			arg2 = MODEL_PATH[model.tag],
			arg3 = &thread_ok[i],
			fn = model_load,
			init_context = context,
		)
	}

	for t in threads {
		thread.destroy(t)
	}

	if ok != nil {
		ok_internal := true

		for thread_result in thread_ok {
			ok_internal &= thread_result
		}

		ok^ = ok_internal
	}
}

model_load :: model_load_obj_path

// Leave string as nil to infer path from `MODEL_PATH` variable
model_load_obj_path :: proc(m: ^Model, path: string = {}, ok: ^bool = nil) {
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

	ok_internal: bool
	defer if ok != nil {ok^ = ok_internal}

	actual_path := path
	if raw_data(actual_path) == nil || len(actual_path) == 0 {
		actual_path = MODEL_PATH[m.tag]
	}

	raw, oserr := os.read_entire_file(actual_path, context.temp_allocator)
	if oserr != nil {ok_internal = false; return}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", actual_path, f32(len(raw)) / (1024 * 1024))

	ok_internal = model_load_obj_memory(m, raw)
	return
}

// odinfmt: disable
model_load_obj_memory :: proc(m: ^Model, data: []byte) -> (ok: bool) {
	line_iter := string(data)
	for line in strings.split_lines_iterator(&line_iter) {
		if len(line) < 2 { continue }

        prefix := ((^u16)(raw_data(line)))^
        prefix = (u16(line[0])<<8) | u16(line[1])

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

	ok = true
	return
}
// odinfmt: enable

model_get_mesh_name :: proc(m: Model, mesh_index: int) -> string {
	mesh := m.meshes[mesh_index]
	return string(m.mesh_name_data[mesh.name_start:mesh.name_end])
}

model_get_mesh_triangles :: proc(m: Model, mesh_index: int) -> []triangle {
	mesh := m.meshes[mesh_index]
	return m.mesh_triangles[mesh.trgl_start:mesh.trgl_end]
}

model_get_mesh_faces :: proc(m: Model, mesh_index: int) -> []Face {
	mesh := m.meshes[mesh_index]
	return m.mesh_faces[mesh.face_start:mesh.face_end]
}

model_append :: proc {
	model_append_vertex,
	model_append_face,
	model_append_normal,
	model_append_texcoord,
	model_append_new_mesh,
}

model_append_new_mesh :: proc(m: ^Model, mesh_name: string) {
	assert(len(mesh_name) != 0)
	assert(len(m.mesh_faces) < bits.U32_MAX)
	assert(len(m.mesh_name_data) + len(mesh_name) < bits.U16_MAX)

	append(
		&m.meshes,
		Mesh {
			name_start = u16(len(m.mesh_name_data)),
			name_end = u16(len(m.mesh_name_data) + len(mesh_name)),
			face_start = u32(len(m.mesh_faces)),
			face_end = u32(len(m.mesh_faces)),
		},
	)

	// Must be after the above append call
	append(&m.mesh_name_data, mesh_name)
}

model_append_face :: proc(m: ^Model, face: ParsedFace) {
	assert(m != nil)
	assert(len(m.meshes) != 0)

	f := Face {
		triangle_start = u32(len(m.mesh_triangles)),
		triangle_end   = u32(len(m.mesh_triangles)) + face.triangle_len,
	}

	m.meshes[len(m.meshes) - 1].face_end += 1
	for i in 0 ..< face.triangle_len {append_elems(&m.mesh_triangles, face.triangle[i])}
	append(&m.mesh_faces, f)
}

model_append_vertex :: proc(m: ^Model, v: vertex) {append(&m.vertexes, v)}
model_append_normal :: proc(m: ^Model, n: normal) {append(&m.normals, n)}
model_append_texcoord :: proc(m: ^Model, t: texcoord) {append(&m.texcoords, t)}

parse_vertex_pos :: #force_inline proc(line: string) -> (v: vertex, ok: bool) {
	return parse_vector(vertex, line)
}

parse_vertex_normal :: #force_inline proc(line: string) -> (v: normal, ok: bool) {
	return parse_vector(normal, line)
}

parse_vertex_texcoord :: #force_inline proc(line: string) -> (v: texcoord, ok: bool) {
	return parse_vector(texcoord, line)
}

@(private = "file")
parse_vector :: proc($T: typeid, line: string) -> (vertex: T, ok: bool) {
	#assert(size_of(T) == size_of([3]f32))

	assert(len(line) > 3)

	i := 0
	s := line[3:]

	for part in strings.split_by_byte_iterator(&s, ' ') {
		defer i += 1
		vertex[i] = strconv.parse_f32(part) or_return
	}

	assert(i == len(vertex))

	ok = true
	return
}

parse_face :: proc(line: string) -> (face: ParsedFace, ok: bool) {
	assert(len(line) > 4)

	s := transmute([]byte)(line[2:])
	sign: index = 1

	idx: int
	for b in s {
		switch b {
		case '-':
			sign = -1
		case '0' ..= '9':
			face.triangle[face.triangle_len][idx] =
				(face.triangle[face.triangle_len][idx] * 10) + sign * index(b - '0')
		case '/':
			idx += 1
			sign = 1
		case ' ':
			idx = 0
			sign = 1
			face.triangle_len += 1
		case:
			unreachable()
		}
	}

	ok = true
	return
}
