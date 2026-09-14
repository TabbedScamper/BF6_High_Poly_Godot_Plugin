// BF6 Oodle shim — the ONLY thing Godot cannot already do for itself.
//
// The plugin needs to read the game's own containers: layout.toc, the
// SuperBundle TOCs, the CAS files, the bundles inside them. All of that is
// byte manipulation, and GDScript does byte manipulation perfectly well with
// FileAccess and PackedByteArray. Exactly one step is impossible there: the
// payloads are Oodle Kraken compressed, and Godot ships FastLZ, Deflate, Zstd,
// gzip and Brotli — not Kraken.
//
// So this extension is deliberately one function wide. Everything else stays
// in GDScript where it can be read, fixed and stepped through without a
// compiler. A large native library would have been the natural shape to reach
// for and would have put the whole container reader behind a build step for no
// gain.
//
// LICENSING, which decides the design: Oodle is proprietary and we do not ship
// it. oo2core_9_win64.dll is already installed as part of Battlefield 6, and
// this loads it FROM THE USER'S OWN GAME DIRECTORY at runtime. Nothing
// proprietary is redistributed, linked, or vendored — the same rule fb_cas.py
// follows on the Python side.
//
// Written against the raw GDExtension C interface rather than godot-cpp: the
// surface here is two methods, and a source dependency that has to be cloned
// and built would outweigh the binding code it saves.

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <string>
#include <vector>
#include <mutex>
#include <stdexcept>
#include <type_traits>
// For the cell merge below: a hash map and a growable buffer. The merge cannot
// know its output size in advance - that is the whole point of welding - so it
// accumulates in std::vector and copies into the PackedByteArray once at the
// end, rather than reserving the worst case, which would be the 4.6 GB this
// design exists to avoid.
#include <cmath>
#include <unordered_map>
#include <climits>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "gdextension_interface.h"
#include "bf6_core.h"
#include "bf6_ocean_replay.h"
#include "bf6_cache_identity.h"

// GDE_EXPORT lives in godot-cpp, which this deliberately does not use, so the
// one macro it would have supplied is spelled out here.
#ifndef GDE_EXPORT
#define GDE_EXPORT __declspec(dllexport)
#endif

// ---------------------------------------------------------------- interface

static GDExtensionInterfaceGetProcAddress g_get_proc = nullptr;
static GDExtensionClassLibraryPtr g_library = nullptr;

static GDExtensionInterfaceStringNameNewWithLatin1Chars sn_new = nullptr;
static GDExtensionInterfaceStringNewWithUtf8Chars string_new_utf8 = nullptr;
static GDExtensionInterfaceClassdbRegisterExtensionClass4 classdb_register = nullptr;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod classdb_method = nullptr;
static GDExtensionInterfaceMemAlloc mem_alloc = nullptr;
static GDExtensionInterfaceMemFree mem_free = nullptr;
static GDExtensionInterfaceVariantGetPtrDestructor get_destructor = nullptr;
static GDExtensionInterfaceGetVariantFromTypeConstructor get_variant_from = nullptr;
static GDExtensionInterfaceGetVariantToTypeConstructor get_variant_to = nullptr;
static GDExtensionInterfacePackedByteArrayOperatorIndex pba_index = nullptr;
static GDExtensionInterfacePackedByteArrayOperatorIndexConst pba_index_const = nullptr;
static GDExtensionPtrConstructor pba_ctor = nullptr;
static GDExtensionPtrDestructor pba_dtor = nullptr;
static GDExtensionPtrBuiltInMethod pba_resize = nullptr;
static GDExtensionPtrBuiltInMethod pba_size = nullptr;
static GDExtensionInterfacePackedFloat32ArrayOperatorIndex pfa_index = nullptr;
static GDExtensionPtrConstructor pfa_ctor = nullptr;
static GDExtensionPtrDestructor pfa_dtor = nullptr;
static GDExtensionPtrBuiltInMethod pfa_resize = nullptr;
static GDExtensionPtrBuiltInMethod pfa_size = nullptr;
static GDExtensionPtrConstructor string_ctor_from_sn = nullptr;

template <typename T>
static T load(const char *name) {
	return reinterpret_cast<T>(g_get_proc(name));
}

// ------------------------------------------------------------------- oodle

typedef intptr_t (*OodleLZ_Decompress_t)(
		const void *src, intptr_t srcLen, void *dst, intptr_t dstLen,
		int fuzz, int crc, int verbose,
		void *dstBase, intptr_t dstSize, void *cb, void *cbCtx,
		void *scratch, intptr_t scratchSize, int threadPhase);

static HMODULE g_oodle = nullptr;
static OodleLZ_Decompress_t g_decompress = nullptr;
static std::string g_last_error;

static bool oodle_open(const std::string &game_dir) {
	if (g_decompress) {
		return true;
	}
	std::string dll = game_dir;
	if (!dll.empty() && dll.back() != '\\' && dll.back() != '/') {
		dll += "\\";
	}
	dll += "oo2core_9_win64.dll";
	g_oodle = LoadLibraryA(dll.c_str());
	if (!g_oodle) {
		g_last_error = "cannot load " + dll +
				" (it ships with Battlefield 6; this never bundles a copy)";
		return false;
	}
	g_decompress = reinterpret_cast<OodleLZ_Decompress_t>(
			GetProcAddress(g_oodle, "OodleLZ_Decompress"));
	if (!g_decompress) {
		g_last_error = "OodleLZ_Decompress missing from " + dll;
		FreeLibrary(g_oodle);
		g_oodle = nullptr;
		return false;
	}
	g_last_error.clear();
	return true;
}

// ------------------------------------------------------------- the class

struct BF6Oodle {
	// no per-instance state: the DLL handle is process-wide
};

// create_instance_func must hand back a GODOT OBJECT, not our own allocation.
// Returning the bare struct compiles, registers, and then fails at
// ClassDB.instantiate() with a null — the class exists but cannot be built,
// which reads like a registration problem and is not one. The object has to be
// constructed as the PARENT class and then told which extension instance backs
// it.
static GDExtensionInterfaceClassdbConstructObject2 construct_object = nullptr;
static GDExtensionInterfaceObjectSetInstance object_set_instance = nullptr;

static void *bf6_create(void *, GDExtensionBool) {
	uint8_t parent[16] = {}, self_name[16] = {};
	sn_new(&parent, "RefCounted", false);
	sn_new(&self_name, "BF6Oodle", false);
	GDExtensionObjectPtr obj = construct_object(&parent);
	BF6Oodle *self = static_cast<BF6Oodle *>(mem_alloc(sizeof(BF6Oodle)));
	object_set_instance(obj, &self_name, self);
	return obj;
}

static void bf6_free(void *, void *instance) {
	if (instance) {
		mem_free(instance);
	}
}

// open(game_dir: String) -> bool
static void call_open(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *err) {
	(void)err;
	bool ok = false;
	if (argc >= 1) {
		// Variant(String) -> utf8 via the string interface
		static GDExtensionInterfaceStringToUtf8Chars to_utf8 =
				load<GDExtensionInterfaceStringToUtf8Chars>("string_to_utf8_chars");
		static GDExtensionTypeFromVariantConstructorFunc to_string =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_STRING);
		alignas(8) uint8_t sbuf[64] = {};
		to_string(&sbuf, const_cast<GDExtensionVariantPtr>(args[0]));
		GDExtensionInt need = to_utf8(&sbuf, nullptr, 0);
		std::string path(static_cast<size_t>(need), '\0');
		if (need > 0) {
			to_utf8(&sbuf, path.data(), need);
		}
		get_destructor(GDEXTENSION_VARIANT_TYPE_STRING)(&sbuf);
		ok = oodle_open(path);
	}
	GDExtensionBool v = ok;
	get_variant_from(GDEXTENSION_VARIANT_TYPE_BOOL)(ret, &v);
}

// decompress(src: PackedByteArray, out_size: int) -> PackedByteArray
// Empty on failure, which the caller must treat as an error rather than as
// "this block was empty" — a silent empty here would show up much later as a
// mesh with no vertices.
static void call_decompress(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *err) {
	(void)err;
	alignas(8) uint8_t out[16] = {};
	pba_ctor(&out, nullptr);

	if (argc >= 2 && g_decompress) {
		static GDExtensionTypeFromVariantConstructorFunc to_pba =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		static GDExtensionTypeFromVariantConstructorFunc to_int =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);

		alignas(8) uint8_t src[16] = {};
		to_pba(&src, const_cast<GDExtensionVariantPtr>(args[0]));
		int64_t want = 0;
		to_int(&want, const_cast<GDExtensionVariantPtr>(args[1]));

		int64_t src_len = 0;
		pba_size(&src, nullptr, &src_len, 0);

		if (want > 0 && src_len > 0) {
			int64_t resize_to = want;
			GDExtensionInt rc = 0;
			const void *rargs[1] = { &resize_to };
			pba_resize(&out, rargs, &rc, 1);

			// src is read-only, so it takes the const index for the same reason
			// find() does — the mutable one would copy the compressed block
			// before every decompression.
			const uint8_t *sp = pba_index_const(&src, 0);
			uint8_t *dp = pba_index(&out, 0);
			if (sp && dp) {
				// Same arguments as fb_cas.py: fuzzSafe=1, checkCRC=0,
				// verbosity=0, and threadPhase=3 (Unthreaded). The last one
				// matters — passing 0 asks Oodle for a threaded phase and the
				// two readers would stop agreeing on the same bytes.
				intptr_t got = g_decompress(sp, (intptr_t)src_len, dp,
						(intptr_t)want, 1, 0, 0,
						nullptr, 0, nullptr, nullptr, nullptr, 0, 3);
				if (got != (intptr_t)want) {
					// Truncate to nothing rather than hand back a partly
					// written buffer that looks like data.
					int64_t zero = 0;
					const void *zargs[1] = { &zero };
					pba_resize(&out, zargs, &rc, 1);
				}
			}
		}
	}
	get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
	pba_dtor(&out);
}

