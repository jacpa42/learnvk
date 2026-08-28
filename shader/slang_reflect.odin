package shader

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "vendor:vulkan"

STAGE_NAME := [Stage]vulkan.ShaderStageFlag {
	.vertex   = .VERTEX,
	.fragment = .FRAGMENT,
	.compute  = .COMPUTE,
	.geometry = .GEOMETRY,
}

JsonObject :: distinct json.Object

SlangReflectData :: struct {
	entryPoints: []SlangEntryPoint,
	parameters:  []ShaderParameter,
}

ShaderParameter :: struct {
	name:    string,
	binding: struct {
		index: int,
		kind:  enum {
			descriptorTableSlot,
		},
	},
	type:    ShaderParameterType,
}

ShaderParameterType :: struct {
	elementType: JsonObject,
	resultType:  JsonObject,
	baseShape:   enum {
		none,
		texture2D,
		structuredBuffer,
	},
	kind:        enum {
		constantBuffer,
		resource,
	},
}

SlangEntryPoint :: struct {
	name:       string,
	stage:      Stage,
	parameters: []StageParameter,
}

StageParameter :: struct {
	stage:   Stage,
	binding: struct {
		count: int,
		index: int,
		kind:  enum {
			varyingInput,
		},
	},
	type:    JsonObject,
}

SlangField :: struct {
	name:    string,
	stage:   Stage,
	type:    SlangType,
	binding: struct {
		offset:        i64,
		size:          i64,
		elementStride: i64,
	},
}

SlangType :: union {
	SlangStruct,
	SlangMatrix,
	SlangVector,
	SlangScalar,
}

SlangStruct :: struct {
	name:   string,
	fields: []SlangField,
	sizes:  [dynamic; 1]SlangSize,
}

SlangSize :: struct {
	kind:      string,
	value:     i64,
	alignment: i64,
}

SlangVector :: struct {
	count: int,
	type:  SlangScalar,
}

SlangScalar :: enum {
	none,

	// signed
	int8,
	int16,
	int32,
	int64,

	// unsigned
	uint8,
	uint16,
	uint32,
	uint64,

	// bool
	bool8,
	bool16,
	bool32,

	// floats
	float16,
	float32,
	float64,
}

SlangMatrix :: struct {
	rows:    int,
	columns: int,
	type:    SlangScalar,
}

Stage :: enum {
	vertex,
	fragment,
	compute,
	geometry,
}

slang_field_parse :: proc(v: json.Object) -> (o: SlangField) {
	//
	// name
	//
	o.name = v["name"].(json.String)

	//
	// type
	//
	o.type = slang_type_parse(JsonObject(v["type"].(json.Object)))

	//
	// binding
	//
	binding := JsonObject(v["binding"].(json.Object))
	found: bool

	o.binding.offset, found = binding["offset"].(json.Integer)
	if !found do o.binding.offset = -1

	o.binding.size, found = binding["size"].(json.Integer)
	if !found do o.binding.size = -1

	o.binding.elementStride, found = binding["elementStride"].(json.Integer)
	if !found do o.binding.elementStride = -1

	return
}

// Uses context.allocator
slang_type_parse :: proc(obj: JsonObject) -> (o: SlangType) {
	kind := obj["kind"].(json.String)

	switch kind {
	case "struct":
		o = slang_type_parse_struct(obj)
	case "matrix":
		o = slang_type_parse_matrix(obj)
	case "vector":
		o = slang_type_parse_vector(obj)
	case "scalar":
		o = slang_type_parse_scalar(obj)
	case:
		fmt.panicf("unknown kind: {}", kind)
	}

	return
}

slang_type_parse_struct :: proc(
	v: JsonObject,
	allocator := context.temp_allocator,
) -> (
	o: SlangStruct,
) {
	context.allocator = mem.nil_allocator()

	assert(v["kind"].(json.String) == "struct")

	//
	// name
	//
	o.name = v["name"].(json.String)

	//
	// sizes
	//
	sizes := v["sizes"].(json.Array)
	assert(len(sizes) <= cap(o.sizes))
	for size_value in sizes {
		size_object := size_value.(json.Object)

		found: bool
		size: SlangSize

		size.kind = size_object["kind"].(json.String)

		size.value, found = size_object["value"].(json.Integer)
		if !found do size.value = -1

		size.alignment, found = size_object["alignment"].(json.Integer)
		if !found do size.alignment = -1

		append(&o.sizes, size)
	}

	//
	// fields
	//
	fields := v["fields"].(json.Array)
	o.fields = make([]SlangField, len(fields), allocator)
	for &f, i in o.fields {
		f = slang_field_parse(fields[i].(json.Object))
	}

	return
}

slang_type_parse_matrix :: proc(v: JsonObject) -> (o: SlangMatrix) {
	assert(v["kind"].(json.String) == "matrix")

	o.rows = int(v["rowCount"].(json.Integer))
	o.columns = int(v["columnCount"].(json.Integer))
	o.type = slang_type_parse_scalar(JsonObject(v["elementType"].(json.Object)))

	return
}

slang_type_parse_vector :: proc(v: JsonObject) -> (o: SlangVector) {
	assert(v["kind"].(json.String) == "vector")

	o.count = int(v["elementCount"].(json.Integer))
	o.type = slang_type_parse_scalar(JsonObject(v["elementType"].(json.Object)))

	return
}

slang_type_parse_scalar :: proc(v: JsonObject, loc := #caller_location) -> (o: SlangScalar) {
	assert(v["kind"].(json.String) == "scalar", loc = loc)

	ok: bool
	o, ok = reflect.enum_from_name(type_of(o), string(v["scalarType"].(json.String)))
	assert(ok)

	return
}

slang_reflect_unmarshal :: proc(path: string) -> (arena: mem.Arena, r: SlangReflectData) {
	data, err := os.read_entire_file(path, context.allocator)
	assert(err == nil)
	defer delete(data)

	buf := make([]byte, 64 * len(data))
	mem.arena_init(&arena, buf)

	jerr := json.unmarshal(data, &r, allocator = mem.arena_allocator(&arena))

	if jerr != nil {
		fmt.eprintfln("Eish json decode failed: {}", jerr)
		assert(false)
	}

	return
}

//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
