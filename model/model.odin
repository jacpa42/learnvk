package model

get_mtl_path :: proc {
	bob_get_mtl_path,
	obj_get_mtl_path,
}
bob_get_mtl_path :: proc(bob: Bob) -> string {
	// TODO
	return get_slice_string(bob.header.mtl_path, bob.data)
}
obj_get_mtl_path :: proc(obj: Obj) -> string {
	// TODO
	return get_slice_string(obj.mtl_path, obj.strings[:])
}

bob_load_or_create :: proc(
	bob: ^Bob,
	bob_path, obj_path: string,
	flipx, flipy: bool,
) -> (
	result: Result,
) {
	result = bob_load(bob, bob_path)
	if result == .Ok do return

	temp_obj: Obj
	obj_init_or_clear(&temp_obj)
	defer destroy(&temp_obj)

	obj_load(&temp_obj, obj_path, flipx = flipx, flipy = flipy) or_return
	bob_create_file(&temp_obj, bob_path) or_return
	bob_load(bob, bob_path) or_return

	result = .Ok
	return
}

destroy :: proc {
	obj_destroy,
	bob_destroy,
}

get_material_string :: proc {
	bob_get_material_string,
	obj_get_material_string,
}
bob_get_material_string :: proc(bob: Bob, mtl: Material, tag: MaterialString) -> string {
	return get_slice_string(mtl.strings[tag], bob.data)
}
obj_get_material_string :: proc(obj: Obj, mtl: Material, tag: MaterialString) -> string {
	return get_slice_string(mtl.strings[tag], obj.strings[:])
}

get_meshes :: proc {
	get_meshes_bob,
	get_meshes_obj,
}
get_meshes_obj :: proc(obj: Obj) -> []Mesh {
	return obj.meshes[:]
}
get_meshes_bob :: proc(bob: Bob, loc := #caller_location) -> []Mesh {
	return get_slice_data(bob.header.meshes, bob.data, loc = loc)
}

get_mesh_name :: proc {
	obj_get_mesh_name,
	bob_get_mesh_name,
	bob_get_mesh_name_index,
	obj_get_mesh_name_index,
}
obj_get_mesh_name :: proc(obj: Obj, mesh: Mesh) -> string {
	return get_slice_string(mesh.name, obj.strings[:])
}
bob_get_mesh_name :: proc(bob: Bob, mesh: Mesh) -> string {
	return get_slice_string(mesh.name, bob.data)
}
bob_get_mesh_name_index :: proc(bob: Bob, mesh_index: int) -> string {
	return get_slice_string(get_meshes(bob)[mesh_index].name, bob.data)
}
obj_get_mesh_name_index :: proc(obj: Obj, mesh_index: int) -> string {
	return get_slice_string(get_meshes(obj)[mesh_index].name, obj.strings[:])
}

get_mesh_material_name :: proc {
	obj_get_mesh_material_name,
	bob_get_mesh_material_name,
	bob_get_mesh_material_name_index,
	obj_get_mesh_material_name_index,
}
obj_get_mesh_material_name :: proc(obj: Obj, mesh: Mesh) -> string {
	return get_slice_string(mesh.material, obj.strings[:])
}
bob_get_mesh_material_name :: proc(bob: Bob, mesh: Mesh) -> string {
	return get_slice_string(mesh.material, bob.data)
}
bob_get_mesh_material_name_index :: proc(bob: Bob, mesh_index: int) -> string {
	return get_slice_string(get_meshes(bob)[mesh_index].material, bob.data)
}
obj_get_mesh_material_name_index :: proc(obj: Obj, mesh_index: int) -> string {
	return get_slice_string(get_meshes(obj)[mesh_index].material, obj.strings[:])
}

get_all_indices :: proc {
	get_all_indices_obj,
	get_all_indices_bob,
}
get_all_indices_obj :: proc(obj: Obj) -> []u32 {
	return obj.indices[:]
}
get_all_indices_bob :: proc(bob: Bob) -> []u32 {
	return get_slice_data(bob.header.indices, bob.data)
}

get_mesh_indices :: proc {
	obj_get_mesh_indices,
	bob_get_mesh_indices,
	obj_get_mesh_indices_index,
	bob_get_mesh_indices_index,
}
obj_get_mesh_indices_index :: proc(obj: Obj, mesh_index: int) -> []u32 {
	return obj_get_mesh_indices(obj, get_meshes(obj)[mesh_index])
}
bob_get_mesh_indices_index :: proc(bob: Bob, mesh_index: int) -> []u32 {
	return bob_get_mesh_indices(bob, get_meshes(bob)[mesh_index])
}
obj_get_mesh_indices :: proc(obj: Obj, mesh: Mesh) -> []u32 {
	return obj.indices[:]
}
bob_get_mesh_indices :: proc(bob: Bob, mesh: Mesh) -> []u32 {
	return get_slice_data(bob.header.indices, bob.data)
}

get_vertices :: proc {
	get_vertices_obj,
	get_vertices_bob,
}
get_vertices_obj :: proc(obj: Obj) -> []Vertex {
	return obj.vertices[:]
}
get_vertices_bob :: proc(bob: Bob) -> []Vertex {
	return get_slice_data(bob.header.vertices, bob.data)
}

get_material_list :: proc {
	bob_get_material_list,
}
bob_get_material_list :: proc(bob: Bob) -> []Material {
	return get_slice_data(bob.header.mtllist, bob.data)
}

find_material_by_mesh :: proc {
	bob_find_material_mesh,
	bob_find_material_mesh_index,
	obj_find_material_mesh,
}
obj_find_material_mesh :: proc(obj: Obj, mesh: Mesh) -> (m: Material, found: bool) {
	name := get_slice_string(mesh.material, obj.strings[:])

	for material in obj.materials {
		if get_slice_string(material.strings[.name], obj.strings[:]) == name {
			return material, true
		}
	}

	return {}, false
}
bob_find_material_mesh_index :: proc(bob: Bob, mesh_index: int) -> (m: Material, found: bool) {
	return bob_find_material_mesh(bob, get_meshes(bob)[mesh_index])
}
bob_find_material_mesh :: proc(bob: Bob, mesh: Mesh) -> (m: Material, found: bool) {
	name := get_slice_string(mesh.material, bob.data)

	for material in get_material_list(bob) {
		if get_slice_string(material.strings[.name], bob.data) == name {
			return material, true
		}
	}

	return {}, false
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
//
//
//
//
//
