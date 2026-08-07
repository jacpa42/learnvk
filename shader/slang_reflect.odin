package shader

import "core:encoding/json"
import "core:os"
import "vendor:vulkan"

slang_reflect_unmarshal :: proc(path: string) -> (r: SlangReflectData) {
	data, err := os.read_entire_file(path, context.allocator)
	assert(err == nil)
	defer delete(data)

	jerr := json.unmarshal(data, &r)
	assert(jerr == nil)

	return
}

slang_reflect_destroy :: proc(r: ^SlangReflectData) {
	for s in r.entryPoints {delete(s.name)}
	delete(r.entryPoints)
}

SlangReflectData :: struct {
	entryPoints: []SlangEntryPoint,
}

SlangEntryPoint :: struct {
	name:  string,
	stage: Stage,
}

Stage :: enum {
	vertex,
	fragment,
	compute,
	geometry,
}

STAGE_NAME := [Stage]vulkan.ShaderStageFlag {
	.vertex   = .VERTEX,
	.fragment = .FRAGMENT,
	.compute  = .COMPUTE,
	.geometry = .GEOMETRY,
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
