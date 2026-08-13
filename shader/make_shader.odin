package shader

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:thread"

g_trace: trace.Context

//
// We use this in our make file to generate an Odin file which gets compiled
// into our main executable which contains our shader SPIR-V byte code.
//
// 1. Input to the program in a list of all shaders to compile.
// 2. Compiles all the shaders to byte code.
// 3. Creates an odin source file which gets compiled into our program.
//
main :: proc() {
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(context.logger)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			dump_mem_info(track)
			mem.tracking_allocator_destroy(&track)
		}
	}

	//
	// Setup stack trace
	//
	when ODIN_DEBUG {
		context.assertion_failure_proc = assertion_failure_proc
		assert(trace.init(&g_trace))
	}

	//
	// Parse cmdline args and spawn compilation tasks
	//

	if len(os.args) < 3 {
		fmt.eprintfln("Usage \"{} output_file.odin ..shaders_to_compile\"", os.args[0])
		return
	}

	output_file_path := os.args[1]
	shader_paths := os.args[2:]

	threads := make([]^thread.Thread, len(shader_paths))
	reflect_arenas := make([]mem.Arena, len(shader_paths))
	reflect_data_objects := make([]SlangReflectData, len(shader_paths))
	compiled_byte_code := make([][]u32, len(shader_paths))

	defer {
		delete(threads)

		for &arena in reflect_arenas {
			delete(arena.data)
		}

		delete(reflect_arenas)
		delete(reflect_data_objects)

		for code in compiled_byte_code {
			delete(code)
		}
		delete(compiled_byte_code)
	}

	for path, i in shader_paths {
		threads[i] = thread.create_and_start_with_poly_data(
			CompileTaskData {
				shader_path = path,
				output = &compiled_byte_code[i],
				reflect_data = &reflect_data_objects[i],
				reflect_arena = &reflect_arenas[i],
			},
			compile_shader_to_spirv,
			context,
		)
	}

	output_file_data := make([dynamic]byte)
	defer {
		oserr := os.write_entire_file_from_bytes(output_file_path, output_file_data[:])
		if oserr != nil {
			fmt.eprintfln("Failed to construct output file: {}", oserr)
		}

		delete(output_file_data)
	}

	append(&output_file_data, "package learnvk\n\n")
	append(&output_file_data, "import vk \"vendor:vulkan\"\n\n")
	append(&output_file_data, "//\n// This file is machine generated :)\n//\n\n")

	//
	// Create the shader enum
	//
	append(&output_file_data, "Pipeline :: enum {")
	for path, i in shader_paths {
		append(&output_file_data, make_shader_enum_variant(path))
		if i < len(shader_paths) - 1 {
			append(&output_file_data, ",")
		}
	}
	append(&output_file_data, "}\n")

	//
	// Create the shader name array
	//
	append(&output_file_data, "PIPELINE_NAME := [Pipeline]cstring {\n")
	for path in shader_paths {
		name := make_shader_enum_variant(path)
		append(&output_file_data, "\t.")
		append(&output_file_data, name)
		append(&output_file_data, " = \"")
		append(&output_file_data, name)
		append(&output_file_data, "\",\n")
	}
	append(&output_file_data, "}\n")

	//
	// Join the threads here, we need the parsed pipeline information
	//
	for t in threads {thread.destroy(t)}

	//
	// Write the max number of shader stages any shader uses
	//
	{
		max_stages: int
		for sr in reflect_data_objects {
			max_stages = max(max_stages, len(sr.entryPoints))
		}

		append(&output_file_data, "PIPELINE_MAX_STAGES :: ")
		append(&output_file_data, fmt.tprintf("{}\n", max_stages))
	}

	//
	// For each input to the vertex shader, create the
	// vk.VertexInputBindingDescription and vk.VertexInputAttributeDescription
	// for them.
	//
	// Also define the structs which are in the shader in the odin file for
	// convenience.
	//
	append_vertex_input_description(&output_file_data, shader_paths, reflect_data_objects)

	//
	// Make an array of all the entrypoints defined in the same order as the
	// entry point layout name below.
	//
	append(&output_file_data, "PIPELINE_STAGES := [Pipeline][]vk.ShaderStageFlag{\n")
	for sr, i in reflect_data_objects {
		assert(len(sr.entryPoints) > 0)

		name := make_shader_enum_variant(shader_paths[i])
		append(&output_file_data, "\t.")
		append(&output_file_data, name)
		append(&output_file_data, " = {")

		for ep, ep_index in sr.entryPoints {
			append(&output_file_data, ".")
			append(&output_file_data, fmt.tprint(STAGE_NAME[ep.stage]))
			if ep_index != len(sr.entryPoints) - 1 {
				append(&output_file_data, ", ")
			}
		}

		append(&output_file_data, "},\n")
	}
	append(&output_file_data, "}\n")

	//
	// Assign entry points
	//
	append(
		&output_file_data,
		"// The vk.ShaderStageFlag for each entry point is defined in the array above\n",
	)
	append(&output_file_data, "PIPELINE_STAGE_NAMES := [Pipeline][]cstring{\n")
	for sr, i in reflect_data_objects {
		assert(len(sr.entryPoints) > 0)

		name := make_shader_enum_variant(shader_paths[i])
		append(&output_file_data, "\t.")
		append(&output_file_data, name)
		append(&output_file_data, " = {")

		for ep, ep_index in sr.entryPoints {
			append(&output_file_data, "\"")
			append(&output_file_data, ep.name)
			append(&output_file_data, "\"")
			if ep_index != len(sr.entryPoints) - 1 {
				append(&output_file_data, ", ")
			}
		}

		append(&output_file_data, "},\n")
	}
	append(&output_file_data, "}\n")

	//
	// Gather the compiled shader data
	//
	append(&output_file_data, "PIPELINE_BYTE_CODE := [Pipeline][]u32{\n")

	for i in 0 ..< len(shader_paths) {
		append(&output_file_data, "\t.")
		append(&output_file_data, make_shader_enum_variant(shader_paths[i]))

		byte_code := compiled_byte_code[i]

		append(&output_file_data, " = {")
		for b, byte_index in byte_code[:] {
			if byte_index % 8 == 0 {
				append(&output_file_data, "\n\t\t")
			}

			append(&output_file_data, fmt.tprintf("0x%8x,", b))
		}

		append(&output_file_data, "\n\t},\n")

	}
	append(&output_file_data, "}\n")
}

