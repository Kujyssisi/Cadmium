// Cadmium — the Godot side of the engine: an AudioStream that pulls from
// cd::Engine, plus one Node exposing the whole API to GDScript.
#include "analyze.h"
#include "crashlog.h"
#include "keyboard.h"
#include "engine.h"
#include "ext_plugins.h"
#include "midi_in.h"
#include "vst3_editor.h"
#include "vst3_host.h"

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <atomic>
#include <cstring>

using namespace godot;

namespace cd {
Engine *g_engine = nullptr;
std::atomic<float> g_render_progress{0.0f};
} // namespace cd

// ---------------------------------------------------------------------------
class CdStreamPlayback : public AudioStreamPlayback {
	GDCLASS(CdStreamPlayback, AudioStreamPlayback)

protected:
	static void _bind_methods() {}

public:
	bool active = false;

	void _start(double) override { active = true; }
	void _stop() override { active = false; }
	bool _is_playing() const override { return active; }
	int32_t _get_loop_count() const override { return 0; }
	double _get_playback_position() const override { return 0.0; }
	void _seek(double) override {}

	int32_t _mix(AudioFrame *buffer, float, int32_t frames) override {
		cd::Engine *e = cd::g_engine;
		if (!e || !active) {
			for (int32_t i = 0; i < frames; i++) { buffer[i].left = 0.0f; buffer[i].right = 0.0f; }
			return frames;
		}
		static thread_local std::vector<float> L, R;
		if ((int32_t)L.size() < frames) { L.resize((size_t)frames); R.resize((size_t)frames); }
		e->process(L.data(), R.data(), (int)frames);
		for (int32_t i = 0; i < frames; i++) {
			buffer[i].left = L[(size_t)i];
			buffer[i].right = R[(size_t)i];
		}
		return frames;
	}
};

class CdStream : public AudioStream {
	GDCLASS(CdStream, AudioStream)

protected:
	static void _bind_methods() {}

public:
	Ref<AudioStreamPlayback> _instantiate_playback() const override {
		Ref<CdStreamPlayback> pb;
		pb.instantiate();
		return pb;
	}
	String _get_stream_name() const override { return "Cadmium"; }
	double _get_length() const override { return 0.0; }
	bool _is_monophonic() const override { return true; }
};

// ---------------------------------------------------------------------------
class CdEngine : public Node {
	GDCLASS(CdEngine, Node)

	cd::Engine *eng = nullptr;
	AudioStreamPlayer *player = nullptr;
	cd::MidiIn midi;
	bool down_ = false;

protected:
	static void _bind_methods();

public:
	CdEngine() {
		eng = new cd::Engine();
		cd::g_engine = eng;
	}
	~CdEngine() {
		// If the node was ever in the tree, shutdown() already ran while Godot
		// was still alive. Reaching here without it means the object is being
		// destroyed during the engine's final sweep, where calling back into
		// Godot (the audio server, memdelete) is no longer safe -- so this path
		// touches nothing but our own memory.
		if (!down_) {
			cd::g_engine = nullptr;
			{
				std::lock_guard<std::mutex> g(eng->mutex);
			}
			midi.close();
		}
		delete eng;
		eng = nullptr;
	}

	void _notification(int what) {
		// EXIT_TREE happens during the ordinary teardown of the scene tree,
		// which is the last moment the audio server and the object allocator
		// are guaranteed to still be there.
		if (what == NOTIFICATION_EXIT_TREE || what == NOTIFICATION_PREDELETE) {
			shutdown();
		}
	}

	/// Stops the audio callback, unhooks the engine from it, and waits for any
	/// block still in flight. Safe to call more than once.
	void shutdown() {
		if (down_) return;
		down_ = true;
		AudioServer *as = AudioServer::get_singleton();
		if (player) {
			player->stop();
			// Drop the stream too: a playback still referencing this engine
			// would otherwise be torn down after the extension is unloaded.
			player->set_stream(Ref<AudioStream>());
			if (player->get_parent()) player->get_parent()->remove_child(player);
			memdelete(player);
			player = nullptr;
		}
		// Swap the pointer out under the audio server's own lock, then wait for
		// any block still in flight before anything is freed.
		if (as) as->lock();
		cd::g_engine = nullptr;
		if (as) as->unlock();
		{
			std::lock_guard<std::mutex> g(eng->mutex);
		}
		midi.close();
	}

	void start_audio() {
		const double rate = AudioServer::get_singleton()->get_mix_rate();
		eng->prepare(rate, 512);
		if (!player) {
			player = memnew(AudioStreamPlayer);
			add_child(player);
			Ref<CdStream> s;
			s.instantiate();
			player->set_stream(s);
			player->set_bus("Master");
		}
		player->play();
	}
	void stop_audio() { if (player) player->stop(); }
	double sample_rate() const { return eng->sr; }

	// --- transport
	void play(bool from_start) { eng->play(from_start); }
	void stop() { eng->stop(); }
	void stop_channel(int ch) { eng->stop_channel(ch); }
	bool is_playing() const { return eng->playing(); }
	void set_bpm(double b) { eng->set_bpm(b); }
	double get_bpm() const { return eng->bpm(); }
	void set_position(double b) { eng->set_position(b); }
	double get_position() const { return eng->position(); }
	void set_mode(int m) { eng->set_mode(m); }
	int get_mode() const { return eng->mode(); }
	void set_loop(double a, double b, bool on) { eng->set_loop(a, b, on); }
	/// What the transport is currently looping over, for anything that needs to
	/// show it or check it.
	double loop_start() const { return eng->loop_start(); }
	double loop_end() const { return eng->loop_end(); }
	void set_current_pattern(int p) { eng->set_pattern_loop(p); }
	int get_current_pattern() const { return eng->current_pattern(); }
	void set_metronome(bool on) { eng->set_metronome(on); }
	/// `which` 0 is the accented click on the first beat of a bar, 1 is every
	/// other beat. `frames` is interleaved and `rate` is what it was recorded
	/// at; an empty array puts that beat back to the synthesised click.
	void set_metronome_sound(int which, const PackedFloat32Array &frames, double rate, int channels) {
		std::vector<float> v((size_t)frames.size());
		for (int i = 0; i < frames.size(); i++) v[(size_t)i] = frames[i];
		eng->set_metronome_sound(which, v, rate, channels);
	}
	void set_time_sig(int n, int d) { eng->set_time_sig(n, d); }

	// --- plugins
	Array stock_plugins() const {
		Array out;
		for (const cd::PlugDesc &d : cd::registry()) {
			Dictionary e;
			e["id"] = String(d.id);
			e["name"] = String(d.name);
			e["vendor"] = String(d.vendor);
			e["category"] = String(d.category);
			e["instrument"] = d.instrument;
			e["ui"] = d.ui;
			out.push_back(e);
		}
		return out;
	}
	int create_plugin(const String &id) { return eng->create_plugin(id.utf8().get_data()); }
	int create_vst3(const String &path, const String &cid) {
		return eng->create_vst3(path.utf8().get_data(), cid.utf8().get_data());
	}
	void destroy_plugin(int h) { eng->destroy_plugin(h); }

	/// Hands a plugin bulk data the engine has no reader for -- a picture, in
	/// Prism's case, decoded on the Godot side where there is an image loader.
	bool plugin_set_data(int h, const String &key, const PackedFloat32Array &data) {
		cd::Plug *p = eng->plug(h);
		if (!p || data.size() == 0) return false;
		std::lock_guard<std::mutex> g(eng->mutex);
		return p->set_data(key.utf8().get_data(), data.ptr(), (int)data.size());
	}

