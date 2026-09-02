/* chanbone_test - identify animation channels by their CONSTANT value.
 *
 * THE IDEA. In any one clip most bones do not move. A channel that holds the
 * same quaternion at every sample is a bone sitting at rest, and a bone at rest
 * is at its BIND-POSE LOCAL ROTATION - which the skeleton gives us by name. So
 * matching constant channels against bind rotations identifies channel -> bone
 * without needing the engine's binding table.
 *
 * THE CONTROL THAT MAKES IT MEAN SOMETHING. Bind rotations are not uniformly
 * spread over the sphere - many bones are near-identity, so a "match" is cheap.
 * This therefore reports:
 *   - how many constant channels match SOME bone,
 *   - how many match UNIQUELY (exactly one bone within tolerance), which is the
 *     only useful kind,
 *   - and the same two numbers for RANDOM unit quaternions, which is the
 *     control. If random quaternions match as often, the method has found
 *     nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdlib>
#include <vector>
#include "bf6_core.h"

static void mat_to_quat(const float* m, float* q)
{
    /* rows are basis vectors: m[r*3+c] */
    const float t = m[0] + m[4] + m[8];
    if (t > 0.0f) {
        float s = std::sqrt(t + 1.0f) * 2.0f;
        q[3] = 0.25f * s; q[0] = (m[7] - m[5]) / s; q[1] = (m[2] - m[6]) / s; q[2] = (m[3] - m[1]) / s;
    } else if (m[0] > m[4] && m[0] > m[8]) {
        float s = std::sqrt(1.0f + m[0] - m[4] - m[8]) * 2.0f;
        q[3] = (m[7] - m[5]) / s; q[0] = 0.25f * s; q[1] = (m[1] + m[3]) / s; q[2] = (m[2] + m[6]) / s;
    } else if (m[4] > m[8]) {
        float s = std::sqrt(1.0f + m[4] - m[0] - m[8]) * 2.0f;
        q[3] = (m[2] - m[6]) / s; q[0] = (m[1] + m[3]) / s; q[1] = 0.25f * s; q[2] = (m[5] + m[7]) / s;
    } else {
        float s = std::sqrt(1.0f + m[8] - m[0] - m[4]) * 2.0f;
        q[3] = (m[3] - m[1]) / s; q[0] = (m[2] + m[6]) / s; q[1] = (m[5] + m[7]) / s; q[2] = 0.25f * s;
    }
    float n = std::sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);
    if (n > 0.0f) { q[0]/=n; q[1]/=n; q[2]/=n; q[3]/=n; }
}

static float qdot(const float* a, const float* b)
{ return std::fabs(a[0]*b[0]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3]); }

