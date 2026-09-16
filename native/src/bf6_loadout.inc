// The shared LootSpawner loadout (bf6_loadout_*), the same catalogue,
// attachments and configured weapon the Unreal add-on builds. Each call needs
// an open BF6Core and mounts the front end on it first.
//
//   loadout_catalogue() -> String (JSON)
//   loadout_attachments(item: String, portal_enums: String) -> String (JSON)
//   loadout_weapon(item: String, fits: String, portal_enums: String) -> PackedByteArray
//       the core's BLWP record; see bf6_loadout_weapon in bf6_core.h

static void call_core_loadout_catalogue(void *, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *, GDExtensionInt,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    auto *self = static_cast<BF6CoreBinding *>(instance);
    std::string text = "{}";
    if (self) {
        std::lock_guard<std::recursive_mutex> guard(self->mutex);
        uint8_t *blob = nullptr;
        const int64_t n = self->ctx ? bf6_loadout_catalogue(self->ctx, &blob) : -1;
        if (n > 0 && blob) text.assign(reinterpret_cast<const char *>(blob), size_t(n));
        bf6_blob_free(blob);
    }
    return_string(ret, text);
}

static void call_core_loadout_attachments(void *, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    auto *self = static_cast<BF6CoreBinding *>(instance);
    std::string text = "{}";
    if (self && argc == 2) {
        const std::string item = variant_utf8(args[0]);
        const std::string enums = variant_utf8(args[1]);
        std::lock_guard<std::recursive_mutex> guard(self->mutex);
        uint8_t *blob = nullptr;
        const int64_t n = self->ctx ? bf6_loadout_attachments(self->ctx, item.c_str(), enums.c_str(), &blob) : -1;
        if (n > 0 && blob) text.assign(reinterpret_cast<const char *>(blob), size_t(n));
        bf6_blob_free(blob);
    }
    return_string(ret, text);
}

static void call_core_loadout_weapon(void *, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    auto *self = static_cast<BF6CoreBinding *>(instance);
    uint8_t *blob = nullptr;
    int64_t n = -1;
    if (self && argc == 3) {
        const std::string item = variant_utf8(args[0]);
        const std::string fits = variant_utf8(args[1]);
        const std::string enums = variant_utf8(args[2]);
        std::lock_guard<std::recursive_mutex> guard(self->mutex);
        if (self->ctx) n = bf6_loadout_weapon(self->ctx, item.c_str(), fits.c_str(), enums.c_str(), &blob);
    }
    return_blob(ret, blob, n);
}

//   loadout_soldier(request_json: String, portal_enums: String) -> PackedByteArray
//       the posed soldier and its weapon as the same BLWP record; the request is
//       {"character","outfit","faction","role","item","fits"}, see
//       bf6_loadout_soldier in bf6_core.h

static void call_core_loadout_soldier(void *, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    auto *self = static_cast<BF6CoreBinding *>(instance);
    uint8_t *blob = nullptr;
    int64_t n = -1;
    if (self && argc == 2) {
        const std::string req = variant_utf8(args[0]);
        const std::string enums = variant_utf8(args[1]);
        std::lock_guard<std::recursive_mutex> guard(self->mutex);
        if (self->ctx) n = bf6_loadout_soldier(self->ctx, req.c_str(), enums.c_str(), &blob);
    }
    return_blob(ret, blob, n);
}

// The VALIDATE map checks (bf6_map_validate), shared with the Unreal SDK. Needs
// no open context.
//
//   map_validate(scene_json: String) -> String (JSON {"items":[...]}, "" on bad input)

static void call_core_map_validate(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    std::string text;
    if (argc == 1) {
        const std::string scene = variant_utf8(args[0]);
        uint8_t *blob = nullptr;
        const int64_t n = bf6_map_validate(scene.c_str(), scene.size(), &blob);
        if (n > 0 && blob) text.assign(reinterpret_cast<const char *>(blob), size_t(n));
        bf6_blob_free(blob);
    }
    return_string(ret, text);
}