	/// The overview of a registered audio asset: `buckets` min/max pairs built
	/// when the file was read, so drawing a clip never walks its samples.
	PackedFloat32Array asset_peaks(int index, int buckets) {
		PackedFloat32Array out;
		const cd::AudioFile *f = eng->asset_file(index);
		if (!f || f->peaks.empty() || buckets < 2) return out;
		const int have = (int)(f->peaks.size() / 2);
		out.resize(buckets * 2);
		for (int i = 0; i < buckets; i++) {
			const int a = (int)((int64_t)have * i / buckets);
			const int b = std::max(a + 1, (int)((int64_t)have * (i + 1) / buckets));
			float lo = 0.0f, hi = 0.0f;
			for (int s = a; s < b && s < have; s++) {
				lo = std::min(lo, f->peaks[(size_t)s * 2]);
				hi = std::max(hi, f->peaks[(size_t)s * 2 + 1]);
			}
			out.set(i * 2, lo);
			out.set(i * 2 + 1, hi);
		}
		return out;
	}

	/// How long a loaded asset is, in seconds. The file is already in memory,
	/// so this is free -- which the alternative was not: the playlist used to
	/// ask ffprobe, in a subprocess, once per audio clip per frame.
	double asset_seconds(int index) const {
		// The played copy: a sample that has been trimmed or stretched is a
		// different length, and a clip on the timeline is as long as what it
		// actually plays.
		const cd::AudioFile *f = eng->asset_played(index);
		if (!f || f->rate <= 0) return 0.0;
		return (double)f->frames() / (double)f->rate;
	}

	/// The overview of one stretch of a file, `t0` to `t1` as fractions of the
	/// whole, in `buckets` min/max pairs.
	///
	/// The whole-file overview is 4096 buckets, which is plenty for a clip drawn
	/// an inch wide and nowhere near enough for one zoomed in until a bar fills
	/// the screen -- that is why zooming in used to stop adding detail. When the
	/// span asked for is finer than the overview, the samples themselves are
	/// walked instead, with a stride that bounds the work whatever the file.
	/// What a sample in the project is set to do with itself -- the same
	/// settings FL puts on an audio clip -- and setting them.
	Dictionary sample_settings(int index) const {
		const cd::SampleSettings s = eng->sample_settings(index);
		Dictionary d;
		d["gain"] = s.gain;
		d["pan"] = s.pan;
		d["pitch"] = s.pitch;
		d["stretch"] = s.stretch;
		d["mode"] = s.mode;
		d["normalize"] = s.normalize;
		d["reverse"] = s.reverse;
		d["remove_dc"] = s.remove_dc;
		d["polarity"] = s.polarity;
		d["swap_stereo"] = s.swap_stereo;
		d["fade_stereo"] = s.fade_stereo;
		d["start"] = s.start;
		d["length"] = s.length;
		d["fade_in"] = s.fade_in;
		d["fade_out"] = s.fade_out;
		d["trim_db"] = s.trim_db;
		d["mixer"] = s.mixer;
		return d;
	}
	void set_sample_settings(int index, const Dictionary &d) {
		cd::SampleSettings s = eng->sample_settings(index);
		if (d.has("gain")) s.gain = (float)(double)d["gain"];
		if (d.has("pan")) s.pan = (float)(double)d["pan"];
		if (d.has("pitch")) s.pitch = (float)(double)d["pitch"];
		if (d.has("stretch")) s.stretch = (float)(double)d["stretch"];
		if (d.has("mode")) s.mode = (int)d["mode"];
		if (d.has("normalize")) s.normalize = (bool)d["normalize"];
		if (d.has("reverse")) s.reverse = (bool)d["reverse"];
		if (d.has("remove_dc")) s.remove_dc = (bool)d["remove_dc"];
		if (d.has("polarity")) s.polarity = (bool)d["polarity"];
		if (d.has("swap_stereo")) s.swap_stereo = (bool)d["swap_stereo"];
		if (d.has("fade_stereo")) s.fade_stereo = (bool)d["fade_stereo"];
		if (d.has("start")) s.start = (float)(double)d["start"];
		if (d.has("length")) s.length = (float)(double)d["length"];
		if (d.has("fade_in")) s.fade_in = (float)(double)d["fade_in"];
		if (d.has("fade_out")) s.fade_out = (float)(double)d["fade_out"];
		if (d.has("trim_db")) s.trim_db = (float)(double)d["trim_db"];
		if (d.has("mixer")) s.mixer = (int)d["mixer"];
		eng->set_sample_settings(index, s);
	}
	/// How long the sample is once everything has been applied to it, which is
	/// what a clip on the timeline should measure itself against.
	double asset_played_seconds(int index) const {
		const cd::AudioFile *f = eng->asset_played(index);
		if (!f || f->rate <= 0) return 0.0;
		return (double)f->frames() / (double)f->rate;
	}

	PackedFloat32Array asset_peaks_range(int index, double t0, double t1, int buckets) {
		PackedFloat32Array out;
		// Drawn from what is played, so reversing a sample reverses its
		// picture too.
		const cd::AudioFile *f = eng->asset_played(index);
		if (!f || buckets < 2) return out;
		t0 = std::max(0.0, std::min(1.0, t0));
		t1 = std::max(t0, std::min(1.0, t1));
		// Turning a sample down draws it smaller. Its level is applied when it
		// is played rather than baked into the file -- so that moving the knob
		// costs nothing -- and the picture has to be told about it, or it goes
		// on showing a sample at a volume nobody will hear.
		const float g = eng->sample_settings(index).gain;
		out.resize(buckets * 2);
		const int have = (int)(f->peaks.size() / 2);
		const double span = t1 - t0;
		if (have >= 2 && span * (double)have >= (double)buckets) {
			for (int i = 0; i < buckets; i++) {
				const double u0 = t0 + span * (double)i / (double)buckets;
				const double u1 = t0 + span * (double)(i + 1) / (double)buckets;
				int a = (int)(u0 * (double)have);
				int b = std::max(a + 1, (int)(u1 * (double)have));
				a = std::max(0, std::min(have - 1, a));
				b = std::max(a + 1, std::min(have, b));
				float lo = 0.0f, hi = 0.0f;
				for (int k = a; k < b; k++) {
					lo = std::min(lo, f->peaks[(size_t)k * 2]);
					hi = std::max(hi, f->peaks[(size_t)k * 2 + 1]);
				}
				out.set(i * 2, std::max(-1.0f, std::min(1.0f, lo * g)));
				out.set(i * 2 + 1, std::max(-1.0f, std::min(1.0f, hi * g)));
			}
			return out;
		}
		const int64_t frames = (int64_t)f->frames();
		if (frames < 2 || f->channels < 1) return out;
		const int64_t f0 = (int64_t)(t0 * (double)frames);
		const int64_t f1 = std::max(f0 + 1, (int64_t)(t1 * (double)frames));
		// At most a couple of hundred thousand samples read per call, however
		// long the file and however far in the view is zoomed.
		const int64_t budget = 200000;
		const int64_t stride = std::max<int64_t>(1, (f1 - f0) / budget);
		for (int i = 0; i < buckets; i++) {
			int64_t a = f0 + (f1 - f0) * i / buckets;
			int64_t b = std::max(a + 1, f0 + (f1 - f0) * (i + 1) / buckets);
			if (b > frames) b = frames;
			float lo = 0.0f, hi = 0.0f;
			for (int64_t k = a; k < b; k += stride) {
				for (int c = 0; c < f->channels; c++) {
					const float v = f->data[(size_t)(k * f->channels + c)];
					if (v < lo) lo = v;
					if (v > hi) hi = v;
				}
			}
			out.set(i * 2, std::max(-1.0f, std::min(1.0f, lo * g)));
			out.set(i * 2 + 1, std::max(-1.0f, std::min(1.0f, hi * g)));
		}
		return out;
	}

