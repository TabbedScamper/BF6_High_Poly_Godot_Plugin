// Installed-game environment products. Protocol v1 is a LE uint32 JSON byte
// length followed by UTF-8 metadata and owned binary blocks. No ABI structs,
// pointers or disk intermediates cross into Godot. All offsets are body-relative.
namespace bf6_godot_env {
struct Object {
    std::string text = "{";
    bool comma = false;
    void key(const char* name) {
        if (comma) text += ',';
        comma = true;
        append_json_string(text, name); text += ':';
    }
    void value(const char* v) { append_json_string(text, v ? v : ""); }
    void value(const std::string& v) { value(v.c_str()); }
    template<class T, std::enable_if_t<std::is_arithmetic_v<T> || std::is_enum_v<T>, int> = 0> void value(T v) {
        char b[64];
        if (!std::isfinite(double(v))) { text += "null"; return; }
        std::snprintf(b, sizeof(b), "%.17g", double(v)); text += b;
    }
    template<class T, size_t N> void value(const T (&v)[N]) {
        text += '[';
        for (size_t i=0; i<N; ++i) { if(i) text+=','; value(v[i]); }
        text += ']';
    }
    template<class T> void put(const char* k, const T& v) { key(k); value(v); }
    std::string done() const { return text + '}'; }
};
struct Frame {
    Object meta;
    std::vector<uint8_t> body;
    Frame() { meta.put("version", 1); meta.put("ok", 1); }
    void block(const char* name, const void* data, size_t bytes) {
        if ((!data && bytes) || bytes > 768ull*1024*1024 || body.size() > 768ull*1024*1024-bytes)
            throw std::runtime_error("environment buffer exceeds limit or is absent");
        Object info; info.put("offset", body.size()); info.put("bytes", bytes);
        meta.key(name); meta.text += info.done();
        if(bytes) { const auto* b=static_cast<const uint8_t*>(data); body.insert(body.end(), b, b+bytes); }
    }
};
#include "bf6_environment_fields.inc"

static void read(BF6CoreBinding& self, const std::string& level,
                 const std::string& kind, int detail, Frame& f) {
    char error[1024] = {};
    if (level.empty()) throw std::runtime_error("A level is required");
    if (self.environment_level != level) {
        // Environment readers need archives/schema, not a second placement
        // walk beside Godot's scene reader. Retain the full route for A/B.
        const char* compare = std::getenv("BF6_ENVIRONMENT_FULL_WALK");
        const int status = compare && std::strcmp(compare, "1") == 0
            ? bf6_open_level(self.ctx, level.c_str(), nullptr, 0, error, sizeof(error))
            : bf6_prepare_level(self.ctx, level.c_str(), error, sizeof(error));
        if (status != 0)
            throw std::runtime_error(error[0] ? error : "Could not open the selected level");
        self.environment_level = level;
        self.ocean.clear(); self.ocean_time_ms=-1;
    }
    f.meta.put("level", level); f.meta.put("kind", kind);
    if (kind=="terrain" || kind=="terrain_depth" || kind=="water_height") {
        const bool compact = kind=="terrain_depth" || detail>0;
        const int limit = kind=="water_height" ? 2048 : 1024;
        int source_size=0;
        bf6_terrain* t = compact
            ? bf6_read_terrain_preview(self.ctx,level.c_str(),kind=="water_height",limit,&source_size)
            : kind!="water_height" ? bf6_read_terrain(self.ctx, level.c_str())
                : bf6_read_water_heightfield(self.ctx, level.c_str());
        if (!t) { f.meta.put("present", 0); return; }
        try {
            if(t->width<1 || t->height<1 || t->width>16385 || t->height>16385)
                throw std::runtime_error("invalid heightfield dimensions");
            if(compact) {
                f.meta.put("present",1); f.meta.put("width",t->width); f.meta.put("height",t->height);
                f.meta.put("source_width",source_size); f.meta.put("source_height",source_size);
                f.meta.put("world_min",t->world_min); f.meta.put("world_max",t->world_max);
                f.meta.put("height_scale",t->height_scale);
                f.block("heights",t->heights,size_t(t->width)*t->height*2);
                bf6_free(self.ctx,t); return;
            }
            // Same sampling as Unreal MakeHeightTexture, before crossing into
            // Godot. A 16385-square terrain exceeds Godot's Image pixel limit.
            const int pw=std::clamp(t->width/4,64,limit), ph=std::clamp(t->height/4,64,limit);
            std::vector<uint16_t> preview(size_t(pw)*ph);
            for(int y=0;y<ph;++y) for(int x=0;x<pw;++x)
                preview[size_t(y)*pw+x]=t->heights[size_t(y*t->height/ph)*t->width+x*t->width/pw];
            f.meta.put("present", 1); f.meta.put("width", compact?pw:t->width); f.meta.put("height", compact?ph:t->height);
            f.meta.put("source_width",t->width); f.meta.put("source_height",t->height);
            f.meta.put("world_min", t->world_min); f.meta.put("world_max", t->world_max);
            f.meta.put("height_scale", t->height_scale);
            if(compact) f.block("heights",preview.data(),preview.size()*2);
            else {
                f.block("heights", t->heights, size_t(t->width)*t->height*2);
                f.meta.put("preview_width",pw); f.meta.put("preview_height",ph);
                f.block("preview_heights",preview.data(),preview.size()*2);
            }
        } catch (...) { bf6_free(self.ctx,t); throw; }
        bf6_free(self.ctx,t); return;
    }
    if(kind=="water_frame") {
        if(detail<0) throw std::runtime_error("simulation time must be nonnegative milliseconds");
        if(self.ocean.empty()) {
            bf6_water_sim_v2 sims[4]={};
            int n=bf6_level_water_sims_effective(self.ctx,level.c_str(),1,sims,4,nullptr);
            if(n<0 || n>4) throw std::runtime_error("invalid cascade count");
            std::vector<bf6_ocean::Cascade> ocean(n);
            for(int i=0;i<n;++i) if(!ocean[i].initialize(sims[i]))
                throw std::runtime_error("could not initialize ocean cascade");
            self.ocean=std::move(ocean);
        }
        if(detail<self.ocean_time_ms) {
            for(auto& c:self.ocean) std::fill(c.history.begin(),c.history.end(),0.f);
            self.ocean_time_ms=-1;
        }
        float dt=self.ocean_time_ms<0?0.f:float(detail-self.ocean_time_ms)*.001f;
        f.meta.put("time_ms",detail); f.meta.put("count",self.ocean.size());
        f.meta.key("resolutions"); f.meta.text+='[';
        for(size_t i=0;i<self.ocean.size();++i) {
            auto& c=self.ocean[i]; c.evolve(float(detail)*.001f,dt);
            if(i)f.meta.text+=','; f.meta.text+=std::to_string(c.input.resolution);
        }
        f.meta.text+=']';
        for(size_t i=0;i<self.ocean.size();++i) {
            auto& c=self.ocean[i];
            f.block(("displacement"+std::to_string(i)).c_str(),c.displacement.data(),c.displacement.size()*sizeof(bf6_ocean::Pixel));
            f.block(("normal"+std::to_string(i)).c_str(),c.normal.data(),c.normal.size()*sizeof(bf6_ocean::Pixel));
        }
        self.ocean_time_ms=detail; return;
    }
    if(kind=="water" || kind=="water_h0") {
        bf6_water_sim_v2 sims[4] = {};
        int n = bf6_level_water_sims_effective(self.ctx, level.c_str(), 1, sims, 4, nullptr);
        if(n<0 || n>4) throw std::runtime_error("invalid ocean cascade count");
        if(kind=="water_h0") {
            if(detail<0 || detail>=n) throw std::runtime_error("ocean cascade index out of range");
            int count=bf6_water_spectrum_h0(&sims[detail], nullptr, 0);
            if(count<=0 || count>2*2048*2048) throw std::runtime_error("invalid ocean spectrum size");
            std::vector<float> h0(count);
            if(bf6_water_spectrum_h0(&sims[detail],h0.data(),count)!=count)
                throw std::runtime_error("ocean spectrum generation failed");
            f.meta.put("resolution", sims[detail].resolution);
            f.block("h0", h0.data(),h0.size()*sizeof(float)); return;
        }
        f.meta.key("cascades"); f.meta.text+='[';
        for(int i=0;i<n;++i) { if(i)f.meta.text+=','; f.meta.text+=describe(sims[i]).done(); }
        f.meta.text+=']';
        int total=bf6_level_water_render(self.ctx,level.c_str(),nullptr,0);
        if(total<0 || total>4096) throw std::runtime_error("invalid water surface count");
        std::vector<bf6_water_render> rows(total);
        if(total && bf6_level_water_render(self.ctx,level.c_str(),rows.data(),total)!=total)
            throw std::runtime_error("water surface count changed");
        const int basic_count=bf6_level_water(self.ctx,level.c_str(),nullptr,0);
        if(basic_count<0 || basic_count>4096) throw std::runtime_error("invalid basic water surface count");
        std::vector<bf6_water> basic(basic_count);
        if(basic_count && bf6_level_water(self.ctx,level.c_str(),basic.data(),basic_count)!=basic_count)
            throw std::runtime_error("basic water surface count changed");
        f.meta.key("surfaces"); f.meta.text+='[';
        for(int i=0;i<total;++i) {
            if(i)f.meta.text+=',';
            Object row=describe(rows[i]);
            // Unreal joins these two native products by index. Verify the
            // geometry first so reordered data cannot attach another lake's
            // ocean gate or colour to this surface after a game update.
            if(i<basic_count && basic[i].center[0]==rows[i].center[0] &&
               basic[i].center[1]==rows[i].center[1] && basic[i].height==rows[i].height &&
               basic[i].size[0]==rows[i].size[0] && basic[i].size[1]==rows[i].size[1]) {
                row.put("is_ocean",basic[i].is_ocean);
                row.put("shallow",basic[i].shallow); row.put("deep",basic[i].deep);
                row.put("surface_join_valid",1);
            } else row.put("surface_join_valid",0);
            f.meta.text+=row.done();
        }
        f.meta.text+=']'; return;
    }
    if(kind=="water_mask") {
        bf6_water_mask m = {};
        if(!bf6_level_water_mask(self.ctx,level.c_str(),&m,error,sizeof(error))) {
            f.meta.put("present",0); f.meta.put("reason",error); return;
        }
        f.meta.put("present",1);
        f.meta.key("mask"); f.meta.text+=describe(m).done();
        f.block("atlas",m.atlas_r8,size_t(m.tile_side)*m.tile_side*m.page_count);
        f.block("indirection",m.indirection_u32,size_t(m.indirection_side)*m.indirection_side*4); return;
    }
    if(kind=="ground") {
        if(detail<64 || detail>4096) throw std::runtime_error("ground coverage size outside 64..4096");
        bf6_ground_coverage g = {};
        if(!bf6_ground_coverage_get(self.ctx,level.c_str(),detail,&g,error,sizeof(error)))
            throw std::runtime_error(error);
        f.meta.put("size",g.size); f.meta.put("lo",g.lo); f.meta.put("hi",g.hi);
        f.meta.put("empty_fraction",g.empty_fraction); f.meta.put("slot_count",g.slot_count);
        f.meta.key("materials"); f.meta.text+='[';
        for(int i=0;i<g.material_count;++i) { if(i)f.meta.text+=','; f.meta.text+=describe(g.materials[i]).done(); }
        f.meta.text+=']';
        const size_t pixels=size_t(g.size)*g.size;
        if(g.slot_count<1 || g.slot_count>8 || g.material_count<1 || g.material_count>255)
            throw std::runtime_error("ground coverage exceeds renderer slot/material budget");
        for(int group=0;group<2;++group) {
            std::vector<uint8_t> ids(pixels*4,255), weights(pixels*4,0);
            for(size_t p=0;p<pixels;++p) for(int lane=0;lane<4;++lane) {
                const int slot=group*4+lane;
                if(slot<g.slot_count) {
                    ids[p*4+lane]=g.idx[p*g.slot_count+slot];
                    weights[p*4+lane]=g.weight[p*g.slot_count+slot];
                }
            }
            f.block(group?"idx1":"idx0",ids.data(),ids.size());
            f.block(group?"weight1":"weight0",weights.data(),weights.size());
        }
        f.block("colour",g.colour,g.colour?pixels*3:0);
        bf6_terrain_bake_opts opts={}; opts.rect_min[0]=g.lo[0]; opts.rect_min[1]=g.lo[1];
        opts.rect_size=g.hi[0]-g.lo[0]; opts.size=std::min(detail,2048); opts.want_normal=1;
        opts.stochastic=1; opts.colour_map=1; opts.fallback_colour_map=1;
        bf6_terrain_bake b={};
        if(bf6_bake_terrain(self.ctx,level.c_str(),&opts,&b,error,sizeof(error))) {
            f.meta.put("bake_size",b.size);
            f.block("baked_albedo",b.albedo,size_t(b.size)*b.size*4);
            f.block("baked_normal",b.normal,b.normal?size_t(b.size)*b.size*4:0);
        }
        return;
    }
    if(kind=="far_ground") {
        if(detail<64 || detail>4096) throw std::runtime_error("far ground size outside 64..4096");
        bf6_terrain_bake_opts opts={}; opts.size=detail; opts.stochastic=1;
        opts.colour_map=1; opts.fallback_colour_map=1; opts.want_normal=1;
        bf6_terrain_bake b={};
        if(!bf6_bake_terrain(self.ctx,level.c_str(),&opts,&b,error,sizeof(error)))
            throw std::runtime_error(error);
        f.meta.put("size",b.size); f.meta.put("lo",b.lo); f.meta.put("hi",b.hi);
        f.block("albedo",b.albedo,size_t(b.size)*b.size*4);
        f.block("normal",b.normal,b.normal?size_t(b.size)*b.size*4:0); return;
    }
    if(kind.rfind("sheet:",0)==0) {
        if(detail<4 || detail>4096) throw std::runtime_error("sheet size outside 4..4096");
        std::vector<uint8_t> rgba(size_t(detail)*detail*4);
        if(!bf6_layer_sheet(self.ctx,kind.c_str()+6,detail,rgba.data(),error,sizeof(error)))
            throw std::runtime_error(error);
        f.meta.put("width",detail); f.meta.put("height",detail); f.meta.put("format",0);
        f.block("pixels",rgba.data(),rgba.size()); return;
    }
    if(kind.rfind("texture:",0)==0) {
        // A texture capped at the given largest dimension, as the Unreal add-on
        // binds decal sheets (1024 for detail, 16384 for markings).
        const int max_dim=std::atoi(kind.c_str()+8);
        const bf6_texture* t=bf6_texture_at_max_dim(self.ctx,detail,max_dim>0?max_dim:1024);
        if(!t || !t->data || t->data_len<=0) throw std::runtime_error("texture unavailable");
        f.meta.put("width",t->width); f.meta.put("height",t->height);
        f.meta.put("mip_count",t->mip_count); f.meta.put("format",t->format);
        f.meta.put("srgb",t->srgb); f.block("pixels",t->data,t->data_len);
        bf6_release_texture_payload(self.ctx,detail,max_dim>0?max_dim:1024); return;
    }
    if(kind=="decal_draws") {
        // The level's road paint and ground decals from the shared core
        // (bf6_level_decal_draws), draped on the shared terrain mesh: the
        // same draws, styles and order the Unreal add-on builds.
        bf6_terrain* t=bf6_read_terrain(self.ctx,level.c_str());
        if(!t || t->width<=1) { if(t) bf6_free(self.ctx,t); f.meta.put("present",0); return; }
        const double wmin[3]={t->world_min[0],t->world_min[1],t->world_min[2]};
        const double wmax[3]={t->world_max[0],t->world_max[1],t->world_max[2]};
        bf6_terrain_mesh* m=bf6_terrain_mesh_build(t->heights,t->width,wmin,wmax,t->height_scale,nullptr);
        bf6_decal_draws* d=m?bf6_level_decal_draws(self.ctx,level.c_str(),m,nullptr):nullptr;
        if(!d) { bf6_terrain_mesh_free(m); bf6_free(self.ctx,t); f.meta.put("present",0); return; }
        // Split per attribute so Godot can slice them straight into vector arrays.
        std::vector<float> positions, uvs, colors;
        f.meta.put("present",1);
        f.meta.key("draws"); f.meta.text+='[';
        const int n=bf6_decal_draws_count(d);
        for(int i=0;i<n;++i) {
            bf6_decal_draw w{}; bf6_decal_draws_get(d,i,&w);
            Object o;
            o.put("record",w.record); o.put("draw_index",w.draw_index); o.put("sort_key",w.sort_key);
            o.put("band",w.band); o.put("marking",w.marking); o.put("wear",w.wear);
            o.put("albedo",w.albedo); o.put("normal",w.normal); o.put("opacity",w.opacity);
            o.put("tint",w.tint); o.put("opacity_scale",w.opacity_scale);
            o.put("mask_select",w.mask_select); o.put("mip_bias",w.mip_bias);
            o.put("first",positions.size()/3); o.put("vertex_count",w.vertex_count);
            for(int v=0;v<w.vertex_count;++v) {
                const float* p=w.verts+size_t(v)*9;
                positions.insert(positions.end(),p,p+3);
                uvs.insert(uvs.end(),p+3,p+5);
                colors.insert(colors.end(),p+5,p+9);
            }
            if(i) f.meta.text+=','; f.meta.text+=o.done();
        }
        f.meta.text+=']';
        bf6_decal_draw_stats s{}; bf6_decal_draws_stats(d,&s);
        Object st;
        st.put("records",s.records); st.put("drawn",s.drawn); st.put("triangles",s.triangles);
        st.put("painted",s.painted); st.put("colourless",s.colourless); st.put("tint_clamped",s.tint_clamped);
        st.put("second_colour",s.second_colour); st.put("markings",s.markings); st.put("wear_softened",s.wear_softened);
        st.put("base_surface_blended",s.base_surface_blended); st.put("surface_blended",s.surface_blended);
        f.meta.key("stats"); f.meta.text+=st.done();
        f.block("positions",positions.data(),positions.size()*sizeof(float));
        f.block("uvs",uvs.data(),uvs.size()*sizeof(float));
        f.block("colors",colors.data(),colors.size()*sizeof(float));
        bf6_decal_draws_free(d); bf6_terrain_mesh_free(m); bf6_free(self.ctx,t); return;
    }
    if(kind=="texture") {
        const bf6_texture* t=bf6_texture_at(self.ctx,detail);
        if(!t || !t->data || t->data_len<=0) throw std::runtime_error("water texture unavailable");
        f.meta.put("width",t->width); f.meta.put("height",t->height);
        f.meta.put("mip_count",t->mip_count); f.meta.put("format",t->format);
        f.meta.put("srgb",t->srgb); f.block("pixels",t->data,t->data_len); return;
    }
    // FX EMITTER LAYERS, per layer, from the install.
    //
    // THE POINT OF THIS PRODUCT. The Godot FX builder drew from ~40 curated
    // emitter-GRAPH archetypes while the game authors thousands of LAYERS, and
    // the core's own header says what that costs: merging them "throws away
    // exactly the variation that makes an explosion read as an explosion and
    // leaves a generic puff". On mp_subsurface, 665 layers resolve to 378
    // DISTINCT looks and base size alone spans 0.01 to 30 - a range no
    // archetype table can carry. Unreal already reads this record; Godot could
    // not reach it at all, which is why its FX are the ones that look wrong.
    //
    // The look is resolved BY THE CORE (bf6_fx_layer_look) so both editors read
    // the same values for the same layer instead of each naming pids itself.
    if(kind=="fx_layers") {
        // bf6_level_fx needs the level WALKED, not merely prepared: a layer is
        // reached through the placement graph. read() prepares by default
        // because most products do not need the walk, so this product asks for
        // it explicitly rather than failing with "call bf6_open_level first".
        if(bf6_open_level(self.ctx,level.c_str(),nullptr,0,error,sizeof(error))!=0)
            throw std::runtime_error(error[0]?error:"could not walk the level for FX");
        bf6_fx_stats fst{};
        const int total=bf6_level_fx(self.ctx,level.c_str(),nullptr,0,&fst,error,sizeof(error));
        if(total<0) throw std::runtime_error(error[0]?error:"fx layers unavailable");
        std::vector<bf6_fx_layer> rows((size_t)(total>0?total:1));
        const int got=total>0
            ? bf6_level_fx(self.ctx,level.c_str(),rows.data(),total,&fst,error,sizeof(error))
            : 0;
        f.meta.put("count",got);
        // When a level reports no layers the reason matters: "this level has
        // none" and "the reader could not reach them" look identical from here
        // otherwise, and the second is a bug.
        f.meta.put("reader_note",error[0]?error:"");
        f.meta.put("stat_effects",fst.distinct_effects);
        f.meta.put("stat_placements",fst.placements);
        f.meta.put("stat_layers",fst.layers);
        // WHICH BIT OF `has` IS WHICH FIELD, asked of the CORE rather than
        // listed here. This file used to carry its own 31-name array in enum
        // order; the enum grew to 80 and every bit after the first insertion
        // silently pointed at the wrong field, so every over-life curve stopped
        // resolving while all the counts still looked right. The names now come
        // from bf6_fx_look_field_name, which is generated from the same table
        // as the enum and cannot disagree with it.
        {
            Object bits;
            for(int b=0;b<BF6_FXLOOK_COUNT;b++) {
                const char* n=bf6_fx_look_field_name(b);
                if(n && *n) bits.put(n,b);
            }
            f.meta.key("has_bits"); f.meta.text+=bits.done();
        }
        f.meta.key("layers"); f.meta.text+='[';
        for(int i=0;i<got;i++) {
            if(i) f.meta.text+=',';
            const bf6_fx_layer& L=rows[(size_t)i];
            bf6_fx_look k{};
            bf6_fx_layer_look(&L,&k);
            Object o;
            o.put("effect",L.effect?L.effect:"");
            o.put("graph",L.graph?L.graph:"");
            o.put("family",L.family?L.family:"");
            o.put("layer",L.layer);
            o.put("placements",L.placements);
            // THE LAYER'S OWN OFFSET inside the effect. An effect is placed
            // once; its layers sit at different points within it, which is how
            // a fire keeps its flame at the base and its smoke column above.
            // Dropping this stacks every layer on the placement origin.
            o.put("local",L.local);
            o.put("atlas",L.atlas?L.atlas:"");
            // The RES the rid resolved to. The partition name above is not what
            // a texture reader looks a sheet up by, so without this a consumer
            // has to guess and lands on a similarly named atlas with a
            // different grid - right texture, wrong frames.
            o.put("atlas_res",L.atlas_res?L.atlas_res:"");
            o.put("atlas_from_override",L.atlas_from_override);
            o.put("mesh",L.mesh?L.mesh:"");
            o.put("mesh_is_placeholder",L.mesh_is_placeholder);
            o.put("atlas_cols",L.atlas_cols);
            o.put("atlas_frames",L.atlas_frames);
            o.put("atlas_left_right",L.atlas_left_right);
            // The three that decide how a particle is drawn at all.
            o.put("lighting_model",L.lighting_model);
            o.put("alignment",L.alignment);
            o.put("particle_type",L.particle_type);
            o.put("sort_mode",L.sort_mode);
            o.put("draw_layer",L.draw_layer);
            o.put("spawn_mode",L.spawn_mode?L.spawn_mode:"");
            o.put("has_spawn_rate",L.has_spawn_rate);
            o.put("spawn_rate",L.spawn_rate);
            o.put("particle_max",L.particle_max);
            o.put("particle_life",L.particle_life);
            o.put("emitter_life",L.emitter_life);
            o.put("preroll_time",L.preroll_time);
            o.put("cull_distance",L.gpu_cull_distance);
            // THE RESOLVED LOOK, EVERY FIELD, walked rather than listed.
            //
            // This used to name about thirty fields by hand while the core
            // resolved eighty, and the two disagreeing is worse than either
            // alone: the `has` mask said RandomForce and SpawnScale were
            // authored while their values were simply absent from the payload,
            // so the consumer read them as an authored ZERO and every emitter
            // came out with no turbulence and an identical spawn volume. A
            // serialiser that names fields can always fall behind a resolver
            // that fills them; one that walks them cannot.
            for(int b=0;b<BF6_FXLOOK_COUNT;b++) {
                const char* nm=bf6_fx_look_field_name(b);
                if(!nm||!*nm) continue;
                float v[4]={0,0,0,0};
                const int arity=bf6_fx_look_field_value(&k,b,v);
                if(arity<=0) continue;
                if(arity==1) o.put(nm,v[0]);
                else if(arity==2) { const float a2[2]={v[0],v[1]}; o.put(nm,a2); }
                else if(arity==3) { const float a3[3]={v[0],v[1],v[2]}; o.put(nm,a3); }
                else o.put(nm,v);
            }
            // WHICH OF THEM THE LAYER ACTUALLY STATED, as 32-bit words: the
            // mask is 128 bits and JSON carries only doubles, exact to 2^53, so
            // one number would silently lose its high bits - and the fields
            // that vanished would be the ones added most recently.
            {
                uint32_t w[4];
                for(int q=0;q<2;q++){ w[q*2]=(uint32_t)(k.has[q]&0xFFFFFFFFu);
                                      w[q*2+1]=(uint32_t)(k.has[q]>>32); }
                o.put("has",w);
            }
            f.meta.text+=o.done();
        }
        f.meta.text+=']';
        return;
    }

    // PLACED SPATIAL SOUND EMITTERS: the level's ambient bed.
    //
    // detail selects what comes back: 0 is the emitter list alone (metadata,
    // cheap), 1+ additionally decodes the PCM for the emitter at index
    // detail-1, so a caller streams one sound at a time rather than pulling a
    // level's whole audio bed across in one packet.
    //
    // The falloff (radius, loudness) comes from the sound CONFIG and is read by
    // the core, so Godot and Unreal attenuate identically instead of each
    // inventing a curve the game does not have.
    if(kind=="sound_emitters") {
        const int total=bf6_level_sound_emitters(self.ctx,level.c_str(),nullptr,0,error,sizeof(error));
        if(total<0) throw std::runtime_error(error[0]?error:"sound emitters unavailable");
        std::vector<bf6_sound_emitter> rows((size_t)(total>0?total:1));
        const int got=total>0
            ? bf6_level_sound_emitters(self.ctx,level.c_str(),rows.data(),total,error,sizeof(error))
            : 0;
        f.meta.put("count",got);
        f.meta.key("emitters"); f.meta.text+='[';
        for(int i=0;i<got;i++) {
            if(i) f.meta.text+=',';
            const bf6_sound_emitter& s=rows[(size_t)i];
            Object o;
            o.put("xform",s.xform);
            o.put("sound",s.sound);
            o.put("amplitude",s.amplitude);
            o.put("play",(int)s.play_on_creation);
            o.put("flags",s.flags);
            o.put("radius",s.radius);
            o.put("loudness",s.loudness);
            f.meta.text+=o.done();
        }
        f.meta.text+=']';
        // ONE sound's PCM, when asked for. Decoded here rather than in GDScript
        // because the core already owns the config-or-wave decision.
        if(detail>0 && detail<=got) {
            const bf6_sound_emitter& s=rows[(size_t)(detail-1)];
            int ch=0,rate=0;
            int n=bf6_ui_sound_decode(self.ctx,s.sound,0,nullptr,0,&ch,&rate);
            // A few configs are graphs referencing other sounds and decode at
            // no variation; reported as zero samples rather than as an error,
            // because the emitter is still real and still worth placing.
            bool gave_pcm=false;
            if(n>0 && ch>0 && rate>0) {
                std::vector<int16_t> pcm((size_t)n);
                n=bf6_ui_sound_decode(self.ctx,s.sound,0,pcm.data(),n,&ch,&rate);
                if(n>0) {
                    f.meta.put("pcm_channels",ch); f.meta.put("pcm_rate",rate);
                    f.meta.put("pcm_samples",n);
                    f.block("pcm",pcm.data(),(size_t)n*sizeof(int16_t));
                    gave_pcm=true;
                }
            }
            // Always answer the question that was asked: a caller must be able
            // to tell "this one has no wave" from "the field is missing".
            if(!gave_pcm) f.meta.put("pcm_samples",0);
        }
        return;
    }

    // REFLECTION VOLUMES: the authored local IBL boxes.
    //
    // Without them an editor has only the sky to reflect, which is why
    // interiors preview grey and metal reads as plastic. The transform is a
    // FULL BASIS whose axis lengths ARE the box half-extents, handed over as
    // authored so the consumer decides how to build its own probe.
    //
    // Level-layer volumes only, and that is a measured decision rather than a
    // limitation nobody looked at: scanning all 220,000 mounted partitions
    // finds the level's own volumes in its lighting layer in WORLD space
    // (farthest 1445 m on mp_isolated), while every other carrier is a prefab
    // holding PREFAB-LOCAL transforms (bounded by the prefab's own size: 190 m,
    // 33 m, 10 m) and each appears twice, once as pf_X and once as
    // pf_X_nongroupable_autogen. Placing those without composing their prefab
    // placements would scatter probes around the origin and double them.
    if(kind=="reflection_probes") {
        const int total=bf6_level_reflection_probes(self.ctx,level.c_str(),nullptr,0,error,sizeof(error));
        if(total<0) throw std::runtime_error(error[0]?error:"reflection volumes unavailable");
        std::vector<bf6_reflection_probe> probes((size_t)(total>0?total:1));
        const int got=total>0
            ? bf6_level_reflection_probes(self.ctx,level.c_str(),probes.data(),total,error,sizeof(error))
            : 0;
        f.meta.put("count",got);
        f.meta.key("probes"); f.meta.text+='[';
        for(int i=0;i<got;i++) {
            if(i) f.meta.text+=',';
            const bf6_reflection_probe& p=probes[(size_t)i];
            Object o;
            o.put("right",p.right); o.put("up",p.up); o.put("forward",p.forward);
            o.put("translation",p.translation);
            o.put("texture",p.texture); o.put("guid",p.guid);
            o.put("is_global",(int)p.is_global);
            f.meta.text+=o.done();
        }
        f.meta.text+=']';
        return;
    }

    // MATERIAL RELATION GRID: what the game does when two surfaces meet.
    // Metadata only, no binary blocks - a caller wants one cell, not the
    // 200,000-cell matrix, so there is nothing large to carry.
    if(kind=="material_grid" || kind=="material_profile" || kind=="material_pair") {
        bf6_material_grid_stats st{};
        if(bf6_material_grid_info(self.ctx,level.c_str(),&st,error,sizeof(error))!=0)
            throw std::runtime_error(error[0]?error:"material grid unavailable");
        f.meta.put("side",st.side); f.meta.put("declared_dim",st.declared_dim);
        f.meta.put("id_map_len",st.id_map_len); f.meta.put("occupied_cells",st.occupied_cells);
        f.meta.put("relations",st.relations); f.meta.put("relation_types",st.relation_types);
        f.meta.put("fallback_ids",st.fallback_ids); f.meta.put("partition",st.partition);
        if(kind=="material_grid") {
            // The level's surfaces, busiest first, ordered by the core so this
            // panel and the Unreal one show the same list. detail caps the rows.
            const int cap = detail>0 ? detail : 24;
            const int total=bf6_material_busiest(self.ctx,level.c_str(),nullptr,0,error,sizeof(error));
            if(total<0) throw std::runtime_error(error[0]?error:"material ranking unavailable");
            std::vector<bf6_material_rank> rank((size_t)(total>0?total:1));
            const int got=total>0
                ? bf6_material_busiest(self.ctx,level.c_str(),rank.data(),total,error,sizeof(error))
                : 0;
            f.meta.put("shipped_materials",got);
            f.meta.key("busiest"); f.meta.text+='[';
            for(int i=0;i<got && i<cap;i++) {
                if(i) f.meta.text+=',';
                Object o;
                o.put("material",rank[(size_t)i].material);
                o.put("row",rank[(size_t)i].row);
                o.put("partners",rank[(size_t)i].partners);
                o.put("relations",rank[(size_t)i].relations);
                f.meta.text+=o.done();
            }
            f.meta.text+=']';
            return;
        }

        if(kind=="material_profile") {
            const int row=bf6_material_row(self.ctx,level.c_str(),detail,error,sizeof(error));
            if(row==-1) throw std::runtime_error(error[0]?error:"material row unavailable");
            f.meta.put("material",detail); f.meta.put("row",row);
            // -2 means the level does not ship it and the game falls back to
            // the default material. Reported as its own state so the panel
            // never shows the default's relations as though they were this
            // material's own.
            f.meta.put("shipped",row>=0?1:0);
            bf6_material_profile pr{};
            if(bf6_material_profile_get(self.ctx,level.c_str(),detail,&pr,error,sizeof(error))<0)
                throw std::runtime_error(error[0]?error:"material profile unavailable");
            f.meta.put("partners",pr.partners); f.meta.put("row_relations",pr.relations);
            f.meta.key("categories"); f.meta.text+='{';
            bool first=true;
            for(int i=0;i<BF6_MATERIAL_CATEGORIES;i++) {
                const char* nm=bf6_material_category_name(i);
                if(!nm||!pr.by_category[i]) continue;
                if(!first) f.meta.text+=','; first=false;
                append_json_string(f.meta.text,nm); f.meta.text+=':';
                char b[32]; std::snprintf(b,sizeof(b),"%d",pr.by_category[i]); f.meta.text+=b;
            }
            f.meta.text+='}';
            return;
        }

        // material_pair: detail packs the ORDERED pair as (a << 10) | b, which
        // fits because a material id is 10 bits. Not symmetrised: four pairs
        // per level are authored one way.
        const int a=(detail>>10)&0x3FF, b=detail&0x3FF;
        f.meta.put("material_a",a); f.meta.put("material_b",b);
        const int n=bf6_material_relations(self.ctx,level.c_str(),a,b,nullptr,0,error,sizeof(error));
        if(n<0) throw std::runtime_error(error[0]?error:"material pair unavailable");
        std::vector<bf6_material_relation> rel((size_t)(n>0?n:1));
        const int got=n>0
            ? bf6_material_relations(self.ctx,level.c_str(),a,b,rel.data(),n,error,sizeof(error))
            : 0;
        f.meta.put("count",got);
        f.meta.key("relations"); f.meta.text+='[';
        for(int i=0;i<got;i++) {
            if(i) f.meta.text+=',';
            Object o;
            o.put("kind",rel[(size_t)i].kind);
            o.put("category",rel[(size_t)i].category);
            o.put("name",rel[(size_t)i].name);
            o.put("type",rel[(size_t)i].type);
            o.put("guid",rel[(size_t)i].guid);
            f.meta.text+=o.done();
        }
        f.meta.text+=']';
        return;
    }
    throw std::runtime_error("unknown environment product");
}
}