// last_error() -> String
static void call_last_error(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *, GDExtensionInt,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	alignas(8) uint8_t s[16] = {};
	string_new_utf8(&s, g_last_error.c_str());
	get_variant_from(GDEXTENSION_VARIANT_TYPE_STRING)(ret, &s);
	get_destructor(GDEXTENSION_VARIANT_TYPE_STRING)(&s);
}

// find(hay: PackedByteArray, needle: PackedByteArray, from: int, to: int) -> int
//
// A substring search over a PackedByteArray, which GDScript has no way to do
// except by looping in script.
//
// This is here for ONE caller and it is not a convenience. Resolving a
// Frostbite type means locating its 16-byte GUID inside the exe's `typeinfo`
// section — 5.3 MB — and a level traversal resolves hundreds of types. In
// GDScript that is a per-byte loop over five million bytes, hundreds of times;
// in C++ it is memchr plus a memcmp on the rare hit.
//
// The alternative was shipping a pre-generated type database, which would have
// put a downloaded file back in the middle of a plugin whose whole point is
// reading the install. The type data is IN the game exe; this is what makes
// reading it there affordable.
//
// -1 when absent. `to` clamps to the array end, so a caller can pass a section
// bound without checking it first.
static void call_find(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	int64_t found = -1;
	if (argc >= 2) {
		static GDExtensionTypeFromVariantConstructorFunc to_pba =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		static GDExtensionTypeFromVariantConstructorFunc to_int =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);

		alignas(8) uint8_t hay[16] = {}, ndl[16] = {};
		to_pba(&hay, const_cast<GDExtensionVariantPtr>(args[0]));
		to_pba(&ndl, const_cast<GDExtensionVariantPtr>(args[1]));
		int64_t from = 0, to = -1;
		if (argc >= 3) {
			to_int(&from, const_cast<GDExtensionVariantPtr>(args[2]));
		}
		if (argc >= 4) {
			to_int(&to, const_cast<GDExtensionVariantPtr>(args[3]));
		}

		int64_t hlen = 0, nlen = 0;
		pba_size(&hay, nullptr, &hlen, 0);
		pba_size(&ndl, nullptr, &nlen, 0);
		if (to < 0 || to > hlen) {
			to = hlen;
		}
		if (from < 0) {
			from = 0;
		}
		if (nlen > 0 && to - from >= nlen) {
			// CONST INDEX, and the distinction is not cosmetic. The mutable
			// operator index calls ptrw(), which on a copy-on-write array with
			// more than one reference DUPLICATES IT — so every search over the
			// 169 MB exe was memcpy'ing 169 MB first. Measured 25 ms per search
			// of a 5.3 MB section, which is memcpy speed for the whole file
			// rather than memchr speed for the section.
			const uint8_t *hp = pba_index_const(&hay, 0);
			const uint8_t *np = pba_index_const(&ndl, 0);
			if (hp && np) {
				const uint8_t *p = hp + from;
				const uint8_t *end = hp + to - nlen + 1;
				while (p < end) {
					const uint8_t *hit = (const uint8_t *)memchr(
							p, np[0], (size_t)(end - p));
					if (!hit) {
						break;
					}
					if (memcmp(hit, np, (size_t)nlen) == 0) {
						found = (int64_t)(hit - hp);
						break;
					}
					p = hit + 1;
				}
			}
		}
		get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&hay);
		get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&ndl);
	}
	get_variant_from(GDEXTENSION_VARIANT_TYPE_INT)(ret, &found);
}

// ------------------------------------------------------------- cell merge
//
// MERGE AND WELD A MAP CELL'S PROPS INTO ONE MESH. The second thing Godot
// cannot do fast enough for us, and the reason is measured rather than assumed:
// welding the densest cell in GDScript takes 33 s, and the whole map about 22
// minutes, because each of 65.9 M vertices costs an interpreted transform plus
// a Dictionary lookup. Threading it was tried and DEADLOCKS - inside the editor
// WorkerThreadPool.wait_for_task_completion never returns - so the loop has to
// get cheaper rather than more parallel.
//
// EVERYTHING CROSSES AS ONE PackedByteArray, both directions, and that is a
// design choice rather than laziness. Marshalling PackedVector3Array through
// the raw GDExtension C interface needs per-type index and resize bindings, and
// resize is a builtin looked up by a VERSION-SPECIFIC HASH; hardcoding those
// breaks the extension on a Godot update in a way that is painful to diagnose.
// PackedByteArray marshalling already exists here and is already proven. On the
// GDScript side to_byte_array() and to_float32_array() are memcpys rather than
// loops, so packing costs nothing worth measuring next to the merge.
//
// in   'BF6M' u32, version u32, weld f32, origin f32[3], chunks u32
//      per chunk: vc u32, ic u32, inst u32, rgba u32,
//                 verts f32[3*vc], normals f32[3*vc], indices u32[ic],
//                 transforms f32[12*inst]  (three basis COLUMNS then the
//                 origin, which is exactly what basis.x/.y/.z give you)
// out  vc u32, ic u32, verts f32[3*vc], normals f32[3*vc],
//      colours u8[4*vc], indices u32[ic]
//
// An empty return means malformed input or nothing to draw. The caller treats
// that as "do not bake this cell" rather than an error: a cell with no drawable
// geometry is a normal thing to meet.

struct MergeKey {
	int32_t x, y, z;
	uint32_t c;
	bool operator==(const MergeKey &o) const {
		return x == o.x && y == o.y && z == o.z && c == o.c;
	}
};

struct MergeKeyHash {
	size_t operator()(const MergeKey &k) const {
		// Quantised coordinates are small and strongly correlated between
		// neighbouring vertices, so a plain xor collides badly enough to turn
		// the map into a linked list.
		uint64_t h = 1469598103934665603ULL;
		auto mix = [&h](uint64_t v) {
			h ^= v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
		};
		mix((uint64_t)(uint32_t)k.x);
		mix((uint64_t)(uint32_t)k.y);
		mix((uint64_t)(uint32_t)k.z);
		mix((uint64_t)k.c);
		return (size_t)h;
	}
};

static inline uint32_t rd_u32(const uint8_t *p) {
	uint32_t v; memcpy(&v, p, 4); return v;
}

static inline float rd_f32(const uint8_t *p) {
	float v; memcpy(&v, p, 4); return v;
}