	/// What this plugin last put out: `frames` interleaved pairs, newest last.
	/// Every stock panel draws this, so none of them is a bare grid of knobs.
	PackedFloat32Array plugin_scope(int h, int frames) {
		PackedFloat32Array out;
		cd::Plug *p = eng->plug(h);
		if (!p || frames < 2) return out;
		const int n = std::min(frames, cd::Plug::SCOPE_LEN);
		out.resize(n * 2);
		for (int i = 0; i < n; i++) {
			const int s = ((p->scope_w + cd::Plug::SCOPE_LEN - n + i) % cd::Plug::SCOPE_LEN) * 2;
			out.set(i * 2, p->scope[s]);
			out.set(i * 2 + 1, p->scope[s + 1]);
		}
		return out;
	}
	double plugin_peak(int h) {
		cd::Plug *p = eng->plug(h);
		return p ? (double)p->out_peak : 0.0;
	}

	Array plugin_params(int h) const {
		Array out;
		const cd::PlugDesc *d = eng->plug_desc(h);
		if (!d) return out;
		for (size_t i = 0; i < d->params.size(); i++) {
			const cd::ParamDesc &p = d->params[i];
			Dictionary e;
			e["index"] = (int)i;
			e["id"] = String(p.id);
			e["name"] = String(p.name);
			e["min"] = p.min;
			e["max"] = p.max;
			e["default"] = p.def;
			e["kind"] = p.kind;
			e["group"] = String(p.group ? p.group : "");
			e["choices"] = String(p.choices ? p.choices : "");
			e["skew"] = p.skew;
			e["steps"] = p.steps;
			e["readonly"] = p.readonly;
			out.push_back(e);
		}
		return out;
	}
	/// One parameter's descriptor. Asking for the whole list to read a single
	/// entry is not free: a big synth publishes thousands of them.
	Dictionary plugin_param(int h, int i) const {
		Dictionary e;
		const cd::PlugDesc *d = eng->plug_desc(h);
		if (!d || i < 0 || i >= (int)d->params.size()) return e;
		const cd::ParamDesc &p = d->params[(size_t)i];
		e["index"] = i;
		e["id"] = String(p.id);
		e["name"] = String(p.name);
		e["min"] = p.min;
		e["max"] = p.max;
		e["default"] = p.def;
		e["kind"] = p.kind;
		e["group"] = String(p.group ? p.group : "");
		e["choices"] = String(p.choices ? p.choices : "");
		e["skew"] = p.skew;
		e["steps"] = p.steps;
		e["readonly"] = p.readonly;
		return e;
	}
	Dictionary plugin_info(int h) const {
		Dictionary e;
		const cd::PlugDesc *d = eng->plug_desc(h);
		if (!d) return e;
		e["id"] = String(d->id);
		e["name"] = String(d->name);
		e["vendor"] = String(d->vendor);
		e["category"] = String(d->category);
		e["instrument"] = d->instrument;
		e["ui"] = d->ui;
		e["params"] = (int)d->params.size();
		auto *v3 = dynamic_cast<cd::Vst3Plug *>(eng->plug(h));
		if (v3) {
			e["single_component"] = v3->single_component();
			e["controller_is_component"] = v3->controller_is_component();
		}
		return e;
	}
	void plugin_set_param(int h, int i, double v) {
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *p = eng->plug(h);
		if (p) p->set_param(i, (float)v);
	}
	double plugin_get_param(int h, int i) const {
		cd::Plug *p = eng->plug(h);
		return (p && i >= 0 && i < (int)p->pv.size()) ? p->pv[(size_t)i] : 0.0;
	}
	bool plugin_set_string(int h, const String &key, const String &value) {
		// File loads can take a while, so the audio thread is stopped for them
		// only at the moment of the swap, inside the plugin.
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *p = eng->plug(h);
		return p ? p->set_string(key.utf8().get_data(), value.utf8().get_data()) : false;
	}
	String plugin_get_string(int h, const String &key) const {
		// Under the same lock the audio thread takes. Asking a plugin for its
		// state reaches into the half of it that makes the sound, and a plugin
		// asked for that while it is in the middle of a block is a plugin
		// being used from two threads at once. It happens on every undo point,
		// which is often, and a big instrument does a lot of work to answer.
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *p = eng->plug(h);
		return p ? String(p->get_string(key.utf8().get_data()).c_str()) : String();
	}
	PackedFloat32Array plugin_aux(int h, int what, int count) {
		PackedFloat32Array out;
		cd::Plug *p = eng->plug(h);
		if (!p || count <= 0) return out;
		std::vector<float> tmp((size_t)count, 0.0f);
		int n = 0;
		{
			std::lock_guard<std::mutex> g(eng->mutex);
			n = p->aux(what, tmp.data(), count);
		}
		out.resize(n);
		for (int i = 0; i < n; i++) out[i] = tmp[(size_t)i];
		return out;
	}
	String plugin_param_text(int h, int i, double v) const {
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *p = eng->plug(h);
		if (!p) return String();
		auto *v3 = dynamic_cast<cd::Vst3Plug *>(p);
		if (v3) return String(v3->param_display(i, (float)v).c_str());
		// Anything else that knows how to spell its own values -- a plugin
		// from the plugin folder with units Cadmium has no kind for.
		return String(p->param_text(i, (float)v).c_str());
	}

	/// The plugin folders, and anything in them that would not open. A plugin
	/// that is installed and silently absent is the one nobody can debug.
	PackedStringArray ext_plugin_dirs() const {
		PackedStringArray out;
		for (const std::string &d : cd::ext_plugin_dirs()) out.push_back(String(d.c_str()));
		return out;
	}
	Array ext_plugin_problems() const {
		Array out;
		for (const cd::ExtProblem &p : cd::ext_problems()) {
			Dictionary e;
			e["path"] = String(p.path.c_str());
			e["error"] = String(p.error.c_str());
			out.push_back(e);
		}
		return out;
	}
	Array plugin_drain_edits(int h) {
		Array out;
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *p = eng->plug(h);
		if (!p) return out;
		// Any plugin with an interface of its own, not only a hosted VST3.
		const std::string s = p->drain_edits();
		size_t pos = 0;
		while (pos < s.size()) {
			const size_t nl = s.find('\n', pos);
			const std::string line = s.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
			const size_t colon = line.find(':');
			if (colon != std::string::npos) {
				Array pair;
				pair.push_back(atoi(line.substr(0, colon).c_str()));
				pair.push_back(atof(line.substr(colon + 1).c_str()));
				out.push_back(pair);
			}
			if (nl == std::string::npos) break;
			pos = nl + 1;
		}
		return out;
	}

