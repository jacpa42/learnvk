package model

import "core:strings"

MAX_POINTS_PER_FACE :: 8

FLOATS_PER_VERTEX :: 3
FLOATS_PER_NORMAL :: 3
FLOATS_PER_TEXCOORD :: 2
FLOATS_PER_POINT :: FLOATS_PER_VERTEX + FLOATS_PER_NORMAL + FLOATS_PER_TEXCOORD

ENABLE_DEBUG_PRINTING :: false
PADDING_BYTES: [8]u8
BOB_ALIGN :: align_of(u32)

Bob :: struct {
	header: BobHeader,
	data:   []u8,
}

Slice :: struct($T: typeid) {
	start, size: u32,
}

BobHeader :: struct #align (BOB_ALIGN) {
	corner:    [3]f32,
	dim:       [3]f32,
	// Slices of the data chunk. Offsets are from the start of the file
	strings:   Slice(byte),
	mtllist:   Slice(Material),
	meshes:    Slice(Mesh),
	vertices:  Slice(f32),
	normals:   Slice(f32),
	texcoords: Slice(f32),
	faces:     Slice(Face),
}


PointIndex :: enum {
	vertex,
	texcoord,
	normal,
}

UnsignedPoint :: [PointIndex]u32
SignedPoint :: [PointIndex]i32
Face :: distinct [3]UnsignedPoint
Vertex :: distinct [3]f32
Normal :: distinct [3]f32
TexCoord :: distinct [2]f32

Point :: [FLOATS_PER_POINT]f32

Obj :: struct {
	header:    struct {
		corner, dim: [3]f32,
	},
	// essentially an arena for our string data
	strings:   [dynamic]byte,

	// Meshes and materials
	meshes:    [dynamic]Mesh,
	materials: [dynamic]Material,

	// The points
	points:    [dynamic]Point,
	// The indicies for the triangles
	indices:   [dynamic]u32,
}

Mesh :: struct #packed {
	material:                 Slice(byte),
	name:                     Slice(byte),
	faces_start, faces_count: u32,
}

@(private)
ParsedFace :: struct {
	points_len: u32,
	points:     struct #raw_union {
		unsigned: [MAX_POINTS_PER_FACE]UnsignedPoint,
		signed:   [MAX_POINTS_PER_FACE]SignedPoint,
	},
}

@(private)
BobCreateContext :: struct {
	// specify this field to make sure that all slices are aligned to this value
	size: int,
	data: [dynamic; 32][]byte,
}


Mtl :: struct {
	strings:   ^[dynamic]byte,
	materials: ^[dynamic]Material,
}

MaterialString :: enum {
	name,
	map_Kd, // diffuse
	map_Ks, // specular
	map_Ke, // emissive
	map_Ka, // ambient
	map_d, // alpha / dissolve
	map_bump, // normal
}

Material :: struct #packed {
	strings:            [MaterialString]Slice(byte),
	illum:              Illumination,
	Ns, Ni, d, Tr:      f32,
	Tf, Ka, Kd, Ks, Ke: [3]f32,
}

Illumination :: enum u32 {
	Color_on_and_Ambient_off                                           = 0,
	Color_on_and_Ambient_on                                            = 1,
	Highlight_on                                                       = 2,
	Reflection_on_and_Ray_trace_on                                     = 3,
	Transparency_Glass_on_Reflection_Ray_trace_on                      = 4,
	Reflection_Fresnel_on_and_Ray_trace_on                             = 5,
	Transparency_Refraction_on_Reflection_Fresnel_off_and_Ray_trace_on = 6,
	Transparency_Refraction_on_Reflection_Fresnel_on_and_Ray_trace_on  = 7,
	Reflection_on_and_Ray_trace_off                                    = 8,
	Transparency_Glass_on_Reflection_Ray_trace_off                     = 9,
	Casts_shadows_onto_invisible_surfaces                              = 10,
}
