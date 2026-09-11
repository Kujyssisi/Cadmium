// FLARE — FLEX pack containers.
#include "pack.h"

#include "preset.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>

namespace flare {

namespace {

uint32_t be32(const uint8_t *p) {
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
uint64_t be64(const uint8_t *p) {
	return ((uint64_t)be32(p) << 32) | (uint64_t)be32(p + 4);
}

/// Whether a member's first bytes match what its extension promises. A FLAC
/// that does not start "fLaC" has been scrambled, and there is nothing useful
/// to be done with it here.
bool looks_intact(const std::string &kind, const uint8_t *head, size_t n) {
	if (n < 4) return false;
	if (kind == "flac") return std::memcmp(head, "fLaC", 4) == 0;
	if (kind == "wav") return std::memcmp(head, "RIFF", 4) == 0;
	if (kind == "ogg") return std::memcmp(head, "OggS", 4) == 0;
	if (kind == "presetsIndex" || kind == "usedsamples" || kind == "pcf") {
		// Text or a list of names: printable bytes, whatever the layout.
		int printable = 0;
		const size_t look = n < 32 ? n : 32;
		for (size_t i = 0; i < look; i++)
			if (head[i] == '\n' || head[i] == '\t' || (head[i] >= 0x20 && head[i] < 0x7F)) printable++;
		return printable * 4 >= (int)look * 3;
	}
	if (kind == "flexpreset" || kind == "flex2preset") {
		// The readable form of these begins with a chunk tag; a scrambled one
		// begins with anything at all.
		return head[0] >= 0x20 && head[0] < 0x7F && head[1] >= 0x20 && head[1] < 0x7F;
	}
	return true;
}

std::string extension(const std::string &name) {
	const size_t d = name.find_last_of('.');
	return d == std::string::npos ? std::string() : name.substr(d + 1);
}

std::string stem_of(const std::string &name) {
	const size_t d = name.find_last_of('.');
	return d == std::string::npos ? name : name.substr(0, d);
}

std::string file_of(const std::string &path) {
	const size_t s = path.find_last_of('/');
	return s == std::string::npos ? path : path.substr(s + 1);
}

} // namespace

bool pack_read(const std::string &path, Pack &out) {
	FILE *f = std::fopen(path.c_str(), "rb");
	if (!f) return false;
	uint8_t head[8];
	if (std::fread(head, 1, 8, f) != 8) { std::fclose(f); return false; }
	out.path = path;
	out.name = stem_of(file_of(path));
	out.version = be32(head);
	const uint32_t count = be32(head + 4);
	// A file that is not one of these will produce a preposterous count rather
	// than failing outright, so it is checked before anything is allocated.
	if (count == 0 || count > 200000) { std::fclose(f); return false; }

	std::fseek(f, 0, SEEK_END);
	const long total = std::ftell(f);
	std::fseek(f, 8, SEEK_SET);

	out.entries.clear();
	out.entries.reserve(count);
	for (uint32_t i = 0; i < count; i++) {
		uint8_t lenb[4];
		if (std::fread(lenb, 1, 4, f) != 4) break;
		const uint32_t nl = be32(lenb);
		if (nl == 0 || nl > 4096) break;
		std::string name((size_t)nl, '\0');
		if (std::fread(&name[0], 1, nl, f) != nl) break;
		while (!name.empty() && name.back() == '\0') name.pop_back();
		uint8_t rec[16];
		if (std::fread(rec, 1, 16, f) != 16) break;

		PackEntry e;
		e.name = name;
		e.stem = stem_of(name);
		e.kind = extension(name);
		e.offset = be64(rec);
		e.size = be64(rec + 8);
		if (e.offset + e.size > (uint64_t)total) { e.readable = false; }
		out.entries.push_back(e);
	}

	const long table_end = std::ftell(f);
	for (PackEntry &e : out.entries) {
		if (e.size == 0 || e.offset < (uint64_t)table_end || e.offset + e.size > (uint64_t)total) continue;
		uint8_t probe[32];
		std::fseek(f, (long)e.offset, SEEK_SET);
		const size_t got = std::fread(probe, 1, sizeof(probe), f);
		e.readable = looks_intact(e.kind, probe, got);
	}
	std::fclose(f);

	for (const PackEntry &e : out.entries) {
		if (e.kind == "flexpreset" || e.kind == "flex2preset") out.preset_count++;
		else if (e.kind == "flac" || e.kind == "wav" || e.kind == "ogg") out.sample_count++;
		if (e.readable) out.readable_count++;
	}
	out.protected_content = out.readable_count == 0 && !out.entries.empty();
	return !out.entries.empty();
}

bool pack_extract(const Pack &p, const PackEntry &e, std::vector<uint8_t> &out) {
	if (!e.readable || e.size == 0) return false;
	FILE *f = std::fopen(p.path.c_str(), "rb");
	if (!f) return false;
	std::fseek(f, (long)e.offset, SEEK_SET);
	out.resize((size_t)e.size);
	const size_t got = std::fread(out.data(), 1, out.size(), f);
	std::fclose(f);
	out.resize(got);
	return got == (size_t)e.size;
}

std::vector<std::string> pack_search_paths() {
	std::vector<std::string> d = content_dirs();
	const char *home = std::getenv("HOME");
	if (home) {
		const std::string h = home;
		// Where FL Studio keeps them, native and under Wine.
		d.push_back(h + "/Documents/Image-Line/FLEX");
		d.push_back(h + "/.wine/drive_c/Program Files/Image-Line/FL Studio/Plugins/Fruity/Generators/FLEX");
		d.push_back(h + "/Desktop/Flex");
	}
	if (const char *e = std::getenv("FLARE_PACKS")) d.push_back(e);
	return d;
}

std::vector<Pack> pack_scan() {
	std::vector<Pack> out;
	std::vector<std::string> todo = pack_search_paths();
	// Two levels down, which is how the packs are laid out wherever they land.
	for (size_t i = 0; i < todo.size() && i < 512; i++) {
		DIR *dp = ::opendir(todo[i].c_str());
		if (!dp) continue;
		while (struct dirent *e = ::readdir(dp)) {
			if (e->d_name[0] == '.') continue;
			const std::string full = todo[i] + "/" + e->d_name;
			struct stat st;
			if (::stat(full.c_str(), &st) != 0) continue;
			if (S_ISDIR(st.st_mode)) {
				if (todo.size() < 512) todo.push_back(full);
				continue;
			}
			const std::string ext = extension(e->d_name);
			if (ext != "flexpack" && ext != "flex2pack") continue;
			Pack p;
			if (pack_read(full, p)) out.push_back(p);
		}
		::closedir(dp);
	}
	return out;
}

} // namespace flare