CompileTaskData :: struct #all_or_none {
	// input
	shader_path:   string,

	// output
	output:        ^[]u32,
	reflect_arena: ^mem.Arena,
	reflect_data:  ^SlangReflectData,
}

compile_shader_to_spirv :: proc(data: CompileTaskData) {
	temp_dir, _ := os.temp_dir(context.temp_allocator)
	json_reflect_path, _ := os.join_path(
		{temp_dir, fmt.tprintf("{}.json", filepath.base(data.shader_path))},
		context.temp_allocator,
	)

	desc := os.Process_Desc {
		command = {
			"/usr/bin/slangc",
			"-disable-dynamic-dispatch",
			"-O3",
			"-reflection-json",
			json_reflect_path,
			"-target",
			"spirv",
			data.shader_path,
		},
	}

	state, stdout, stderr, err := os.process_exec(desc, context.allocator)

	if err != nil {
		fmt.eprintfln("I fucked up I think: {}", err)
		delete(stdout)
		delete(stderr)
		return
	}

	if state.exit_code != 0 {
		fmt.eprintfln("Process exited weirdly: {}", string(stderr))
		delete(stdout)
		delete(stderr)
		return
	}

	if len(stdout) % size_of(u32) != 0 {
		fmt.eprintfln("Output is not a slice of u32 values!")
		delete(stdout)
		delete(stderr)
		return
	}

	delete(stderr)

	ptr := ([^]u32)(raw_data(stdout))
	len := len(stdout) / size_of(u32)
	data.output^ = ptr[:len]

	data.reflect_arena^, data.reflect_data^ = slang_reflect_unmarshal(json_reflect_path)

	return
}

dump_mem_info :: proc(track: mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
		for _, entry in track.allocation_map {
			log.debugf("%v bytes @ %v", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
		for entry in track.bad_free_array {
			log.debugf("%p @ %v", entry.memory, entry.location)
		}
	}
}

assertion_failure_proc :: proc(prefix, message: string, loc := #caller_location) -> ! {
	runtime.print_caller_location(loc)
	runtime.print_string(" ")
	runtime.print_string(prefix)
	if len(message) > 0 {
		runtime.print_string(": ")
		runtime.print_string(message)
	}
	runtime.print_byte('\n')

	ctx := &g_trace
	if !trace.in_resolve(ctx) {
		buf: [64]trace.Frame
		runtime.print_string("Debug Trace:\n")
		frames := trace.frames(ctx, 1, buf[:])
		for f, i in frames {
			fl := trace.resolve(ctx, f, context.temp_allocator)
			if fl.loc.file_path == "" && fl.loc.line == 0 {
				continue
			}
			runtime.print_caller_location(fl.loc)
			runtime.print_string(" - frame ")
			runtime.print_int(i)
			runtime.print_byte('\n')
		}
	}
	runtime.trap()
}
