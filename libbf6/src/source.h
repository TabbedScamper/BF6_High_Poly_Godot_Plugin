/* libbf6 internal - the mount (module 2, final piece).
 *
 * Ties the mount together: a locator (cas_path), one or more parsed TOCs, and
 * for each bundle the segments-vs-payload zip that fills the res/ebx tables.
 * get_res / get_ebx then resolve a name to its CAS location and read+decompress
 * it. First mount wins on a name collision, matching bf6_source.gd.
 */
#ifndef LIBBF6_SOURCE_H
#define LIBBF6_SOURCE_H

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#include "caslocator.h"
#include "toc.h"

namespace bf6 {

struct ResEntry { CasLoc loc; uint32_t dsize = 0; uint32_t type = 0; uint64_t rid = 0; };
struct EbxEntry { CasLoc loc; uint32_t dsize = 0; };

class Source {
public:
    bool open(const std::string& game_dir, std::string& err);   // build the locator
    bool mount_toc(const std::string& toc_path, std::string& err);

    // Called from inside the long loops. See the ABI's note: it can be called
    // from several threads at once and must not touch a UI. False asks to stop.
    using Progress = std::function<bool(const char*, int, int)>;
    void set_progress(Progress p) { progress_ = std::move(p); }

    // ---- mounting a LEVEL, not just the shared archives ----
    //
    // Non-level archives are always mounted. Level archives are normally just
    // the one asked for, which is right for READING a level: its terrain, its
    // placements, its lighting.
    //
    // It is the wrong answer for the objects a PLAYER can place. Measured on
    // mp_dumbo, one level's mount carries pf_portal_ prefabs for 1,609 of the
    // SDK's 10,883 placeables and another 235 reachable by folder name; the
    // remaining 9,039 are not in that mount in any form, because a prefab lives
    // in the bundles of the levels that use the object. all_levels mounts every
    // level so the whole catalogue resolves. It is not the default, because a
    // level read does not need it and it is not free.
    bool mount_level(const std::string& level, bool all_levels, std::string& err);

    // The .toc paths under the install, IN MOUNT ORDER. See the ordering law in
    // the .cpp: first mount wins, so shared archives go first, then the level
    // being read, then every other level.
    std::vector<std::string> find_tocs(const std::string& level, bool all_levels) const;

    // The level ids the install actually carries, from directory names only.
    std::vector<std::string> available_levels() const;

    // Partition guid -> "<name>.ebx", for resolving EBX imports to real names.
    // Every partition's EFIX header is read to build it, which is the whole
    // cost; the result is cached on this Source. First name wins, so the result
    // is stable across runs rather than dependent on iteration order.
    const std::map<std::string, std::string>& partition_index();

    static bool        is_level_toc(const std::string& path);
    static std::string mount_key(const std::string& path);

    std::vector<uint8_t> get_res(const std::string& name, std::string& err);
    std::vector<uint8_t> get_ebx(const std::string& name, std::string& err);
    // Loose chunk or bundle chunk, by guid hex (either spelling - see get_chunk).
    std::vector<uint8_t> get_chunk(const std::string& guid_hex, std::string& err);

    const std::string& game_dir() const { return game_; }
    size_t res_count() const { return res_.size(); }
    size_t ebx_count() const { return ebx_.size(); }
    const std::unordered_map<std::string, ResEntry>& res() const { return res_; }
    const std::unordered_map<std::string, EbxEntry>& ebx() const { return ebx_; }

private:
    std::string game_;
    CasLocator  loc_;
    std::unordered_map<std::string, ResEntry> res_;
    std::unordered_map<std::string, EbxEntry> ebx_;
    std::map<std::string, CasLoc>             chunks_;    // loose-chunk guid -> loc
    std::map<std::string, CasLoc>             chunk_seg_; // bundle-chunk guid -> loc
    Progress                                  progress_;
    std::map<std::string, std::string>        pidx_;      // partition guid -> name.ebx
    bool                                      pidx_built_ = false;

    std::vector<uint8_t> read_seg(const CasLoc& seg, bool allow_raw, std::string& err);
};

}  // namespace bf6
#endif