static void call_merge_cell(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *err) {
	(void)err;
	alignas(8) uint8_t out[16] = {};
	pba_ctor(&out, nullptr);

	if (argc >= 1) {
		static GDExtensionTypeFromVariantConstructorFunc to_pba =
				get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		alignas(8) uint8_t src[16] = {};
		to_pba(&src, const_cast<GDExtensionVariantPtr>(args[0]));

		int64_t src_len = 0;
		pba_size(&src, nullptr, &src_len, 0);
		const uint8_t *b = src_len > 0 ? pba_index_const(&src, 0) : nullptr;

		if (b && src_len >= 28 && rd_u32(b) == 0x4D364642u /* 'BF6M' */) {
			size_t at = 8;
			const float weld = rd_f32(b + at); at += 4;
			const float ox = rd_f32(b + at); at += 4;
			const float oy = rd_f32(b + at); at += 4;
			const float oz = rd_f32(b + at); at += 4;
			const uint32_t chunks = rd_u32(b + at); at += 4;
			const float inv_w = weld > 0.0f ? 1.0f / weld : 0.0f;

			std::vector<float> ov, on;
			std::vector<uint8_t> oc;
			std::vector<uint32_t> oi;
			std::unordered_map<MergeKey, uint32_t, MergeKeyHash> wmap;
			wmap.reserve(1u << 16);
			std::vector<uint32_t> remap;
			bool ok = true;

			for (uint32_t ci = 0; ci < chunks && ok; ++ci) {
				if (at + 16 > (size_t)src_len) { ok = false; break; }
				const uint32_t vc = rd_u32(b + at); at += 4;
				const uint32_t ic = rd_u32(b + at); at += 4;
				const uint32_t inst = rd_u32(b + at); at += 4;
				const uint32_t rgba = rd_u32(b + at); at += 4;
				const size_t need = (size_t)vc * 24 + (size_t)ic * 4
						+ (size_t)inst * 48;
				if (at + need > (size_t)src_len) { ok = false; break; }
				const uint8_t *pv = b + at; at += (size_t)vc * 12;
				const uint8_t *pn = b + at; at += (size_t)vc * 12;
				const uint8_t *pi = b + at; at += (size_t)ic * 4;
				const uint8_t *pt = b + at; at += (size_t)inst * 48;

				const uint8_t cr = (uint8_t)(rgba & 0xFF);
				const uint8_t cg = (uint8_t)((rgba >> 8) & 0xFF);
				const uint8_t cb = (uint8_t)((rgba >> 16) & 0xFF);
				const uint8_t ca = (uint8_t)((rgba >> 24) & 0xFF);
				// 5 bits a channel in the KEY, matching the GDScript version:
				// two props of different colours must not weld together, but
				// neighbouring shades of one prop should.
				const uint32_t ckey = (uint32_t)((cr >> 3) << 10)
						| (uint32_t)((cg >> 3) << 5) | (uint32_t)(cb >> 3);

				for (uint32_t k = 0; k < inst; ++k) {
					const uint8_t *tp = pt + (size_t)k * 48;
					const float bx0 = rd_f32(tp + 0), bx1 = rd_f32(tp + 4), bx2 = rd_f32(tp + 8);
					const float by0 = rd_f32(tp + 12), by1 = rd_f32(tp + 16), by2 = rd_f32(tp + 20);
					const float bz0 = rd_f32(tp + 24), bz1 = rd_f32(tp + 28), bz2 = rd_f32(tp + 32);
					const float tx = rd_f32(tp + 36), ty = rd_f32(tp + 40), tz = rd_f32(tp + 44);
					// A parked (zero scale) instance draws nothing, and adding
					// it would collapse its triangles onto a point.
					const float det = bx0 * (by1 * bz2 - by2 * bz1)
							- by0 * (bx1 * bz2 - bx2 * bz1)
							+ bz0 * (bx1 * by2 - bx2 * by1);
					if (det == 0.0f) continue;

					remap.assign(vc, 0u);
					for (uint32_t vi = 0; vi < vc; ++vi) {
						const float sx = rd_f32(pv + (size_t)vi * 12 + 0);
						const float sy = rd_f32(pv + (size_t)vi * 12 + 4);
						const float sz = rd_f32(pv + (size_t)vi * 12 + 8);
						const float wx = bx0 * sx + by0 * sy + bz0 * sz + tx - ox;
						const float wy = bx1 * sx + by1 * sy + bz1 * sz + ty - oy;
						const float wz = bx2 * sx + by2 * sy + bz2 * sz + tz - oz;

						if (inv_w > 0.0f) {
							MergeKey key;
							// roundf, NOT lrintf. GDScript's round() rounds half
							// AWAY FROM ZERO; lrintf follows the current FPU
							// mode, which defaults to half-to-EVEN. A vertex
							// sitting exactly on a half-grid boundary then
							// lands in a different cell in each path, and the
							// two merges disagreed by 7 vertices out of 275,973
							// - small, but two implementations of one thing
							// should agree exactly or the fast one cannot be
							// checked against the slow one.
							key.x = (int32_t)roundf(wx * inv_w);
							key.y = (int32_t)roundf(wy * inv_w);
							key.z = (int32_t)roundf(wz * inv_w);
							key.c = ckey;
							auto it = wmap.find(key);
							if (it != wmap.end()) { remap[vi] = it->second; continue; }
							wmap.emplace(key, (uint32_t)(ov.size() / 3));
						}
						const uint32_t idx = (uint32_t)(ov.size() / 3);
						const float nx = rd_f32(pn + (size_t)vi * 12 + 0);
						const float ny = rd_f32(pn + (size_t)vi * 12 + 4);
						const float nz = rd_f32(pn + (size_t)vi * 12 + 8);
						float rx = bx0 * nx + by0 * ny + bz0 * nz;
						float ry = bx1 * nx + by1 * ny + bz1 * nz;
						float rz = bx2 * nx + by2 * ny + bz2 * nz;
						const float len = sqrtf(rx * rx + ry * ry + rz * rz);
						if (len > 1e-8f) { rx /= len; ry /= len; rz /= len; }
						else { rx = 0.0f; ry = 1.0f; rz = 0.0f; }
						ov.push_back(wx); ov.push_back(wy); ov.push_back(wz);
						on.push_back(rx); on.push_back(ry); on.push_back(rz);
						oc.push_back(cr); oc.push_back(cg);
						oc.push_back(cb); oc.push_back(ca);
						remap[vi] = idx;
					}
					if (ic == 0) {
						for (uint32_t vi = 0; vi < vc; ++vi) oi.push_back(remap[vi]);
					} else {
						for (uint32_t j = 0; j + 2 < ic; j += 3) {
							const uint32_t a = rd_u32(pi + (size_t)j * 4);
							const uint32_t b2 = rd_u32(pi + (size_t)(j + 1) * 4);
							const uint32_t c = rd_u32(pi + (size_t)(j + 2) * 4);
							if (a >= vc || b2 >= vc || c >= vc) continue;
							const uint32_t ra = remap[a], rb = remap[b2], rc2 = remap[c];
							// Welding collapses corners wherever detail was
							// finer than the grid. A zero-area triangle still
							// costs index bandwidth and a rasteriser reject.
							if (ra == rb || rb == rc2 || ra == rc2) continue;
							oi.push_back(ra); oi.push_back(rb); oi.push_back(rc2);
						}
					}
				}
			}

			if (ok && !ov.empty()) {
				const uint32_t out_vc = (uint32_t)(ov.size() / 3);
				const uint32_t out_ic = (uint32_t)oi.size();
				const int64_t total = 8 + (int64_t)out_vc * 24
						+ (int64_t)out_vc * 4 + (int64_t)out_ic * 4;
				GDExtensionInt rc = 0;
				const void *rargs[1] = { &total };
				pba_resize(&out, rargs, &rc, 1);
				uint8_t *dp = pba_index(&out, 0);
				if (dp) {
					size_t o = 0;
					memcpy(dp + o, &out_vc, 4); o += 4;
					memcpy(dp + o, &out_ic, 4); o += 4;
					memcpy(dp + o, ov.data(), (size_t)out_vc * 12); o += (size_t)out_vc * 12;
					memcpy(dp + o, on.data(), (size_t)out_vc * 12); o += (size_t)out_vc * 12;
					memcpy(dp + o, oc.data(), (size_t)out_vc * 4);  o += (size_t)out_vc * 4;
					if (out_ic) memcpy(dp + o, oi.data(), (size_t)out_ic * 4);
				}
			}
		}
		get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&src);
	}
	get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
	get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&out);
}

// ----------------------------------------------------------------- the core
//
// BF6Oodle predates the core and remains as the compatibility shim used by the
// GDScript parity readers. New production cuts bind the engine-neutral core
// instead. Start with the smallest complete product (scatter catalogue), prove
// it against the old live reader, then move larger products across the same
// seam. No exported JSON/TSV is read here: the JSON string below is only the
// in-process Godot ABI envelope around rows decoded from the installed game.

struct BF6CoreBinding {
	bf6_ctx *ctx = nullptr;
	std::string last_error;
	std::string environment_level;
	std::recursive_mutex mutex;
	std::vector<bf6_ocean::Cascade> ocean;
	int ocean_time_ms = -1;
	HANDLE preparation_mutex = nullptr;
	bf6_precache *precache = nullptr;   // the shared up-front cache (BF6_High_Poly_Core)
	~BF6CoreBinding() {
		if (precache) bf6_precache_close(precache);
		if (ctx) bf6_close(ctx);
		if (preparation_mutex) { ReleaseMutex(preparation_mutex); CloseHandle(preparation_mutex); }
	}
};

static std::string variant_utf8(GDExtensionConstVariantPtr arg) {
	static GDExtensionInterfaceStringToUtf8Chars to_utf8 =
			load<GDExtensionInterfaceStringToUtf8Chars>("string_to_utf8_chars");
	static GDExtensionTypeFromVariantConstructorFunc to_string =
			get_variant_to(GDEXTENSION_VARIANT_TYPE_STRING);
	alignas(8) uint8_t sbuf[64] = {};
	to_string(&sbuf, const_cast<GDExtensionVariantPtr>(arg));
	GDExtensionInt need = to_utf8(&sbuf, nullptr, 0);
	std::string out(static_cast<size_t>(need > 0 ? need : 0), '\0');
	if (need > 0) to_utf8(&sbuf, out.data(), need);
	get_destructor(GDEXTENSION_VARIANT_TYPE_STRING)(&sbuf);
	return out;
}

static void return_bool(GDExtensionVariantPtr ret, bool value) {
	GDExtensionBool v = value;
	get_variant_from(GDEXTENSION_VARIANT_TYPE_BOOL)(ret, &v);
}

