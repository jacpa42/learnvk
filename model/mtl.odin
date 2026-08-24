package model

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

@(require_results)
mtl_load :: proc(mtl: Mtl, path: string) -> (result: Result) {
	if len(path) == 0 {
		result = .Mtl_Path_Empty
		return
	}

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		log.fatalf("Failed to load mtl file \"{}\": {}", path, oserr)
		return .Mtl_Load_Error
	}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", path, f32(len(raw)) / (1024 * 1024))

	mtl_load_memory(mtl, raw) or_return

	result = .Ok
	return
}

mtl_load_memory :: proc(m: Mtl, data: []byte) -> (result: Result) {

	mat: ^Material

	line_iter := string(data)
	for next_line in strings.split_lines_iterator(&line_iter) {
		if len(next_line) < 2 {continue}
		line := strings.trim(next_line, "\t\n\v\f\r ")

		space := strings.index_byte(line, ' ')
		if space < 0 do return .Mtl_Line_Missing_Separator

		noprefix := line[space + 1:]

		if line[0] == '#' {continue}

		if starts_with(line, "newmtl") {
			mat = mtl_new_material(m)
			mat.strings[.name] = mtl_new_string(m, noprefix)

			//
			// Float values
			//

		} else if starts_with(line, "Ns") {
			mat.Ns = parse_v1(noprefix) or_return

		} else if starts_with(line, "Ni") {
			mat.Ni = parse_v1(noprefix) or_return

		} else if starts_with(line, "d") {
			mat.d = parse_v1(noprefix) or_return

		} else if starts_with(line, "Tr") {
			mat.Tr = parse_v1(noprefix) or_return

			//
			// Floatx3 values
			//

		} else if starts_with(line, "Tf") {
			mat.Tf.x, mat.Tf.y, mat.Tf.z = parse_v3(noprefix) or_return

		} else if starts_with(line, "Ka") {
			mat.Ka.x, mat.Ka.y, mat.Ka.z = parse_v3(noprefix) or_return

		} else if starts_with(line, "Kd") {
			mat.Kd.x, mat.Kd.y, mat.Kd.z = parse_v3(noprefix) or_return

		} else if starts_with(line, "Ks") {
			mat.Ks.x, mat.Ks.y, mat.Ks.z = parse_v3(noprefix) or_return

		} else if starts_with(line, "Ke") {
			mat.Ke.x, mat.Ke.y, mat.Ke.z = parse_v3(noprefix) or_return

			//
			// Special enum
			//

		} else if starts_with(line, "illum") {
			mat.illum = parse_illum(noprefix)

			//
			// path strings
			//

		} else if starts_with(line, "map_Ka") {
			mat.strings[.map_Ka] = mtl_new_string(m, noprefix)

		} else if starts_with(line, "map_Ks") {
			mat.strings[.map_Ks] = mtl_new_string(m, noprefix)

		} else if starts_with(line, "map_Ke") {
			mat.strings[.map_Ke] = mtl_new_string(m, noprefix)

		} else if starts_with(line, "map_Kd") {
			mat.strings[.map_Kd] = mtl_new_string(m, noprefix)

		} else if starts_with(line, "map_d") {
			mat.strings[.map_d] = mtl_new_string(m, noprefix)

		} else if starts_with(line, "map_bump") || starts_with(line, "bump") {
			mat.strings[.map_bump] = mtl_new_string(m, noprefix)
		}

	}

	result = .Ok
	return
}

@(private)
mtl_new_material :: proc(mtl: Mtl) -> ^Material {
	idx := len(mtl.materials)
	append_nothing(mtl.materials)
	return &mtl.materials[idx]
}

@(private)
mtl_new_string :: proc(mtl: Mtl, data: string) -> (str: Slice(byte)) {
	str.start = u32(len(mtl.strings))
	str.size = u32(len(data))

	append(mtl.strings, data)
	return
}

@(private)
parse_v1 :: proc(noprefix: string) -> (v: f32, result: Result) {
	ok: bool

	v, ok = strconv.parse_f32(noprefix)
	if !ok do result = .Invalid_Char

	return
}

parse_illum :: proc(noprefix: string) -> (illum: Illumination) {

	for b in transmute([]byte)(noprefix) {
		when ODIN_DEBUG do assert(b >= '0' && b <= '9')
		illum = illum * Illumination(10) + Illumination(b - '0')
	}

	return
}

