/* Locate authored baked reflection textures without a name convention.
 *
 *   reflection_test <game-dir> <exe> <reflection-volume-partition>
 *
 * The BakedTexture field is reflected with no type in this build, so an
 * ordinary schema dump truthfully reports Null.  Ebx::import_ref is the
 * bounded escape hatch for exactly that case.  A fake field-hash control is
 * reported beside the real result.
 */
#include "source.h"
#include "types.h"
#include "ebx.h"

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <string>
#include <vector>

struct Vec3 { double x = 0, y = 0, z = 0; };

static double real(const bf6::EbxValue* v)
{
    if (!v) return 0.0;
    if (v->kind == bf6::EbxValue::Kind::Real) return v->f;
    if (v->kind == bf6::EbxValue::Kind::Int) return static_cast<double>(v->i);
    if (v->kind == bf6::EbxValue::Kind::Uint) return static_cast<double>(v->u);
    return 0.0;
}

static Vec3 vec3(const bf6::EbxValue* v)
{
    if (!v || v->kind != bf6::EbxValue::Kind::Struct) return {};
    return { real(v->field(0x3901DB14u)), real(v->field(0x42FC0F5Eu)),
             real(v->field(0x32A99B9Cu)) };
}

static Vec3 cross(Vec3 a, Vec3 b)
{
    return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}

static double dot(Vec3 a, Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }

static Vec3 local_point(Vec3 p, Vec3 r, Vec3 u, Vec3 f, Vec3 t)
{
    const Vec3 d{p.x-t.x, p.y-t.y, p.z-t.z};
    const double det = dot(r, cross(u, f));
    if (std::abs(det) < 1e-12) return {INFINITY, INFINITY, INFINITY};
    return {dot(d, cross(u, f))/det, dot(r, cross(d, f))/det,
            dot(r, cross(u, d))/det};
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr,
            "usage: reflection_test <game-dir> <exe> <reflection-volume-partition>\n");
        return 2;
    }
    bf6::Source src;
    std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(std::string(), true, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str());
        return 1;
    }
    bf6::TypeDb types;
    if (!types.open(argv[2], err)) {
        std::fprintf(stderr, "types: %s\n", err.c_str());
        return 1;
    }
    std::vector<uint8_t> raw = src.get_ebx(argv[3], err);
    bf6::Ebx e(types);
    if (raw.empty() || !e.parse(std::move(raw), err)) {
        std::fprintf(stderr, "ebx: %s\n", err.c_str());
        return 1;
    }
    e.set_guid_index(&src.partition_index());
    constexpr uint32_t kBakedTexture = 0xA8285286u;
    constexpr uint32_t kFakeField = 0xA8285287u;
    const bool have_point = argc >= 7;
    const Vec3 point = have_point
        ? Vec3{std::atof(argv[4]), std::atof(argv[5]), std::atof(argv[6])}
        : Vec3{};
    int real = 0, fake = 0, inside_one = 0, inside_half = 0;
    for (size_t i = 0; i < e.instance_count(); ++i) {
        std::string guid, path;
        if (e.import_ref(i, kBakedTexture, guid, path)) {
            ++real;
            const bf6::EbxValue v = e.read_instance(i);
            const bf6::EbxValue* tr = v.field(0xD6351EDEu);
            const Vec3 r = vec3(tr ? tr->field(0xC478CC3Bu) : nullptr);
            const Vec3 u = vec3(tr ? tr->field(0xBF151EF9u) : nullptr);
            const Vec3 f = vec3(tr ? tr->field(0x695D12A4u) : nullptr);
            const Vec3 t = vec3(tr ? tr->field(0xBC4B07B4u) : nullptr);
            const Vec3 lp = local_point(point, r, u, f, t);
            const bool in1 = have_point && std::abs(lp.x) <= 1.0 &&
                std::abs(lp.y) <= 1.0 && std::abs(lp.z) <= 1.0;
            const bool inhalf = have_point && std::abs(lp.x) <= 0.5 &&
                std::abs(lp.y) <= 0.5 && std::abs(lp.z) <= 0.5;
            inside_one += in1 ? 1 : 0;
            inside_half += inhalf ? 1 : 0;
            std::printf("%zu\t%s\t%s\t%s\tt=(%.6f,%.6f,%.6f)", i,
                        e.instance_guid(i).c_str(), guid.c_str(), path.c_str(),
                        t.x, t.y, t.z);
            if (have_point)
                std::printf("\tlocal=(%.6f,%.6f,%.6f) inside1=%d insideHalf=%d",
                            lp.x, lp.y, lp.z, in1 ? 1 : 0, inhalf ? 1 : 0);
            std::printf("\n");
        }
        if (e.import_ref(i, kFakeField, guid, path)) ++fake;
    }
    std::printf("real=%d fake=%d instances=%zu inside1=%d insideHalf=%d\n",
                real, fake, e.instance_count(), inside_one, inside_half);
    return real > 0 && fake == 0 ? 0 : 1;
}
