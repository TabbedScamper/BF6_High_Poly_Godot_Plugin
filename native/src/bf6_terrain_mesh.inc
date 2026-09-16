// The shared terrain mesh (bf6_terrain_mesh_*), the same surface the Unreal
// add-on draws. A handle keeps a reference to the caller's PackedByteArray of
// heights (no copy) and the core's mesh; tiles are fetched one at a time and
// may be fetched from several worker threads at once.
//
//   terrain_mesh_open(heights: PackedByteArray, params: PackedFloat32Array) -> int
//       params: size, world min x, y, z, world max x, y, z, height scale
//               (metres = raw * scale / 65536), base side, tile quads, flip
//   terrain_mesh_info(handle) -> String (JSON)
//   terrain_mesh_tile(handle, index) -> PackedByteArray
//       int32 vertex_count, index_count, tile_x, tile_z, then float32 positions
//       (xyz), normals (xyz), uvs (uv) and int32 indices
//   terrain_mesh_heights(handle, xz: PackedFloat32Array) -> PackedFloat32Array
//   terrain_mesh_close(handle) -> bool

struct TerrainMeshHandle {
    alignas(8) uint8_t heights[16] = {};
    bf6_terrain_mesh* mesh = nullptr;
};
static std::mutex terrain_mesh_mx;
static std::unordered_map<int64_t, TerrainMeshHandle*> terrain_meshes;
static int64_t terrain_mesh_next = 1;

static TerrainMeshHandle* terrain_mesh_find(int64_t id) {
    std::lock_guard<std::mutex> lock(terrain_mesh_mx);
    auto it = terrain_meshes.find(id);
    return it == terrain_meshes.end() ? nullptr : it->second;
}

static int64_t arg_int(GDExtensionConstVariantPtr v) {
    int64_t out = 0;
    get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&out, const_cast<GDExtensionVariantPtr>(v));
    return out;
}

static void call_core_terrain_mesh_open(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    static auto type_of = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    if (argc != 2 || type_of(args[0]) != GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY ||
        type_of(args[1]) != GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY) { return_int(ret, 0); return; }
    auto* h = new TerrainMeshHandle();
    get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&h->heights, const_cast<GDExtensionVariantPtr>(args[0]));
    alignas(8) uint8_t params[16] = {};
    get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&params, const_cast<GDExtensionVariantPtr>(args[1]));
    int64_t pcount = 0, bytes = 0;
    pfa_size(&params, nullptr, &pcount, 0);
    pba_size(&h->heights, nullptr, &bytes, 0);
    if (pcount >= 11) {
        const float* p = pfa_index(&params, 0);
        const int32_t size = int32_t(p[0]);
        if (size > 1 && bytes >= int64_t(size) * size * 2) {
            const double wmin[3] = { p[1], p[2], p[3] };
            const double wmax[3] = { p[4], p[5], p[6] };
            bf6_terrain_mesh_options o{};
            o.base_side = int32_t(p[8]);
            o.tile_quads = int32_t(p[9]);
            o.flip_winding = p[10] != 0.f;
            const uint16_t* heights = reinterpret_cast<const uint16_t*>(pba_index_const(&h->heights, 0));
            h->mesh = bf6_terrain_mesh_build(heights, size, wmin, wmax, p[7], &o);
        }
    }
    pfa_dtor(&params);
    if (!h->mesh) { pba_dtor(&h->heights); delete h; return_int(ret, 0); return; }
    std::lock_guard<std::mutex> lock(terrain_mesh_mx);
    const int64_t id = terrain_mesh_next++;
    terrain_meshes[id] = h;
    return_int(ret, id);
}

