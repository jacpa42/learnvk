package model

destroy :: proc {
	obj_destroy,
	bob_destroy,
	mtl_destroy,
}

load :: proc {
	obj_load,
	bob_load,
	mtl_load,
}

get_meshes :: proc {
	get_meshes_bob,
	get_meshes_obj,
}
get_meshes_bob :: proc(bob: Bob) -> []Mesh {
	return bob_get_slice(bob, bob.header.meshes)
}
get_meshes_obj :: proc(obj: Obj) -> []Mesh {
	return obj.meshes[:]
}

get_faces :: proc {
	get_faces_obj,
	get_faces_bob,
}
get_faces_obj :: proc(obj: Obj) -> []Face {
	return obj.faces[:]
}
get_faces_bob :: proc(bob: Bob) -> []Face {
	return bob_get_slice(bob, bob.header.faces)
}


get_vertices :: proc {
	get_vertices_obj,
	get_vertices_bob,
}
get_vertices_obj :: proc(obj: Obj) -> []f32 {
	return obj.vertices[:]
}
get_vertices_bob :: proc(bob: Bob) -> []f32 {
	return bob_get_slice(bob, bob.header.vertices)
}

get_normals :: proc {
	get_normals_obj,
	get_normals_bob,
}
get_normals_obj :: proc(obj: Obj) -> []f32 {
	return obj.normals[:]
}
get_normals_bob :: proc(bob: Bob) -> []f32 {
	return bob_get_slice(bob, bob.header.normals)
}

get_texcoords :: proc {
	get_texcoords_obj,
	get_texcoords_bob,
}
get_texcoords_obj :: proc(obj: Obj) -> []f32 {
	return obj.texcoords[:]
}
get_texcoords_bob :: proc(bob: Bob) -> []f32 {
	return bob_get_slice(bob, bob.header.texcoords)
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
