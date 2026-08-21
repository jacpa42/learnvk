package model

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

starts_with := strings.starts_with

Mtl :: struct {
	strings:   [dynamic]byte,
	materials: [dynamic]Material,
}

Material :: struct {
	name:               Slice(byte),
	map_Kd:             Slice(byte), // diffuse
	map_Ks:             Slice(byte), // specular
	map_Ke:             Slice(byte), // emissive
	map_Ka:             Slice(byte), // ambient
	map_d:              Slice(byte), // alpha / dissolve
	map_bump:           Slice(byte), // normal
	illum:              Illumination,
	Ns, Ni, d, Tr:      f32,
	Tf, Ka, Kd, Ks, Ke: [3]f32,
}

Illumination :: enum u32 {
	Color_on_and_Ambient_off                                           = 0,
	Color_on_and_Ambient_on                                            = 1,
	Highlight_on                                                       = 2,
	Reflection_on_and_Ray_trace_on                                     = 3,
	Transparency_Glass_on_Reflection_Ray_trace_on                      = 4,
	Reflection_Fresnel_on_and_Ray_trace_on                             = 5,
	Transparency_Refraction_on_Reflection_Fresnel_off_and_Ray_trace_on = 6,
	Transparency_Refraction_on_Reflection_Fresnel_on_and_Ray_trace_on  = 7,
	Reflection_on_and_Ray_trace_off                                    = 8,
	Transparency_Glass_on_Reflection_Ray_trace_off                     = 9,
	Casts_shadows_onto_invisible_surfaces                              = 10,
}

mtl_offset_strings :: proc(mtl: ^Mtl, #any_int offset: u32) {
	for &material in mtl.materials {
		material.name.start += offset
		material.map_Kd.start += offset
		material.map_Ks.start += offset
		material.map_Ke.start += offset
		material.map_Ka.start += offset
		material.map_d.start += offset
		material.map_bump.start += offset
	}
}

mtl_init_or_clear :: proc(m: ^Mtl) {
	assert(m != nil)
	make_or_clear(&m.materials)
	make_or_clear(&m.strings)
}

mtl_destroy :: proc(m: ^Mtl) {
	assert(m != nil)
	defer m^ = {}
	delete(m.materials)
	delete(m.strings)
}

mtl_load :: proc(mtl: ^Mtl, path: string, ok: ^bool = nil) {
	assert(path != {})

	raw, oserr := os.read_entire_file(path, context.temp_allocator)
	if oserr != nil {
		if ok != nil do ok^ = false
		return
	}

	fmt.eprintfln("Loading \"{}\" ({} Mib)", path, f32(len(raw)) / (1024 * 1024))

	load_mem_ok := mtl_load_memory(mtl, raw)

	if ok != nil do ok^ = load_mem_ok

	return

}

mtl_load_memory :: proc(m: ^Mtl, data: []byte) -> (ok: bool) {
	mtl_init_or_clear(m)

	mat: ^Material

	line_iter := string(data)
	for next_line in strings.split_lines_iterator(&line_iter) {
		if len(next_line) < 2 {continue}
		line := strings.trim(next_line, "\t\n\v\f\r ")

		if line[0] == '#' {continue}

		if starts_with(line, "newmtl") {
			mat = mtl_new_material(m)
			mat.name = mtl_append_string(m, mtl_parse_string(line))

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
			mat.map_Ka = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Ks") {
			mat.map_Ks = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Ke") {
			mat.map_Ke = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Kd") {
			mat.map_Kd = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_d") {
			mat.map_d = mtl_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_bump") || starts_with(line, "bump") {
			mat.map_bump = mtl_append_string(m, mtl_parse_string(line))
		}

	}

	ok = true
	return
}

mtl_new_material :: proc(mtl: ^Mtl) -> ^Material {
	idx := len(mtl.materials)
	append_nothing(&mtl.materials)
	return &mtl.materials[idx]
}

mtl_append_string :: proc(mtl: ^Mtl, data: string) -> (str: Slice(byte)) {
	str.start = u32(len(mtl.strings))
	str.size = u32(len(data))

	append(&mtl.strings, data)
	return
}

mtl_parse_string :: proc(line: string) -> (o: string) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		return
	}

	o = line[space + 1:]
	return
}

mtl_parse_f32 :: proc(line: string) -> (v: f32, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		ok = false
		return
	}

	return strconv.parse_f32(line[space + 1:])
}

mtl_parse_3_f32 :: proc(line: string) -> (v: [3]f32, ok: bool) {

	space0 := strings.index_byte(line, ' ')
	space1 := space0 + 1 + strings.index_byte(line[space0 + 1:], ' ')
	space2 := space1 + 1 + strings.index_byte(line[space1 + 1:], ' ')

	if space0 == -1 || space1 == -1 || space2 == -1 {
		ok = false
		return
	}

	v = {
		strconv.parse_f32(line[space0 + 1:space1]) or_return,
		strconv.parse_f32(line[space1 + 1:space2]) or_return,
		strconv.parse_f32(line[space2 + 1:]) or_return,
	}

	return
}

mtl_parse_illum :: proc(line: string) -> (illum: Illumination, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space == -1 {
		ok = false
		return
	}

	bytes := transmute([]byte)(line[space + 1:])
	if len(bytes) == 0 {
		ok = false
		return
	}

	for b in bytes {
		when ODIN_DEBUG {
			assert(b >= '0' && b <= '9')
		}
		illum = illum * Illumination(10) + Illumination(b - '0')
	}

	ok = true
	return
}