	static Dictionary vst3_entry(const cd::Vst3Info &i) {
		Dictionary e;
		e["path"] = String(i.path.c_str());
		e["cid"] = String(i.cid.c_str());
		e["name"] = String(i.name.c_str());
		e["vendor"] = String(i.vendor.c_str());
		e["category"] = String(i.category.c_str());
		e["version"] = String(i.version.c_str());
		e["instrument"] = i.instrument;
		e["error"] = String(i.error.c_str());
		return e;
	}

	std::vector<std::string> vst3_dir_list(const PackedStringArray &dirs) const {
		std::vector<std::string> d;
		if (dirs.is_empty()) return cd::vst3_default_dirs();
		for (int i = 0; i < dirs.size(); i++) d.push_back(dirs[i].utf8().get_data());
		return d;
	}

	Array scan_vst3(const PackedStringArray &dirs) const {
		Array out;
		for (const cd::Vst3Info &i : cd::vst3_scan(vst3_dir_list(dirs))) out.push_back(vst3_entry(i));
		return out;
	}

	/// The bundles under `dirs`, without opening any of them.
	PackedStringArray vst3_bundles(const PackedStringArray &dirs) const {
		PackedStringArray out;
		for (const std::string &b : cd::vst3_bundles(vst3_dir_list(dirs))) out.push_back(String(b.c_str()));
		return out;
	}

	/// One bundle, opened and asked what it holds. Always answers with at
	/// least one entry; a failed one carries the reason in "error".
	Array scan_vst3_bundle(const String &bundle) const {
		Array out;
		for (const cd::Vst3Info &i : cd::vst3_scan_bundle(bundle.utf8().get_data())) {
			out.push_back(vst3_entry(i));
		}
		return out;
	}

	/// The same, but each class is actually loaded the way opening it in a
	/// project loads it -- created, initialised and taken down again. A plugin
	/// that falls over on the way up does it here, in whatever process is
	/// running this, rather than the first time somebody puts it on a channel.
	Array probe_vst3_bundle(const String &bundle) {
		Array out;
		// So a report from the scan is not mistaken for one from the program
		// itself: this is the copy of Cadmium whose whole job is to find out
		// whether a plugin can be opened at all.
		cd::crash_note(std::string("looking at whether ") + bundle.utf8().get_data()
				+ " can be opened at all (this is the scan, not the program)");
		for (const cd::Vst3Info &i : cd::vst3_scan_bundle(bundle.utf8().get_data())) {
			Dictionary e = vst3_entry(i);
			if (i.error.empty()) {
				cd::Vst3Plug *p = new cd::Vst3Plug();
				const bool ok = p->load(i.path, i.cid, 48000.0, 512);
				if (!ok) e["error"] = String(p->error().c_str());
				delete p;
			}
			out.push_back(e);
		}
		return out;
	}

	/// Where crash reports go, and what to stamp them with.
	void crash_init(const String &dir, const String &version, const String &prefix) {
		cd::crash_init(dir.utf8().get_data(), version.utf8().get_data(),
				prefix.is_empty() ? std::string("cadmium-crash")
								  : std::string(prefix.utf8().get_data()));
	}
	/// What Cadmium is doing, in a few words, for the report if it stops.
	void crash_note(const String &what) { cd::crash_note(what.utf8().get_data()); }
	/// Falls over on purpose, so that all of the above can be tested.
	void crash_now() { cd::crash_now(); }

	/// Whether any key at all is physically down. See keyboard.h: this is the
	/// only way to tell a key that is still held from one whose release went
	/// to somebody else's window.
	bool any_key_held() const { return cd::any_key_held(); }

	/// Closes the libraries a scan opened and nothing is playing through.
	void vst3_release_scanned() { cd::vst3_release_unused_modules(); }
	PackedStringArray vst3_dirs() const {
		PackedStringArray out;
		for (const std::string &s : cd::vst3_default_dirs()) out.push_back(String(s.c_str()));
		return out;
	}

	// --- channels
	int add_channel(const String &name) { return eng->add_channel(name.utf8().get_data()); }
	void remove_channel(int i) { eng->remove_channel(i); }
	void move_channel(int a, int b) { eng->move_channel(a, b); }
	int channel_count() const { return eng->channel_count(); }
	void set_channel_instrument(int ch, int h) { eng->set_channel_instrument(ch, h); }
	int get_channel_instrument(int ch) {
		cd::Channel *c = eng->channel(ch);
		return c ? c->handle : -1;
	}
	void set_channel(int ch, double vol, double pan, bool mute, bool solo, int mixer, int transpose) {
		eng->set_channel(ch, (float)vol, (float)pan, mute, solo, mixer, transpose);
	}
	void set_channel_name(int ch, const String &n) { eng->set_channel_name(ch, n.utf8().get_data()); }
	/// `layers` is an array of [channel, transpose, gain] triples.
	void set_channel_layers(int ch, const Array &layers, bool layer_only) {
		std::vector<cd::Channel::Layer> out;
		for (int i = 0; i < layers.size(); i++) {
			Array a = layers[i];
			if (a.size() < 3) continue;
			cd::Channel::Layer l;
			l.channel = (int)a[0];
			l.transpose = (int)a[1];
			l.gain = (float)(double)a[2];
			out.push_back(l);
		}
		eng->set_channel_layers(ch, out, layer_only);
	}

	// --- mixer
	void set_mixer_count(int n) { eng->set_mixer_count(n); }
	int mixer_count() const { return eng->mixer_count(); }
	void set_mixer(int t, double vol, double pan, bool mute, bool solo, int route) {
		eng->set_mixer(t, (float)vol, (float)pan, mute, solo, route);
	}
	void set_mixer_name(int t, const String &n) { eng->set_mixer_name(t, n.utf8().get_data()); }
	void set_send(int t, int i, int dest, double amount, bool pre, bool sidechain) {
		eng->set_send(t, i, dest, (float)amount, pre, sidechain);
	}
	void set_insert(int t, int slot, int h) { eng->set_insert(t, slot, h); }
	void set_insert_flags(int t, int slot, bool bypass, double wet) {
		eng->set_insert_flags(t, slot, bypass, (float)wet);
	}
	void move_insert(int t, int a, int b) { eng->move_insert(t, a, b); }
	int insert_handle(int t, int slot) const { return eng->insert_handle(t, slot); }
	PackedFloat32Array meters() const {
		std::vector<float> m;
		eng->meters(m);
		PackedFloat32Array out;
		out.resize((int)m.size());
		for (size_t i = 0; i < m.size(); i++) out[(int)i] = m[i];
		return out;
	}

