// WALKING THE MAP, through the shared core.
//
// bf6_walk_step is what the Unreal SDK's walk mode already steps on: the same
// probes at knee, chest and head, the same gravity, step-up, slope limit and
// stair snapping. Exposing it here rather than writing a second walker in
// GDScript is the whole point - a walk that behaved differently in the two
// editors would be a new divergence in exactly the system that is meant to
// prove the two agree.
//
// THE SURFACE IS DELIBERATELY THREE CALLS. The core's ray scene is a handful of
// primitives (create, add mesh, add instance, trace, clear, free), and binding
// each one through the raw GDExtension interface would be a lot of marshalling
// for no gain: the walker only ever wants "here is the world, now step". So the
// geometry arrives once as world-space triangles and the stepping is one
// array in, one array out.
//
//   walk_open(triangles: PackedFloat32Array) -> int   handle, 0 on failure
//       9 floats per triangle (x y z per corner), ALREADY IN WORLD SPACE and in
//       the core's frame: metres, Y up.
//   walk_step(handle: int, state_and_input: PackedFloat32Array)
//                                          -> PackedFloat32Array (10 floats)
//       in : pos[3] vel[3] vel_up grounded eye eye_last  wish[3] run crouch jump dt
//            (10 state + 7 input = 17)
//       out: pos[3] vel[3] vel_up grounded eye eye_last  (10)
//       The core walks in doubles; this crosses to float32 at the edge because
//       that is the packed array the binding already has helpers for. A float32
//       metre is good to about a quarter of a millimetre four kilometres out,
//       which is far finer than anything a walker can feel.
//       An empty array back means the handle was unknown or the input was the
//       wrong length - a silent no-op would read as "the walker is stuck".
//   walk_close(handle: int) -> bool

struct WalkHandle {
    int32_t id = 0;
    bf6_ray_scene* scene = nullptr;
    /* THE GAME'S OWN NUMBERS, read once when the walk opens. Step height, the
     * jump's horizontal cap and the landing penalty are authored by BF6; the
     * speeds are not, and stay the engine's. Read per handle rather than per
     * step because it costs a mount and never changes mid-walk. */
    bf6_walk_tuning tuning{};
};

static std::vector<WalkHandle*> g_walks;
static int32_t g_walk_next = 1;

static WalkHandle* walk_find(int64_t id) {
    for (WalkHandle* h : g_walks)
        if (h && h->id == (int32_t)id) return h;
    return nullptr;
}

static void call_core_walk_open(void *, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    auto *self = static_cast<BF6CoreBinding *>(instance);
    static auto type_of = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    if (argc != 1 || type_of(args[0]) != GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY) {
        return_int(ret, 0);
        return;
    }
    alignas(8) uint8_t tris[16] = {};
    get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&tris, const_cast<GDExtensionVariantPtr>(args[0]));
    int64_t n = 0;
    pfa_size(&tris, nullptr, &n, 0);
    const int64_t verts = n / 3;
    int64_t id = 0;
    if (verts >= 3) {
        bf6_ray_scene* scene = bf6_ray_scene_create();
        if (scene) {
            // The triangles arrive already wound and already in world space, so
            // the index list is just 0..verts-1 and the instance is identity.
            std::vector<int32_t> idx((size_t)(verts - verts % 3));
            for (size_t i = 0; i < idx.size(); ++i) idx[i] = (int32_t)i;
            const float* p = pfa_index(&tris, 0);
            const int32_t mesh = p ? bf6_ray_scene_add_mesh(scene, p, (int32_t)verts,
                                                            idx.data(), (int32_t)idx.size())
                                   : -1;
            if (mesh >= 0) {
                const double identity[12] = {1,0,0,0, 0,1,0,0, 0,0,1,0};
                if (bf6_ray_scene_add_instance(scene, mesh, identity) >= 0) {
                    auto* h = new WalkHandle();
                    h->id = g_walk_next++;
                    h->scene = scene;
                    /* Read the game's values when there is a game open; the
                     * defaults already carry the authored ones decoded from the
                     * current install, so a walk with no install still steps
                     * over the right kerb height. */
                    if (self && self->ctx) {
                        std::lock_guard<std::recursive_mutex> guard(self->mutex);
                        bf6_walk_tuning_read(self->ctx, &h->tuning);
                    } else {
                        bf6_walk_tuning_defaults(&h->tuning);
                    }
                    g_walks.push_back(h);
                    id = h->id;
                }
            }
            if (id == 0) bf6_ray_scene_free(scene);
        }
    }
    pfa_dtor(&tris);
    return_int(ret, id);
}