static void return_int(GDExtensionVariantPtr ret, int64_t value) {
	get_variant_from(GDEXTENSION_VARIANT_TYPE_INT)(ret, &value);
}

static void return_string(GDExtensionVariantPtr ret, const std::string &value) {
	alignas(8) uint8_t s[16] = {};
	string_new_utf8(&s, value.c_str());
	get_variant_from(GDEXTENSION_VARIANT_TYPE_STRING)(ret, &s);
	get_destructor(GDEXTENSION_VARIANT_TYPE_STRING)(&s);
}

static void append_json_string(std::string &out, const char *text) {
	out.push_back('"');
	if (text) for (const unsigned char c : std::string(text)) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\b': out += "\\b"; break;
			case '\f': out += "\\f"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20) {
					char escaped[7] = {};
					std::snprintf(escaped, sizeof(escaped), "\\u%04x", (unsigned)c);
					out += escaped;
				} else out.push_back((char)c);
		}
	}
	out.push_back('"');
}

static void *core_create(void *, GDExtensionBool) {
	uint8_t parent[16] = {}, self_name[16] = {};
	sn_new(&parent, "RefCounted", false);
	sn_new(&self_name, "BF6Core", false);
	GDExtensionObjectPtr obj = construct_object(&parent);
	void *storage = mem_alloc(sizeof(BF6CoreBinding));
	BF6CoreBinding *self = new (storage) BF6CoreBinding();
	object_set_instance(obj, &self_name, self);
	return obj;
}

static void core_free(void *, void *instance) {
	if (!instance) return;
	BF6CoreBinding *self = static_cast<BF6CoreBinding *>(instance);
	self->~BF6CoreBinding();
	mem_free(self);
}

// open(game_dir: String) -> bool
static void call_core_open(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	BF6CoreBinding *self = static_cast<BF6CoreBinding *>(instance);
	std::unique_lock<std::recursive_mutex> guard;
	if (self) guard = std::unique_lock<std::recursive_mutex>(self->mutex);
	if (!self || argc < 1) { return_bool(ret, false); return; }
	if (self->ctx) { bf6_close(self->ctx); self->ctx = nullptr; }
	self->environment_level.clear(); self->ocean.clear(); self->ocean_time_ms = -1;
	if (bf6_abi_version() != BF6_ABI_VERSION) {
		self->last_error = "bf6_core ABI mismatch: binding="
				+ std::to_string(BF6_ABI_VERSION) + " runtime="
				+ std::to_string(bf6_abi_version());
		return_bool(ret, false);
		return;
	}
	char err[1024] = {};
	const std::string game_dir = variant_utf8(args[0]);
	self->ctx = bf6_open(game_dir.c_str(), err, (int)sizeof(err));
	self->last_error = self->ctx ? std::string() : std::string(err);
	return_bool(ret, self->ctx != nullptr);
}

static void call_core_last_error(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *, GDExtensionInt,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	BF6CoreBinding *self = static_cast<BF6CoreBinding *>(instance);
	std::unique_lock<std::recursive_mutex> guard;
	if (self) guard = std::unique_lock<std::recursive_mutex>(self->mutex);
	return_string(ret, self ? self->last_error : "BF6Core instance is null");
}

static void call_core_abi_version(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *, GDExtensionInt,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	return_int(ret, bf6_abi_version());
}

// This does not open the decoder. Hosts run the file inspection on a worker.
static void call_core_install_identity(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	if (argc != 1) {
		return_string(ret, "{\"ok\":false,\"error\":\"Expected a game folder\"}");
		return;
	}
	try {
		const auto snapshot = bf6_cache::inspect(std::filesystem::u8path(variant_utf8(args[0])));
		std::string json = snapshot.ok ? "{\"ok\":true" : "{\"ok\":false";
		json += ",\"identity\":"; append_json_string(json, snapshot.identity.c_str());
		json += ",\"root\":"; append_json_string(json, snapshot.root.c_str());
		json += ",\"error\":"; append_json_string(json, snapshot.error.c_str());
		json += ",\"files\":" + std::to_string(snapshot.entry_count()) + ",\"levels\":[";
		std::vector<std::string> levels;
		for (const auto& entry : snapshot.entries) {
			std::string name = entry.path;
			for (char& c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
			const auto start = name.find("/levels/mp_");
			if (start == std::string::npos) continue;
			const auto end = name.find('/', start + 8);
			if (end != std::string::npos) levels.push_back(name.substr(start + 8, end - start - 8));
		}
		std::sort(levels.begin(), levels.end());
		levels.erase(std::unique(levels.begin(), levels.end()), levels.end());
		for (size_t i = 0; i < levels.size(); ++i) {
			if (i) json += ',';
			append_json_string(json, levels[i].c_str());
		}
		return_string(ret, json + "]}");
	} catch (const std::exception& e) {
		std::string json = "{\"ok\":false,\"error\":";
		append_json_string(json, e.what());
		return_string(ret, json + "}");
	}
}

// A worker holds this instance on its main thread until it exits. Windows
// releases ownership after a crash; no stale lock file can block later runs.
static void call_core_preparation_lock(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || argc != 1) { return_bool(ret, false); return; }
	if (self->preparation_mutex) { return_bool(ret, true); return; }
	const std::string key = variant_utf8(args[0]);
	if (key.size() != 64 || key.find_first_not_of("0123456789abcdef") != std::string::npos) {
		return_bool(ret, false); return;
	}
	HANDLE handle = CreateMutexA(nullptr, FALSE, ("Local\\BF6GodotPreparation_" + key).c_str());
	if (!handle) { return_bool(ret, false); return; }
	const DWORD result = WaitForSingleObject(handle, 0);
	if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
		self->preparation_mutex = handle;
		return_bool(ret, true);
	} else { CloseHandle(handle); return_bool(ret, false); }
}

// Query arbitrary processes, including the editor which launched this worker.
// Return -1 for an unavailable query, 0 for exited, and 1 for still running.
static void call_core_process_status(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	if (argc != 1) { return_int(ret, -1); return; }
	int64_t pid = 0;
	get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&pid, const_cast<GDExtensionVariantPtr>(args[0]));
	if (pid <= 0 || pid > UINT32_MAX) { return_int(ret, 0); return; }
	HANDLE handle = OpenProcess(SYNCHRONIZE, FALSE, static_cast<DWORD>(pid));
	if (!handle) { return_int(ret, GetLastError() == ERROR_INVALID_PARAMETER ? 0 : -1); return; }
	const DWORD state = WaitForSingleObject(handle, 0);
	CloseHandle(handle);
	return_int(ret, state == WAIT_TIMEOUT ? 1 : (state == WAIT_OBJECT_0 ? 0 : -1));
}

// scatter(level: String) -> String
// Returns a JSON envelope because the raw GDExtension interface has no stable,
// version-independent Dictionary constructor. This string never touches disk.
static void call_core_scatter(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	BF6CoreBinding *self = static_cast<BF6CoreBinding *>(instance);
	std::unique_lock<std::recursive_mutex> guard;
	if (self) guard = std::unique_lock<std::recursive_mutex>(self->mutex);
	if (!self || !self->ctx || argc < 1) {
		if (self) self->last_error = "BF6Core is not open";
		return_string(ret, "{\"ok\":false,\"error\":\"BF6Core is not open\",\"rows\":[]}");
		return;
	}
	const std::string level = variant_utf8(args[0]);
	char err[1024] = {};
	const int count = bf6_level_scatter(self->ctx, level.c_str(), nullptr, 0,
			err, (int)sizeof(err));
	if (count < 0) {
		self->last_error = err;
		std::string json = "{\"ok\":false,\"error\":";
		append_json_string(json, err);
		json += ",\"rows\":[]}";
		return_string(ret, json);
		return;
	}
	std::vector<bf6_scatter_entry> rows((size_t)count);
	const int got = bf6_level_scatter(self->ctx, level.c_str(),
			rows.empty() ? nullptr : rows.data(), count, err, (int)sizeof(err));
	if (got != count) {
		self->last_error = err[0] ? err : "scatter count changed between calls";
		std::string json = "{\"ok\":false,\"error\":";
		append_json_string(json, self->last_error.c_str());
		json += ",\"rows\":[]}";
		return_string(ret, json);
		return;
	}
	self->last_error.clear();
	std::string json = "{\"ok\":true,\"error\":\"\",\"rows\":[";
	char number[128] = {};
	for (int i = 0; i < got; ++i) {
		if (i) json.push_back(',');
		json += "{\"name\":";
		append_json_string(json, rows[(size_t)i].name);
		json += ",\"mesh\":";
		append_json_string(json, rows[(size_t)i].mesh_res);
		std::snprintf(number, sizeof(number),
				",\"distance\":%.9g,\"ratio\":%.9g,\"point_count\":%d}",
				(double)rows[(size_t)i].view_distance,
				(double)rows[(size_t)i].dissolve_ratio,
				rows[(size_t)i].point_count);
		json += number;
	}
	json += "]}";
	return_string(ret, json);
}