	// --- song
	void set_pattern(int id, const PackedFloat32Array &notes, double length) {
		std::vector<cd::Note> v;
		const int stride = 7;
		for (int i = 0; i + stride <= notes.size(); i += stride) {
			cd::Note n;
			n.channel = (int)notes[i];
			n.beat = notes[i + 1];
			n.length = notes[i + 2];
			n.key = (int)notes[i + 3];
			n.vel = notes[i + 4];
			n.pan = notes[i + 5];
			n.fine = notes[i + 6];
			v.push_back(n);
		}
		eng->set_pattern(id, v, (float)length);
	}
	void clear_pattern(int id) { eng->clear_pattern(id); }
	void set_playlist(const PackedFloat32Array &clips) {
		std::vector<cd::Clip> v;
		const int stride = 9;
		for (int i = 0; i + stride <= clips.size(); i += stride) {
			cd::Clip c;
			c.type = (int)clips[i];
			c.index = (int)clips[i + 1];
			c.track = (int)clips[i + 2];
			c.start = clips[i + 3];
			c.length = clips[i + 4];
			c.offset = clips[i + 5];
			c.gain = clips[i + 6];
			c.mute = clips[i + 7] > 0.5f;
			c.pitch = clips[i + 8];
			v.push_back(c);
		}
		eng->set_playlist(v);
	}
	void set_automation_full(int id, int target, int a, int b, const PackedFloat32Array &points,
			int mode, bool on, double base) {
		std::vector<cd::AutoPoint> v;
		for (int i = 0; i + 3 <= points.size(); i += 3) {
			cd::AutoPoint p;
			p.beat = points[i];
			p.value = points[i + 1];
			p.curve = points[i + 2];
			v.push_back(p);
		}
		eng->set_automation(id, target, a, b, v, mode, on, (float)base);
	}
	/// A lane driving several controls at once. `links` is a flat run of
	/// target, a, b, base -- four numbers per control.
	void set_automation_links(int id, const PackedFloat32Array &links,
			const PackedFloat32Array &points, int mode, bool on) {
		std::vector<cd::AutoLink> ls;
		for (int i = 0; i + 4 <= links.size(); i += 4) {
			cd::AutoLink l;
			l.target = (int)links[i];
			l.a = (int)links[i + 1];
			l.b = (int)links[i + 2];
			l.base = links[i + 3];
			ls.push_back(l);
		}
		std::vector<cd::AutoPoint> v;
		for (int i = 0; i + 3 <= points.size(); i += 3) {
			cd::AutoPoint p;
			p.beat = points[i];
			p.value = points[i + 1];
			p.curve = points[i + 2];
			v.push_back(p);
		}
		eng->set_automation_links(id, ls, v, mode, on);
	}
	void set_automation(int id, int target, int a, int b, const PackedFloat32Array &points) {
		std::vector<cd::AutoPoint> v;
		for (int i = 0; i + 3 <= points.size(); i += 3) {
			cd::AutoPoint p;
			p.beat = points[i];
			p.value = points[i + 1];
			p.curve = points[i + 2];
			v.push_back(p);
		}
		eng->set_automation(id, target, a, b, v);
	}
	void clear_automation() { eng->clear_automation(); }
	void set_audio(int index, const String &path) {
		eng->set_audio(index, std::string(path.utf8().get_data()));
	}
	int register_audio(const String &path) { return eng->register_audio(path.utf8().get_data()); }
	void forget_audio() { eng->forget_audio(); }
	double song_length() const { return eng->song_length(); }

	// --- live
	void note_on(int ch, int key, double vel) { eng->note_on(ch, key, (float)vel); }
	void note_off(int ch, int key) { eng->note_off(ch, key); }
	void panic() { eng->panic(); }

	// --- visualisation
	PackedFloat32Array scope(int frames) {
		std::vector<float> v;
		eng->scope(frames, v);
		PackedFloat32Array out;
		out.resize((int)v.size());
		for (size_t i = 0; i < v.size(); i++) out[(int)i] = v[i];
		return out;
	}
	PackedFloat32Array spectrum(int bins) {
		std::vector<float> v;
		eng->spectrum(bins, v);
		PackedFloat32Array out;
		out.resize((int)v.size());
		for (size_t i = 0; i < v.size(); i++) out[(int)i] = v[i];
		return out;
	}
	PackedInt32Array active_notes(int channel) {
		std::vector<int> v;
		eng->active_notes(channel, v);
		PackedInt32Array out;
		out.resize((int)v.size());
		for (size_t i = 0; i < v.size(); i++) out[(int)i] = v[i];
		return out;
	}
	double channel_level(int channel) const { return eng->channel_level(channel); }

	// --- analysis
	Dictionary analyze(const String &path) {
		const cd::Analysis a = cd::analyze_file(path.utf8().get_data());
		Dictionary d;
		d["ok"] = a.ok;
		d["bpm"] = a.bpm;
		d["bpm_confidence"] = a.bpm_confidence;
		d["key"] = a.key;
		d["minor"] = a.minor;
		d["key_confidence"] = a.key_confidence;
		d["duration"] = a.duration;
		return d;
	}

	// --- info
	double cpu() const { return eng->cpu(); }
	int voices() const { return eng->voices(); }
	int sample_voices() const { return eng->sample_voices(); }
	void set_sample_live(int index, double pitch_semis, double speed) {
		eng->set_sample_live(index, (float)pitch_semis, (float)speed);
	}

