package shader

import "core:fmt"
import "core:log"
import "core:strings"
import "vendor:vulkan"


VertexShaderInfo :: struct {
	shader_path: string,
	ep:          SlangEntryPoint,
	params:      []ShaderParameter,
}

//
// The convention I use is to assume that anything containing the word
// `instance` must be stepped through per instance and similarly with vertex.
//
// WARN: I panic if it has neither.
//
append_vertex_input_description :: proc(
	o: ^[dynamic]byte,
	shader_paths: []string,
	reflect_data_objects: []SlangReflectData,
) {

	//
	// Pick out the vertex shaders
	//

	// It's dynamic as we might have compute shaders here
	vertex_shader_info := make(
		[dynamic]VertexShaderInfo,
		0,
		len(shader_paths),
		context.temp_allocator,
	)

	for sr, i in reflect_data_objects {
		vertex_entry, found := get_vertex_entry(sr)
		assert(vertex_entry.stage == .vertex)

		if found {
			append(
				&vertex_shader_info,
				VertexShaderInfo{shader_paths[i], vertex_entry, sr.parameters},
			)
		} else {
			log.warnf("Failed to find the vertex shader entry point in {}", shader_paths[i])
		}
	}

	//
	// First write the struct definitions into the file for each shader
	//
	for vs in vertex_shader_info {
		shader_struct_name := make_shader_struct_variant(vs.shader_path)

		for param in vs.ep.parameters {
			if len(param.type.name) == 0 {continue}

			append(o, shader_struct_name)
			append(o, param.type.name)
			append(o, " :: struct {\n")

			for field in param.type.fields {
				odin_name, odin_type := field_to_odin_name_and_type(field)
				assert(raw_data(odin_name) != nil && raw_data(odin_type) != nil)

				append(o, '\t')
				append(o, odin_name)
				append(o, ": ")
				append(o, odin_type)
				append(o, ",\n")
			}

			append(o, "}\n\n")

		}
	}

	//
	// Then create an enumerated array of vertex binding descriptions
	//

	append(o, "PIPELINE_VERTEX_BINDING := [Pipeline][]vk.VertexInputBindingDescription {\n")

	for vs in vertex_shader_info {

		shader_enum_name := make_shader_enum_variant(vs.shader_path)

		append(o, "\t.")
		append(o, shader_enum_name)
		append(o, " = ")

		if !vs_has_params(vs) {
			append(o, "nil,\n")
			continue
		}

		shader_struct_name := make_shader_struct_variant(vs.shader_path)

		append(o, "{\n")

		for param, binding_no in vs.ep.parameters {
			if len(param.type.name) == 0 {continue}

			append(o, "\t\tvk.VertexInputBindingDescription {\n")

			// binding: u32
			append(o, fmt.tprintf("\t\t\tbinding = {},\n", binding_no))

			// stride: u32
			append(o, "\t\t\tstride = size_of(")
			append(o, shader_struct_name)
			append(o, param.type.name)
			append(o, "),\n")

			// inputRate: enum c.int { VERTEX = 0, INSTANCE = 1 }
			append(o, "\t\t\tinputRate = ")
			append(o, param_guess_input_rate(param))
			append(o, ",\n\t\t},\n")

		}

		append(o, "\t},\n")
	}

	append(o, "}\n\n")

	//
	// Then create an enumerated array of vertex attribute descriptions
	//

	append(o, "PIPELINE_VERTEX_ATTRIBUTE := [Pipeline][]vk.VertexInputAttributeDescription {\n")

	for vs in vertex_shader_info {
		shader_enum_name := make_shader_enum_variant(vs.shader_path)

		append(o, "\t.")
		append(o, shader_enum_name)
		append(o, " = ")

		if !vs_has_params(vs) {
			append(o, "nil,\n")
			continue
		}

		shader_struct_name := make_shader_struct_variant(vs.shader_path)

		append(o, "{\n")

		location: int

		for param, binding_no in vs.ep.parameters {
			if len(param.type.name) == 0 {continue}

			for param_field in param.type.fields {
				count, offset_per_attribute, vkformat := param_get_vk_format(param_field)

				total_offset_to_add: int

				for _ in 0 ..< count {
					defer total_offset_to_add += offset_per_attribute
					append(o, "\t\tvk.VertexInputAttributeDescription {\n")

					// location: u32
					append(o, fmt.tprintf("\t\t\tlocation = {},\n", location))
					location += 1

					// binding: u32
					append(o, fmt.tprintf("\t\t\tbinding = {},\n", binding_no))

					// format: vulkan.Format
					append(o, fmt.tprintf("\t\t\tformat = .{},\n", vkformat))

					// offset:   u32,

					//
					// Get the base offset of the element using offset_of_by_string
					//
					append(o, "\t\t\toffset = u32(offset_of_by_string(")
					append(o, shader_struct_name)
					append(o, param.type.name)
					append(o, ", \"")
					append(o, param_field.name)
					append(o, "\"))")

					if total_offset_to_add == 0 {
						append(o, ",\n")
					} else {
						append(o, fmt.tprintf(" + {},\n", total_offset_to_add))
					}

					append(o, "\t\t},\n")
				}
			}
		}

		append(o, "\t},\n")
	}

	append(o, "}\n\n")

	//
	// Then create an enumerated array of vertex set layout descriptions
	//

	append(o, "PIPELINE_SET_LAYOUTS := [Pipeline][]vk.DescriptorSetLayoutBinding {\n")

	for vs in vertex_shader_info {
		shader_enum_name := make_shader_enum_variant(vs.shader_path)

		append(o, "\t.")
		append(o, shader_enum_name)
		append(o, " = ")

		if !vs_has_params(vs) {
			append(o, "nil,\n")
			continue
		}

		append(o, "{\n")

		for param in vs.params {

			append(o, "\t\tvk.DescriptorSetLayoutBinding {\n")

			// binding: u32
			append(o, fmt.tprintf("\t\t\tbinding = {},\n", param.binding.index))

			// descriptorType:  vulkan.DescriptorType,
			descriptor_type := shader_param_get_descriptor_type(param)
			append(o, fmt.tprintf("\t\t\tdescriptorType = .{},\n", descriptor_type))

			// descriptorCount:  u32,
			// NOTE: I hardcode the descriptorCount to 1
			append(o, "\t\t\tdescriptorCount = 1,\n")

			// stageFlags: vulkan.ShaderStageFlags,
			append(o, "\t\t\tstageFlags = vk.ShaderStageFlags_ALL_GRAPHICS,\n")

			append(o, "\t\t},\n")
		}
		append(o, "\t},\n\n")
	}

	append(o, "}\n\n")

	//
	// Add the largest number of set layouts as a constant
	//
	pipeline_max_set_layouts := 0
	for vs in vertex_shader_info {
		pipeline_max_set_layouts = max(pipeline_max_set_layouts, len(vs.params))
	}
	append(o, fmt.tprintf("PIPELINE_MAX_SET_LAYOUTS :: {}\n\n", pipeline_max_set_layouts))
}