// lighting_zones(level: String) -> String
// Exact installed-game AreaProximity.Geometry shapes. The envelope includes
// the real-link and rotated-source control scores so a consumer can reject a
// plausible empty or misjoined result rather than merely drawing it.
static void call_core_lighting_zones(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	BF6CoreBinding *self = static_cast<BF6CoreBinding *>(instance);
	std::unique_lock<std::recursive_mutex> guard;
	if (self) guard = std::unique_lock<std::recursive_mutex>(self->mutex);
	if (!self || !self->ctx || argc < 1) {
		if (self) self->last_error = "BF6Core is not open";
		return_string(ret, "{\"ok\":false,\"error\":\"BF6Core is not open\",\"rows\":[]}");
		return;
	}
	const std::string level = variant_utf8(args[0]);
	char err[1024] = {};
	bf6_lighting_zone_stats stats = {};
	const int count = bf6_level_lighting_zones(self->ctx, level.c_str(),
			nullptr, 0, &stats, err, (int)sizeof(err));
	if (count == 0 && err[0]) {
		self->last_error = err;
		std::string json = "{\"ok\":false,\"error\":";
		append_json_string(json, err);
		json += ",\"rows\":[]}";
		return_string(ret, json);
		return;
	}
	std::vector<bf6_lighting_zone> rows((size_t)count);
	err[0] = 0;
	const int got = bf6_level_lighting_zones(self->ctx, level.c_str(),
			rows.empty() ? nullptr : rows.data(), count, nullptr,
			err, (int)sizeof(err));
	if (got != count) {
		self->last_error = err[0] ? err : "lighting-zone count changed between calls";
		std::string json = "{\"ok\":false,\"error\":";
		append_json_string(json, self->last_error.c_str());
		json += ",\"rows\":[]}";
		return_string(ret, json);
		return;
	}

	self->last_error.clear();
	char number[512] = {};
	std::snprintf(number, sizeof(number),
			"{\"ok\":true,\"error\":\"\",\"stats\":{"
			"\"total\":%d,\"obb\":%d,\"polygon\":%d,"
			"\"partitions\":%d,\"instances\":%d,\"proximity\":%d,"
			"\"shape_links\":%d,\"non_geometry_links\":%d,"
			"\"non_shape_geometry_links\":%d,\"target_other\":%d,"
			"\"joined_preset\":%d,\"omitted_no_preset\":%d,"
			"\"rotated_control_hits\":%d,\"parse_fail\":%d,"
			"\"missing\":%d,\"malformed_shape\":%d,"
			"\"unresolved_types\":%d},\"rows\":[",
			stats.total, stats.obb, stats.polygon, stats.partitions,
			stats.instances, stats.proximity, stats.shape_links,
			stats.non_geometry_links, stats.non_shape_geometry_links,
			stats.target_other, stats.joined_preset, stats.omitted_no_preset,
			stats.rotated_control_hits, stats.parse_fail, stats.missing,
			stats.malformed_shape, stats.unresolved_types);
	std::string json = number;
	for (int i = 0; i < got; ++i) {
		const bf6_lighting_zone &z = rows[(size_t)i];
		if (i) json.push_back(',');
		std::snprintf(number, sizeof(number),
				"{\"kind\":%d,\"xform\":[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,"
				"%.9g,%.9g,%.9g,%.9g,%.9g,%.9g],"
				"\"half_extents\":[%.9g,%.9g,%.9g],\"height\":%.9g,"
				"\"fade_distance\":%.9g,\"proximity_instance\":%d,"
				"\"shape_instance\":%d,\"preset\":",
				z.kind,
				(double)z.xform[0], (double)z.xform[1], (double)z.xform[2],
				(double)z.xform[3], (double)z.xform[4], (double)z.xform[5],
				(double)z.xform[6], (double)z.xform[7], (double)z.xform[8],
				(double)z.xform[9], (double)z.xform[10], (double)z.xform[11],
				(double)z.half_extents[0], (double)z.half_extents[1],
				(double)z.half_extents[2], (double)z.height,
				(double)z.fade_distance, z.proximity_instance, z.shape_instance);
		json += number;
		append_json_string(json, z.preset);
		json += ",\"source\":";
		append_json_string(json, z.source);
		json += ",\"points\":[";
		for (int p = 0; p < z.point_count; ++p) {
			if (p) json.push_back(',');
			std::snprintf(number, sizeof(number), "[%.9g,%.9g,%.9g]",
					(double)z.points[p * 3 + 0], (double)z.points[p * 3 + 1],
					(double)z.points[p * 3 + 2]);
			json += number;
		}
		json += "]}";
	}
	json += "]}";
	return_string(ret, json);
}


// decode_vertex_attribute(buffer, first, stride, count, format) -> PackedFloat32Array.
// A single bulk call into the shared reader; no game context or scene access.
// The source uses the CONST PackedByteArray accessor to avoid copy-on-write of
// the entire geometry chunk. The core writes directly into Godot's float array,
// avoiding an intermediate byte array and a second full-size float copy.
static void call_core_decode_vertex_attribute(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *error) {
    alignas(8) uint8_t output[16] = {};
    pfa_ctor(&output, nullptr);
    bool valid = argc == 5;
    if (error) {
        error->error = valid ? GDEXTENSION_CALL_OK : (argc < 5
            ? GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS : GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS);
        error->argument = 0;
        error->expected = 5;
    }
    if (valid) {
        static auto type_of = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
        for (int i = 0; i < 5; ++i) {
            const auto expected = i == 0 ? GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY : GDEXTENSION_VARIANT_TYPE_INT;
            if (type_of(args[i]) != expected) {
                valid = false;
                if (error) { error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
                    error->argument = i; error->expected = expected; }
                break;
            }
        }
    }
    if (valid) {
        static auto to_pba = get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
        static auto to_int = get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);
        alignas(8) uint8_t source[16] = {};
        to_pba(&source, const_cast<GDExtensionVariantPtr>(args[0]));
        int64_t values[4] = {};
        for (int i = 0; i < 4; ++i) to_int(&values[i], const_cast<GDExtensionVariantPtr>(args[i + 1]));
        int64_t bytes = 0;
        pba_size(&source, nullptr, &bytes, 0);
        if (bytes > 0 && values[2] > 0 && values[2] <= INT_MAX
            && values[3] >= 0 && values[3] <= INT_MAX) {
            const uint8_t *input = pba_index_const(&source, 0);
            const int comps = bf6_decode_vertex_attribute(input, bytes, values[0],
                values[1], int32_t(values[2]), int32_t(values[3]), nullptr, 0);
            const int64_t floats = values[2] * comps;
            // Bound a single binding allocation. Larger inputs use the script
            // fallback rather than risking an unbounded native allocation.
            if (comps && floats <= (256 * 1024 * 1024)) {
                int64_t length = floats;
                const void *resize_args[1] = { &length };
                GDExtensionInt rc = 0;
                pfa_resize(&output, resize_args, &rc, 1);
                int64_t actual = 0;
                pfa_size(&output, nullptr, &actual, 0);
                if (actual == length) {
                    float *destination = pfa_index(&output, 0);
                    const int got = destination ? bf6_decode_vertex_attribute(input, bytes, values[0],
                        values[1], int32_t(values[2]), int32_t(values[3]), destination, floats) : 0;
                    if (got != comps) {
                        int64_t zero = 0;
                        const void *clear_args[1] = { &zero };
                        pfa_resize(&output, clear_args, &rc, 1);
                    }
                }
            }
        }
        pba_dtor(&source);
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(ret, &output);
    pfa_dtor(&output);
}

#include "bf6_environment.inc"


// ---- up-front cache (bf6_precache_*) -------------------------------------------
// precache_open(game_dir: String, cache_root: String) -> bool
static void call_core_precache_open(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || argc != 2) { return_bool(ret, false); return; }
	std::lock_guard<std::recursive_mutex> guard(self->mutex);
	if (self->precache) { bf6_precache_close(self->precache); self->precache = nullptr; }
	char err[1024] = {};
	const std::string game = variant_utf8(args[0]);
	const std::string root = variant_utf8(args[1]);
	self->precache = bf6_precache_open(game.c_str(), root.c_str(), err, (int)sizeof(err));
	self->last_error = self->precache ? std::string() : std::string(err);
	return_bool(ret, self->precache != nullptr);
}

// precache_start(levels: String (comma separated), flags: int) -> int (0 started)
static void call_core_precache_start(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || argc != 2) { return_int(ret, -1); return; }
	std::lock_guard<std::recursive_mutex> guard(self->mutex);
	if (!self->precache) { return_int(ret, -1); return; }
	const std::string list = variant_utf8(args[0]);
	int64_t flags = 0;
	get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&flags, const_cast<GDExtensionVariantPtr>(args[1]));
	std::vector<std::string> names;
	size_t start = 0;
	while (start <= list.size()) {
		size_t end = list.find(',', start);
		if (end == std::string::npos) end = list.size();
		if (end > start) names.push_back(list.substr(start, end - start));
		start = end + 1;
	}
	std::vector<const char *> ptrs;
	for (const auto &n : names) ptrs.push_back(n.c_str());
	return_int(ret, bf6_precache_build_start(self->precache, ptrs.data(), (int)ptrs.size(), (int)flags));
}

