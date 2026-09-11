// Cadmium — plugins that live in their own shared libraries.
#include "ext_plugins.h"

#include "cadmium_ext.h"
#include "crashlog.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cstdlib>
#include <map>

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <dlfcn.h>
#include <sys/stat.h>
#endif

namespace cd {

namespace {

struct Loaded {
	std::string path;
	const CdExtEntry *entry = nullptr;
};

std::vector<Loaded> g_loaded;
std::vector<ExtProblem> g_problems;
/// Which library and descriptor an id belongs to. The stock table's `make`
/// hook has no room for that, so it is kept here and consulted by make_plug.
std::map<std::string, std::pair<const CdExtEntry *, const CdExtDesc *>> g_by_id;
bool g_scanned = false;

std::string home_dir() {
	if (const char *h = std::getenv("HOME")) return h;
	if (const char *u = std::getenv("USERPROFILE")) return u;
	return ".";
}

bool has_suffix(const std::string &s, const char *suffix) {
	const size_t n = std::strlen(suffix);
	return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

void note_problem(const std::string &path, const std::string &why) {
	g_problems.push_back({path, why});
}

#ifdef _WIN32
void *open_library(const std::string &path, std::string &err) {
	HMODULE h = LoadLibraryA(path.c_str());
	if (!h) err = "the operating system would not load it";
	return (void *)h;
}
void *find_symbol(void *lib, const char *name) {
	return (void *)GetProcAddress((HMODULE)lib, name);
}
const char *LIB_SUFFIX = ".cdplug";
const char *LIB_ALT = ".dll";
#else
void *open_library(const std::string &path, std::string &err) {
	// Local, so a plugin's own copy of a library cannot replace one Cadmium
	// is already using; NOW, so a missing symbol is found here rather than
	// halfway through a block.
	void *h = ::dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		const char *e = ::dlerror();
		err = e ? e : "it would not open";
	}
	return h;
}
void *find_symbol(void *lib, const char *name) { return ::dlsym(lib, name); }
const char *LIB_SUFFIX = ".cdplug";
const char *LIB_ALT = ".so";
#endif

int kind_from_ext(int k) {
	switch (k) {
		case CD_EXT_DB: return P_DB;
		case CD_EXT_HZ: return P_HZ;
		case CD_EXT_PCT: return P_PCT;
		case CD_EXT_CHOICE: return P_CHOICE;
		case CD_EXT_BOOL: return P_BOOL;
		case CD_EXT_SEMI: return P_SEMI;
		case CD_EXT_MS: return P_MS;
		case CD_EXT_SEC: return P_SEC;
		case CD_EXT_BEATS: return P_BEATS;
		case CD_EXT_Q: return P_Q;
		default: return P_FLOAT;
	}
}

/// Whether the entry a library returned is filled in enough to be used. A
/// plugin missing process() would take the audio thread down on the first
/// block, which is a long way from where the mistake was made.
bool entry_usable(const CdExtEntry *e, std::string &why) {
	if (!e) { why = "it returned nothing"; return false; }
	if (e->abi != CD_EXT_ABI) {
		why = "it was built for interface version " + std::to_string(e->abi)
				+ ", this Cadmium speaks " + std::to_string(CD_EXT_ABI);
		return false;
	}
	if (e->desc_count <= 0 || !e->descs) { why = "it offers no processors"; return false; }
	if (!e->create || !e->destroy || !e->process || !e->set_param) {
		why = "it is missing part of the interface";
		return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
/// One instance of an external processor, wearing Cadmium's interface.
class ExtPlug : public Plug {
public:
	ExtPlug(const CdExtEntry *e, CdExtPlug *p) : e_(e), p_(p) {}
	~ExtPlug() override {
		if (p_ && e_ && e_->destroy) e_->destroy(p_);
	}

	void prepare() override { if (e_->prepare) e_->prepare(p_, sr, block); }
	void reset() override { if (e_->reset) e_->reset(p_); }

	void note_on(int key, float vel, int id) override {
		// Cadmium carries a note's own pan and detune on the plugin rather
		// than on the call; an external plugin is told before the note so it
		// can pick them up as the voice starts.
		if (e_->expression) e_->expression(p_, next_pan, next_fine);
		next_pan = 0.0f;
		next_fine = 0.0f;
		if (e_->note_on) e_->note_on(p_, key, vel, id);
	}
	void note_off(int key, int id) override { if (e_->note_off) e_->note_off(p_, key, id); }
	void all_notes_off() override { if (e_->all_notes_off) e_->all_notes_off(p_); }
	void pitch_bend(float s) override { if (e_->pitch_bend) e_->pitch_bend(p_, s); }
	void mod_wheel(float v) override { if (e_->mod_wheel) e_->mod_wheel(p_, v); }
	void aftertouch(float v) override { if (e_->aftertouch) e_->aftertouch(p_, v); }

	void process(float *L, float *R, int n) override {
		if (e_->transport) e_->transport(p_, bpm, song_beat, playing ? 1 : 0);
		e_->process(p_, L, R, n);
	}
	void sidechain(const float *L, const float *R, int n) override {
		if (e_->sidechain) e_->sidechain(p_, L, R, n);
	}
	bool wants_sidechain() const override {
		return e_->wants_sidechain ? e_->wants_sidechain(p_) != 0 : false;
	}

	void set_param(int i, float v) override {
		Plug::set_param(i, v);
		e_->set_param(p_, i, v);
	}

	bool set_string(const std::string &key, const std::string &value) override {
		if (!e_->set_string) return false;
		const bool ok = e_->set_string(p_, key.c_str(), value.c_str()) != 0;
		// Loading a preset moves every control at once. Cadmium's own copy of
		// the values has to be brought back into line or the panel keeps
		// drawing the patch that was there before.
		if (ok && e_->get_param) {
			for (size_t i = 0; i < pv.size(); i++) pv[i] = e_->get_param(p_, (int)i);
		}
		return ok;
	}

	std::string get_string(const std::string &key) const override {
		if (!e_->get_string) return std::string();
		const int need = e_->get_string(p_, key.c_str(), nullptr, 0);
		if (need <= 0) return std::string();
		std::string out((size_t)need + 1, '\0');
		const int n = e_->get_string(p_, key.c_str(), &out[0], need + 1);
		out.resize(n > 0 ? (size_t)n : 0);
		return out;
	}

	bool set_data(const std::string &key, const float *d, int n) override {
		return e_->set_data ? e_->set_data(p_, key.c_str(), d, n) != 0 : false;
	}
	int aux(int what, float *out, int max) override {
		return e_->aux ? e_->aux(p_, what, out, max) : 0;
	}
	std::string param_text(int i, float v) const override {
		if (!e_->param_text) return std::string();
		char buf[128];
		const int n = e_->param_text(p_, i, v, buf, (int)sizeof(buf));
		return n > 0 ? std::string(buf, (size_t)n) : std::string();
	}
	int active_voices() const override { return e_->active_voices ? e_->active_voices(p_) : 0; }
	float tail() const override { return e_->tail ? e_->tail(p_) : 2.0f; }

	// --- the plugin's own interface
	bool has_editor() override { return e_->has_editor && e_->has_editor(p_) != 0; }
	bool open_editor(uint64_t parent, int x, int y, int w, int h) override {
		if (!e_->open_editor) return false;
		// Not under the audio lock: building an interface takes as long as it
		// takes, and holding the lock through it stops the sound.
		return e_->open_editor(p_, parent, x, y, w, h) != 0;
	}
	void close_editor() override { if (e_->close_editor) e_->close_editor(p_); }
	void editor_idle() override { if (e_->editor_idle) e_->editor_idle(p_); }
	bool editor_open() const override { return e_->editor_is_open && e_->editor_is_open(p_) != 0; }
	void editor_size(int &w, int &h) override {
		w = h = 0;
		if (e_->editor_default_size) e_->editor_default_size(p_, &w, &h);
	}
	void editor_move(int x, int y, int w, int h) override {
		if (e_->editor_move) e_->editor_move(p_, x, y, w, h);
	}
	bool editor_can_resize() const override {
		return e_->editor_can_resize && e_->editor_can_resize(p_) != 0;
	}
	void editor_constrain(int &w, int &h) const override {
		if (e_->editor_constrain) e_->editor_constrain(p_, &w, &h);
	}
	void editor_focus() override { if (e_->editor_focus) e_->editor_focus(p_, 1); }
	void editor_unfocus() override { if (e_->editor_focus) e_->editor_focus(p_, 0); }
	bool editor_has_keys() const override { return true; }
	bool editor_ready() const override { return e_->editor_ready && e_->editor_ready(p_) != 0; }
	bool editor_started() const override { return editor_open(); }
	void editor_show() override { if (e_->editor_show) e_->editor_show(p_); }
	bool editor_showing() const override {
		// A plugin that does not park its canvas has nothing to bring in, so
		// it counts as showing from the moment it is open. Saying otherwise
		// would leave the window waiting for a signal that never comes.
		if (!e_->editor_showing) return editor_open();
		return e_->editor_showing(p_) != 0;
	}
	void editor_set_scale(float f) override {
		if (e_->editor_set_scale) e_->editor_set_scale(p_, f);
	}
	std::string drain_edits() override {
		if (!e_->drain_edits) return std::string();
		char buf[4096];
		const int n = e_->drain_edits(p_, buf, (int)sizeof(buf));
		if (n <= 0) return std::string();
		// Its own interface moved these, so Cadmium's copy of the values is
		// behind; bringing it up to date here is what makes the fallback panel
		// and the automation lanes agree with what is on screen.
		std::string out(buf, (size_t)n);
		if (e_->get_param) {
			size_t pos = 0;
			while (pos < out.size()) {
				const size_t nl = out.find('\n', pos);
				const std::string line = out.substr(pos,
						nl == std::string::npos ? std::string::npos : nl - pos);
				const size_t colon = line.find(':');
				if (colon != std::string::npos) {
					const int idx = std::atoi(line.c_str());
					if (idx >= 0 && idx < (int)pv.size()) pv[(size_t)idx] = e_->get_param(p_, idx);
				}
				if (nl == std::string::npos) break;
				pos = nl + 1;
			}
		}
		return out;
	}

private:
	const CdExtEntry *e_;
	CdExtPlug *p_;
};

/// Opens one candidate and keeps it if it is a Cadmium plugin.
void load_one(const std::string &f) {
	for (const Loaded &l : g_loaded) {
		if (l.path == f) return;
	}
	std::string err;
	// Opening somebody else's library runs their static constructors, and this
	// is where that happens; the crash report should say so.
	CrashStep step("opening a Cadmium plugin", f.c_str());
	void *lib = open_library(f, err);
	if (!lib) { note_problem(f, err); return; }
	auto get = (const CdExtEntry *(*)(void))find_symbol(lib, "cd_plugin_entry_v1");
	// Not one of ours. Silent: a plugin folder can hold anything.
	if (!get) return;
	const CdExtEntry *entry = get();
	std::string why;
	if (!entry_usable(entry, why)) { note_problem(f, why); return; }
	g_loaded.push_back({f, entry});
}

void scan_dir(const std::string &dir) {
#ifdef _WIN32
	WIN32_FIND_DATAA fd;
	HANDLE h = FindFirstFileA((dir + "\\*").c_str(), &fd);
	if (h == INVALID_HANDLE_VALUE) return;
	do {
		const std::string name = fd.cFileName;
		if (name == "." || name == "..") continue;
		if (!has_suffix(name, LIB_SUFFIX) && !has_suffix(name, LIB_ALT)) continue;
		load_one(dir + "\\" + name);
	} while (FindNextFileA(h, &fd));
	FindClose(h);
#else
	DIR *dp = ::opendir(dir.c_str());
	if (!dp) return;
	std::vector<std::string> files;
	while (struct dirent *e = ::readdir(dp)) {
		if (e->d_name[0] == '.') continue;
		const std::string name = e->d_name;
		if (!has_suffix(name, LIB_SUFFIX) && !has_suffix(name, LIB_ALT)) continue;
		const std::string full = dir + "/" + name;
		struct stat st;
		if (::stat(full.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
		files.push_back(full);
	}
	::closedir(dp);
	// A stable order, so the plugin list does not shuffle between runs.
	std::sort(files.begin(), files.end());
	for (const std::string &f : files) load_one(f);
#endif
}

} // namespace

std::vector<std::string> ext_plugin_dirs() {
	std::vector<std::string> d;
	if (const char *e = std::getenv("CADMIUM_PLUGIN_PATH")) {
		std::string s(e), cur;
		for (size_t i = 0; i <= s.size(); i++) {
#ifdef _WIN32
			const bool sep = (i == s.size() || s[i] == ';');
#else
			const bool sep = (i == s.size() || s[i] == ':');
#endif
			if (sep) { if (!cur.empty()) d.push_back(cur); cur.clear(); }
			else cur.push_back(s[i]);
		}
	}
#ifdef _WIN32
	d.push_back(home_dir() + "\\Documents\\Cadmium\\plugins");
#else
	d.push_back(home_dir() + "/.local/share/Cadmium/plugins");
	d.push_back("/usr/lib/cadmium/plugins");
	d.push_back("/usr/local/lib/cadmium/plugins");
#endif
	return d;
}

void register_external(std::vector<PlugDesc> &out) {
	if (!g_scanned) {
		g_scanned = true;
		for (const std::string &dir : ext_plugin_dirs()) scan_dir(dir);
	}
	for (const Loaded &l : g_loaded) {
		for (int i = 0; i < l.entry->desc_count; i++) {
			const CdExtDesc &d = l.entry->descs[i];
			if (!d.id || !d.name) continue;
			bool clash = false;
			for (const PlugDesc &existing : out) {
				if (std::strcmp(existing.id, d.id) == 0) clash = true;
			}
			if (clash) {
				note_problem(l.path, std::string("its id \"") + d.id
						+ "\" is already taken by something built in");
				continue;
			}
			PlugDesc pd;
			pd.id = d.id;
			pd.name = d.name;
			pd.vendor = d.vendor ? d.vendor : "";
			pd.category = d.category ? d.category : "Synth";
			pd.instrument = d.instrument != 0;
			pd.ui = d.ui;
			// Created through make_external, which knows which library the id
			// came from; a plain function pointer could not.
			pd.make = nullptr;
			pd.params.reserve((size_t)d.param_count);
			for (int k = 0; k < d.param_count; k++) {
				const CdExtParam &s = d.params[k];
				ParamDesc p;
				// The strings belong to the library, which is never closed.
				p.id = s.id;
				p.name = s.name;
				p.min = s.min;
				p.max = s.max;
				p.def = s.def;
				p.kind = kind_from_ext(s.kind);
				p.group = s.group ? s.group : "";
				p.choices = s.choices ? s.choices : "";
				p.skew = s.skew > 0.0f ? s.skew : 1.0f;
				p.steps = s.steps;
				p.readonly = s.readonly != 0;
				pd.params.push_back(p);
			}
			g_by_id[d.id] = {l.entry, &d};
			out.push_back(pd);
		}
	}
}

Plug *make_external(const std::string &id, double sr, int block) {
	auto it = g_by_id.find(id);
	if (it == g_by_id.end()) return nullptr;
	const CdExtEntry *e = it->second.first;
	CrashStep step("creating an external plugin", id.c_str());
	CdExtPlug *raw = e->create(id.c_str(), sr, block);
	if (!raw) return nullptr;
	return new ExtPlug(e, raw);
}

const std::vector<ExtProblem> &ext_problems() { return g_problems; }

} // namespace cd