shader_param_get_descriptor_type :: proc(shader_param: ShaderParameter) -> string {
	switch shader_param.type.baseShape {
	case .structuredBuffer:
		return "STORAGE_BUFFER_DYNAMIC"
	}

	assert(false)
	return {}
}

// The `count` field of the struct member defines how many times we should
// repeat this layout
param_get_vk_format :: proc(f: Field) -> (count: int, offset_per_attribute: int, format: string) {

	switch f.type.kind {
	case "vector":
		assert(f.type.elementCount > 0)

		color_order := []u8{'R', 'G', 'B', 'A'}
		bit_size := scalar_get_bit_size(f.type.elementType.scalarType)

		format_array := make([dynamic]u8, 0, 32, context.temp_allocator)
		for i in 0 ..< f.type.elementCount {
			append(&format_array, color_order[i])
			append(&format_array, bit_size)
		}

		append(&format_array, '_')
		vulkan_name := scalar_get_vulkan_name(f.type.elementType.scalarType)
		append(&format_array, vulkan_name)

		count = 1
		offset_per_attribute = 0
		format = string(format_array[:])
		return

	case "scalar":
		bit_size := scalar_get_bit_size(f.type.scalarType)

		format_array := make([dynamic]u8, 0, 32, context.temp_allocator)

		append(&format_array, 'R')
		append(&format_array, bit_size)

		append(&format_array, '_')
		vulkan_name := scalar_get_vulkan_name(f.type.scalarType)
		append(&format_array, vulkan_name)

		count = 1
		offset_per_attribute = 0
		format = string(format_array[:])
		return

	case "matrix":
		assert(f.type.columnCount > 0)
		assert(f.type.rowCount > 0)

		color_order := []u8{'R', 'G', 'B', 'A'}
		bit_size := scalar_get_bit_size(f.type.elementType.scalarType)

		format_array := make([dynamic]u8, 0, 32, context.temp_allocator)
		for i in 0 ..< f.type.rowCount {
			append(&format_array, color_order[i])
			append(&format_array, bit_size)
		}

		append(&format_array, '_')
		vulkan_name := scalar_get_vulkan_name(f.type.elementType.scalarType)
		append(&format_array, vulkan_name)

		byte_size_int := scalar_get_byte_size_int(f.type.elementType.scalarType)

		count = f.type.columnCount
		offset_per_attribute = f.type.columnCount * byte_size_int
		format = string(format_array[:])
		return

	case:
		fmt.panicf("unknown field type: {}", f.type.kind)
	}
}

