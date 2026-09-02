/* Find the authored EBX reverse edge to one or more target partitions.
 *
 *   import_backref_test <game-dir> <exe> <scan-prefix> <target-ebx> [...]
 *
 * Nothing is exported or staged: every candidate EBX and target partition is
 * read from the mounted install.  A perturbed target GUID is scanned beside
 * every real GUID so an accidental substring/path match cannot pass silently.
 */
#include "source.h"
#include "types.h"
#include "ebx.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

static std::string lower_slash(std::string s)
{
    for (char& c : s) {
        if (c == '\\') c = '/';
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    if (s.size() > 4 && s.substr(s.size() - 4) == ".ebx") s.resize(s.size() - 4);
    return s;
}

static std::string perturbed(std::string guid)
{
    for (char& c : guid) {
        if (c == '-') continue;
        c = c == '0' ? '1' : '0';
        break;
    }
    return guid;
}

int main(int argc, char** argv)
{
    if (argc < 5) {
        std::fprintf(stderr,
            "usage: import_backref_test <game-dir> <exe> <scan-prefix> <target-ebx> [...]\n");
        return 2;
    }

    bf6::Source src;
    bf6::TypeDb types;
    std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(std::string(), true, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str());
        return 1;
    }
    if (!types.open(argv[2], err)) {
        std::fprintf(stderr, "types: %s\n", err.c_str());
        return 1;
    }

    std::map<std::string, std::string> targets;
    std::map<std::string, std::string> controls;
    for (int a = 4; a < argc; ++a) {
        const std::string name = lower_slash(argv[a]);
        std::vector<uint8_t> raw = src.get_ebx(name, err);
        bf6::Ebx e(types);
        if (raw.empty() || !e.parse(std::move(raw), err)) {
            std::fprintf(stderr, "target %s: %s\n", name.c_str(), err.c_str());
            return 1;
        }
        targets[e.partition_guid()] = name;
        controls[perturbed(e.partition_guid())] = name;
        std::printf("target\t%s\t%s\n", e.partition_guid().c_str(), name.c_str());
    }

    const std::string prefix = lower_slash(argv[3]);
    std::vector<std::string> names;
    names.reserve(src.ebx_count());
    for (const auto& kv : src.ebx()) {
        const std::string n = lower_slash(kv.first);
        if (n.rfind(prefix, 0) == 0) names.push_back(n);
    }
    std::sort(names.begin(), names.end());

    int parsed = 0, parse_fail = 0, real = 0, fake = 0;
    for (const std::string& name : names) {
        err.clear();
        std::vector<uint8_t> raw = src.get_ebx(name, err);
        bf6::Ebx e(types);
        if (raw.empty() || !e.parse(std::move(raw), err)) {
            ++parse_fail;
            continue;
        }
        ++parsed;
        for (size_t i = 0; i < e.import_count(); ++i) {
            const std::string& g = e.import_at(i).partition;
            auto hit = targets.find(g);
            if (hit != targets.end()) {
                ++real;
                std::printf("import\t%s\t%s\t%s\n",
                            name.c_str(), g.c_str(), hit->second.c_str());
            }
            if (controls.find(g) != controls.end()) ++fake;
        }
    }
    std::printf("summary\tprefix=%s candidates=%zu parsed=%d parse_fail=%d real=%d fake=%d\n",
                prefix.c_str(), names.size(), parsed, parse_fail, real, fake);
    return real > 0 && fake == 0 ? 0 : 1;
}