static void call_core_environment(void*, GDExtensionClassInstancePtr instance,
    const GDExtensionConstVariantPtr* args, GDExtensionInt argc,
    GDExtensionVariantPtr ret, GDExtensionCallError* error) {
    alignas(8) uint8_t output[16] = {};
    pba_ctor(&output,nullptr);
    auto* self=static_cast<BF6CoreBinding*>(instance);
    bf6_godot_env::Frame frame;
    try {
        auto type_of=load<GDExtensionInterfaceVariantGetType>("variant_get_type");
        if(argc!=3 || type_of(args[0])!=GDEXTENSION_VARIANT_TYPE_STRING ||
           type_of(args[1])!=GDEXTENSION_VARIANT_TYPE_STRING ||
           type_of(args[2])!=GDEXTENSION_VARIANT_TYPE_INT)
            throw std::runtime_error("environment expects (level: String, kind: String, detail: int)");
        if(!self) throw std::runtime_error("BF6Core instance missing");
        std::lock_guard<std::recursive_mutex> guard(self->mutex);
        if(!self->ctx) throw std::runtime_error("BF6Core is not open");
        int64_t detail=0; get_variant_to(GDEXTENSION_VARIANT_TYPE_INT)(&detail,const_cast<GDExtensionVariantPtr>(args[2]));
        if(detail<INT_MIN || detail>INT_MAX) throw std::runtime_error("detail outside int32 range");
        bf6_godot_env::read(*self,variant_utf8(args[0]),variant_utf8(args[1]),int(detail),frame);
        self->last_error.clear();
    } catch(const std::exception& e) {
        frame=bf6_godot_env::Frame(); frame.meta=bf6_godot_env::Object();
        frame.meta.put("version",1); frame.meta.put("ok",0); frame.meta.put("error",e.what());
    }
    const std::string json=frame.meta.done();
    uint32_t header=uint32_t(json.size());
    int64_t size=4+json.size()+frame.body.size();
    const void* resize_args[]={&size}; GDExtensionInt rc=0;
    pba_resize(&output,resize_args,&rc,1);
    int64_t actual=0; pba_size(&output,nullptr,&actual,0);
    if(actual==size) {
        uint8_t* dst=pba_index(&output,0);
        std::memcpy(dst,&header,4); std::memcpy(dst+4,json.data(),json.size());
        if(!frame.body.empty()) std::memcpy(dst+4+json.size(),frame.body.data(),frame.body.size());
    }
    get_variant_from(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(ret,&output);
    pba_dtor(&output);
    if(error) error->error=GDEXTENSION_CALL_OK;
}
