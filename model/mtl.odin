package model

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

mtl_load :: proc(mtl: Mtl, path: string, ok: ^bool = nil) {
	if len(path) == 0 {
		if ok != nil do ok^ = false
		return
	}

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", path, f32(len(raw)) / (1024 * 1024))

	load_mem_ok := mtl_load_memory(mtl, raw)
	if !load_mem_ok {
		if ok != nil do ok^ = false
		return
	}

	if ok != nil do ok^ = true
	return
}

mtl_load_memory :: proc(m: Mtl, data: []byte) -> (ok: bool) {

	mat: ^Material

	line_iter := string(data)
	for next_line in strings.split_lines_iterator(&line_iter) {
		if len(next_line) < 2 {continue}
		line := strings.trim(next_line, "\t\n\v\f\r ")

		if line[0] == '#' {continue}

		if starts_with(line, "newmtl") {
			mat = mtl_new_material(m)
			mat.strings[.name] = mtl_append_string(m, mtl_parse_string(line))

			//
			// Float values
			//

		} else if starts_with(line, "Ns") {
			mat.Ns = mtl_parse_f32(line) or_return

		} else if starts_with(line, "Ni") {
			mat.Ni = mtl_parse_f32(line) or_return

		} else if starts_with(line, "d") {
			mat.d = mtl_parse_f32(line) or_return

		} else if starts_with(line, "Tr") {
			mat.Tr = mtl_parse_f32(line) or_return

			//
			// Floatx3 values
			//

		} else if starts_with(line, "Tf") {
			mat.Tf = mtl_parse_3_f32(line) or_return

		} else if starts_with(line, "Ka") {
			mat.Ka = mtl_parse_3_f32(line) or_return

		} else if starts_with(line, "Kd") {
			mat.Kd = mtl_parse_3_f32(line) or_return

		} else if starts_with(line, "Ks") {
			mat.Ks = mtl_parse_3_f32(line) or_return

		} else if starts_with(line, "Ke") {
			mat.Ke = mtl_parse_3_f32(line) or_return


			//
			// Special enum
			//

		} else if starts_with(line, "illum") {
			mat.illum = mtl_parse_illum(line) or_return


			//
			// path strings
			//

		} else if starts_with(line, "map_Ka") {
			mat.strings[.map_Ka] = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Ks") {
			mat.strings[.map_Ks] = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Ke") {
			mat.strings[.map_Ke] = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Kd") {
			mat.strings[.map_Kd] = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_d") {
			mat.strings[.map_d] = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_bump") || starts_with(line, "bump") {
			mat.strings[.map_bump] = mtl_append_string(m, mtl_parse_string(line))
		}

	}

	ok = true
	return
}

mtl_new_material :: proc(mtl: Mtl) -> ^Material {
	idx := len(mtl.materials)
	append_nothing(mtl.materials)
	return &mtl.materials[idx]
}

mtl_append_string :: proc(mtl: Mtl, data: string) -> (str: Slice(byte)) {
	str.start = u32(len(mtl.strings))
	str.size = u32(len(data))

	append(mtl.strings, data)
	return
}

mtl_parse_string :: proc(line: string) -> (o: string) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		when ODIN_DEBUG do log.warnf("Failed to parse \"{}\": string empty", line)
		return
	}

	o = line[space + 1:]
	return
}

mtl_parse_f32 :: proc(line: string) -> (v: f32, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		ok = false

		when ODIN_DEBUG do log.warnf("Failed to parse \"{}\"", line)

		return
	}

	return strconv.parse_f32(line[space + 1:])
}

mtl_parse_3_f32 :: proc(line: string) -> (v: [3]f32, ok: bool) {
	when ODIN_DEBUG do defer if !ok do log.warnf("Failed to parse \"{}\"", line)

	space0 := strings.index_byte(line, ' ')
	space1 := space0 + 1 + strings.index_byte(line[space0 + 1:], ' ')
	space2 := space1 + 1 + strings.index_byte(line[space1 + 1:], ' ')

	if space0 == -1 || space1 == -1 || space2 == -1 {
		ok = false
		return
	}

	v0 := line[space0 + 1:space1]
	v[0] = strconv.parse_f32(v0) or_return

	v1 := line[space1 + 1:space2]
	v[1] = strconv.parse_f32(v1) or_return

	v2 := line[space2 + 1:]
	v[2] = strconv.parse_f32(v2) or_return

	ok = true
	return
}

mtl_parse_illum :: proc(line: string) -> (illum: Illumination, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		ok = false

		when ODIN_DEBUG do log.warnf("Failed to parse \"{}\": no space found", line)

		return
	}

	bytes := transmute([]byte)(line[space + 1:])
	if len(bytes) == 0 {
		ok = false

		when ODIN_DEBUG do log.warnf("Failed to parse \"{}\": empty after space", line)

		return
	}

	for b in bytes {
		when ODIN_DEBUG do assert(b >= '0' && b <= '9')
		illum = illum * Illumination(10) + Illumination(b - '0')
	}

	ok = true
	return
}

