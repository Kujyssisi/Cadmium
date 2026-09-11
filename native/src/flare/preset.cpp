// FLARE — presets.
#include "preset.h"

#include "engine.h"
#include "platform.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

namespace flare {

const char *TYPE_TAGS =
	"Arp|Bass|Bell|Brass|Drone|Drum|Guitar|Keys|Lead|Organ|Pad|Percussion|"
	"Piano|Pluck|Sequence|SFX|String|Synth|Vocal|Wind";
const char *STYLE_TAGS =
	"Basic|Complex|Bright|Dark|Warm|Hard|Soft|Short|Long|Layered|Split|"
	"Evolving|Modulated|Analog|Digital|Clean|Dirty|Wide|Mono";

namespace {

std::string read_file(const std::string &path) {
	FILE *f = std::fopen(path.c_str(), "rb");
	if (!f) return std::string();
	std::fseek(f, 0, SEEK_END);
	const long n = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	if (n <= 0) { std::fclose(f); return std::string(); }
	std::string s((size_t)n, '\0');
	const size_t got = std::fread(&s[0], 1, (size_t)n, f);
	std::fclose(f);
	s.resize(got);
	return s;
}

bool write_file(const std::string &path, const std::string &text) {
	FILE *f = std::fopen(path.c_str(), "wb");
	if (!f) return false;
	const size_t n = std::fwrite(text.data(), 1, text.size(), f);
	std::fclose(f);
	return n == text.size();
}

std::string home() {
	const char *h = std::getenv("HOME");
	if (h && *h) return h;
	const char *u = std::getenv("USERPROFILE");
	return u ? u : ".";
}

/// Where a program keeps a user's own files. Windows has its own answer to
/// this and putting a dot-directory in somebody's profile is not it.
std::string user_data() {
#if defined(_WIN32)
	if (const char *a = std::getenv("APPDATA")) return std::string(a) + "/FLARE";
	return home() + "/AppData/Roaming/FLARE";
#else
	return home() + "/.local/share/Flare";
#endif
}

Json build(const Synth &s) {
	Json j = Json::object();
	j.set("flare", Json::number(1));
	j.set("name", Json::string(s.preset_name));
	if (!s.preset_author.empty()) j.set("author", Json::string(s.preset_author));
	if (!s.preset_type.empty()) j.set("type", Json::string(s.preset_type));
	if (!s.preset_style.empty()) j.set("style", Json::string(s.preset_style));
	if (!s.preset_pack.empty()) j.set("pack", Json::string(s.preset_pack));

	Json macros = Json::array();
	bool any_macro = false;
	for (int i = 0; i < MACRO_N; i++) {
		macros.push(Json::string(s.macro_name(i)));
		if (!s.macro_name(i).empty()) any_macro = true;
	}
	if (any_macro) j.set("macros", macros);

	// Only what differs from the default. A preset that stores everything is
	// a preset that breaks the day a default is improved.
	Json ps = Json::object();
	const std::vector<ParamInfo> &d = params();
	for (size_t i = 0; i < d.size(); i++) {
		const float v = s.get_param((int)i);
		if (std::fabs(v - d[i].def) < 1e-6f) continue;
		ps.set(d[i].id, Json::number(v));
	}
	j.set("params", ps);

	Json content = Json::object();
	for (int i = 0; i < PART_N; i++) {
		const PartSource &src = s.source(i);
		const std::string key = std::string("osc") + (char)('a' + i);
		if (!src.sample_path.empty()) content.set(key + ".sample", Json::string(src.sample_path));
		if (!src.wavetable_path.empty()) content.set(key + ".wavetable", Json::string(src.wavetable_path));
	}
	if (!content.obj.empty()) j.set("content", content);
	return j;
}

bool apply(Synth &s, const Json &j) {
	if (!j.is_obj()) return false;
	s.set_all_default();
	for (int i = 0; i < MACRO_N; i++) s.set_macro_name(i, std::string());
	s.preset_name = j.get_str("name");
	s.preset_author = j.get_str("author");
	s.preset_type = j.get_str("type");
	s.preset_style = j.get_str("style");
	s.preset_pack = j.get_str("pack");

	if (const Json *m = j.find("macros")) {
		for (int i = 0; i < MACRO_N && i < (int)m->arr.size(); i++)
			s.set_macro_name(i, m->arr[(size_t)i].as_string());
	}
	// Content first: a part's source has to exist before the parameter that
	// picks a zone in it is set.
	if (const Json *c = j.find("content")) {
		for (int i = 0; i < PART_N; i++) {
			const std::string key = std::string("osc") + (char)('a' + i);
			const std::string sample = c->get_str(key + ".sample");
			if (!sample.empty()) s.load_sample(i, sample);
			const std::string wt = c->get_str(key + ".wavetable");
			if (!wt.empty()) s.load_wavetable(i, wt);
		}
	}
	if (const Json *ps = j.find("params")) {
		for (const auto &kv : ps->obj) {
			const int idx = param_index(kv.first);
			if (idx < 0) continue;   // a control this version does not have
			s.set_param(idx, (float)kv.second.as_number());
		}
	}
	return true;
}

} // namespace

bool preset_read_meta(const std::string &path, PresetMeta &out) {
	const std::string text = read_file(path);
	if (text.empty()) return false;
	Json j;
	if (!Json::parse(text, j) || !j.is_obj()) return false;
	out.path = path;
	out.name = j.get_str("name");
	if (out.name.empty()) {
		const size_t s = path.find_last_of("/\\");
		std::string f = s == std::string::npos ? path : path.substr(s + 1);
		const size_t d = f.find_last_of('.');
		out.name = d == std::string::npos ? f : f.substr(0, d);
	}
	out.author = j.get_str("author");
	out.type = j.get_str("type");
	out.style = j.get_str("style");
	out.pack = j.get_str("pack");
	out.comment = j.get_str("comment");
	if (const Json *m = j.find("macros"))
		for (int i = 0; i < 8 && i < (int)m->arr.size(); i++) out.macros[i] = m->arr[(size_t)i].as_string();
	return true;
}

std::string preset_to_string(const Synth &s) { return build(s).dump(1); }

bool preset_from_string(Synth &s, const std::string &text) {
	Json j;
	if (!Json::parse(text, j)) return false;
	return apply(s, j);
}

bool preset_save(const Synth &s, const std::string &path) {
	const size_t slash = path.find_last_of('/');
	if (slash != std::string::npos) make_dirs(path.substr(0, slash));
	return write_file(path, build(s).dump(1));
}

bool preset_load(Synth &s, const std::string &path) {
	const std::string text = read_file(path);
	if (text.empty()) return false;
	Json j;
	if (!Json::parse(text, j)) return false;
	if (!apply(s, j)) return false;
	if (s.preset_name.empty()) {
		const size_t sl = path.find_last_of("/\\");
		std::string f = sl == std::string::npos ? path : path.substr(sl + 1);
		const size_t d = f.find_last_of('.');
		s.preset_name = d == std::string::npos ? f : f.substr(0, d);
	}
	return true;
}

std::string user_preset_dir() { return user_data() + "/Presets"; }

std::vector<std::string> preset_dirs() {
	std::vector<std::string> d;
	if (const char *e = std::getenv("FLARE_BANKS")) {
		// Several, separated the way a PATH is.
		std::string s(e), cur;
		for (size_t i = 0; i <= s.size(); i++) {
			if (i == s.size() || s[i] == ':') { if (!cur.empty()) d.push_back(cur); cur.clear(); }
			else cur.push_back(s[i]);
		}
	}
	// Beside the application first, so a build that carries its own presets
	// finds them wherever it has been unpacked.
	if (const std::string exe = executable_dir(); !exe.empty()) {
		d.push_back(exe + "/Banks");
		d.push_back(exe + "/FLARE/Banks");
	}
	d.push_back(user_data() + "/Banks");
	d.push_back(user_preset_dir());
#if !defined(_WIN32)
	d.push_back("/usr/share/Flare/Banks");
	d.push_back("/usr/local/share/Flare/Banks");
#else
	// Beside the plugin, so a bank can travel with an install.
	if (const char *p = std::getenv("ProgramFiles"))
		d.push_back(std::string(p) + "/FLARE/Banks");
#endif
	return d;
}

std::vector<std::string> content_dirs() {
	std::vector<std::string> d;
	if (const char *e = std::getenv("FLARE_CONTENT")) d.push_back(e);
	if (const std::string exe = executable_dir(); !exe.empty()) {
		d.push_back(exe + "/Content");
		d.push_back(exe + "/FLARE/Content");
	}
	d.push_back(user_data() + "/Content");
#if defined(_WIN32)
	d.push_back(home() + "/Documents/FLARE");
	d.push_back("C:/soundfonts");
#else
	d.push_back(home() + "/.local/share/soundfonts");
	d.push_back("/usr/share/soundfonts");
	d.push_back("/usr/share/sounds/sf2");
#endif
	return d;
}

} // namespace flare
