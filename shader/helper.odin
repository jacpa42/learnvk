package shader

import "core:path/filepath"
import "core:strings"

make_shader_enum_variant :: proc(path: string) -> string {
	outp, err := strings.to_snake_case(filepath.short_stem(path), context.temp_allocator)
	assert(err == .None)
	return outp
}

make_shader_enum_variant_upper :: proc(path: string) -> string {
	outp, err := strings.to_upper_snake_case(filepath.short_stem(path), context.temp_allocator)
	assert(err == .None)
	return outp
}


make_shader_struct_variant :: proc(path: string) -> string {
	outp, err := strings.to_pascal_case(filepath.short_stem(path), context.temp_allocator)
	assert(err == .None)
	return outp
}