// precache_cancel() -> bool
static void call_core_precache_cancel(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || !self->precache) { return_bool(ret, false); return; }
	bf6_precache_build_cancel(self->precache);
	return_bool(ret, true);
}

// precache_map_ready(level: String) -> bool
static void call_core_precache_map_ready(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc, GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || !self->precache || argc != 1) { return_bool(ret, false); return; }
	const std::string level = variant_utf8(args[0]);
	return_bool(ret, bf6_precache_map_ready(self->precache, level.c_str()) == 1);
}

// precache_sweep() -> int (stale caches removed, -1 on error)
static void call_core_precache_sweep(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || !self->precache) { return_int(ret, -1); return; }
	char err[512] = {};
	return_int(ret, bf6_precache_sweep_stale(self->precache, err, (int)sizeof(err)));
}

// precache_status() -> String (JSON): overall, per map, per layer, current item.
// Cheap enough to poll every frame; lock-free with respect to the build.
static void call_core_precache_status(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	if (!self || !self->precache) { return_string(ret, "{\"open\":false}"); return; }
	bf6_precache_progress p{};
	p.struct_size = sizeof(p);
	bf6_precache_progress_get(self->precache, &p);
	char num[64];
	std::string json = "{\"open\":true,\"key\":";
	append_json_string(json, bf6_precache_key(self->precache));
	json += ",\"ready\":"; json += bf6_precache_ready(self->precache) == 1 ? "true" : "false";
	json += ",\"state\":" + std::to_string(p.state);
	std::snprintf(num, sizeof num, "%.6f", p.overall); json += ",\"overall\":"; json += num;
	std::snprintf(num, sizeof num, "%.6f", p.shared); json += ",\"shared\":"; json += num;
	std::snprintf(num, sizeof num, "%.3f", p.seconds_since_update); json += ",\"since_update\":"; json += num;
	json += ",\"map_count\":" + std::to_string(p.map_count) + ",\"maps_done\":" + std::to_string(p.maps_done);
	json += ",\"bytes\":" + std::to_string(p.bytes_written);
	json += ",\"current_map\":"; append_json_string(json, p.current_map);
	json += ",\"current_layer\":"; append_json_string(json, p.current_layer);
	json += ",\"current_item\":"; append_json_string(json, p.current_item);
	json += ",\"error\":"; append_json_string(json, p.error);
	json += ",\"layers\":[";
	const int layer_count = bf6_precache_layer_count(self->precache);
	for (int i = 0; i < layer_count; ++i) {
		char name[64] = {};
		bf6_precache_layer_name(self->precache, i, name, (int)sizeof(name));
		if (i) json += ',';
		append_json_string(json, name);
	}
	json += "],\"maps\":[";
	const int count = bf6_precache_map_progress_get(self->precache, nullptr, 0);
	std::vector<bf6_precache_map_progress> rows((size_t)std::max(0, count));
	if (count > 0) bf6_precache_map_progress_get(self->precache, rows.data(), count);
	for (int i = 0; i < count; ++i) {
		const auto &r = rows[(size_t)i];
		if (i) json += ',';
		json += "{\"level\":"; append_json_string(json, r.level);
		json += ",\"state\":" + std::to_string(r.state);
		std::snprintf(num, sizeof num, "%.6f", r.progress); json += ",\"progress\":"; json += num;
		json += ",\"layers\":[";
		for (int k = 0; k < r.layer_count; ++k) {
			std::snprintf(num, sizeof num, "%.4f", r.layer_progress[k]);
			if (k) json += ',';
			json += num;
		}
		json += "]}";
	}
	json += "]}";
	return_string(ret, json);
}


// meshset_sections(res: PackedByteArray, lod: int, chunk: PackedByteArray, flags: int)
// -> PackedByteArray: the core's bf6_meshset_sections record (see bf6_core.h), or
// empty when the call fails. Stateless; safe from worker threads.
static void call_core_meshset_sections(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	alignas(8) uint8_t out[16] = {};
	pba_ctor(&out, nullptr);
	if (argc == 4) {
		static auto to_pba = get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		static auto to_int = get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);
		alignas(8) uint8_t res[16] = {};
		alignas(8) uint8_t chunk[16] = {};
		to_pba(&res, const_cast<GDExtensionVariantPtr>(args[0]));
		to_pba(&chunk, const_cast<GDExtensionVariantPtr>(args[2]));
		int64_t lod = 0, flags = 0;
		to_int(&lod, const_cast<GDExtensionVariantPtr>(args[1]));
		to_int(&flags, const_cast<GDExtensionVariantPtr>(args[3]));
		int64_t res_len = 0, chunk_len = 0;
		pba_size(&res, nullptr, &res_len, 0);
		pba_size(&chunk, nullptr, &chunk_len, 0);
		const uint8_t *rp = res_len > 0 ? pba_index_const(&res, 0) : nullptr;
		const uint8_t *cp = chunk_len > 0 ? pba_index_const(&chunk, 0) : nullptr;
		uint8_t *blob = nullptr;
		const int64_t len = (lod >= 0 && lod <= INT_MAX)
				? bf6_meshset_sections(rp, res_len, (int)lod, cp, chunk_len, (int)flags, &blob) : -1;
		if (len > 0 && blob) {
			int64_t size = len;
			GDExtensionInt rc = 0;
			const void *rargs[1] = { &size };
			pba_resize(&out, rargs, &rc, 1);
			uint8_t *dp = pba_index(&out, 0);
			if (dp) std::memcpy(dp, blob, (size_t)len);
		}
		bf6_blob_free(blob);
		pba_dtor(&res);
		pba_dtor(&chunk);
	}
	get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
	pba_dtor(&out);
}


// meshset_surfaces(res, lod, chunk, flags, hidden, uv_overrides, canon_keys, canon_tables)
// -> PackedByteArray: bf6_meshset_surfaces record, or empty. hidden and uv_overrides
// are PackedInt32Array bytes, canon_keys PackedInt64Array bytes, canon_tables 8 per key.
static void call_core_meshset_surfaces(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	alignas(8) uint8_t out[16] = {};
	pba_ctor(&out, nullptr);
	if (argc == 8) {
		static auto to_pba = get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		static auto to_int = get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);
		const int byte_args[6] = { 0, 2, 4, 5, 6, 7 };
		alignas(8) uint8_t arrays[6][16] = {};
		const uint8_t *ptr[6] = {};
		int64_t len[6] = {};
		for (int k = 0; k < 6; ++k) {
			to_pba(&arrays[k], const_cast<GDExtensionVariantPtr>(args[byte_args[k]]));
			pba_size(&arrays[k], nullptr, &len[k], 0);
			ptr[k] = len[k] > 0 ? pba_index_const(&arrays[k], 0) : nullptr;
		}
		int64_t lod = 0, flags = 0;
		to_int(&lod, const_cast<GDExtensionVariantPtr>(args[1]));
		to_int(&flags, const_cast<GDExtensionVariantPtr>(args[3]));
		const int32_t hidden_count = (int32_t)(len[2] / 4);
		const int32_t override_count = (int32_t)(len[3] / 8);
		int32_t canon_count = (int32_t)(len[4] / 8);
		if (len[5] / 8 < canon_count) canon_count = (int32_t)(len[5] / 8);
		// Copied into aligned storage: a PackedByteArray's bytes carry no alignment promise.
		std::vector<int32_t> hidden((size_t)hidden_count), overrides((size_t)override_count * 2);
		std::vector<int64_t> keys((size_t)canon_count);
		if (hidden_count) std::memcpy(hidden.data(), ptr[2], (size_t)hidden_count * 4);
		if (override_count) std::memcpy(overrides.data(), ptr[3], (size_t)override_count * 8);
		if (canon_count) std::memcpy(keys.data(), ptr[4], (size_t)canon_count * 8);
		uint8_t *blob = nullptr;
		const int64_t got = (lod >= 0 && lod <= INT_MAX)
				? bf6_meshset_surfaces(ptr[0], len[0], (int)lod, ptr[1], len[1], (int)flags,
						hidden.data(), hidden_count, overrides.data(), override_count,
						keys.data(), ptr[5], canon_count, &blob)
				: -1;
		if (got > 0 && blob) {
			int64_t size = got;
			GDExtensionInt rc = 0;
			const void *rargs[1] = { &size };
			pba_resize(&out, rargs, &rc, 1);
			uint8_t *dp = pba_index(&out, 0);
			if (dp) std::memcpy(dp, blob, (size_t)got);
		}
		bf6_blob_free(blob);
		for (int k = 0; k < 6; ++k) pba_dtor(&arrays[k]);
	}
	get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
	pba_dtor(&out);
}