// MODE SETUP's pieces and SCATTER's layout (bf6_mode_plan, bf6_scatter_layout),
// shared with the Unreal SDK. Neither needs an open context.
//
//   mode_plan(request_json: String) -> String (JSON, "" on a bad request)
//   scatter_layout(request_json: String, ground: Callable) -> String (JSON)
//       ground.call(x, z, ref_y, terrain_only: bool) returns the height under
//       the point, or null for nothing there. An invalid Callable skips it.

static void call_core_mode_plan(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    std::string text;
    if (argc == 1) {
        const std::string req = variant_utf8(args[0]);
        uint8_t *blob = nullptr;
        const int64_t n = bf6_mode_plan(req.c_str(), req.size(), &blob);
        if (n > 0 && blob) text.assign(reinterpret_cast<const char *>(blob), size_t(n));
        bf6_blob_free(blob);
    }
    return_string(ret, text);
}

struct ScatterGround {
    GDExtensionConstVariantPtr callable = nullptr;
};

static int scatter_ground_bridge(void *user, double x, double z, double ref_y, int terrain_only, double *out_y) {
    static auto variant_call = load<GDExtensionInterfaceVariantCall>("variant_call");
    static auto variant_destroy = load<GDExtensionInterfaceVariantDestroy>("variant_destroy");
    static auto variant_type = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    static GDExtensionVariantFromTypeConstructorFunc from_float = get_variant_from(GDEXTENSION_VARIANT_TYPE_FLOAT);
    static GDExtensionVariantFromTypeConstructorFunc from_bool = get_variant_from(GDEXTENSION_VARIANT_TYPE_BOOL);
    static GDExtensionTypeFromVariantConstructorFunc to_float = get_variant_to(GDEXTENSION_VARIANT_TYPE_FLOAT);
    auto *g = static_cast<ScatterGround *>(user);
    if (!g || !g->callable) return 0;
    alignas(8) uint8_t vx[40] = {}, vz[40] = {}, vy[40] = {}, vt[40] = {}, result[40] = {};
    double dx = x, dz = z, dy = ref_y;
    GDExtensionBool bt = terrain_only ? 1 : 0;
    from_float(&vx, &dx);
    from_float(&vz, &dz);
    from_float(&vy, &dy);
    from_bool(&vt, &bt);
    const GDExtensionConstVariantPtr call_args[4] = { &vx, &vz, &vy, &vt };
    alignas(8) uint8_t method[16] = {};
    sn_new(&method, "call", false);
    GDExtensionCallError error = {};
    variant_call(const_cast<GDExtensionVariantPtr>(g->callable), &method, call_args, 4, &result, &error);
    get_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME)(&method);
    int hit = 0;
    if (error.error == GDEXTENSION_CALL_OK) {
        const GDExtensionVariantType t = variant_type(&result);
        if (t == GDEXTENSION_VARIANT_TYPE_FLOAT || t == GDEXTENSION_VARIANT_TYPE_INT) {
            double y = 0.0;
            if (t == GDEXTENSION_VARIANT_TYPE_FLOAT) {
                to_float(&y, &result);
            } else {
                static GDExtensionTypeFromVariantConstructorFunc to_int = get_variant_to(GDEXTENSION_VARIANT_TYPE_INT);
                int64_t iy = 0;
                to_int(&iy, &result);
                y = double(iy);
            }
            *out_y = y;
            hit = 1;
        }
        variant_destroy(&result);
    }
    variant_destroy(&vx);
    variant_destroy(&vz);
    variant_destroy(&vy);
    variant_destroy(&vt);
    return hit;
}

static void call_core_scatter_layout(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    static auto variant_type = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    std::string text;
    if (argc >= 1) {
        const std::string req = variant_utf8(args[0]);
        ScatterGround g;
        if (argc >= 2 && variant_type(args[1]) == GDEXTENSION_VARIANT_TYPE_CALLABLE) g.callable = args[1];
        uint8_t *blob = nullptr;
        const int64_t n = bf6_scatter_layout(req.c_str(), req.size(), g.callable ? scatter_ground_bridge : nullptr, &g, &blob);
        if (n > 0 && blob) text.assign(reinterpret_cast<const char *>(blob), size_t(n));
        bf6_blob_free(blob);
    }
    return_string(ret, text);
}
