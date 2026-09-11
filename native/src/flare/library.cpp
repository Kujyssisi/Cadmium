// FLARE — the browser's view of what is installed.
#include "library.h"

#include "json.h"
#include "pack.h"
#include "sf2.h"

#include <algorithm>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>

namespace flare {

namespace {

bool ends_with_ci(const std::string &s, const char *suffix) {
	const size_t n = std::strlen(suffix);
	if (s.size() < n) return false;
	for (size_t i = 0; i < n; i++)
		if (std::tolower((unsigned char)s[s.size() - n + i]) != std::tolower((unsigned char)suffix[i]))
			return false;
	return true;
}

std::string file_of(const std::string &p) {
	const size_t s = p.find_last_of('/');
	return s == std::string::npos ? p : p.substr(s + 1);
}

std::string stem_of(const std::string &p) {
	std::string f = file_of(p);
	const size_t d = f.find_last_of('.');
	return d == std::string::npos ? f : f.substr(0, d);
}

/// Depth-limited walk. A content folder pointed at a whole sample drive should
/// not turn opening a window into a filesystem crawl.
void walk(const std::string &dir, int depth, std::vector<std::string> &files,
		std::vector<std::string> &dirs) {
	if (depth <= 0) return;
	DIR *dp = ::opendir(dir.c_str());
	if (!dp) return;
	while (struct dirent *e = ::readdir(dp)) {
		if (e->d_name[0] == '.') continue;
		const std::string full = dir + "/" + e->d_name;
		struct stat st;
		if (::stat(full.c_str(), &st) != 0) continue;
		if (S_ISDIR(st.st_mode)) {
			dirs.push_back(full);
			walk(full, depth - 1, files, dirs);
		} else {
			files.push_back(full);
		}
	}
	::closedir(dp);
}

int wavs_in(const std::string &dir) {
	int n = 0;
	DIR *dp = ::opendir(dir.c_str());
	if (!dp) return 0;
	while (struct dirent *e = ::readdir(dp)) {
		if (e->d_name[0] == '.') continue;
		if (ends_with_ci(e->d_name, ".wav")) n++;
	}
	::closedir(dp);
	return n;
}

} // namespace

void Library::scan() {
	presets_.clear();
	content_.clear();
	packs_.clear();

	for (const std::string &d : preset_dirs()) {
		std::vector<std::string> files, dirs;
		walk(d, 4, files, dirs);
		for (const std::string &f : files) {
			if (!ends_with_ci(f, ".flare")) continue;
			PresetMeta m;
			if (!preset_read_meta(f, m)) continue;
			if (m.pack.empty()) {
				// The folder it sits in is its pack, which is what makes a
				// dropped-in bank appear as a bank rather than as loose files.
				const size_t s = f.find_last_of('/');
				if (s != std::string::npos) m.pack = stem_of(f.substr(0, s));
			}
			presets_.push_back(m);
		}
	}
	std::sort(presets_.begin(), presets_.end(), [](const PresetMeta &a, const PresetMeta &b) {
		if (a.pack != b.pack) return a.pack < b.pack;
		return a.name < b.name;
	});

	for (const std::string &d : content_dirs()) {
		std::vector<std::string> files, dirs;
		walk(d, 3, files, dirs);
		for (const std::string &f : files) {
			ContentItem c;
			c.path = f;
			c.name = stem_of(f);
			if (ends_with_ci(f, ".sf2") || ends_with_ci(f, ".sf3")) c.kind = "soundfont";
			else if (ends_with_ci(f, ".wav")) c.kind = "sample";
			else continue;
			content_.push_back(c);
		}
		for (const std::string &sub : dirs) {
			const int n = wavs_in(sub);
			if (n < 2) continue;
			ContentItem c;
			c.path = sub;
			c.name = file_of(sub);
			c.kind = "folder";
			c.sub_count = n;
			content_.push_back(c);
		}
	}
	std::sort(content_.begin(), content_.end(), [](const ContentItem &a, const ContentItem &b) {
		if (a.kind != b.kind) return a.kind < b.kind;
		return a.name < b.name;
	});

	for (const Pack &p : pack_scan()) {
		Json j = Json::object();
		j.set("name", Json::string(p.name));
		j.set("path", Json::string(p.path));
		j.set("presets", Json::number(p.preset_count));
		j.set("samples", Json::number(p.sample_count));
		j.set("protected", Json::boolean(p.protected_content));
		packs_.push_back(j.dump());
	}
	scanned_ = true;
}

std::vector<std::string> Library::pack_names() const {
	std::vector<std::string> out;
	for (const PresetMeta &m : presets_)
		if (std::find(out.begin(), out.end(), m.pack) == out.end()) out.push_back(m.pack);
	return out;
}

std::string Library::presets_json() const {
	Json a = Json::array();
	for (const PresetMeta &m : presets_) {
		Json j = Json::object();
		j.set("name", Json::string(m.name));
		j.set("path", Json::string(m.path));
		if (!m.pack.empty()) j.set("pack", Json::string(m.pack));
		if (!m.type.empty()) j.set("type", Json::string(m.type));
		if (!m.style.empty()) j.set("style", Json::string(m.style));
		if (!m.author.empty()) j.set("author", Json::string(m.author));
		a.push(j);
	}
	return a.dump();
}

std::string Library::content_json() const {
	Json a = Json::array();
	for (const ContentItem &c : content_) {
		Json j = Json::object();
		j.set("name", Json::string(c.name));
		j.set("path", Json::string(c.path));
		j.set("kind", Json::string(c.kind));
		if (c.sub_count) j.set("count", Json::number(c.sub_count));
		a.push(j);
	}
	for (const std::string &p : packs_) {
		Json j;
		if (Json::parse(p, j)) {
			j.set("kind", Json::string("pack"));
			a.push(j);
		}
	}
	return a.dump();
}

std::string Library::soundfont_presets_json(const std::string &path) {
	Sf2 sf;
	Json a = Json::array();
	if (!sf.load(path)) return a.dump();
	int i = 0;
	for (const Sf2PresetInfo &p : sf.presets()) {
		Json j = Json::object();
		j.set("name", Json::string(p.name));
		j.set("index", Json::number(i++));
		j.set("bank", Json::number(p.bank));
		j.set("program", Json::number(p.program));
		a.push(j);
	}
	return a.dump();
}

Library &library() {
	static Library l;
	return l;
}

} // namespace flare
