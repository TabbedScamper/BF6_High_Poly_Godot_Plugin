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
#include <string>
// For the cell merge below: a hash map and a growable buffer. The merge cannot
// know its output size in advance - that is the whole point of welding - so it
// accumulates in std::vector and copies into the PackedByteArray once at the
// end, rather than reserving the worst case, which would be the 4.6 GB this
// design exists to avoid.
#include <cmath>
#include <unordered_map>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "gdextension_interface.h"

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
	GDExtensionPropertyInfo arg_info[4] = {};
	GDExtensionClassMethodArgumentMetadata arg_meta[4] = {};
	for (int i = 0; i < argc && i < 4; ++i) {
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

	uint8_t m_resize[16] = {}, m_size[16] = {};
	sn_new(&m_resize, "resize", false);
	sn_new(&m_size, "size", false);
	pba_resize = bim(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, &m_resize, 848867239);
	pba_size = bim(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, &m_size, 3173160232);

	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->userdata = nullptr;
	r_init->initialize = initialize;
	r_init->deinitialize = deinitialize;
	return 1;
}