static void call_core_terrain_mesh_info(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    TerrainMeshHandle* h = argc == 1 ? terrain_mesh_find(arg_int(args[0])) : nullptr;
    bf6_terrain_mesh_info info{};
    if (!h || !bf6_terrain_mesh_describe(h->mesh, &info)) { return_string(ret, "{}"); return; }
    char buf[1024];
    std::snprintf(buf, sizeof(buf),
        "{\"native_size\":%d,\"base_side\":%d,\"native_step\":%d,\"tile_quads\":%d,\"tiles_per_side\":%d,"
        "\"base_cells\":%d,\"max_level\":%d,\"adaptive\":%d,\"native_spacing_m\":%.9g,\"base_spacing_m\":%.9g,"
        "\"finest_spacing_m\":%.9g,\"height_per_unit\":%.12g,\"cells_by_level\":[%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld]}",
        info.native_size, info.base_side, info.native_step, info.tile_quads, info.tiles_per_side,
        info.base_cells, info.max_level, info.adaptive, info.native_spacing_m, info.base_spacing_m,
        info.finest_spacing_m, info.height_per_unit,
        (long long)info.cells_by_level[0], (long long)info.cells_by_level[1], (long long)info.cells_by_level[2],
        (long long)info.cells_by_level[3], (long long)info.cells_by_level[4], (long long)info.cells_by_level[5],
        (long long)info.cells_by_level[6], (long long)info.cells_by_level[7]);
    return_string(ret, buf);
}

static void call_core_terrain_mesh_tile(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    alignas(8) uint8_t out[16] = {};
    pba_ctor(&out, nullptr);
    TerrainMeshHandle* h = argc == 2 ? terrain_mesh_find(arg_int(args[0])) : nullptr;
    bf6_terrain_tile t{};
    const int32_t index = h ? int32_t(arg_int(args[1])) : -1;
    if (h && bf6_terrain_mesh_tile(h->mesh, index, &t)) {
        const size_t vb = size_t(t.vertex_count) * 4;   // bytes per float
        int64_t size = 16 + int64_t(vb) * 8 + int64_t(t.index_count) * 4;
        GDExtensionInt rc = 0;
        const void *rargs[1] = { &size };
        pba_resize(&out, rargs, &rc, 1);
        uint8_t* dp = pba_index(&out, 0);
        if (dp) {
            const int32_t head[4] = { t.vertex_count, t.index_count, t.tile_x, t.tile_z };
            std::memcpy(dp, head, 16); dp += 16;
            std::memcpy(dp, t.positions, vb * 3); dp += vb * 3;
            std::memcpy(dp, t.normals, vb * 3); dp += vb * 3;
            std::memcpy(dp, t.uvs, vb * 2); dp += vb * 2;
            std::memcpy(dp, t.indices, size_t(t.index_count) * 4);
        }
        bf6_terrain_mesh_release_tile(h->mesh, index);
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret, &out);
    pba_dtor(&out);
}

static void call_core_terrain_mesh_heights(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    alignas(8) uint8_t out[16] = {};
    pfa_ctor(&out, nullptr);
    static auto type_of = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    TerrainMeshHandle* h = argc == 2 && type_of(args[1]) == GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY
        ? terrain_mesh_find(arg_int(args[0])) : nullptr;
    if (h) {
        alignas(8) uint8_t xz[16] = {};
        get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&xz, const_cast<GDExtensionVariantPtr>(args[1]));
        int64_t n = 0;
        pfa_size(&xz, nullptr, &n, 0);
        int64_t count = n / 2;
        if (count > 0) {
            GDExtensionInt rc = 0;
            const void *rargs[1] = { &count };
            pfa_resize(&out, rargs, &rc, 1);
            const float* in = pfa_index(&xz, 0);
            float* dst = pfa_index(&out, 0);
            for (int64_t i = 0; in && dst && i < count; ++i)
                dst[i] = float(bf6_terrain_mesh_height_at(h->mesh, in[i * 2], in[i * 2 + 1]));
        }
        pfa_dtor(&xz);
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(ret, &out);
    pfa_dtor(&out);
}

static void call_core_terrain_mesh_close(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    TerrainMeshHandle* h = nullptr;
    if (argc == 1) {
        std::lock_guard<std::mutex> lock(terrain_mesh_mx);
        auto it = terrain_meshes.find(arg_int(args[0]));
        if (it != terrain_meshes.end()) { h = it->second; terrain_meshes.erase(it); }
    }
    if (h) {
        bf6_terrain_mesh_free(h->mesh);
        pba_dtor(&h->heights);
        delete h;
    }
    return_bool(ret, h != nullptr);
}
