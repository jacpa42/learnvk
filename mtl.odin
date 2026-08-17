package learnvk

import "core:strconv"
import "core:strings"

MAX_MATERIALS :: 16
starts_with := strings.starts_with

MaterialList :: struct {
	material_strings: [dynamic]byte,
	materials:        [dynamic; MAX_MATERIALS]Material,
}

Material :: struct {
	name:               Slice,
	map_Ka:             Slice,
	map_Kd:             Slice,
	map_d:              Slice,
	map_bump:           Slice,
	illum:              Illumination,
	Ns, Ni, d, Tr:      f32,
	Tf, Ka, Kd, Ks, Ke: [3]f32,
}

Illumination :: enum {
	Color_on_and_Ambient_off = 0,
	Color_on_and_Ambient_on = 1,
	Highlight_on = 2,
	Reflection_on_and_Ray_trace_on = 3,
	Transparency_Glass_on_Reflection_Ray_trace_on = 4,
	Reflection_Fresnel_on_and_Ray_trace_on = 5,
	Transparency_Refraction_on_Reflection_Fresnel_off_and_Ray_trace_on = 6,
	Transparency_Refraction_on_Reflection_Fresnel_on_and_Ray_trace_on = 7,
	Reflection_on_and_Ray_trace_off = 8,
	Transparency_Glass_on,
	Reflection_Ray_trace_off = 9,
	Casts_shadows_onto_invisible_surfaces = 10,
}

mtllist_new_material :: proc(mtllist: ^MaterialList) -> ^Material {
	idx := len(mtllist.materials)
	append_nothing(&mtllist.materials)
	return &mtllist.materials[idx]
}

mtllist_append_string :: proc(mtllist: ^MaterialList, data: string) -> (str: Slice) {
	str = Slice{u32(len(mtllist.material_strings)), u32(len(data))}
	append(&mtllist.material_strings, data)
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

//
// newmtl leaf
// 	Ns 10.0000
// 	Ni 1.5000
// 	d 1.0000
// 	Tr 0.0000
// 	Tf 1.0000 1.0000 1.0000
// 	illum 2
// 	Ka 1 1 1
// 	Kd 1 1 1
// 	Ks 0.0000 0.0000 0.0000
// 	Ke 0.0000 0.0000 0.0000
// 	map_Ka textures\sponza_thorn_diff.png
// 	map_Kd textures\sponza_thorn_diff.png
// 	map_d textures\sponza_thorn_mask.png
//  map_bump textures\sponza_thorn_bump.png
//
mtllist_load_mtl_memory :: proc(m: ^MaterialList, data: []byte) -> (ok: bool) {
	mtllist_init(m)

	mat: ^Material

	line_iter := string(data)
	for next_line in strings.split_lines_iterator(&line_iter) {
		if len(next_line) < 2 {continue}
		line := strings.trim(next_line, "\t\n\v\f\r ")

		if line[0] == '#' {continue}


		if starts_with(line, "newmtl") {
			mat = mtllist_new_material(m)
			mat.name = mtllist_append_string(m, mtl_parse_string(line))

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
			mat.map_Ka = mtllist_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_Kd") {
			mat.map_Kd = mtllist_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_d") {
			mat.map_d = mtllist_append_string(m, mtl_parse_string(line))

		} else if starts_with(line, "map_bump") {
			mat.map_bump = mtllist_append_string(m, mtl_parse_string(line))
		}

	}

	ok = true
	return
}

mtllist_init :: proc(m: ^MaterialList) {
	assert(m != nil)
	clear(&m.materials)

	if cap(m.material_strings) == 0 {
		m.material_strings = make([dynamic]byte, 0, 128)
	} else {
		clear(&m.material_strings)
	}

}