int main(int argc, char** argv)
{
    if (argc < 4) { std::printf("usage: chanbone_test <game> <skeleton_ebx> <clip_res>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    bf6_skeleton* sk = bf6_skeleton_read(c, argv[2]);
    if (!sk) { std::printf("skeleton read failed\n"); return 1; }
    bf6_anim_clip* cl = bf6_anim_clip_open(c, argv[3]);
    if (!cl) { std::printf("clip open failed\n"); return 1; }
    std::printf("skeleton %s bones=%d   clip quat=%d vec3=%d keys=%d\n",
                argv[2], sk->bone_count, cl->quat_count, cl->vec3_count, cl->key_time_count);

    std::vector<float> bq((size_t)sk->bone_count * 4);
    for (int b = 0; b < sk->bone_count; b++) mat_to_quat(sk->bones[b].local, &bq[(size_t)b*4]);

    /* which quaternion channels are constant across the clip? */
    const int n = cl->channel_count;
    std::vector<float> first((size_t)n*4), cur((size_t)n*4);
    if (!bf6_anim_clip_sample(c, cl, 0, first.data(), nullptr)) { std::printf("sample 0 failed\n"); return 1; }
    std::vector<int> constant((size_t)cl->quat_count, 1);
    for (int o = 1; o < cl->key_time_count; o++) {
        if (!bf6_anim_clip_sample(c, cl, o, cur.data(), nullptr)) break;
        for (int q = 0; q < cl->quat_count; q++)
            if (constant[(size_t)q] && qdot(&first[(size_t)q*4], &cur[(size_t)q*4]) < 0.99999f)
                constant[(size_t)q] = 0;
    }
    int nconst = 0; for (int q = 0; q < cl->quat_count; q++) nconst += constant[(size_t)q];

    const float TOL = 0.9999f;
    int matched = 0, unique = 0;
    std::vector<int> hit_bone((size_t)cl->quat_count, -1);
    for (int q = 0; q < cl->quat_count; q++) {
        if (!constant[(size_t)q]) continue;
        int hits = 0, which = -1;
        for (int b = 0; b < sk->bone_count; b++)
            if (qdot(&first[(size_t)q*4], &bq[(size_t)b*4]) > TOL) { hits++; if (which < 0) which = b; }
        if (hits > 0) matched++;
        if (hits == 1) { unique++; hit_bone[(size_t)q] = which; }
    }

    /* CONTROL: random unit quaternions, same count, same tolerance */
    std::srand(12345);
    int rmatched = 0, runique = 0;
    for (int i = 0; i < nconst; i++) {
        float r[4];
        for (int k = 0; k < 4; k++) r[k] = (float)std::rand() / (float)RAND_MAX * 2.0f - 1.0f;
        float nn = std::sqrt(r[0]*r[0]+r[1]*r[1]+r[2]*r[2]+r[3]*r[3]);
        for (int k = 0; k < 4; k++) r[k] /= nn;
        int hits = 0;
        for (int b = 0; b < sk->bone_count; b++) if (qdot(r, &bq[(size_t)b*4]) > TOL) hits++;
        if (hits > 0) rmatched++;
        if (hits == 1) runique++;
    }

    std::printf("  constant quaternion channels : %d of %d\n", nconst, cl->quat_count);
    std::printf("  matched some bind rotation   : %d   (control, random quats: %d)\n", matched, rmatched);
    std::printf("  matched EXACTLY ONE bone     : %d   (control, random quats: %d)\n", unique, runique);
    int shown = 0;
    for (int q = 0; q < cl->quat_count && shown < 12; q++)
        if (hit_bone[(size_t)q] >= 0) {
            std::printf("     channel %-4d -> bone %-4d %s\n", q, hit_bone[(size_t)q],
                        sk->bones[hit_bone[(size_t)q]].name);
            shown++;
        }
    /* Export both sides so the ordering question can be attacked offline:
     * every channel with its constant flag and quaternion, and every bone with
     * its bind-local quaternion. */
    if (argc > 4) {
        char path[512];
        std::snprintf(path, sizeof(path), "%s/channels.csv", argv[4]);
        if (FILE* f = std::fopen(path, "w")) {
            std::fprintf(f, "channel,constant,qx,qy,qz,qw\n");
            for (int q = 0; q < cl->quat_count; q++)
                std::fprintf(f, "%d,%d,%.6f,%.6f,%.6f,%.6f\n", q, constant[(size_t)q],
                             first[(size_t)q*4+0], first[(size_t)q*4+1],
                             first[(size_t)q*4+2], first[(size_t)q*4+3]);
            std::fclose(f);
        }
        std::snprintf(path, sizeof(path), "%s/bones.csv", argv[4]);
        if (FILE* f = std::fopen(path, "w")) {
            std::fprintf(f, "bone,name,qx,qy,qz,qw\n");
            for (int b = 0; b < sk->bone_count; b++)
                std::fprintf(f, "%d,%s,%.6f,%.6f,%.6f,%.6f\n", b, sk->bones[b].name,
                             bq[(size_t)b*4+0], bq[(size_t)b*4+1],
                             bq[(size_t)b*4+2], bq[(size_t)b*4+3]);
            std::fclose(f);
        }
        std::printf("  exported channels.csv and bones.csv to %s\n", argv[4]);
    }
    bf6_close(c);
    return 0;
}
