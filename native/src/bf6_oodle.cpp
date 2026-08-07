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

			const uint8_t *sp = pba_index(&src, 0);
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
			const uint8_t *hp = pba_index(&hay, 0);
			const uint8_t *np = pba_index(&ndl, 0);
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