	// --- plugin editors
	// --- a plugin's own interface
	//
	// Asked of the processor rather than of a VST3 in particular: a plugin out
	// of the plugin folder can draw its own window too, and everything from
	// here down works the same for both. A processor with no interface
	// answers no and the window falls back to Cadmium's own controls.
	bool plugin_has_editor(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed ? ed->has_editor() : false;
	}
	Vector2i plugin_editor_size(int h) {
		cd::Plug *ed = eng->plug(h);
		if (!ed) return Vector2i(0, 0);
		int w = 0, hh = 0;
		ed->editor_size(w, hh);
		return Vector2i(w, hh);
	}
	bool plugin_open_editor(int h, int64_t parent, int x, int y, int w, int hh) {
		// Deliberately not under the audio lock: building an interface can take
		// seconds and the plugin needs its own run loop pumped while it does,
		// which is the very thing the lock would be holding up. IPlugView is
		// the interface thread's to call in the first place.
		cd::Plug *ed = eng->plug(h);
		return ed ? ed->open_editor((uint64_t)parent, x, y, w, hh) : false;
	}
	void plugin_close_editor(int h) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->close_editor();
	}
	bool plugin_editor_open(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed ? ed->editor_open() : false;
	}
	void plugin_editor_idle(int h) {
		// Skipped rather than waited for: this runs every frame, and a plugin's
		// timers being ticked a frame late is nothing, while ticking them
		// while the audio thread is inside the same plugin is a crash.
		std::unique_lock<std::mutex> g(eng->mutex, std::try_to_lock);
		if (!g.owns_lock()) return;
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_idle();
	}
	/// Ticks every hosted plugin's event loop, whether or not its editor is on
	/// screen -- plugins register timers as soon as they are created and some
	/// stop responding if those never fire.
	void vst3_idle_all() {
		// The same again for every plugin at once, and for the same reason:
		// this is other people's code running on the interface thread, and the
		// audio thread must not be inside the same plugin while it does.
		std::unique_lock<std::mutex> g(eng->mutex, std::try_to_lock);
		if (!g.owns_lock()) return;
		cd::vst3_pump_global();
		for (int h : eng->plugin_handles()) {
			cd::Plug *ed = eng->plug(h);
			if (ed) ed->editor_idle();
		}
	}
	bool plugin_editor_can_resize(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed ? ed->editor_can_resize() : false;
	}
	/// What the plugin actually painted, as an Image -- the harness uses this to
	/// tell an editor that opened from one that never drew anything.
	Ref<Image> plugin_editor_grab(int h) {
		cd::Plug *ed = eng->plug(h);
		if (!ed) return Ref<Image>();
		std::vector<unsigned char> rgb;
		int w = 0, hh = 0;
		if (!ed->editor_grab(rgb, w, hh) || w <= 0 || hh <= 0) return Ref<Image>();
		PackedByteArray data;
		data.resize((int64_t)rgb.size());
		std::memcpy(data.ptrw(), rgb.data(), rgb.size());
		return Image::create_from_data(w, hh, false, Image::FORMAT_RGB8, data);
	}
	/// The nearest size the plugin can draw at, for a window the user is
	/// dragging the corner of.
	Vector2i plugin_editor_constrain(int h, int w, int hh) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_constrain(w, hh);
		return Vector2i(w, hh);
	}
	void plugin_editor_focus(int h) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_focus();
	}
	/// Takes the keyboard back off the plugin's own window, so the typing keys
	/// keep playing notes while its interface is in front.
	void plugin_editor_unfocus(int h) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_unfocus();
	}
	/// True while the keyboard is going to the plugin's own window instead of
	/// to Cadmium: a key held down now will never be seen coming back up.
	bool plugin_editor_has_keys(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed != nullptr && ed->editor_has_keys();
	}
	/// True once the plugin has drawn its own interface into the window it was
	/// given. Attaching succeeds well before that.
	bool plugin_editor_ready(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed != nullptr && ed->editor_ready();
	}
	/// True as soon as the plugin has made a window of its own inside the one
	/// it was given: it is building its interface rather than doing nothing.
	bool plugin_editor_started(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed != nullptr && ed->editor_started();
	}
	/// Brings the plugin's own canvas in from where it was parked while it
	/// built itself. Until then the window shows Cadmium's own "loading".
	void plugin_editor_show(int h) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_show();
	}
	bool plugin_editor_showing(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed != nullptr && ed->editor_showing();
	}
	/// True once after the plugin says everything about it has changed -- a
	/// preset chosen in its own window. The values are re-read from it first.
	bool plugin_take_restart(int h) {
		std::lock_guard<std::mutex> g(eng->mutex);
		cd::Plug *ed = eng->plug(h);
		return ed != nullptr && ed->take_restart();
	}
	/// Test hook: acts as though the plugin's own interface moved a control,
	/// which is the one path a test cannot drive with a mouse.
	void plugin_simulate_gui_edit(int h, int i, double v) {
		std::lock_guard<std::mutex> g(eng->mutex);
		// VST3 only: it reaches into the controller half of a hosted plugin,
		// which is a thing only a hosted plugin has.
		auto *v3 = dynamic_cast<cd::Vst3Plug *>(eng->plug(h));
		if (v3) v3->simulate_gui_edit(i, (float)v);
	}
	/// What the plugin says the parameter is now, asked of the plugin rather
	/// than read from our own copy. -1 if it will not say.
	double plugin_param_live(int h, int i) {
		std::lock_guard<std::mutex> g(eng->mutex);
		auto *v3 = dynamic_cast<cd::Vst3Plug *>(eng->plug(h));
		return v3 != nullptr ? (double)v3->param_live(i) : -1.0;
	}
	void plugin_editor_set_scale(int h, double factor) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_set_scale((float)factor);
	}
	void plugin_editor_move(int h, int x, int y, int w, int hh) {
		cd::Plug *ed = eng->plug(h);
		if (ed) ed->editor_move(x, y, w, hh);
	}
	String plugin_editor_debug(int h) {
		cd::Plug *ed = eng->plug(h);
		return ed ? String(ed->editor_debug().c_str()) : String();
	}
	Vector2i plugin_editor_take_resize(int h) {
		cd::Plug *ed = eng->plug(h);
		if (!ed) return Vector2i(0, 0);
		int w = 0, hh = 0;
		if (!ed->editor_take_resize(w, hh)) return Vector2i(0, 0);
		return Vector2i(w, hh);
	}

	// --- MIDI input
	bool midi_open() { return midi.open(); }
	void midi_close() { midi.close(); }
	bool midi_is_open() const { return const_cast<cd::MidiIn &>(midi).is_open(); }
	Array midi_ports() {
		Array out;
		for (const cd::MidiPort &p : midi.ports()) {
			Dictionary e;
			e["client"] = p.client;
			e["port"] = p.port;
			e["name"] = String(p.name.c_str());
			out.push_back(e);
		}
		return out;
	}
	int midi_connect_all() { return midi.connect_all(); }
	bool midi_connect(int client, int port) { return midi.connect(client, port); }
	PackedInt32Array midi_poll() {
		PackedInt32Array out;
		const std::vector<int> ev = midi.poll_events();
		out.resize((int)ev.size());
		for (size_t i = 0; i < ev.size(); i++) out[(int)i] = ev[i];
		return out;
	}

	/// The master's safety ceiling.
	void set_limiter(bool on, double ceiling_db) { eng->set_limiter(on, (float)ceiling_db); }
	bool limiter_on() const { return eng->limiter_on(); }
	double limiter_reduction() const { return (double)eng->limiter_reduction(); }

	// --- render
	/// `tail` negative renders until the sound has decayed. `loop_fold` adds
	/// the tail back onto the beginning and cuts the file to the range, so it
	/// loops seamlessly.
	bool render_loop(const String &path, double a, double b, double tail, int bits, bool normalize,
			bool loop_fold) {
		cd::g_render_progress = 0.0f;
		float pr = 0.0f;
		const bool ok = eng->render(path.utf8().get_data(), a, b, tail, bits, normalize, &pr, loop_fold);
		cd::g_render_progress = 1.0f;
		return ok;
	}
	bool render(const String &path, double a, double b, double tail, int bits, bool normalize) {
		cd::g_render_progress = 0.0f;
		float pr = 0.0f;
		const bool ok = eng->render(path.utf8().get_data(), a, b, tail, bits, normalize, &pr);
		cd::g_render_progress = 1.0f;
		return ok;
	}
	bool render_stems(const String &dir, double a, double b, double tail, int bits) {
		return eng->render_stems(dir.utf8().get_data(), a, b, tail, bits);
	}
	double render_progress() const { return cd::g_render_progress.load(); }
};

