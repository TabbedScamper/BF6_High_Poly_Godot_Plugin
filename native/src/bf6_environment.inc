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
