// FLARE — FLEX pack containers.
//
// The archive itself is a plain index: a count, then one record per member
// giving its name, offset and length. That much FLARE reads, so a pack can be
// listed and any member that is stored in the clear can be taken out.
//
// The members inside the commercial packs are not stored in the clear. FLARE
// does not attempt to undo that: breaking a protection measure on licensed
// content is a different thing from reading a file format, and a plugin that
// did it would be a circumvention tool rather than an importer. Encrypted
// members are reported as such and skipped.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace flare {

struct PackEntry {
	std::string name;      // "70s Bounce.flexpreset"
	std::string stem;      // "70s Bounce"
	std::string kind;      // "flexpreset", "flac", "presetsIndex"
	uint64_t offset = 0;
	uint64_t size = 0;
	/// False when the member's own header says it is not what its name claims,
	/// which is what protected content looks like from out here.
	bool readable = false;
};

struct Pack {
	std::string path;
	std::string name;
	uint32_t version = 0;
	std::vector<PackEntry> entries;
	int preset_count = 0;
	int sample_count = 0;
	int readable_count = 0;
	bool protected_content = false;
};

/// Reads the index. Never reads a member's body beyond the few bytes needed to
/// see whether it is intact.
bool pack_read(const std::string &path, Pack &out);

/// Copies one member out, if it is readable. Returns false for a protected one.
bool pack_extract(const Pack &p, const PackEntry &e, std::vector<uint8_t> &out);

/// Every pack found in the content folders and in FL Studio's own.
std::vector<std::string> pack_search_paths();
std::vector<Pack> pack_scan();

} // namespace flare