static void call_core_walk_step(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    alignas(8) uint8_t out[16] = {};
    pfa_ctor(&out, nullptr);
    static auto type_of = load<GDExtensionInterfaceVariantGetType>("variant_get_type");
    WalkHandle* h = argc == 2 && type_of(args[1]) == GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY
        ? walk_find(arg_int(args[0])) : nullptr;
    if (h && h->scene) {
        alignas(8) uint8_t in[16] = {};
        get_variant_to(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&in, const_cast<GDExtensionVariantPtr>(args[1]));
        int64_t n = 0;
        pfa_size(&in, nullptr, &n, 0);
        const float* v = n >= 17 ? pfa_index(&in, 0) : nullptr;
        if (v) {
            bf6_walk_state st{};
            st.pos[0] = v[0]; st.pos[1] = v[1]; st.pos[2] = v[2];
            st.vel[0] = v[3]; st.vel[1] = v[4]; st.vel[2] = v[5];
            st.vel_up = v[6];
            st.grounded = (int32_t)v[7];
            st.eye = v[8];
            st.eye_last = v[9];
            bf6_walk_input wi{};
            wi.wish[0] = v[10]; wi.wish[1] = v[11]; wi.wish[2] = v[12];
            wi.run = (int32_t)v[13];
            wi.crouch = (int32_t)v[14];
            wi.jump = (int32_t)v[15];
            wi.dt = v[16];
            bf6_walk_step_scene_tuned(&st, &wi, &h->tuning, h->scene);
            int64_t count = 10;
            GDExtensionInt rc = 0;
            const void *rargs[1] = { &count };
            pfa_resize(&out, rargs, &rc, 1);
            float* dst = pfa_index(&out, 0);
            if (dst) {
                // Explicit narrowing: the core walks in doubles and the packed
                // array is float32, so every one of these is a deliberate cast
                // rather than a warning worth reading past.
                dst[0] = (float)st.pos[0]; dst[1] = (float)st.pos[1]; dst[2] = (float)st.pos[2];
                dst[3] = (float)st.vel[0]; dst[4] = (float)st.vel[1]; dst[5] = (float)st.vel[2];
                dst[6] = (float)st.vel_up;
                dst[7] = st.grounded ? 1.0f : 0.0f;
                dst[8] = (float)st.eye;
                dst[9] = (float)st.eye_last;
            }
        }
        pfa_dtor(&in);
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(ret, &out);
    pfa_dtor(&out);
}

//   walk_tuning(handle: int) -> PackedFloat32Array
//       the numbers this walk is using, so an engine can show them and set what
//       it owns - the camera's field of view above all, which is authored as a
//       player option and is nobody's business but the engine's to apply.
//       [0] field of view, vertical degrees   [1] its minimum   [2] its maximum
//       [3] step height   [4] jump horizontal cap   [5] slide needed velocity
//       [6] vault max height   [7] walk speed   [8] run speed   [9] crouch speed
static void call_core_walk_tuning(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    alignas(8) uint8_t out[16] = {};
    pfa_ctor(&out, nullptr);
    WalkHandle* h = argc == 1 ? walk_find(arg_int(args[0])) : nullptr;
    if (h) {
        int64_t count = 10;
        GDExtensionInt rc = 0;
        const void *rargs[1] = { &count };
        pfa_resize(&out, rargs, &rc, 1);
        float* d = pfa_index(&out, 0);
        if (d) {
            d[0] = h->tuning.fov_vertical;
            d[1] = h->tuning.fov_vertical_min;
            d[2] = h->tuning.fov_vertical_max;
            d[3] = h->tuning.step_height;
            d[4] = h->tuning.jump_horizontal_cap;
            d[5] = h->tuning.slide_needed_velocity;
            d[6] = h->tuning.vault_max_height;
            d[7] = h->tuning.walk_speed;
            d[8] = h->tuning.run_speed;
            d[9] = h->tuning.crouch_speed;
        }
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(ret, &out);
    pfa_dtor(&out);
}

static void call_core_walk_close(void *, GDExtensionClassInstancePtr,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *) {
    bool closed = false;
    if (argc == 1) {
        const int64_t id = arg_int(args[0]);
        for (size_t i = 0; i < g_walks.size(); ++i) {
            if (g_walks[i] && g_walks[i]->id == (int32_t)id) {
                if (g_walks[i]->scene) bf6_ray_scene_free(g_walks[i]->scene);
                delete g_walks[i];
                g_walks.erase(g_walks.begin() + (long)i);
                closed = true;
                break;
            }
        }
    }
    return_bool(ret, closed);
}
