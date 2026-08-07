package shader

import "core:path/filepath"
import "core:strings"

make_shader_enum_variant :: proc(path: string) -> string {
	outp, err := strings.to_snake_case(filepath.short_stem(path), context.temp_allocator)
	assert(err == .None)
	return outp
}