void CdEngine::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start_audio"), &CdEngine::start_audio);
	ClassDB::bind_method(D_METHOD("stop_audio"), &CdEngine::stop_audio);
	ClassDB::bind_method(D_METHOD("sample_rate"), &CdEngine::sample_rate);

	ClassDB::bind_method(D_METHOD("play", "from_start"), &CdEngine::play);
	ClassDB::bind_method(D_METHOD("stop"), &CdEngine::stop);
	ClassDB::bind_method(D_METHOD("is_playing"), &CdEngine::is_playing);
	ClassDB::bind_method(D_METHOD("set_bpm", "bpm"), &CdEngine::set_bpm);
	ClassDB::bind_method(D_METHOD("get_bpm"), &CdEngine::get_bpm);
	ClassDB::bind_method(D_METHOD("set_position", "beat"), &CdEngine::set_position);
	ClassDB::bind_method(D_METHOD("get_position"), &CdEngine::get_position);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &CdEngine::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &CdEngine::get_mode);
	ClassDB::bind_method(D_METHOD("set_loop", "a", "b", "on"), &CdEngine::set_loop);
	ClassDB::bind_method(D_METHOD("loop_start"), &CdEngine::loop_start);
	ClassDB::bind_method(D_METHOD("loop_end"), &CdEngine::loop_end);
	ClassDB::bind_method(D_METHOD("set_current_pattern", "p"), &CdEngine::set_current_pattern);
	ClassDB::bind_method(D_METHOD("get_current_pattern"), &CdEngine::get_current_pattern);
	ClassDB::bind_method(D_METHOD("set_metronome", "on"), &CdEngine::set_metronome);
	ClassDB::bind_method(D_METHOD("set_metronome_sound", "which", "frames", "rate", "channels"),
			&CdEngine::set_metronome_sound);
	ClassDB::bind_method(D_METHOD("set_time_sig", "num", "den"), &CdEngine::set_time_sig);

	ClassDB::bind_method(D_METHOD("stock_plugins"), &CdEngine::stock_plugins);
	ClassDB::bind_method(D_METHOD("create_plugin", "id"), &CdEngine::create_plugin);
	ClassDB::bind_method(D_METHOD("create_vst3", "path", "cid"), &CdEngine::create_vst3);
	ClassDB::bind_method(D_METHOD("destroy_plugin", "handle"), &CdEngine::destroy_plugin);
	ClassDB::bind_method(D_METHOD("plugin_params", "handle"), &CdEngine::plugin_params);
	ClassDB::bind_method(D_METHOD("plugin_param", "handle", "index"), &CdEngine::plugin_param);
	ClassDB::bind_method(D_METHOD("plugin_info", "handle"), &CdEngine::plugin_info);
	ClassDB::bind_method(D_METHOD("plugin_set_param", "handle", "index", "value"), &CdEngine::plugin_set_param);
	ClassDB::bind_method(D_METHOD("plugin_get_param", "handle", "index"), &CdEngine::plugin_get_param);
	ClassDB::bind_method(D_METHOD("plugin_set_string", "handle", "key", "value"), &CdEngine::plugin_set_string);
	ClassDB::bind_method(D_METHOD("plugin_get_string", "handle", "key"), &CdEngine::plugin_get_string);
	ClassDB::bind_method(D_METHOD("plugin_aux", "handle", "what", "count"), &CdEngine::plugin_aux);
	ClassDB::bind_method(D_METHOD("plugin_set_data", "handle", "key", "data"), &CdEngine::plugin_set_data);
	ClassDB::bind_method(D_METHOD("asset_seconds", "index"), &CdEngine::asset_seconds);
	ClassDB::bind_method(D_METHOD("asset_peaks", "index", "buckets"), &CdEngine::asset_peaks);
	ClassDB::bind_method(D_METHOD("asset_peaks_range", "index", "t0", "t1", "buckets"), &CdEngine::asset_peaks_range);
	ClassDB::bind_method(D_METHOD("sample_settings", "index"), &CdEngine::sample_settings);
	ClassDB::bind_method(D_METHOD("set_sample_settings", "index", "settings"), &CdEngine::set_sample_settings);
	ClassDB::bind_method(D_METHOD("asset_played_seconds", "index"), &CdEngine::asset_played_seconds);
	ClassDB::bind_method(D_METHOD("plugin_scope", "handle", "frames"), &CdEngine::plugin_scope);
	ClassDB::bind_method(D_METHOD("plugin_peak", "handle"), &CdEngine::plugin_peak);
	ClassDB::bind_method(D_METHOD("plugin_param_text", "handle", "index", "value"), &CdEngine::plugin_param_text);
	ClassDB::bind_method(D_METHOD("ext_plugin_dirs"), &CdEngine::ext_plugin_dirs);
	ClassDB::bind_method(D_METHOD("ext_plugin_problems"), &CdEngine::ext_plugin_problems);
	ClassDB::bind_method(D_METHOD("plugin_drain_edits", "handle"), &CdEngine::plugin_drain_edits);
	ClassDB::bind_method(D_METHOD("scan_vst3", "dirs"), &CdEngine::scan_vst3);
	ClassDB::bind_method(D_METHOD("vst3_bundles", "dirs"), &CdEngine::vst3_bundles);
	ClassDB::bind_method(D_METHOD("scan_vst3_bundle", "bundle"), &CdEngine::scan_vst3_bundle);
	ClassDB::bind_method(D_METHOD("probe_vst3_bundle", "bundle"), &CdEngine::probe_vst3_bundle);
	ClassDB::bind_method(D_METHOD("crash_init", "dir", "version", "prefix"), &CdEngine::crash_init);
	ClassDB::bind_method(D_METHOD("crash_note", "what"), &CdEngine::crash_note);
	ClassDB::bind_method(D_METHOD("crash_now"), &CdEngine::crash_now);
	ClassDB::bind_method(D_METHOD("any_key_held"), &CdEngine::any_key_held);
	ClassDB::bind_method(D_METHOD("vst3_release_scanned"), &CdEngine::vst3_release_scanned);
	ClassDB::bind_method(D_METHOD("vst3_dirs"), &CdEngine::vst3_dirs);

	ClassDB::bind_method(D_METHOD("add_channel", "name"), &CdEngine::add_channel);
	ClassDB::bind_method(D_METHOD("remove_channel", "index"), &CdEngine::remove_channel);
	ClassDB::bind_method(D_METHOD("move_channel", "from", "to"), &CdEngine::move_channel);
	ClassDB::bind_method(D_METHOD("channel_count"), &CdEngine::channel_count);
	ClassDB::bind_method(D_METHOD("stop_channel", "channel"), &CdEngine::stop_channel);
	ClassDB::bind_method(D_METHOD("set_channel_layers", "channel", "layers", "layer_only"), &CdEngine::set_channel_layers);
	ClassDB::bind_method(D_METHOD("set_channel_instrument", "channel", "handle"), &CdEngine::set_channel_instrument);
	ClassDB::bind_method(D_METHOD("get_channel_instrument", "channel"), &CdEngine::get_channel_instrument);
	ClassDB::bind_method(D_METHOD("set_channel", "channel", "vol", "pan", "mute", "solo", "mixer", "transpose"), &CdEngine::set_channel);
	ClassDB::bind_method(D_METHOD("set_channel_name", "channel", "name"), &CdEngine::set_channel_name);

	ClassDB::bind_method(D_METHOD("set_mixer_count", "n"), &CdEngine::set_mixer_count);
	ClassDB::bind_method(D_METHOD("mixer_count"), &CdEngine::mixer_count);
	ClassDB::bind_method(D_METHOD("set_mixer", "track", "vol", "pan", "mute", "solo", "route"), &CdEngine::set_mixer);
	ClassDB::bind_method(D_METHOD("set_mixer_name", "track", "name"), &CdEngine::set_mixer_name);
	ClassDB::bind_method(D_METHOD("set_send", "track", "index", "dest", "amount", "pre", "sidechain"), &CdEngine::set_send);
	ClassDB::bind_method(D_METHOD("set_insert", "track", "slot", "handle"), &CdEngine::set_insert);
	ClassDB::bind_method(D_METHOD("set_insert_flags", "track", "slot", "bypass", "wet"), &CdEngine::set_insert_flags);
	ClassDB::bind_method(D_METHOD("move_insert", "track", "from", "to"), &CdEngine::move_insert);
	ClassDB::bind_method(D_METHOD("insert_handle", "track", "slot"), &CdEngine::insert_handle);
	ClassDB::bind_method(D_METHOD("meters"), &CdEngine::meters);

	ClassDB::bind_method(D_METHOD("set_pattern", "id", "notes", "length"), &CdEngine::set_pattern);
	ClassDB::bind_method(D_METHOD("clear_pattern", "id"), &CdEngine::clear_pattern);
	ClassDB::bind_method(D_METHOD("set_playlist", "clips"), &CdEngine::set_playlist);
	ClassDB::bind_method(D_METHOD("set_automation", "id", "target", "a", "b", "points"), &CdEngine::set_automation);
	ClassDB::bind_method(D_METHOD("set_automation_full", "id", "target", "a", "b", "points",
			"mode", "on", "base"), &CdEngine::set_automation_full);
	ClassDB::bind_method(D_METHOD("set_automation_links", "id", "links", "points", "mode", "on"),
			&CdEngine::set_automation_links);
	ClassDB::bind_method(D_METHOD("clear_automation"), &CdEngine::clear_automation);
	ClassDB::bind_method(D_METHOD("register_audio", "path"), &CdEngine::register_audio);
	ClassDB::bind_method(D_METHOD("set_audio", "index", "path"), &CdEngine::set_audio);
	ClassDB::bind_method(D_METHOD("forget_audio"), &CdEngine::forget_audio);
	ClassDB::bind_method(D_METHOD("song_length"), &CdEngine::song_length);

	ClassDB::bind_method(D_METHOD("note_on", "channel", "key", "vel"), &CdEngine::note_on);
	ClassDB::bind_method(D_METHOD("note_off", "channel", "key"), &CdEngine::note_off);
	ClassDB::bind_method(D_METHOD("panic"), &CdEngine::panic);

	ClassDB::bind_method(D_METHOD("plugin_has_editor", "handle"), &CdEngine::plugin_has_editor);
	ClassDB::bind_method(D_METHOD("plugin_editor_size", "handle"), &CdEngine::plugin_editor_size);
	ClassDB::bind_method(D_METHOD("plugin_open_editor", "handle", "parent", "x", "y", "w", "h"), &CdEngine::plugin_open_editor);
	ClassDB::bind_method(D_METHOD("plugin_close_editor", "handle"), &CdEngine::plugin_close_editor);
	ClassDB::bind_method(D_METHOD("plugin_editor_open", "handle"), &CdEngine::plugin_editor_open);
	ClassDB::bind_method(D_METHOD("plugin_editor_idle", "handle"), &CdEngine::plugin_editor_idle);
	ClassDB::bind_method(D_METHOD("vst3_idle_all"), &CdEngine::vst3_idle_all);
	ClassDB::bind_method(D_METHOD("shutdown"), &CdEngine::shutdown);
	ClassDB::bind_method(D_METHOD("plugin_editor_can_resize", "handle"), &CdEngine::plugin_editor_can_resize);
	ClassDB::bind_method(D_METHOD("plugin_editor_focus", "handle"), &CdEngine::plugin_editor_focus);
	ClassDB::bind_method(D_METHOD("plugin_editor_unfocus", "handle"), &CdEngine::plugin_editor_unfocus);
	ClassDB::bind_method(D_METHOD("plugin_editor_has_keys", "handle"), &CdEngine::plugin_editor_has_keys);
	ClassDB::bind_method(D_METHOD("plugin_editor_ready", "handle"), &CdEngine::plugin_editor_ready);
	ClassDB::bind_method(D_METHOD("plugin_editor_started", "handle"), &CdEngine::plugin_editor_started);
	ClassDB::bind_method(D_METHOD("plugin_editor_show", "handle"), &CdEngine::plugin_editor_show);
	ClassDB::bind_method(D_METHOD("plugin_editor_showing", "handle"), &CdEngine::plugin_editor_showing);
	ClassDB::bind_method(D_METHOD("plugin_param_live", "handle", "index"), &CdEngine::plugin_param_live);
	ClassDB::bind_method(D_METHOD("plugin_simulate_gui_edit", "handle", "index", "value"), &CdEngine::plugin_simulate_gui_edit);
	ClassDB::bind_method(D_METHOD("plugin_take_restart", "handle"), &CdEngine::plugin_take_restart);
	ClassDB::bind_method(D_METHOD("plugin_editor_set_scale", "handle", "factor"), &CdEngine::plugin_editor_set_scale);
	ClassDB::bind_method(D_METHOD("plugin_editor_constrain", "handle", "w", "h"), &CdEngine::plugin_editor_constrain);
	ClassDB::bind_method(D_METHOD("plugin_editor_grab", "handle"), &CdEngine::plugin_editor_grab);
	ClassDB::bind_method(D_METHOD("plugin_editor_move", "handle", "x", "y", "w", "h"), &CdEngine::plugin_editor_move);
	ClassDB::bind_method(D_METHOD("plugin_editor_take_resize", "handle"), &CdEngine::plugin_editor_take_resize);
	ClassDB::bind_method(D_METHOD("plugin_editor_debug", "handle"), &CdEngine::plugin_editor_debug);

	ClassDB::bind_method(D_METHOD("midi_open"), &CdEngine::midi_open);
	ClassDB::bind_method(D_METHOD("midi_close"), &CdEngine::midi_close);
	ClassDB::bind_method(D_METHOD("midi_is_open"), &CdEngine::midi_is_open);
	ClassDB::bind_method(D_METHOD("midi_ports"), &CdEngine::midi_ports);
	ClassDB::bind_method(D_METHOD("midi_connect_all"), &CdEngine::midi_connect_all);
	ClassDB::bind_method(D_METHOD("midi_connect", "client", "port"), &CdEngine::midi_connect);
	ClassDB::bind_method(D_METHOD("midi_poll"), &CdEngine::midi_poll);

	ClassDB::bind_method(D_METHOD("scope", "frames"), &CdEngine::scope);
	ClassDB::bind_method(D_METHOD("spectrum", "bins"), &CdEngine::spectrum);
	ClassDB::bind_method(D_METHOD("active_notes", "channel"), &CdEngine::active_notes);
	ClassDB::bind_method(D_METHOD("channel_level", "channel"), &CdEngine::channel_level);
	ClassDB::bind_method(D_METHOD("analyze", "path"), &CdEngine::analyze);

	ClassDB::bind_method(D_METHOD("cpu"), &CdEngine::cpu);
	ClassDB::bind_method(D_METHOD("voices"), &CdEngine::voices);
	ClassDB::bind_method(D_METHOD("sample_voices"), &CdEngine::sample_voices);
	ClassDB::bind_method(D_METHOD("set_sample_live", "index", "pitch", "speed"),
			&CdEngine::set_sample_live);

	ClassDB::bind_method(D_METHOD("set_limiter", "on", "ceiling_db"), &CdEngine::set_limiter);
	ClassDB::bind_method(D_METHOD("limiter_on"), &CdEngine::limiter_on);
	ClassDB::bind_method(D_METHOD("limiter_reduction"), &CdEngine::limiter_reduction);
	ClassDB::bind_method(D_METHOD("render", "path", "start", "end", "tail", "bits", "normalize"), &CdEngine::render);
	ClassDB::bind_method(D_METHOD("render_loop", "path", "start", "end", "tail", "bits", "normalize", "loop_fold"), &CdEngine::render_loop);
	ClassDB::bind_method(D_METHOD("render_stems", "dir", "start", "end", "tail", "bits"), &CdEngine::render_stems);
	ClassDB::bind_method(D_METHOD("render_progress"), &CdEngine::render_progress);
}

// ---------------------------------------------------------------------------
void cadmium_register_classes() {
	GDREGISTER_CLASS(CdStreamPlayback);
	GDREGISTER_CLASS(CdStream);
	GDREGISTER_CLASS(CdEngine);
}
