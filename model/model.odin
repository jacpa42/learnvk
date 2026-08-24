package model

destroy :: proc {
	obj_destroy,
	bob_destroy,
}

load :: proc {
	bob_load,
	obj_load,
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
get_meshes_bob :: proc(bob: Bob) -> []Mesh {
	return get_slice_data(bob.header.meshes, bob.data)
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

get_faces :: proc {
	get_faces_obj,
	get_faces_bob,
}
get_faces_obj :: proc(obj: Obj) -> []Face {
	return obj.faces[:]
}
get_faces_bob :: proc(bob: Bob) -> []Face {
	return get_slice_data(bob.header.faces, bob.data)
}


get_vertices :: proc {
	get_vertices_obj,
	get_vertices_bob,
}
get_vertices_obj :: proc(obj: Obj) -> []f32 {
	return obj.vertices[:]
}
get_vertices_bob :: proc(bob: Bob) -> []f32 {
	return get_slice_data(bob.header.vertices, bob.data)
}

get_normals :: proc {
	get_normals_obj,
	get_normals_bob,
}
get_normals_obj :: proc(obj: Obj) -> []f32 {
	return obj.normals[:]
}
get_normals_bob :: proc(bob: Bob) -> []f32 {
	return get_slice_data(bob.header.normals, bob.data)
}

get_texcoords :: proc {
	get_texcoords_obj,
	get_texcoords_bob,
}
get_texcoords_obj :: proc(obj: Obj) -> []f32 {
	return obj.texcoords[:]
}
get_texcoords_bob :: proc(bob: Bob) -> []f32 {
	return get_slice_data(bob.header.texcoords, bob.data)
}

get_material_list :: proc {
	bob_get_material_list,
}
bob_get_material_list :: proc(bob: Bob) -> []Material {
	return get_slice_data(bob.header.mtllist, bob.data)
}

find_material_by_mesh :: proc {
	bob_find_material_mesh,
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
