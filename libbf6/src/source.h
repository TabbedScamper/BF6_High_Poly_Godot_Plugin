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

    std::vector<uint8_t> get_res(const std::string& name, std::string& err);
    std::vector<uint8_t> get_ebx(const std::string& name, std::string& err);

    size_t res_count() const { return res_.size(); }
    size_t ebx_count() const { return ebx_.size(); }
    const std::unordered_map<std::string, ResEntry>& res() const { return res_; }

private:
    std::string game_;
    CasLocator  loc_;
    std::unordered_map<std::string, ResEntry> res_;
    std::unordered_map<std::string, EbxEntry> ebx_;
    std::map<std::string, CasLoc>             chunks_;   // loose-chunk guid -> loc

    std::vector<uint8_t> read_seg(const CasLoc& seg, bool allow_raw, std::string& err);
};

}  // namespace bf6
#endif