static void return_blob(GDExtensionVariantPtr ret, uint8_t *blob, int64_t len) {
	alignas(8) uint8_t out[16] = {};
	pba_ctor(&out, nullptr);
	if (len > 0 && blob) {
		int64_t size = len;
		GDExtensionInt rc = 0;
		const void *rargs[1] = { &size };
		pba_resize(&out, rargs, &rc, 1);
		uint8_t *dp = pba_index(&out, 0);
		if (dp) std::memcpy(dp, blob, (size_t)len);
	}
	bf6_blob_free(blob);
	get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
	pba_dtor(&out);
}

// precache_mesh_surfaces(level: String, mesh_names: String (newline separated), lod: int, threads: int)
// -> PackedByteArray (bf6_precache_mesh_surfaces record), empty when no cache is open.
static void call_core_precache_mesh_surfaces(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	uint8_t *blob = nullptr;
	int64_t len = -1;
	if (self && self->precache && argc == 4) {
		const std::string level = variant_utf8(args[0]);
		const std::string names = variant_utf8(args[1]);
		int64_t lod = 0, threads = 0;
		get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&lod, const_cast<GDExtensionVariantPtr>(args[2]));
		get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&threads, const_cast<GDExtensionVariantPtr>(args[3]));
		len = bf6_precache_mesh_surfaces(self->precache, level.c_str(), names.c_str(), (int)lod, (int)threads, &blob);
	}
	return_blob(ret, blob, len);
}

// precache_mesh_record(level: String, mesh_res: String) -> PackedByteArray (empty: not cached)
static void call_core_precache_mesh_record(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	uint8_t *blob = nullptr;
	int64_t len = -1;
	if (self && self->precache && argc == 2) {
		const std::string level = variant_utf8(args[0]);
		const std::string res = variant_utf8(args[1]);
		len = bf6_precache_mesh_record(self->precache, level.c_str(), res.c_str(), &blob);
	}
	return_blob(ret, blob, len);
}

// meshset_surfaces_reference(game_dir: String, record, lod: int, uv_overrides, canon_keys, canon_tables)
// -> PackedByteArray (bf6_meshset_surfaces record), empty on failure or another LOD.
static void call_core_meshset_surfaces_reference(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	uint8_t *blob = nullptr;
	int64_t got = -1;
	if (argc == 6) {
		static auto to_pba = get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
		const std::string game = variant_utf8(args[0]);
		int64_t lod = 0;
		get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&lod, const_cast<GDExtensionVariantPtr>(args[2]));
		const int byte_args[4] = { 1, 3, 4, 5 };
		alignas(8) uint8_t arrays[4][16] = {};
		const uint8_t *ptr[4] = {};
		int64_t len[4] = {};
		for (int k = 0; k < 4; ++k) {
			to_pba(&arrays[k], const_cast<GDExtensionVariantPtr>(args[byte_args[k]]));
			pba_size(&arrays[k], nullptr, &len[k], 0);
			ptr[k] = len[k] > 0 ? pba_index_const(&arrays[k], 0) : nullptr;
		}
		const int32_t override_count = (int32_t)(len[1] / 8);
		int32_t canon_count = (int32_t)(len[2] / 8);
		if (len[3] / 8 < canon_count) canon_count = (int32_t)(len[3] / 8);
		std::vector<int32_t> overrides((size_t)override_count * 2);
		std::vector<int64_t> keys((size_t)canon_count);
		if (override_count) std::memcpy(overrides.data(), ptr[1], (size_t)override_count * 8);
		if (canon_count) std::memcpy(keys.data(), ptr[2], (size_t)canon_count * 8);
		if (lod >= 0 && lod <= INT_MAX)
			got = bf6_meshset_surfaces_reference(game.c_str(), ptr[0], len[0], (int)lod, 0,
					overrides.data(), override_count, keys.data(), ptr[3], canon_count, &blob);
		for (int k = 0; k < 4; ++k) pba_dtor(&arrays[k]);
	}
	return_blob(ret, blob, got);
}


// precache_mesh_texture_names(level: String, mesh_names: String) -> String (newline separated)
static void call_core_precache_mesh_texture_names(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	std::string text;
	if (self && self->precache && argc == 2) {
		const std::string level = variant_utf8(args[0]);
		const std::string names = variant_utf8(args[1]);
		uint8_t *blob = nullptr;
		const int64_t len = bf6_precache_mesh_texture_names(self->precache, level.c_str(), names.c_str(), &blob);
		if (len > 0 && blob) text.assign((const char *)blob, (size_t)len);
		bf6_blob_free(blob);
	}
	return_string(ret, text);
}

// precache_texture_chunks(texture_names: String, max_dim: int, threads: int) -> PackedByteArray
static void call_core_precache_texture_chunks(void *, GDExtensionClassInstancePtr instance,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	auto *self = static_cast<BF6CoreBinding *>(instance);
	uint8_t *blob = nullptr;
	int64_t len = -1;
	if (self && self->precache && argc == 3) {
		const std::string names = variant_utf8(args[0]);
		int64_t max_dim = 0, threads = 0;
		get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&max_dim, const_cast<GDExtensionVariantPtr>(args[1]));
		get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&threads, const_cast<GDExtensionVariantPtr>(args[2]));
		len = bf6_precache_texture_chunks(self->precache, names.c_str(), (int)max_dim, (int)threads, &blob);
	}
	return_blob(ret, blob, len);
}


// cas_read_batch(game_dir: String, spec: String) -> PackedByteArray (bf6_cas_read_batch record)
static void call_core_cas_read_batch(void *, GDExtensionClassInstancePtr,
		const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
		GDExtensionVariantPtr ret, GDExtensionCallError *) {
	uint8_t *blob = nullptr;
	int64_t len = -1;
	if (argc == 2) {
		const std::string game = variant_utf8(args[0]);
		const std::string spec = variant_utf8(args[1]);
		len = bf6_cas_read_batch(game.c_str(), spec.c_str(), &blob);
	}
	return_blob(ret, blob, len);
}

static void bind_method(const char *class_name, const char *method_name,
		GDExtensionClassMethodCall call, GDExtensionVariantType ret_type,
		int argc, const GDExtensionVariantType *arg_types) {
	uint8_t cn[16] = {}, mn[16] = {};
	sn_new(&cn, class_name, false);
	sn_new(&mn, method_name, false);

	GDExtensionPropertyInfo ret_info = {};
	ret_info.type = ret_type;
	uint8_t empty_sn[16] = {}, empty_s[16] = {};
	sn_new(&empty_sn, "", false);
	string_new_utf8(&empty_s, "");
	ret_info.name = &empty_sn;
	ret_info.class_name = &empty_sn;
	ret_info.hint_string = &empty_s;
	ret_info.usage = 6; // PROPERTY_USAGE_DEFAULT

	// ARGUMENT TYPES COME FROM THE CALLER. They used to be inferred from the
	// method name — first argument is a PackedByteArray if the method is called
	// "decompress", otherwise a String — which worked only because there were
	// two methods and no reason to add a third.
	GDExtensionPropertyInfo arg_info[8] = {};
	GDExtensionClassMethodArgumentMetadata arg_meta[8] = {};
	for (int i = 0; i < argc && i < 8; ++i) {
		arg_info[i] = ret_info;
		arg_info[i].type = arg_types[i];
		arg_meta[i] = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	}

	GDExtensionClassMethodInfo mi = {};
	mi.name = &mn;
	mi.method_userdata = nullptr;
	mi.call_func = call;
	mi.ptrcall_func = nullptr;
	mi.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
	mi.has_return_value = 1;
	mi.return_value_info = &ret_info;
	mi.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	mi.argument_count = (uint32_t)argc;
	mi.arguments_info = argc ? arg_info : nullptr;
	mi.arguments_metadata = argc ? arg_meta : nullptr;
	mi.default_argument_count = 0;

	classdb_method(g_library, &cn, &mi);
}