param_guess_input_rate :: proc(param: StageParameter) -> string {
	lowercase_name := strings.to_lower(param.type.name, context.temp_allocator)

	if strings.contains(lowercase_name, "instance") {
		return ".INSTANCE"
	} else if strings.contains(lowercase_name, "vertex") {
		return ".VERTEX"
	}

	fmt.panicf(
		"I have no idea whether or not this vertex shader input is per vertex or per instance. Please put in the name of the struct either \"vertex\" or \"instance\" (case does not matter).",
	)
}

vs_has_params :: proc(vs: VertexShaderInfo) -> (has_params: bool) {
	for param in vs.ep.parameters {
		has_params |= (len(param.type.name) > 0)
	}

	return
}

field_to_odin_name_and_type :: proc(f: Field) -> (name: string, type: string) {

	//
	// We just copy the name in slang
	//
	name = f.name

	//
	// For the type it is a bit more involved
	//
	switch f.type.kind {
	case "vector":
		// [elementCount]elementType.scalarType
		assert(f.type.elementCount > 0)
		odin_scalar_name := make_odin_scalar_name(f.type.elementType.scalarType)
		type = fmt.tprintf("[{}]{}", f.type.elementCount, odin_scalar_name)

	case "scalar":
		// scalarType
		type = make_odin_scalar_name(f.type.scalarType)

	case "matrix":
		//
		// From 'https://shader-slang.org/slang/user-guide/a1-01-matrix-layout.html':
		// ```
		// Except when running the compiler through the slangc tool, in which case the
		// default is col-major. This default is for legacy reasons and may change in
		// the future.
		// ```
		//
		// matrix[row, col]elementType

		assert(f.type.rowCount > 0)
		assert(f.type.columnCount > 0)

		odin_scalar_name := make_odin_scalar_name(f.type.elementType.scalarType)
		type = fmt.tprintf(
			"matrix[{}, {}]{}",
			f.type.rowCount,
			f.type.columnCount,
			odin_scalar_name,
		)

	case:
		fmt.panicf("unknown field type: {}", f.type.kind)
	}

	return
}


// odinfmt: disable
scalar_get_byte_size_int :: proc(scalar_type: Scalar) -> int {
    switch scalar_type {
    case .none: assert(false)

    case .int8,  .uint8,  .bool8:             return 1
    case .int16, .uint16, .float16, .bool16:  return 2
    case .int32, .uint32, .bool32,  .float32: return 3
    case .int64, .uint64, .float64:           return 4
    }

    assert(false)
    return 0
}
// odinfmt: enable
// odinfmt: disable
scalar_get_bit_size :: proc(scalar_type: Scalar) -> string {
    switch scalar_type {
    case .none: assert(false)

    case .int8,  .uint8,  .bool8:             return "8"
    case .int16, .uint16, .float16, .bool16:  return "16"
    case .int32, .uint32, .bool32,  .float32: return "32"
    case .int64, .uint64, .float64:           return "64"
    }

    assert(false)
    return {}
}
// odinfmt: enable
// odinfmt: disable
scalar_get_vulkan_name :: proc(scalar_type: Scalar) -> (name: string) {
	switch scalar_type {
    case .none: assert(false)

	case .int8,    .int16,   .int32,  .int64:  name = "SINT"
	case .uint8,   .uint16,  .uint32, .uint64: name = "UINT"
	case .bool8,   .bool16,  .bool32:          name = "UINT"
	case .float16, .float32, .float64:         name = "SFLOAT"
	}

    return
}
// odinfmt: enable
// odinfmt: disable
make_odin_scalar_name :: proc(scalar_type: Scalar) -> string {
    switch scalar_type {
    case .none: assert(false)

    case .int8:    return "i8"
    case .int16:   return "i16"
    case .int32:   return "i32"
    case .int64:   return "i64"

    case .uint8:   return "u8"
    case .uint16:  return "u16"
    case .uint32:  return "u32"
    case .uint64:  return "u64"

    case .bool8:   return "b8"
    case .bool16:  return "b16"
    case .bool32:  return "b32"

    case .float16: return "f16"
    case .float32: return "f32"
    case .float64: return "f64"
    }

    assert(false)
    return {}
}
// odinfmt: enable

get_vertex_entry :: proc(sr: SlangReflectData) -> (vertex_entry: SlangEntryPoint, found: bool) {
	for ep in sr.entryPoints {
		if ep.stage == .vertex {
			vertex_entry = ep
			found = true
			return
		}
	}

	found = false
	return
}

