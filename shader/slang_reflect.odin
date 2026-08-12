package shader

import "core:encoding/json"
import "core:mem"
import "core:os"
import "vendor:vulkan"

STAGE_NAME := [Stage]vulkan.ShaderStageFlag {
	.vertex   = .VERTEX,
	.fragment = .FRAGMENT,
	.compute  = .COMPUTE,
	.geometry = .GEOMETRY,
}

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
	resultType: FieldType,
	baseShape:  enum {
		structuredBuffer,
	},
	kind:       enum {
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
	type:    SlangStructType,
}

SlangStructType :: struct {
	// The name of the struct in the shader. We use this to guess whether
	// this thing should be stepped across per instance or per vertex.
	name:   string,
	fields: []Field,
}

Field :: struct {
	name:    string,
	stage:   Stage,
	binding: struct {
		count: int,
		index: int,
	},
	type:    FieldType,
}

FieldType :: struct {
	// This is kind a union ?
	kind:         string,

	// kind == vector
	elementCount: int,
	elementType:  struct {
		kind:       enum {
			scalar,
		},
		scalarType: Scalar,
	},

	// kind == scalar
	scalarType:   Scalar,

	// kind == matrix
	rowCount:     int,
	columnCount:  int,
	// elementType: blah blah see above
}

Scalar :: enum {
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

Stage :: enum {
	vertex,
	fragment,
	compute,
	geometry,
}

slang_reflect_unmarshal :: proc(path: string) -> (arena: mem.Arena, r: SlangReflectData) {
	data, err := os.read_entire_file(path, context.allocator)
	assert(err == nil)
	defer delete(data)

	buf := make([]byte, len(data))
	mem.arena_init(&arena, buf)

	jerr := json.unmarshal(data, &r, allocator = mem.arena_allocator(&arena))
	assert(jerr == nil)

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