static void initialize(void *, GDExtensionInitializationLevel level) {
	if (level != GDEXTENSION_INITIALIZATION_SCENE) {
		return;
	}
	uint8_t cn[16] = {}, parent[16] = {};
	sn_new(&cn, "BF6Oodle", false);
	sn_new(&parent, "RefCounted", false);

	GDExtensionClassCreationInfo4 ci = {};
	ci.is_virtual = 0;
	ci.is_abstract = 0;
	ci.is_exposed = 1;
	ci.is_runtime = 0;
	ci.create_instance_func = bf6_create;
	ci.free_instance_func = bf6_free;

	classdb_register(g_library, &cn, &parent, &ci);

	uint8_t core_cn[16] = {};
	sn_new(&core_cn, "BF6Core", false);
	GDExtensionClassCreationInfo4 core_ci = {};
	core_ci.is_virtual = 0;
	core_ci.is_abstract = 0;
	core_ci.is_exposed = 1;
	core_ci.is_runtime = 0;
	core_ci.create_instance_func = core_create;
	core_ci.free_instance_func = core_free;
	classdb_register(g_library, &core_cn, &parent, &core_ci);

	static const GDExtensionVariantType a_open[1] = {
		GDEXTENSION_VARIANT_TYPE_STRING };
	static const GDExtensionVariantType a_decomp[2] = {
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_INT };
	static const GDExtensionVariantType a_find[4] = {
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_INT,
		GDEXTENSION_VARIANT_TYPE_INT };

	bind_method("BF6Oodle", "open", call_open,
			GDEXTENSION_VARIANT_TYPE_BOOL, 1, a_open);
	bind_method("BF6Oodle", "decompress", call_decompress,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 2, a_decomp);
	bind_method("BF6Oodle", "last_error", call_last_error,
			GDEXTENSION_VARIANT_TYPE_STRING, 0, nullptr);
	bind_method("BF6Oodle", "find", call_find,
			GDEXTENSION_VARIANT_TYPE_INT, 4, a_find);

	// The cell merge. Named for what it does rather than for Oodle, because it
	// has nothing to do with compression - it lives in this extension only
	// because this is where the build already is, and a second one-function DLL
	// would be a second thing to build and ship for no gain.
	static const GDExtensionVariantType a_merge[1] = {
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY };
	bind_method("BF6Oodle", "merge_cell", call_merge_cell,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 1, a_merge);

	static const GDExtensionVariantType a_string[1] = {
		GDEXTENSION_VARIANT_TYPE_STRING };
	bind_method("BF6Core", "open", call_core_open,
			GDEXTENSION_VARIANT_TYPE_BOOL, 1, a_string);
	bind_method("BF6Core", "last_error", call_core_last_error,
			GDEXTENSION_VARIANT_TYPE_STRING, 0, nullptr);
	bind_method("BF6Core", "abi_version", call_core_abi_version,
			GDEXTENSION_VARIANT_TYPE_INT, 0, nullptr);
	bind_method("BF6Core", "install_identity", call_core_install_identity,
			GDEXTENSION_VARIANT_TYPE_STRING, 1, a_string);
	bind_method("BF6Core", "preparation_lock", call_core_preparation_lock,
			GDEXTENSION_VARIANT_TYPE_BOOL, 1, a_string);
	static const GDExtensionVariantType a_pid[1] = { GDEXTENSION_VARIANT_TYPE_INT };
	bind_method("BF6Core", "process_status", call_core_process_status,
			GDEXTENSION_VARIANT_TYPE_INT, 1, a_pid);
	bind_method("BF6Core", "scatter", call_core_scatter,
			GDEXTENSION_VARIANT_TYPE_STRING, 1, a_string);
	bind_method("BF6Core", "lighting_zones", call_core_lighting_zones,
			GDEXTENSION_VARIANT_TYPE_STRING, 1, a_string);
    static const GDExtensionVariantType a_environment[3] = {
        GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_STRING,
        GDEXTENSION_VARIANT_TYPE_INT };
    bind_method("BF6Core", "environment", call_core_environment,
        GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 3, a_environment);
    static const GDExtensionVariantType a_attribute[5] = {
        GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
        GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_INT,
        GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_INT };
    bind_method("BF6Core", "decode_vertex_attribute", call_core_decode_vertex_attribute,
        GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, 5, a_attribute);
	static const GDExtensionVariantType a_two_strings[2] = {
		GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_STRING };
	static const GDExtensionVariantType a_string_int[2] = {
		GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_INT };
	bind_method("BF6Core", "precache_open", call_core_precache_open,
			GDEXTENSION_VARIANT_TYPE_BOOL, 2, a_two_strings);
	bind_method("BF6Core", "precache_start", call_core_precache_start,
			GDEXTENSION_VARIANT_TYPE_INT, 2, a_string_int);
	bind_method("BF6Core", "precache_cancel", call_core_precache_cancel,
			GDEXTENSION_VARIANT_TYPE_BOOL, 0, nullptr);
	bind_method("BF6Core", "precache_map_ready", call_core_precache_map_ready,
			GDEXTENSION_VARIANT_TYPE_BOOL, 1, a_string);
	bind_method("BF6Core", "precache_sweep", call_core_precache_sweep,
			GDEXTENSION_VARIANT_TYPE_INT, 0, nullptr);
	bind_method("BF6Core", "precache_status", call_core_precache_status,
			GDEXTENSION_VARIANT_TYPE_STRING, 0, nullptr);
	static const GDExtensionVariantType a_sections[4] = {
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_INT,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_INT };
	bind_method("BF6Core", "meshset_sections", call_core_meshset_sections,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 4, a_sections);
	static const GDExtensionVariantType a_surfaces[8] = {
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_INT,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_INT,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY };
	bind_method("BF6Core", "meshset_surfaces", call_core_meshset_surfaces,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 8, a_surfaces);
	static const GDExtensionVariantType a_pc_surfaces[4] = {
		GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_STRING,
		GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_INT };
	bind_method("BF6Core", "precache_mesh_surfaces", call_core_precache_mesh_surfaces,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 4, a_pc_surfaces);
	bind_method("BF6Core", "precache_mesh_record", call_core_precache_mesh_record,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 2, a_two_strings);
	static const GDExtensionVariantType a_ref_surfaces[6] = {
		GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY,
		GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY };
	bind_method("BF6Core", "meshset_surfaces_reference", call_core_meshset_surfaces_reference,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 6, a_ref_surfaces);
	bind_method("BF6Core", "precache_mesh_texture_names", call_core_precache_mesh_texture_names,
			GDEXTENSION_VARIANT_TYPE_STRING, 2, a_two_strings);
	bind_method("BF6Core", "cas_read_batch", call_core_cas_read_batch,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 2, a_two_strings);
	static const GDExtensionVariantType a_tex_chunks[3] = {
		GDEXTENSION_VARIANT_TYPE_STRING, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_INT };
	bind_method("BF6Core", "precache_texture_chunks", call_core_precache_texture_chunks,
			GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 3, a_tex_chunks);
}

static void deinitialize(void *, GDExtensionInitializationLevel) {}

extern "C" GDExtensionBool GDE_EXPORT bf6_oodle_init(
		GDExtensionInterfaceGetProcAddress p_get_proc,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_init) {
	g_get_proc = p_get_proc;
	g_library = p_library;

	sn_new = load<GDExtensionInterfaceStringNameNewWithLatin1Chars>(
			"string_name_new_with_latin1_chars");
	string_new_utf8 = load<GDExtensionInterfaceStringNewWithUtf8Chars>(
			"string_new_with_utf8_chars");
	classdb_register = load<GDExtensionInterfaceClassdbRegisterExtensionClass4>(
			"classdb_register_extension_class4");
	classdb_method = load<GDExtensionInterfaceClassdbRegisterExtensionClassMethod>(
			"classdb_register_extension_class_method");
	mem_alloc = load<GDExtensionInterfaceMemAlloc>("mem_alloc");
	mem_free = load<GDExtensionInterfaceMemFree>("mem_free");
	get_destructor = load<GDExtensionInterfaceVariantGetPtrDestructor>(
			"variant_get_ptr_destructor");
	get_variant_from = load<GDExtensionInterfaceGetVariantFromTypeConstructor>(
			"get_variant_from_type_constructor");
	get_variant_to = load<GDExtensionInterfaceGetVariantToTypeConstructor>(
			"get_variant_to_type_constructor");
	pba_index = load<GDExtensionInterfacePackedByteArrayOperatorIndex>(
			"packed_byte_array_operator_index");
	pba_index_const = load<GDExtensionInterfacePackedByteArrayOperatorIndexConst>(
			"packed_byte_array_operator_index_const");
	construct_object = load<GDExtensionInterfaceClassdbConstructObject2>(
			"classdb_construct_object2");
	object_set_instance = load<GDExtensionInterfaceObjectSetInstance>(
			"object_set_instance");

	auto ctor = load<GDExtensionInterfaceVariantGetPtrConstructor>(
			"variant_get_ptr_constructor");
	auto dtor = load<GDExtensionInterfaceVariantGetPtrDestructor>(
			"variant_get_ptr_destructor");
	auto bim = load<GDExtensionInterfaceVariantGetPtrBuiltinMethod>(
			"variant_get_ptr_builtin_method");
	pba_ctor = ctor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
	pba_dtor = dtor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    pfa_ctor = ctor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, 0);
    pfa_dtor = dtor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY);
    pfa_index = load<GDExtensionInterfacePackedFloat32ArrayOperatorIndex>("packed_float32_array_operator_index");

	uint8_t m_resize[16] = {}, m_size[16] = {};
	sn_new(&m_resize, "resize", false);
	sn_new(&m_size, "size", false);
	pba_resize = bim(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, &m_resize, 848867239);
	pba_size = bim(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, &m_size, 3173160232);
    pfa_resize = bim(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, &m_resize, 848867239);
    pfa_size = bim(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, &m_size, 3173160232);

	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->userdata = nullptr;
	r_init->initialize = initialize;
	r_init->deinitialize = deinitialize;
	return 1;
}
