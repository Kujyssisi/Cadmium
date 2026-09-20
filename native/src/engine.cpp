#include "crashlog.h"
#include "engine.h"
#include "vst3_host.h"

#include <algorithm>
#include <chrono>
#include <cstring>

namespace cd {

// ---------------------------------------------------------------------------
float Automation::value_at(double beat) const {
	if (points.empty()) return 0.0f;
	if (beat <= points.front().beat) return points.front().value;
	if (beat >= points.back().beat) return points.back().value;
	size_t i = 0;
	while (i + 1 < points.size() && points[i + 1].beat <= beat) i++;
	const AutoPoint &a = points[i];
	const AutoPoint &b = points[std::min(points.size() - 1, i + 1)];
	const double span = std::max(1e-9, b.beat - a.beat);
	double t = (beat - a.beat) / span;
	// Curve bends the ramp: negative slow-in, positive slow-out.
	if (a.curve > 0.001f) t = std::pow(t, 1.0 + a.curve * 3.0);
	else if (a.curve < -0.001f) t = 1.0 - std::pow(1.0 - t, 1.0 - a.curve * 3.0);
	return lerp(a.value, b.value, (float)t);
}

// ---------------------------------------------------------------------------
Engine::Engine() {
	mixer_.resize(1);
	mixer_[0].name = "Master";
	set_mixer_count(17);
	// Both rings are allocated once, here, and never resized: the audio thread
	// reads one and writes the other, and neither may ever allocate.
	in_l_.assign((size_t)kInRing, 0.0f);
	in_r_.assign((size_t)kInRing, 0.0f);
	rec_ring_.assign((size_t)kRecRing, 0.0f);
}

Engine::~Engine() {
	for (auto &kv : plugins_) delete kv.second;
	plugins_.clear();
}

void Engine::prepare(double rate, int blk) {
	std::lock_guard<std::mutex> g(mutex);
	sr = rate;
	block = blk;
	for (auto &kv : plugins_) {
		Plug *p = kv.second;
		p->sr = rate;
		p->block = blk;
		p->prepare();
	}
	for (auto &t : mixer_) {
		t.g_vol.prepare(sr, 12.0f);
		t.g_pan.prepare(sr, 12.0f);
		t.g_vol.snap(t.vol);
		t.g_pan.snap(t.pan);
	}
	for (auto &c : channels_) { c.g_vol.prepare(sr, 12.0f); c.g_vol.snap(c.vol); }
	ensure_buffers(blk);
}

void Engine::scope(int frames, std::vector<float> &out) const {
	frames = std::max(1, std::min(SCOPE_N, frames));
	out.resize((size_t)frames * 2);
	if (scope_l_.empty()) {
		std::fill(out.begin(), out.end(), 0.0f);
		return;
	}
	for (int i = 0; i < frames; i++) {
		const int idx = (scope_w_ - frames + i + SCOPE_N * 2) % SCOPE_N;
		out[(size_t)i * 2] = scope_l_[(size_t)idx];
		out[(size_t)i * 2 + 1] = scope_r_[(size_t)idx];
	}
}

void Engine::spectrum(int bins, std::vector<float> &out) const {
	const int N = 2048;
	bins = std::max(4, std::min(N / 2, bins));
	out.assign((size_t)bins, -120.0f);
	if (scope_l_.empty()) return;
	static thread_local std::vector<float> re, im;
	re.assign(N, 0.0f);
	im.assign(N, 0.0f);
	for (int i = 0; i < N; i++) {
		const int idx = (scope_w_ - N + i + SCOPE_N * 2) % SCOPE_N;
		const float w = 0.5f - 0.5f * std::cos((float)TAU * i / (float)(N - 1));
		re[(size_t)i] = (scope_l_[(size_t)idx] + scope_r_[(size_t)idx]) * 0.5f * w;
	}
	fft(re.data(), im.data(), N, false);
	// Bins are spaced logarithmically: an analyser with a linear x axis wastes
	// nine tenths of its width on the top two octaves.
	for (int b = 0; b < bins; b++) {
		const float t0 = (float)b / (float)bins;
		const float t1 = (float)(b + 1) / (float)bins;
		const float hz0 = 20.0f * std::pow(1000.0f, t0);
		const float hz1 = 20.0f * std::pow(1000.0f, t1);
		const int i0 = std::max(1, (int)(hz0 * N / (float)sr));
		const int i1 = std::max(i0 + 1, (int)(hz1 * N / (float)sr));
		float peak = 0.0f;
		for (int i = i0; i < i1 && i < N / 2; i++) {
			peak = std::max(peak, std::sqrt(re[(size_t)i] * re[(size_t)i] + im[(size_t)i] * im[(size_t)i]));
		}
		out[(size_t)b] = gain_to_db(peak * (2.0f / (float)N) + 1e-7f);
	}
}

void Engine::active_notes(int channel, std::vector<int> &out) const {
	out.clear();
	if (channel < 0 || channel >= (int)channels_.size()) return;
	for (int k = 0; k < 128; k++) {
		if (channels_[(size_t)channel].keys[k]) out.push_back(k);
	}
}

float Engine::channel_level(int channel) const {
	if (channel < 0 || channel >= (int)channels_.size()) return 0.0f;
	return channels_[(size_t)channel].level;
}

void Engine::ensure_buffers(int frames) {
	const size_t n = (size_t)std::max(frames, block);
	// Every buffer, not a sample of them: a mixer track added after the last
	// allocation has none of its own, and the audio thread writing into it is
	// a crash rather than a wrong note. Checking a size per track per block is
	// nothing next to what is about to be done with them.
	bool ready = mixL_.size() >= n && !mixL_.empty();
	if (ready) {
		for (const auto &c : channels_) {
			if (c.L.size() < n || c.R.size() < n) { ready = false; break; }
		}
	}
	if (ready) {
		for (const auto &t : mixer_) {
			if (t.L.size() < n || t.R.size() < n || t.scL.size() < n || t.scR.size() < n) {
				ready = false;
				break;
			}
		}
	}
	if (ready) return;
	mixL_.assign(n, 0.0f); mixR_.assign(n, 0.0f);
	tmpL_.assign(n, 0.0f); tmpR_.assign(n, 0.0f);
	for (auto &c : channels_) { c.L.assign(n, 0.0f); c.R.assign(n, 0.0f); }
	for (auto &t : mixer_) {
		t.L.assign(n, 0.0f); t.R.assign(n, 0.0f);
		t.scL.assign(n, 0.0f); t.scR.assign(n, 0.0f);
	}
}

void Engine::panic() {
	std::lock_guard<std::mutex> g(mutex);
	for (auto &c : channels_) {
		if (c.inst) c.inst->all_notes_off();
		c.held.clear();
		std::memset(c.keys, 0, sizeof(c.keys));
	}
	for (auto &v : audio_voices_) v.active = false;
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------
void Engine::play(bool from_start) {
	double at = 0.0;
	{
		std::lock_guard<std::mutex> g(mutex);
		if (from_start) beat_ = (mode_ == MODE_PATTERN || !loop_on_) ? 0.0 : loop_a_;
		last_beat_ = -1.0;
		playing_ = true;
		at = beat_;
	}
	// Anything the playhead is standing in the middle of starts now.
	retrigger_at(at);
	{
		std::lock_guard<std::mutex> g(mutex);
		if (mode_ == MODE_SONG) start_audio_at(at);
	}
}

void Engine::stop() {
	std::lock_guard<std::mutex> g(mutex);
	playing_ = false;
	for (auto &c : channels_) {
		if (c.inst) c.inst->all_notes_off();
		c.held.clear();
		std::memset(c.keys, 0, sizeof(c.keys));
	}
	for (auto &v : audio_voices_) v.active = false;
}

// Switching between the pattern and the song while the transport runs swaps
// what is being played for something else entirely, so whatever the playhead
// now stands in starts here rather than on the next pass.
void Engine::set_mode(int m) {
	std::lock_guard<std::mutex> g(mutex);
	if (m == mode_) return;
	mode_ = m;
	resync_locked();
}

void Engine::set_pattern_loop(int p) {
	std::lock_guard<std::mutex> g(mutex);
	if (p == cur_pattern_) return;
	cur_pattern_ = p;
	if (mode_ == MODE_PATTERN) resync_locked();
}

void Engine::set_metronome_sound(int which, const std::vector<float> &frames, double rate,
		int channels) {
	if (which < 0 || which > 1) return;
	std::lock_guard<std::mutex> g(mutex);
	MetroSound &s = metro_snd_[which];
	s.channels = std::max(1, channels);
	s.rate = rate > 1.0 ? rate : 48000.0;
	s.data = frames;
	// Whatever was sounding came out of the old buffer, which has just gone.
	metro_voice_ = -1;
}

void Engine::set_position(double beat) {
	std::lock_guard<std::mutex> g(mutex);
	beat_ = std::max(0.0, beat);
	last_beat_ = -1.0;
	for (auto &c : channels_) {
		if (c.inst) c.inst->all_notes_off();
		c.held.clear();
		std::memset(c.keys, 0, sizeof(c.keys));
	}
	// Ramped out rather than cut: scrubbing across a busy arrangement used to
	// be a series of clicks, one per clip the playhead crossed.
	for (auto &v : audio_voices_) if (v.active) v.release();
	// Dropping the playhead into the middle of a note while the transport is
	// running plays that note, the same as pressing play there would -- and
	// the same for an audio clip.
	if (playing_) {
		retrigger_locked(beat_);
		if (mode_ == MODE_SONG) start_audio_at(beat_);
	}
}

// ---------------------------------------------------------------------------
// Plugins
// ---------------------------------------------------------------------------
int Engine::create_plugin(const std::string &id) {
	Plug *p = make_plug(id, sr, block);
	if (!p) return -1;
	std::lock_guard<std::mutex> g(mutex);
	const int h = next_handle_++;
	plugins_[h] = p;
	return h;
}

int Engine::create_vst3(const std::string &path, const std::string &cid) {
	// Loading happens outside the lock: a plugin can take a second to come up
	// and the audio thread must not wait for it.
	Vst3Plug *p = new Vst3Plug();
	if (!p->load(path, cid, sr, block)) {
		delete p;
		return -1;
	}
	std::lock_guard<std::mutex> g(mutex);
	const int h = next_handle_++;
	plugins_[h] = p;
	return h;
}

void Engine::destroy_plugin(int handle) {
	Plug *victim = nullptr;
	{
		std::lock_guard<std::mutex> g(mutex);
		auto it = plugins_.find(handle);
		if (it == plugins_.end()) return;
		victim = it->second;
		plugins_.erase(it);
		for (auto &c : channels_) if (c.handle == handle) { c.inst = nullptr; c.handle = -1; }
		for (auto &t : mixer_) {
			for (auto &s : t.inserts) if (s.handle == handle) { s.plug = nullptr; s.handle = -1; }
		}
	}
	delete victim;   // outside the lock; a VST3 teardown can block
}

Plug *Engine::plug(int handle) const {
	auto it = plugins_.find(handle);
	return it == plugins_.end() ? nullptr : it->second;
}

std::vector<int> Engine::plugin_handles() const {
	std::vector<int> out;
	out.reserve(plugins_.size());
	for (const auto &kv : plugins_) out.push_back(kv.first);
	return out;
}

const PlugDesc *Engine::plug_desc(int handle) const {
	Plug *p = plug(handle);
	return p ? p->desc : nullptr;
}

// ---------------------------------------------------------------------------
// Channels and mixer
// ---------------------------------------------------------------------------
int Engine::add_channel(const std::string &name) {
	std::lock_guard<std::mutex> g(mutex);
	Channel c;
	c.name = name;
	c.g_vol.prepare(sr, 12.0f);
	c.g_vol.snap(c.vol);
	c.L.assign((size_t)std::max(block, 1), 0.0f);
	c.R.assign(c.L.size(), 0.0f);
	channels_.push_back(c);
	// A channel added while the song runs takes the notes addressed to it now,
	// not when the playhead next comes round.
	resync_locked();
	return (int)channels_.size() - 1;
}

void Engine::remove_channel(int index) {
	std::lock_guard<std::mutex> g(mutex);
	if (index < 0 || index >= (int)channels_.size()) return;
	channels_.erase(channels_.begin() + index);
	// Notes address channels by index, so everything after shifts down.
	for (auto &p : patterns_) {
		for (auto it = p.notes.begin(); it != p.notes.end();) {
			if (it->channel == index) it = p.notes.erase(it);
			else { if (it->channel > index) it->channel--; ++it; }
		}
	}
	resync_locked();
}

void Engine::move_channel(int from, int to) {
	std::lock_guard<std::mutex> g(mutex);
	if (from < 0 || from >= (int)channels_.size() || to < 0 || to >= (int)channels_.size() || from == to) return;
	Channel c = channels_[(size_t)from];
	channels_.erase(channels_.begin() + from);
	channels_.insert(channels_.begin() + to, c);
	for (auto &p : patterns_) {
		for (auto &n : p.notes) {
			if (n.channel == from) n.channel = to;
			else if (from < to && n.channel > from && n.channel <= to) n.channel--;
			else if (from > to && n.channel >= to && n.channel < from) n.channel++;
		}
	}
	resync_locked();
}

void Engine::set_channel_instrument(int ch, int handle) {
	std::lock_guard<std::mutex> g(mutex);
	if (ch < 0 || ch >= (int)channels_.size()) return;
	Channel &c = channels_[(size_t)ch];
	if (c.inst) c.inst->all_notes_off();
	c.held.clear();
	c.handle = handle;
	c.inst = plug(handle);
	std::memset(c.keys, 0, sizeof(c.keys));
	// An instrument dropped onto a channel mid-bar picks up the note the
	// playhead is inside instead of waiting for the next one.
	resync_locked();
}

void Engine::set_channel(int ch, float vol, float pan, bool mute, bool solo, int mixer, int transpose) {
	std::lock_guard<std::mutex> g(mutex);
	if (ch < 0 || ch >= (int)channels_.size()) return;
	Channel &c = channels_[(size_t)ch];
	c.vol = vol; c.pan = pan; c.mute = mute; c.solo = solo;
	c.mixer = std::max(0, std::min((int)mixer_.size() - 1, mixer));
	c.transpose = transpose;
}

void Engine::set_channel_name(int ch, const std::string &n) {
	std::lock_guard<std::mutex> g(mutex);
	if (ch >= 0 && ch < (int)channels_.size()) channels_[(size_t)ch].name = n;
}

void Engine::set_channel_layers(int ch, const std::vector<Channel::Layer> &layers, bool layer_only) {
	std::lock_guard<std::mutex> g(mutex);
	if (ch < 0 || ch >= (int)channels_.size()) return;
	Channel &c = channels_[(size_t)ch];
	c.layers.clear();
	for (const Channel::Layer &l : layers) {
		// Only one level deep and never itself: a layer that pointed back would
		// multiply notes without bound on the audio thread.
		if (l.channel < 0 || l.channel >= (int)channels_.size() || l.channel == ch) continue;
		c.layers.push_back(l);
	}
	c.layer_only = layer_only && !c.layers.empty();
	resync_locked();
}

void Engine::set_mixer_count(int n) {
	std::lock_guard<std::mutex> g(mutex);
	// No ceiling worth speaking of: a track is a few buffers and a fader, and
	// how many a song wants is the song's business.
	n = std::max(1, std::min(4096, n));
	const size_t old = mixer_.size();
	mixer_.resize((size_t)n);
	for (size_t i = old; i < mixer_.size(); i++) {
		mixer_[i].name = "Insert " + std::to_string(i);
		mixer_[i].g_vol.prepare(sr, 12.0f);
		mixer_[i].g_pan.prepare(sr, 12.0f);
		mixer_[i].g_vol.snap(mixer_[i].vol);
		mixer_[i].g_pan.snap(mixer_[i].pan);
		mixer_[i].inserts.resize(8);
		mixer_[i].sends.resize(4);
	}
	if (!mixer_.empty()) {
		mixer_[0].name = "Master";
		if (mixer_[0].inserts.empty()) mixer_[0].inserts.resize(8);
		if (mixer_[0].sends.empty()) mixer_[0].sends.resize(4);
	}
	ensure_buffers(block);
	order_tracks();
}

void Engine::set_mixer(int t, float vol, float pan, bool mute, bool solo, int route) {
	std::lock_guard<std::mutex> g(mutex);
	if (t < 0 || t >= (int)mixer_.size()) return;
	MixerTrack &m = mixer_[(size_t)t];
	m.vol = vol; m.pan = pan; m.mute = mute; m.solo = solo;
	m.route = (t == 0) ? -1 : std::max(-1, std::min((int)mixer_.size() - 1, route));
	order_tracks();
}

void Engine::set_mixer_name(int t, const std::string &n) {
	std::lock_guard<std::mutex> g(mutex);
	if (t >= 0 && t < (int)mixer_.size()) mixer_[(size_t)t].name = n;
}

void Engine::set_send(int t, int i, int dest, float amount, bool pre, bool sidechain) {
	std::lock_guard<std::mutex> g(mutex);
	if (t < 0 || t >= (int)mixer_.size() || i < 0 || i > 4096) return;
	MixerTrack &mt = mixer_[(size_t)t];
	if (i >= (int)mt.sends.size()) mt.sends.resize((size_t)i + 1);
	Send &s = mt.sends[(size_t)i];
	s.dest = (dest >= 0 && dest < (int)mixer_.size() && dest != t) ? dest : -1;
	s.amount = amount;
	s.pre = pre;
	s.sidechain = sidechain;
	order_tracks();
}

void Engine::set_insert(int t, int slot, int handle) {
	std::lock_guard<std::mutex> g(mutex);
	if (t < 0 || t >= (int)mixer_.size()) return;
	MixerTrack &m = mixer_[(size_t)t];
	if (slot < 0 || slot >= (int)m.inserts.size()) return;
	m.inserts[(size_t)slot].handle = handle;
	m.inserts[(size_t)slot].plug = plug(handle);
	m.inserts[(size_t)slot].bypass = false;
	m.inserts[(size_t)slot].wet = 1.0f;
}

void Engine::set_insert_flags(int t, int slot, bool bypass, float wet) {
	std::lock_guard<std::mutex> g(mutex);
	if (t < 0 || t >= (int)mixer_.size()) return;
	MixerTrack &m = mixer_[(size_t)t];
	if (slot < 0 || slot >= (int)m.inserts.size()) return;
	m.inserts[(size_t)slot].bypass = bypass;
	m.inserts[(size_t)slot].wet = wet;
}

void Engine::move_insert(int t, int from, int to) {
	std::lock_guard<std::mutex> g(mutex);
	if (t < 0 || t >= (int)mixer_.size()) return;
	MixerTrack &m = mixer_[(size_t)t];
	if (from < 0 || to < 0 || from >= (int)m.inserts.size() || to >= (int)m.inserts.size()) return;
	Slot s = m.inserts[(size_t)from];
	m.inserts.erase(m.inserts.begin() + from);
	m.inserts.insert(m.inserts.begin() + to, s);
}

int Engine::insert_handle(int t, int slot) const {
	if (t < 0 || t >= (int)mixer_.size()) return -1;
	const MixerTrack &m = mixer_[(size_t)t];
	if (slot < 0 || slot >= (int)m.inserts.size()) return -1;
	return m.inserts[(size_t)slot].handle;
}

// Sources before destinations, master last; falls back to reverse index order
// if the routing has a cycle (which the UI refuses to create anyway).
void Engine::order_tracks() {
	const int n = (int)mixer_.size();
	std::vector<int> indeg((size_t)n, 0);
	std::vector<std::vector<int>> edges((size_t)n);
	auto add_edge = [&](int a, int b) {
		if (a < 0 || b < 0 || a >= n || b >= n || a == b) return;
		edges[(size_t)a].push_back(b);
		indeg[(size_t)b]++;
	};
	for (int i = 1; i < n; i++) {
		add_edge(i, mixer_[(size_t)i].route);
		for (const Send &sd : mixer_[(size_t)i].sends) {
			if (sd.dest >= 0 && sd.amount > 0.0f) add_edge(i, sd.dest);
		}
	}
	std::vector<int> out;
	std::vector<int> stack;
	for (int i = 1; i < n; i++) if (indeg[(size_t)i] == 0) stack.push_back(i);
	while (!stack.empty()) {
		const int t = stack.back();
		stack.pop_back();
		out.push_back(t);
		for (int e : edges[(size_t)t]) {
			if (--indeg[(size_t)e] == 0 && e != 0) stack.push_back(e);
		}
	}
	if ((int)out.size() != n - 1) {
		out.clear();
		for (int i = n - 1; i >= 1; i--) out.push_back(i);
	}
	out.push_back(0);
	order_ = out;
}

// ---------------------------------------------------------------------------
// Song data
// ---------------------------------------------------------------------------
void Engine::set_pattern(int id, const std::vector<Note> &notes, float length) {
	std::lock_guard<std::mutex> g(mutex);
	if (id < 0 || id > 4095) return;
	if ((int)patterns_.size() <= id) patterns_.resize((size_t)id + 1);
	Pattern &p = patterns_[(size_t)id];
	p.notes = notes;
	p.length = std::max(0.25f, length);
	std::sort(p.notes.begin(), p.notes.end(), [](const Note &a, const Note &b) { return a.beat < b.beat; });
	resync_locked();
}

void Engine::clear_pattern(int id) {
	std::lock_guard<std::mutex> g(mutex);
	if (id >= 0 && id < (int)patterns_.size()) patterns_[(size_t)id].notes.clear();
}

float Engine::pattern_length(int id) const {
	if (id < 0 || id >= (int)patterns_.size()) return 16.0f;
	return patterns_[(size_t)id].length;
}

void Engine::set_playlist(const std::vector<Clip> &clips) {
	std::lock_guard<std::mutex> g(mutex);
	// A voice points at a clip by index, and the indices are about to mean
	// something else. Anything still sounding is asked to stop: deleting a
	// sample while it played used to leave it playing to the end, because the
	// clip it came from was gone but the voice reading the file was not.
	for (auto &v : audio_voices_) {
		if (!v.active || v.clip < 0) continue;
		const bool same = (size_t)v.clip < clips.size() &&
				clips[(size_t)v.clip].type == CLIP_AUDIO &&
				clips[(size_t)v.clip].index == v.asset &&
				clips[(size_t)v.clip].track == v.track &&
				!clips[(size_t)v.clip].mute;
		if (!same) v.release();
	}
	clips_ = clips;
	std::sort(clips_.begin(), clips_.end(), [](const Clip &a, const Clip &b) { return a.start < b.start; });
	// The sort moved them, so the voices are re-pointed at where their clip
	// went rather than being left pointing at a stranger.
	for (auto &v : audio_voices_) {
		if (!v.active || v.clip < 0 || v.fading()) continue;
		v.clip = -1;
		for (size_t i = 0; i < clips_.size(); i++) {
			if (clips_[i].type == CLIP_AUDIO && clips_[i].index == v.asset && clips_[i].track == v.track) {
				v.clip = (int)i;
				break;
			}
		}
	}
	resync_locked();
}

void Engine::set_automation(int id, int target, int a, int b, const std::vector<AutoPoint> &points,
		int mode, bool on, float base) {
	AutoLink one;
	one.target = target;
	one.a = a;
	one.b = b;
	one.base = base;
	set_automation_links(id, {one}, points, mode, on);
}

void Engine::set_automation_links(int id, const std::vector<AutoLink> &links,
		const std::vector<AutoPoint> &points, int mode, bool on) {
	std::lock_guard<std::mutex> g(mutex);
	if (id < 0 || id > 4095) return;
	if ((int)autos_.size() <= id) autos_.resize((size_t)id + 1);
	Automation &au = autos_[(size_t)id];
	au.links = links;
	au.mode = mode;
	au.on = on;
	au.points = points;
	std::sort(au.points.begin(), au.points.end(), [](const AutoPoint &x, const AutoPoint &y) { return x.beat < y.beat; });
}

void Engine::clear_automation() {
	std::lock_guard<std::mutex> g(mutex);
	autos_.clear();
}

// ---------------------------------------------------------------------------
// Samples
// ---------------------------------------------------------------------------
/// The played copy of one of the project's samples.
void Engine::bake_asset(int index) {
	if (index < 0 || index >= (int)assets_.size()) return;
	AudioAsset &a = assets_[(size_t)index];
	if (!a.file) return;
	auto out = std::make_shared<AudioFile>();
	bake_sample(*a.file, a.set, *out);
	build_peaks(*out);
	a.baked = out;
}


/// Called with the lock already held, from automation and from the setter.
void Engine::set_sample_live_locked(int index, float pitch_semis, float speed) {
	if (index < 0 || index >= (int)assets_.size()) return;
	AudioAsset &a = assets_[(size_t)index];
	a.live_pitch = pitch_semis;
	a.live_speed = std::max(0.02f, speed);
	const double mul = std::pow(2.0, (double)a.live_pitch / 12.0) * (double)a.live_speed;
	for (auto &v : audio_voices_) {
		if (v.active && v.asset == index) v.inc = v.base_inc * mul;
	}
}

void Engine::set_sample_live(int index, float pitch_semis, float speed) {
	std::lock_guard<std::mutex> g(mutex);
	set_sample_live_locked(index, pitch_semis, speed);
}

int Engine::voice_track(int wanted, int clip_index) const {
	if (wanted >= 0) return wanted;
	if (clip_index >= 0 && clip_index < (int)clips_.size()) return clips_[(size_t)clip_index].track;
	return 0;
}

void Engine::set_sample_settings(int index, const SampleSettings &s) {
	std::lock_guard<std::mutex> g(mutex);
	if (index < 0 || index >= (int)assets_.size()) return;
	AudioAsset &a = assets_[(size_t)index];
	// Which mixer track it goes through is settled on its own, before anything
	// else: it changes where the sound goes rather than what the sound is, so
	// it must never cost a re-bake, and what is already sounding moves across
	// as it is changed rather than at the next note.
	if (a.set.mixer != s.mixer) {
		a.set.mixer = s.mixer;
		for (auto &v : audio_voices_) {
			if (v.active && v.asset == index) v.track = voice_track(s.mixer, v.clip);
		}
	}
	if (a.set == s && a.baked) return;
	// What is playing keeps playing. Turning a knob used to stop every voice
	// reading this sample, so hearing what a change did meant stopping the song
	// and starting it again. Each voice is remembered as how far through the
	// sample it had got, and put back at the same point of the new one -- so a
	// sample stretched to twice the length carries on from the same place in it
	// rather than jumping or going quiet.
	struct Where { size_t voice; double frac; };
	const AudioFile *before = a.baked ? a.baked.get() : a.file.get();
	const double before_frames = before ? (double)before->frames() : 0.0;
	const int before_rate = before ? before->rate : 0;
	std::vector<Where> playing;
	for (size_t i = 0; i < audio_voices_.size(); i++) {
		const AudioVoice &v = audio_voices_[i];
		if (v.active && v.asset == index && before_frames > 0.0) {
			playing.push_back({i, v.pos / before_frames});
		}
	}

	a.set = s;
	bake_asset(index);

	const AudioFile *now = a.baked ? a.baked.get() : a.file.get();
	const double now_frames = now ? (double)now->frames() : 0.0;
	for (const Where &w : playing) {
		AudioVoice &v = audio_voices_[w.voice];
		if (now_frames <= 0.0) { v.active = false; continue; }
		v.pos = w.frac * now_frames;
		if (before_rate > 0 && now->rate > 0 && now->rate != before_rate) {
			const double r = (double)now->rate / (double)before_rate;
			v.inc *= r;
			v.base_inc *= r;
		}
		// Level and position follow at once as well, which is the whole point
		// of turning those two knobs while the song is playing.
		const double clip_gain = (v.clip >= 0 && v.clip < (int)clips_.size())
				? (double)clips_[(size_t)v.clip].gain : 1.0;
		v.gain = (float)(clip_gain * (double)a.set.gain);
		v.pan = a.set.pan;
	}
}


int Engine::register_audio(const std::string &path) {
	auto f = std::make_shared<AudioFile>();
	if (!wav_load(path, *f)) return -1;
	std::lock_guard<std::mutex> g(mutex);
	for (size_t i = 0; i < assets_.size(); i++) {
		if (assets_[i].path == path) {
			assets_[i].file = f;
			bake_asset((int)i);
			return (int)i;
		}
	}
	AudioAsset a;
	a.path = path;
	a.file = f;
	assets_.push_back(a);
	bake_asset((int)assets_.size() - 1);
	return (int)assets_.size() - 1;
}

void Engine::set_audio(int index, const std::string &path) {
	if (index < 0 || index > 4095) return;
	{
		// Already what it should be: nothing to do, and nothing to re-decode.
		std::lock_guard<std::mutex> g(mutex);
		if (index < (int)assets_.size() && assets_[(size_t)index].path == path
				&& (assets_[(size_t)index].file || path.empty())) {
			return;
		}
	}
	// Reading the file happens outside the lock; a long one takes a while and
	// the audio thread must not wait for it.
	std::shared_ptr<AudioFile> f;
	if (!path.empty()) {
		auto loaded = std::make_shared<AudioFile>();
		if (wav_load(path, *loaded)) f = loaded;
	}
	std::lock_guard<std::mutex> g(mutex);
	if ((int)assets_.size() <= index) assets_.resize((size_t)index + 1);
	AudioAsset &a = assets_[(size_t)index];
	// Anything sounding out of this slot is reading a file that is about to be
	// replaced. Let it go rather than leave it pointing at freed audio.
	for (auto &v : audio_voices_) {
		if (v.active && v.asset == index) v.active = false;
	}
	a.path = path;
	a.file = f;
	a.baked.reset();
	// No file means a slot that holds its number and makes no sound; everything
	// that plays a sample already checks for one.
	if (f) bake_asset(index);
}

void Engine::forget_audio() {
	std::lock_guard<std::mutex> g(mutex);
	assets_.clear();
	for (auto &v : audio_voices_) v.active = false;
}

double Engine::song_length() const {
	double end = 0.0;
	for (const Clip &c : clips_) end = std::max(end, c.start + c.length);
	return end;
}

// ---------------------------------------------------------------------------
// Live audio input
// ---------------------------------------------------------------------------
/// Interface thread. Only the write cursor is touched, so a full ring drops
/// what has just arrived rather than reaching into what the audio thread is
/// reading.
void Engine::push_input(const float *l, const float *r, int n) {
	if (n <= 0 || !l || !r) return;
	const uint64_t rd = in_rd_.load(std::memory_order_acquire);
	uint64_t w = in_w_.load(std::memory_order_relaxed);
	for (int i = 0; i < n; i++) {
		if (w - rd >= kInRing) break;
		const size_t k = (size_t)(w & (kInRing - 1));
		in_l_[k] = l[i];
		in_r_[k] = r[i];
		w++;
	}
	in_w_.store(w, std::memory_order_release);
}

void Engine::set_input(int track, float gain) {
	in_gain_.store(gain, std::memory_order_relaxed);
	const int was = in_track_.exchange(track, std::memory_order_relaxed);
	// Switching the input on starts from whatever arrives next rather than
	// from a ring full of the last time it was on.
	if (was < 0 && track >= 0) {
		in_rd_.store(in_w_.load(std::memory_order_acquire), std::memory_order_release);
		in_primed_ = false;
	}
}

void Engine::arm_record(bool on) {
	if (on == rec_on_.load(std::memory_order_relaxed)) return;
	if (on) {
		rec_rd_.store(rec_w_.load(std::memory_order_acquire), std::memory_order_release);
		rec_mark_.store(true, std::memory_order_relaxed);
	}
	rec_on_.store(on, std::memory_order_release);
}

/// Audio thread. A block of the machine's input into the track that is
/// listening for it, and into the take's ring if one is being recorded.
void Engine::pull_input(int frames) {
	const int track = in_track_.load(std::memory_order_relaxed);
	const bool rec = rec_on_.load(std::memory_order_relaxed);
	if (offline_ || (track < 0 && !rec)) {
		in_peak_ *= 0.8f;
		return;
	}
	const uint64_t w = in_w_.load(std::memory_order_acquire);
	uint64_t rd = in_rd_.load(std::memory_order_relaxed);
	uint64_t avail = w > rd ? w - rd : 0;
	// A little is held back before anything is read at all. The interface
	// thread fills this in bursts and the audio thread empties it steadily, so
	// reading the instant the first frame lands means a gap every few blocks.
	if (!in_primed_) {
		if (avail < kInPrime) return;
		in_primed_ = true;
	}
	// Once it is running it keeps running, short or not. An empty ring is a
	// block of silence, never a block that is skipped: skipping one stops the
	// take as well, and a take with the quiet parts missing does not line up
	// with anything.
	if (avail > kInMax) {
		rd += avail - kInMax;
		avail = kInMax;
	}
	if (rec && rec_mark_.exchange(false, std::memory_order_relaxed)) {
		rec_beat_.store(beat_, std::memory_order_relaxed);
	}
	const float g = in_gain_.load(std::memory_order_relaxed);
	MixerTrack *t = (track >= 0 && track < (int)mixer_.size()) ? &mixer_[(size_t)track] : nullptr;
	uint64_t rw = rec_w_.load(std::memory_order_relaxed);
	// How far the interface thread has drained to. Read once: it only ever
	// moves forward, so a stale answer holds a frame back rather than letting
	// one be written over something not yet taken.
	const uint64_t rrd = rec_rd_.load(std::memory_order_acquire);
	float peak = 0.0f;
	for (int i = 0; i < frames; i++) {
		float l = 0.0f, r = 0.0f;
		if (avail > 0) {
			const size_t k = (size_t)(rd & (kInRing - 1));
			l = in_l_[k];
			r = in_r_[k];
			rd++;
			avail--;
		}
		peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
		if (t) {
			t->L[(size_t)i] += l * g;
			t->R[(size_t)i] += r * g;
		}
		// The take is the input as it came in: what the strip does to it is
		// the mix's business, not the recording's.
		if (rec && rw + 2 - rrd <= kRecRing) {
			rec_ring_[(size_t)(rw & (kRecRing - 1))] = l;
			rec_ring_[(size_t)((rw + 1) & (kRecRing - 1))] = r;
			rw += 2;
		}
	}
	if (rec) rec_w_.store(rw, std::memory_order_release);
	in_rd_.store(rd, std::memory_order_release);
	in_peak_ = std::max(peak, in_peak_ * 0.8f);
}

/// Interface thread. What the audio thread has put in the ring, onto the end
/// of the take.
int Engine::pump_take() {
	const uint64_t w = rec_w_.load(std::memory_order_acquire);
	uint64_t rd = rec_rd_.load(std::memory_order_relaxed);
	if (w <= rd) return 0;
	const uint64_t have = w - rd;
	if (take_.size() + (size_t)have > kTakeMax) return 0;
	const int frames = (int)(have / 2);
	for (uint64_t i = 0; i < have; i++) {
		take_.push_back(rec_ring_[(size_t)((rd + i) & (kRecRing - 1))]);
	}
	rec_rd_.store(w, std::memory_order_release);
	return frames;
}

double Engine::take_seconds() const {
	return sr > 0.0 ? (double)(take_.size() / 2) / sr : 0.0;
}

bool Engine::write_take(const std::string &path, int bits) {
	if (take_.size() < 2) return false;
	return wav_save(path, take_.data(), (int)(take_.size() / 2), 2, (int)sr, bits);
}

void Engine::clear_take() {
	take_.clear();
	take_.shrink_to_fit();
}

// ---------------------------------------------------------------------------
// Live note input
// ---------------------------------------------------------------------------
void Engine::note_on(int channel, int key, float vel) {
	std::lock_guard<std::mutex> g(mutex);
	if (channel < 0 || channel >= (int)channels_.size()) return;
	auto one = [&](int ci, int semis, float gain) {
		Channel &c = channels_[(size_t)ci];
		const int k = (int)clampf((float)(key + semis + c.transpose), 0, 127);
		if (c.inst) c.inst->note_on(k, clampf(vel * gain, 0.0f, 2.0f), -2);
		c.keys[k] = (unsigned char)std::min(200, c.keys[k] + 1);
	};
	const Channel &src = channels_[(size_t)channel];
	if (!src.layer_only) one(channel, 0, 1.0f);
	for (const Channel::Layer &l : src.layers) one(l.channel, l.transpose, l.gain);
}

void Engine::note_off(int channel, int key) {
	std::lock_guard<std::mutex> g(mutex);
	if (channel < 0 || channel >= (int)channels_.size()) return;
	auto one = [&](int ci, int semis) {
		Channel &c = channels_[(size_t)ci];
		const int k = (int)clampf((float)(key + semis + c.transpose), 0, 127);
		if (c.inst) c.inst->note_off(k, -2);
		if (c.keys[k] > 0) c.keys[k]--;
	};
	const Channel &src = channels_[(size_t)channel];
	if (!src.layer_only) one(channel, 0);
	for (const Channel::Layer &l : src.layers) one(l.channel, l.transpose);
}

void Engine::all_notes_off() { panic(); }

void Engine::stop_channel(int channel) {
	std::lock_guard<std::mutex> g(mutex);
	if (channel < 0 || channel >= (int)channels_.size()) return;
	Channel &c = channels_[(size_t)channel];
	if (c.inst) c.inst->all_notes_off();
	c.held.clear();
	std::memset(c.keys, 0, sizeof(c.keys));
}

/// Notes that started before `beat` and have not finished yet, begun now with
/// whatever is left of them. Without this, dropping the playhead into the
/// middle of a long note gives silence until the next note starts.
void Engine::retrigger_at(double beat) {
	std::lock_guard<std::mutex> g(mutex);
	retrigger_locked(beat);
}

void Engine::retrigger_locked(double beat) {
	auto play_from = [&](const Note &n, double note_start, double clip_end) {
		const double end = note_start + std::max(0.02f, n.length);
		if (note_start >= beat || end <= beat + 1e-6) return;
		if (clip_end > 0.0 && beat >= clip_end) return;
		if (n.channel < 0 || n.channel >= (int)channels_.size()) return;
		Channel &src = channels_[(size_t)n.channel];
		auto one = [&](int ci, int semis, float gain) {
			if (ci < 0 || ci >= (int)channels_.size()) return;
			Channel &c = channels_[(size_t)ci];
			const int k = (int)clampf((float)(n.key + semis + c.transpose), 0.0f, 127.0f);
			const int id = next_note_id_++;
			if (c.inst) {
				c.inst->next_pan = n.pan;
				c.inst->next_fine = n.fine;
				c.inst->note_on(k, clampf(n.vel * gain, 0.0f, 2.0f), id);
				c.inst->next_pan = 0.0f;
				c.inst->next_fine = 0.0f;
			}
			c.keys[k] = (unsigned char)std::min(200, c.keys[k] + 1);
			Channel::Held h;
			h.key = k;
			h.id = id;
			h.off_beat = clip_end > 0.0 ? std::min(end, clip_end) : end;
			c.held.push_back(h);
		};
		if (!src.layer_only) one(n.channel, 0, 1.0f);
		for (const Channel::Layer &l : src.layers) one(l.channel, l.transpose, l.gain);
	};

	if (mode_ == MODE_PATTERN) {
		if (cur_pattern_ < 0 || cur_pattern_ >= (int)patterns_.size()) return;
		const Pattern &p = patterns_[(size_t)cur_pattern_];
		const double len = std::max(0.25f, p.length);
		const double local = beat - std::floor(beat / len) * len;
		const double base = beat - local;
		for (const Note &n : p.notes) play_from(n, base + n.beat, 0.0);
		return;
	}
	for (const Clip &c : clips_) {
		if (c.mute || c.type != CLIP_PATTERN) continue;
		if (beat < c.start || beat >= c.start + c.length) continue;
		if (c.index < 0 || c.index >= (int)patterns_.size()) continue;
		const Pattern &p = patterns_[(size_t)c.index];
		const double len = std::max(0.25f, p.length);
		const double local = beat - c.start + c.offset;
		const double base = c.start - c.offset + std::floor(local / len) * len;
		for (const Note &n : p.notes) play_from(n, base + n.beat, c.start + c.length);
	}
}

/// Everything the song says should be sounding at the playhead, started if it
/// is not sounding already. This is what makes an edit made while the transport
/// runs audible now rather than on the next pass: a pattern clip dropped over
/// the playhead, a note drawn into the bar that is playing, a sample dragged
/// onto the arrangement under the marker.
///
/// It only ever adds. A note the sequencer is already holding keeps the voice
/// it has, so dragging a clip about does not retrigger what is already playing,
/// and a key held down on the keyboard is left alone: live notes are not the
/// sequencer's to stop.
void Engine::resync_locked() {
	if (!playing_) return;
	const double beat = beat_;

	struct Want {
		int channel;
		int key;
		double off_beat;
		float vel;
		float pan;
		float fine;
	};
	std::vector<Want> want;
	auto gather = [&](const Note &n, double note_start, double clip_end) {
		const double end = note_start + std::max(0.02f, n.length);
		if (note_start >= beat || end <= beat + 1e-6) return;
		if (clip_end > 0.0 && beat >= clip_end) return;
		if (n.channel < 0 || n.channel >= (int)channels_.size()) return;
		const Channel &src = channels_[(size_t)n.channel];
		const double off = clip_end > 0.0 ? std::min(end, clip_end) : end;
		auto one = [&](int ci, int semis, float gain) {
			if (ci < 0 || ci >= (int)channels_.size()) return;
			Want w;
			w.channel = ci;
			w.key = (int)clampf((float)(n.key + semis + channels_[(size_t)ci].transpose), 0.0f, 127.0f);
			w.off_beat = off;
			w.vel = clampf(n.vel * gain, 0.0f, 2.0f);
			w.pan = n.pan;
			w.fine = n.fine;
			want.push_back(w);
		};
		if (!src.layer_only) one(n.channel, 0, 1.0f);
		for (const Channel::Layer &l : src.layers) one(l.channel, l.transpose, l.gain);
	};

	if (mode_ == MODE_PATTERN) {
		if (cur_pattern_ >= 0 && cur_pattern_ < (int)patterns_.size()) {
			const Pattern &p = patterns_[(size_t)cur_pattern_];
			const double len = std::max(0.25f, p.length);
			const double base = std::floor(beat / len) * len;
			for (const Note &n : p.notes) gather(n, base + n.beat, 0.0);
		}
	} else {
		for (const Clip &c : clips_) {
			if (c.mute || c.type != CLIP_PATTERN) continue;
			if (beat < c.start || beat >= c.start + c.length) continue;
			if (c.index < 0 || c.index >= (int)patterns_.size()) continue;
			const Pattern &p = patterns_[(size_t)c.index];
			const double len = std::max(0.25f, p.length);
			const double local = beat - c.start + c.offset;
			const double base = c.start - c.offset + std::floor(local / len) * len;
			for (const Note &n : p.notes) gather(n, base + n.beat, c.start + c.length);
		}
	}

	for (const Want &w : want) {
		Channel &c = channels_[(size_t)w.channel];
		// Already holding that key here: whatever is holding it, a second voice
		// on top of it would be a doubling, not a fix.
		bool sounding = false;
		for (const Channel::Held &h : c.held) {
			if (h.key == w.key) { sounding = true; break; }
		}
		if (sounding || c.keys[w.key] > 0) continue;
		const int id = next_note_id_++;
		if (c.inst) {
			c.inst->next_pan = w.pan;
			c.inst->next_fine = w.fine;
			c.inst->note_on(w.key, w.vel, id);
			c.inst->next_pan = 0.0f;
			c.inst->next_fine = 0.0f;
		}
		c.keys[w.key] = (unsigned char)std::min(200, c.keys[w.key] + 1);
		Channel::Held h;
		h.key = w.key;
		h.id = id;
		h.off_beat = w.off_beat;
		c.held.push_back(h);
	}

	// And the audio clips the playhead is standing in. Matched by the sample
	// rather than by the clip so that moving a clip about, which takes its
	// voice away and gives it a new number, does not start a second copy of it
	// on every mouse move.
	if (mode_ == MODE_SONG) {
		for (size_t ci = 0; ci < clips_.size(); ci++) {
			const Clip &c = clips_[ci];
			if (c.type != CLIP_AUDIO || c.mute) continue;
			if (beat <= c.start || beat >= c.start + c.length) continue;
			bool sounding = false;
			for (const auto &v : audio_voices_) {
				if (v.active && !v.fading() && v.asset == c.index) { sounding = true; break; }
			}
			if (!sounding) start_audio_clip(ci, beat - c.start);
		}
	}
}

int Engine::voices() const {
	int n = 0;
	for (const auto &c : channels_) if (c.inst) n += c.inst->active_voices();
	return n;
}

void Engine::meters(std::vector<float> &out) const {
	out.resize(mixer_.size() * 4);
	for (size_t i = 0; i < mixer_.size(); i++) {
		out[i * 4 + 0] = mixer_[i].peak_l;
		out[i * 4 + 1] = mixer_[i].peak_r;
		out[i * 4 + 2] = mixer_[i].rms_l;
		out[i * 4 + 3] = mixer_[i].rms_r;
	}
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------
void Engine::collect_events(double b0, double b1, int frames, std::vector<Event> &out) {
	const double span = std::max(1e-12, b1 - b0);
	auto emit_one = [&](const Note &n, double at_beat, int channel, int extra_semis, float gain) {
		if (channel < 0 || channel >= (int)channels_.size()) return;
		Event e;
		e.frame = (int)clampf((float)((at_beat - b0) / span * frames), 0.0f, (float)(frames - 1));
		e.type = 0;
		e.channel = channel;
		e.key = (int)clampf((float)(n.key + extra_semis + channels_[(size_t)channel].transpose), 0.0f, 127.0f);
		e.vel = clampf(n.vel * gain, 0.0f, 2.0f);
		e.pan = n.pan;
		e.fine = n.fine;
		e.id = next_note_id_++;
		out.push_back(e);
		Channel::Held h;
		h.key = e.key;
		h.id = e.id;
		h.off_beat = at_beat + std::max(0.02f, n.length);
		channels_[(size_t)channel].held.push_back(h);
	};
	auto push_note = [&](const Note &n, double at_beat, int channel) {
		if (channel < 0 || channel >= (int)channels_.size()) return;
		const Channel &src = channels_[(size_t)channel];
		if (!src.layer_only) emit_one(n, at_beat, channel, 0, 1.0f);
		for (const Channel::Layer &l : src.layers) {
			emit_one(n, at_beat, l.channel, l.transpose, l.gain);
		}
	};

	if (mode_ == MODE_PATTERN) {
		if (cur_pattern_ >= 0 && cur_pattern_ < (int)patterns_.size()) {
			const Pattern &p = patterns_[(size_t)cur_pattern_];
			// The pattern repeats forever, so search it modulo its length.
			const double len = std::max(0.25f, p.length);
			for (const Note &n : p.notes) {
				// Every repetition of this note that lands inside the window.
				double k = std::floor(b0 / len);
				for (int rep = 0; rep < 3; rep++) {
					const double at = (k + rep) * len + n.beat;
					if (at >= b0 && at < b1) push_note(n, at, n.channel);
				}
			}
		}
	} else {
		for (const Clip &c : clips_) {
			if (c.mute || c.type != CLIP_PATTERN) continue;
			if (c.start >= b1 || c.start + c.length <= b0) continue;
			if (c.index < 0 || c.index >= (int)patterns_.size()) continue;
			const Pattern &p = patterns_[(size_t)c.index];
			const double len = std::max(0.25f, p.length);
			// Clips longer than the pattern repeat it.
			const double local0 = b0 - c.start + c.offset;
			const double local1 = b1 - c.start + c.offset;
			for (const Note &n : p.notes) {
				double k = std::floor(local0 / len);
				for (int rep = 0; rep < 3; rep++) {
					const double at_local = (k + rep) * len + n.beat;
					const double at = at_local + c.start - c.offset;
					if (at < c.start || at >= c.start + c.length) continue;
					if (at >= b0 && at < b1) push_note(n, at, n.channel);
				}
			}
		}
	}

	// Note-offs for anything whose length ran out in this window.
	for (int ci = 0; ci < (int)channels_.size(); ci++) {
		Channel &c = channels_[(size_t)ci];
		for (auto it = c.held.begin(); it != c.held.end();) {
			if (it->off_beat < b1) {
				Event e;
				e.frame = (int)clampf((float)((it->off_beat - b0) / span * frames), 0.0f, (float)(frames - 1));
				e.type = 1;
				e.channel = ci;
				e.key = it->key;
				e.vel = 0.0f;
				e.id = it->id;
				out.push_back(e);
				it = c.held.erase(it);
			} else {
				++it;
			}
		}
	}
	// Ends before beginnings when they land on the same sample. Two notes that
	// touch -- what quick legato leaves everywhere -- put the first one's end
	// and the second one's start at the same instant, and a plugin that goes by
	// pitch rather than by note id would hear the start and then be told to
	// stop that very note. Sorting the ends first is what makes the second note
	// play instead of stopping dead.
	std::sort(out.begin(), out.end(), [](const Event &a, const Event &b) {
		if (a.frame != b.frame) return a.frame < b.frame;
		return a.type > b.type;
	});
}

/// Starts one audio clip, `into` beats in. Zero for a clip the playhead has
/// just reached; more when the playhead landed in the middle of one.
void Engine::start_audio_clip(size_t ci, double into) {
	const Clip &c = clips_[ci];
	if (c.index < 0 || c.index >= (int)assets_.size() || !assets_[(size_t)c.index].file) return;
	// The same clip triggered again replaces itself. Round a loop the playhead
	// restarts every clip inside it, and without this the second pass played
	// on top of the first, the third on top of both, until it was a mess.
	for (auto &v : audio_voices_) {
		if (v.active && v.clip == (int)ci && !v.fading()) v.release();
	}
	AudioVoice *slot = nullptr;
	for (auto &v : audio_voices_) if (!v.active) { slot = &v; break; }
	if (!slot) {
		audio_voices_.push_back(AudioVoice());
		slot = &audio_voices_.back();
	}
	const AudioAsset &as = assets_[(size_t)c.index];
	const AudioFile &f = as.baked ? *as.baked : *as.file;
	slot->active = true;
	slot->clip = (int)ci;
	slot->asset = c.index;
	slot->track = voice_track(as.set.mixer, (int)ci);
	slot->gain = c.gain * as.set.gain;
	slot->pan = as.set.pan;
	// The clip's own pitch on top of whatever the sample is set to, unless the
	// sample is being stretched, in which case its speed is already decided.
	slot->base_inc = std::pow(2.0, c.pitch / 12.0) * (double)f.rate / sr;
	slot->inc = slot->base_inc * std::pow(2.0, (double)as.live_pitch / 12.0)
			* std::max(0.02, (double)as.live_speed);
	// Where in the file to start, in source frames, and how far into the clip
	// the playhead already is, in output frames. The two are only the same
	// number when the sample is played at its own rate: read it twice as fast
	// and half a clip's worth of arrangement is a whole clip's worth of file.
	const double into_out = std::max(0.0, into) * 60.0 / bpm_ * sr;
	slot->pos = c.offset * 60.0 / bpm_ * (double)f.rate + into_out * slot->inc;
	// And how long it has left to sound for, which is the rest of the clip.
	slot->left = std::max(0.0, (double)c.length - std::max(0.0, into)) * 60.0 / bpm_ * sr;
	slot->fade = 0.0;
}

/// Every audio clip the playhead is standing in the middle of, started from
/// where it has got to. Pressing play half way through a vocal take should
/// play the rest of the take, not silence until the next clip.
void Engine::start_audio_at(double beat) {
	for (auto &v : audio_voices_) if (v.active) v.release();
	for (size_t ci = 0; ci < clips_.size(); ci++) {
		const Clip &c = clips_[ci];
		if (c.type != CLIP_AUDIO || c.mute) continue;
		if (beat <= c.start || beat >= c.start + c.length) continue;
		start_audio_clip(ci, beat - c.start);
	}
}

void Engine::start_audio_clips(double b0, double b1) {
	for (size_t ci = 0; ci < clips_.size(); ci++) {
		const Clip &c = clips_[ci];
		if (c.type != CLIP_AUDIO || c.mute) continue;
		if (c.start < b0 || c.start >= b1) continue;
		start_audio_clip(ci, 0.0);
	}
}

/// One control moved to `v`, whatever kind of control it is.
void Engine::apply_link(const AutoLink &link, float v) {
	const AutoLink &au = link;
	switch (au.target) {
		case AT_PLUGIN: {
			Plug *p = plug(au.a);
			if (p && au.b >= 0 && au.b < (int)p->pv.size()) p->set_param(au.b, v);
		} break;
		case AT_MIXER_VOL:
			if (au.a >= 0 && au.a < (int)mixer_.size()) mixer_[(size_t)au.a].vol = v;
			break;
		case AT_MIXER_PAN:
			if (au.a >= 0 && au.a < (int)mixer_.size()) mixer_[(size_t)au.a].pan = v;
			break;
		case AT_CHANNEL_VOL:
			if (au.a >= 0 && au.a < (int)channels_.size()) channels_[(size_t)au.a].vol = v;
			break;
		case AT_CHANNEL_PAN:
			if (au.a >= 0 && au.a < (int)channels_.size()) channels_[(size_t)au.a].pan = v;
			break;
		case AT_TEMPO:
			bpm_ = clampf(v, 20.0f, 400.0f);
			break;
		case AT_SEND:
			if (au.a >= 0 && au.a < (int)mixer_.size() && au.b >= 0 && au.b < 4)
			if (au.b >= 0 && au.b < (int)mixer_[(size_t)au.a].sends.size()) {
				mixer_[(size_t)au.a].sends[(size_t)au.b].amount = v;
			}
			break;
		// A sample's own level and position, heard by whatever is playing
		// it right now: the setting is moved and so is every voice reading
		// it, or the automation would only be heard by the next clip.
		case AT_SAMPLE_PITCH:
			if (au.a >= 0 && au.a < (int)assets_.size()) {
			set_sample_live_locked(au.a, v, assets_[(size_t)au.a].live_speed);
			}
			break;
		case AT_SAMPLE_SPEED:
			if (au.a >= 0 && au.a < (int)assets_.size()) {
			set_sample_live_locked(au.a, assets_[(size_t)au.a].live_pitch, v);
			}
			break;
		case AT_SAMPLE_VOL:
		case AT_SAMPLE_PAN:
			if (au.a >= 0 && au.a < (int)assets_.size()) {
			AudioAsset &as = assets_[(size_t)au.a];
			if (au.target == AT_SAMPLE_VOL) as.set.gain = v;
			else as.set.pan = v;
			for (auto &voice : audio_voices_) {
				if (!voice.active || voice.asset != au.a) continue;
				if (au.target == AT_SAMPLE_PAN) {
					voice.pan = as.set.pan;
					continue;
				}
				const double clip_gain = (voice.clip >= 0 && voice.clip < (int)clips_.size())
						? (double)clips_[(size_t)voice.clip].gain : 1.0;
				voice.gain = (float)(clip_gain * (double)as.set.gain);
			}
			}
			break;
		default: break;
		}
}

void Engine::apply_automation(double beat) {
	for (const Clip &c : clips_) {
		if (c.type != CLIP_AUTOMATION || c.mute) continue;
		if (beat < c.start || beat >= c.start + c.length) continue;
		if (c.index < 0 || c.index >= (int)autos_.size()) continue;
		const Automation &au = autos_[(size_t)c.index];
		if (au.points.empty() || !au.on) continue;
		const float curve = au.value_at(beat - c.start + c.offset);
		// Forced holds each control at the curve; additive adds the curve to
		// what that control was set to by hand -- which is its own number, so
		// one shape can ride on top of three different settings.
		for (const AutoLink &link : au.links) {
			apply_link(link, au.mode == AM_ADDITIVE ? curve + link.base : curve);
		}
	}
}

// ---------------------------------------------------------------------------
// Mixing
// ---------------------------------------------------------------------------
void Engine::mix_tracks(int frames, float *outL, float *outR) {
	bool any_solo = false;
	for (const auto &t : mixer_) if (t.solo) { any_solo = true; break; }

	for (int idx : order_) {
		if (idx < 0 || idx >= (int)mixer_.size()) continue;
		MixerTrack &t = mixer_[(size_t)idx];
		float *L = t.L.data(), *R = t.R.data();

		for (auto &s : t.inserts) {
			if (!s.plug || s.bypass) continue;
			if (s.plug->wants_sidechain() && t.has_sc) s.plug->sidechain(t.scL.data(), t.scR.data(), frames);
			s.plug->bpm = bpm_;
			s.plug->song_beat = beat_;
			s.plug->playing = playing_;
			if (s.wet >= 0.999f) {
				s.plug->process(L, R, frames);
				s.plug->capture(L, R, frames);
			} else {
				std::memcpy(tmpL_.data(), L, sizeof(float) * (size_t)frames);
				std::memcpy(tmpR_.data(), R, sizeof(float) * (size_t)frames);
				s.plug->process(tmpL_.data(), tmpR_.data(), frames);
				s.plug->capture(tmpL_.data(), tmpR_.data(), frames);
				for (int i = 0; i < frames; i++) {
					L[i] = lerp(L[i], tmpL_[(size_t)i], s.wet);
					R[i] = lerp(R[i], tmpR_[(size_t)i], s.wet);
				}
			}
		}

		const bool audible = !t.mute && (!any_solo || t.solo || idx == 0);
		float peak_l = 0.0f, peak_r = 0.0f, sum_l = 0.0f, sum_r = 0.0f;

		// Pre-fader sends.
		for (const Send &s : t.sends) {
			if (s.dest < 0 || s.dest >= (int)mixer_.size()) continue;
			if (s.amount <= 0.0001f || !s.pre) continue;
			MixerTrack &dst = mixer_[(size_t)s.dest];
			float *dl = s.sidechain ? dst.scL.data() : dst.L.data();
			float *dr = s.sidechain ? dst.scR.data() : dst.R.data();
			for (int i = 0; i < frames; i++) { dl[i] += L[i] * s.amount; dr[i] += R[i] * s.amount; }
			if (s.sidechain) dst.has_sc = true;
		}

		t.g_vol.set(audible ? t.vol : 0.0f);
		t.g_pan.set(t.pan);
		for (int i = 0; i < frames; i++) {
			const float v = t.g_vol.next();
			const float pan = t.g_pan.next();
			const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			L[i] = flush(L[i] * v * pl);
			R[i] = flush(R[i] * v * pr);
			const float al = std::fabs(L[i]), ar = std::fabs(R[i]);
			peak_l = std::max(peak_l, al);
			peak_r = std::max(peak_r, ar);
			sum_l += L[i] * L[i];
			sum_r += R[i] * R[i];
		}
		// Meters decay between blocks so a short peak stays readable.
		const float fall = 0.82f;
		t.peak_l = std::max(peak_l, t.peak_l * fall);
		t.peak_r = std::max(peak_r, t.peak_r * fall);
		t.rms_l = std::sqrt(sum_l / (float)frames);
		t.rms_r = std::sqrt(sum_r / (float)frames);

		// Post-fader sends.
		for (const Send &s : t.sends) {
			if (s.dest < 0 || s.dest >= (int)mixer_.size()) continue;
			if (s.amount <= 0.0001f || s.pre) continue;
			MixerTrack &dst = mixer_[(size_t)s.dest];
			float *dl = s.sidechain ? dst.scL.data() : dst.L.data();
			float *dr = s.sidechain ? dst.scR.data() : dst.R.data();
			for (int i = 0; i < frames; i++) { dl[i] += L[i] * s.amount; dr[i] += R[i] * s.amount; }
			if (s.sidechain) dst.has_sc = true;
		}

		if (idx == 0) {
			if (limit_on_) limit(L, R, frames);
			std::memcpy(outL, L, sizeof(float) * (size_t)frames);
			std::memcpy(outR, R, sizeof(float) * (size_t)frames);
		} else if (t.route >= 0 && t.route < (int)mixer_.size() && t.route != idx) {
			MixerTrack &dst = mixer_[(size_t)t.route];
			for (int i = 0; i < frames; i++) { dst.L[(size_t)i] += L[i]; dst.R[(size_t)i] += R[i]; }
		}
	}
}

void Engine::set_limiter(bool on, float ceiling_db) {
	std::lock_guard<std::mutex> g(mutex);
	limit_on_ = on;
	limit_ceiling_ = std::pow(10.0f, std::max(-24.0f, std::min(0.0f, ceiling_db)) / 20.0f);
	limit_gain_ = 1.0f;
}

float Engine::limiter_reduction() const {
	return limit_gain_ >= 0.999f ? 0.0f : 20.0f * std::log10(std::max(0.0001f, limit_gain_));
}

/// Instant when it has to be, slow on the way back: a peak is caught on the
/// sample it happens rather than a moment later, and the gain returns over
/// about a tenth of a second so the hold is not audible as pumping. The clamp
/// afterwards is what makes it a ceiling rather than a suggestion -- one
/// sample of a transient can still get past a gain that only moves per sample.
void Engine::limit(float *L, float *R, int frames) {
	const float ceiling = limit_ceiling_;
	// About 100 ms to come back up, whatever the sample rate.
	const float release = std::exp(-1.0f / (float)(0.1 * sr));
	for (int i = 0; i < frames; i++) {
		const float peak = std::max(std::fabs(L[i]), std::fabs(R[i]));
		const float want = peak > ceiling ? ceiling / peak : 1.0f;
		if (want < limit_gain_) {
			limit_gain_ = want;
		} else {
			limit_gain_ = want + (limit_gain_ - want) * release;
		}
		L[i] = std::max(-ceiling, std::min(ceiling, L[i] * limit_gain_));
		R[i] = std::max(-ceiling, std::min(ceiling, R[i] * limit_gain_));
	}
}

void Engine::render_block(float *outL, float *outR, int frames, bool advance) {
	ensure_buffers(frames);
	for (auto &t : mixer_) {
		std::memset(t.L.data(), 0, sizeof(float) * (size_t)frames);
		std::memset(t.R.data(), 0, sizeof(float) * (size_t)frames);
		std::memset(t.scL.data(), 0, sizeof(float) * (size_t)frames);
		std::memset(t.scR.data(), 0, sizeof(float) * (size_t)frames);
		t.has_sc = false;
	}
	// The machine's own input goes in first, so the track it lands on carries
	// a voice exactly the way it carries a synth: through its inserts, its
	// fader, and any send -- sidechain sends included.
	pull_input(frames);

	const double bps = bpm_ / 60.0 / sr;
	const double b0 = beat_;
	const double b1 = beat_ + (advance ? bps * frames : 0.0);

	events_.clear();
	if (advance) {
		collect_events(b0, b1, frames, events_);
		if (mode_ == MODE_SONG) {
			start_audio_clips(b0, b1);
			apply_automation(b0);
		}
	}

	// Instruments, split at every event so timing stays sample accurate.
	int cursor = 0;
	size_t ei = 0;
	while (cursor < frames) {
		while (ei < events_.size() && events_[ei].frame <= cursor) {
			const Event &e = events_[ei];
			Channel &c = channels_[(size_t)e.channel];
			if (c.inst) {
				if (e.type == 0) {
					c.inst->next_pan = e.pan;
					c.inst->next_fine = e.fine;
					c.inst->note_on(e.key, e.vel, e.id);
					c.inst->next_pan = 0.0f;
					c.inst->next_fine = 0.0f;
				} else {
					c.inst->note_off(e.key, e.id);
				}
			}
			if (e.key >= 0 && e.key < 128) {
				if (e.type == 0) c.keys[e.key] = (unsigned char)std::min(200, c.keys[e.key] + 1);
				else if (c.keys[e.key] > 0) c.keys[e.key]--;
			}
			ei++;
		}
		int next = frames;
		if (ei < events_.size()) next = std::min(frames, events_[ei].frame);
		const int seg = std::max(1, next - cursor);
		for (auto &c : channels_) {
			if (!c.inst) continue;
			c.inst->bpm = bpm_;
			c.inst->song_beat = b0 + bps * cursor;
			c.inst->playing = playing_;
			c.inst->process(c.L.data() + cursor, c.R.data() + cursor, seg);
			c.inst->capture(c.L.data() + cursor, c.R.data() + cursor, seg);
		}
		cursor += seg;
	}

	// Channels into their mixer tracks.
	bool any_solo = false;
	for (const auto &c : channels_) if (c.solo) { any_solo = true; break; }
	for (auto &c : channels_) {
		if (!c.inst) continue;
		float chan_peak = 0.0f;
		for (int i = 0; i < frames; i++) {
			chan_peak = std::max(chan_peak, std::max(std::fabs(c.L[(size_t)i]), std::fabs(c.R[(size_t)i])));
		}
		c.level = std::max(chan_peak, c.level * 0.86f);
		const bool audible = !c.mute && (!any_solo || c.solo);
		c.g_vol.set(audible ? c.vol : 0.0f);
		MixerTrack &t = mixer_[(size_t)std::max(0, std::min((int)mixer_.size() - 1, c.mixer))];
		const float pl = std::cos((c.pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const float pr = std::sin((c.pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		for (int i = 0; i < frames; i++) {
			const float v = c.g_vol.next();
			t.L[(size_t)i] += c.L[(size_t)i] * v * pl;
			t.R[(size_t)i] += c.R[(size_t)i] * v * pr;
		}
	}

	// Audio clips.
	for (auto &v : audio_voices_) {
		if (!v.active) continue;
		if (v.asset < 0 || v.asset >= (int)assets_.size() || !assets_[(size_t)v.asset].file) { v.active = false; continue; }
		const AudioAsset &as = assets_[(size_t)v.asset];
		const AudioFile &f = as.baked ? *as.baked : *as.file;
		MixerTrack &t = mixer_[(size_t)std::max(0, std::min((int)mixer_.size() - 1, v.track))];
		const int fr = f.frames();
		// Two milliseconds of ramp when a voice is asked to stop. Cutting a
		// sample dead mid-cycle is a click, and a click on every loop is worse
		// than the overlap it replaced.
		const float fade_step = 1.0f / std::max(1.0f, (float)(sr * 0.002));
		for (int i = 0; i < frames; i++) {
			const int i0 = (int)v.pos;
			if (i0 < 0 || i0 + 1 >= fr || v.left <= 0.0) { v.active = false; break; }
			const float frac = (float)(v.pos - (double)i0);
			const float l = lerp(f.data[(size_t)i0 * f.channels], f.data[(size_t)(i0 + 1) * f.channels], frac);
			const float r = f.channels > 1
					? lerp(f.data[(size_t)i0 * f.channels + 1], f.data[(size_t)(i0 + 1) * f.channels + 1], frac)
					: l;
			float amp = v.gain;
			if (v.fading()) {
				v.fade -= fade_step;
				if (v.fade <= 0.0) { v.active = false; break; }
				amp *= (float)v.fade;
			}
			const float pl = std::cos((v.pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41421356f;
			const float pr = std::sin((v.pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41421356f;
			t.L[(size_t)i] += l * amp * pl;
			t.R[(size_t)i] += r * amp * pr;
			v.pos += v.inc;
			v.left -= 1.0;
		}
	}

	// A recorded click is mastered to full scale, which straight into the
	// master bus is both louder than anything it is counting over and enough to
	// put the limiter to work on its own. This is what the synthesised click
	// peaked at, so turning the metronome on sounds the same as it always did.
	const float kMetroGain = 0.45f;

	// Metronome, straight into master. Recorded clicks when it has been given
	// any -- the first beat of a bar gets the accented one and the rest get the
	// other -- and the synthesised click when it has not, so the engine still
	// counts on its own with nothing loaded. Either way it keeps going across
	// block boundaries: the earlier version restarted the oscillator every
	// buffer, which is why it was more of a tick than a beat.
	if (metro_ && playing_ && advance) {
		MixerTrack &m = mixer_[0];
		const float decay = std::exp(-1.0f / (float)(sr * 0.035));
		for (int i = 0; i < frames; i++) {
			const double b = b0 + bps * i;
			if (std::floor(b) != std::floor(metro_last_beat_) || metro_last_beat_ < 0.0) {
				const bool bar = (((long long)std::floor(b)) % std::max(1, sig_num_)) == 0;
				const int want = bar ? 0 : 1;
				if (metro_snd_[want].frames() > 1) {
					metro_voice_ = want;
					metro_pos_ = 0.0;
					metro_env_ = 0.0f;
				} else {
					metro_voice_ = -1;
					metro_env_ = 1.0f;
					metro_freq_ = bar ? 1760.0f : 1174.0f;
					metro_phase_ = 0.0;
				}
			}
			metro_last_beat_ = b;
			if (metro_voice_ >= 0) {
				const MetroSound &snd = metro_snd_[metro_voice_];
				const int i0 = (int)metro_pos_;
				if (i0 < 0 || i0 + 1 >= snd.frames()) {
					metro_voice_ = -1;
					continue;
				}
				const size_t a = (size_t)i0 * (size_t)snd.channels;
				const size_t c = (size_t)(i0 + 1) * (size_t)snd.channels;
				const float frac = (float)(metro_pos_ - (double)i0);
				const float l = lerp(snd.data[a], snd.data[c], frac);
				const float r = snd.channels > 1 ? lerp(snd.data[a + 1], snd.data[c + 1], frac) : l;
				m.L[(size_t)i] += l * kMetroGain;
				m.R[(size_t)i] += r * kMetroGain;
				// Read at whatever the engine is running at, so a 44.1 kHz
				// click is the same click at 48.
				metro_pos_ += snd.rate / sr;
			} else if (metro_env_ > 0.0005f) {
				metro_phase_ += metro_freq_ / sr;
				if (metro_phase_ >= 1.0) metro_phase_ -= std::floor(metro_phase_);
				// Two partials and a short noise-free envelope: audible over a
				// dense mix without being shrill.
				const float x = (std::sin((float)TAU * (float)metro_phase_) * 0.75f
						+ std::sin((float)TAU * 2.0f * (float)metro_phase_) * 0.25f)
						* metro_env_ * 0.45f;
				metro_env_ *= decay;
				m.L[(size_t)i] += x;
				m.R[(size_t)i] += x;
			}
		}
	} else {
		metro_last_beat_ = -1.0;
		metro_voice_ = -1;
	}

	mix_tracks(frames, outL, outR);

	// Keep the master output for the scope and the analyser.
	if (scope_l_.size() != (size_t)SCOPE_N) {
		scope_l_.assign(SCOPE_N, 0.0f);
		scope_r_.assign(SCOPE_N, 0.0f);
		scope_w_ = 0;
	}
	for (int i = 0; i < frames; i++) {
		scope_l_[(size_t)scope_w_] = outL[i];
		scope_r_[(size_t)scope_w_] = outR[i];
		scope_w_ = (scope_w_ + 1) % SCOPE_N;
	}

	if (advance) beat_ = b1;
}

void Engine::process(float *outL, float *outR, int frames) {
	// Said once, so a report can tell a crash on the audio thread from one on
	// the thread the interface runs on. They mean different things.
	static bool marked = false;
	if (!marked) {
		marked = true;
		cd::crash_mark_audio_thread();
	}
	const auto t0 = std::chrono::steady_clock::now();
	std::unique_lock<std::mutex> g(mutex, std::try_to_lock);
	if (!g.owns_lock()) {
		// The UI is mid-edit; a block of silence beats a torn read.
		std::memset(outL, 0, sizeof(float) * (size_t)frames);
		std::memset(outR, 0, sizeof(float) * (size_t)frames);
		return;
	}
	int done = 0;
	while (done < frames) {
		// Never more at once than everything was set up for. Every processor in
		// the chain -- stock, hosted, or one living in its own library -- is
		// told a block size when it is prepared and is entitled to size its
		// working buffers to it. A host that then hands it a bigger block is
		// asking it to write off the end of them, and what comes out of that is
		// noise, if the program survives at all. Godot asks for whatever its
		// own mixer feels like, which is not always what we asked for.
		int chunk = (std::min)(frames - done, (std::max)(1, block));
		const double bps = bpm_ / 60.0 / sr;
		if (playing_ && loop_on_) {
			const double end = (mode_ == MODE_PATTERN)
					? (double)pattern_length(cur_pattern_)
					: loop_b_;
			const double start = (mode_ == MODE_PATTERN) ? 0.0 : loop_a_;
			if (end > start) {
				const double left = (end - beat_) / std::max(1e-12, bps);
				if (left <= 0.0) {
					beat_ = start;
					for (auto &c : channels_) {
						if (c.inst) c.inst->all_notes_off();
						c.held.clear();
						std::memset(c.keys, 0, sizeof(c.keys));
					}
					// And the samples: a clip that ran past the loop point was
					// still playing when the playhead came round and started
					// it again, so every pass added another copy of it.
					for (auto &v : audio_voices_) {
						if (v.active && !v.fading()) v.release();
					}
				} else if (left < (double)chunk) {
					chunk = std::max(1, (int)left);
				}
			}
		}
		render_block(outL + done, outR + done, chunk, playing_);
		done += chunk;
	}
	const auto t1 = std::chrono::steady_clock::now();
	const double used = std::chrono::duration<double>(t1 - t0).count();
	const double avail = (double)frames / sr;
	cpu_ = (float)(cpu_ * 0.9 + (used / std::max(1e-9, avail)) * 0.1);
}

// ---------------------------------------------------------------------------
// Offline render
// ---------------------------------------------------------------------------
/// The longest an automatic tail is allowed to run for before it is cut off
/// anyway. A reverb that is still audible after this is a drone, not a tail.
static const double kAutoTailMax = 60.0;

bool Engine::render(const std::string &path, double start_beat, double end_beat, double tail, int bits,
		bool normalize, float *progress, bool loop_fold) {
	std::lock_guard<std::mutex> g(mutex);
	const bool was_playing = playing_;
	const double was_beat = beat_;
	const bool was_loop = loop_on_;
	const int was_mode = mode_;
	const bool was_offline = offline_;
	// Nothing is coming in off the machine's input during a render, and what
	// is in the ring belongs to the audio thread that is still playing.
	offline_ = true;
	loop_on_ = false;
	playing_ = true;
	beat_ = start_beat;
	// A render starts from nothing, the ceiling's own state included: what it
	// was holding back a moment ago is not this file's business.
	limit_gain_ = 1.0f;
	for (auto &c : channels_) {
		if (c.inst) { c.inst->all_notes_off(); c.inst->reset(); }
		c.held.clear();
	}
	for (auto &v : audio_voices_) v.active = false;
	// Whatever the start point lands inside starts with the rest of itself.
	retrigger_locked(start_beat);
	if (mode_ == MODE_SONG) start_audio_at(start_beat);

	const int blk = 512;
	std::vector<float> L((size_t)blk), R((size_t)blk);
	std::vector<float> out;
	const double total_beats = std::max(0.25, end_beat - start_beat);
	// A negative tail means "as long as it takes": the render carries on past
	// the end until what is coming out has gone quiet, so a long reverb is not
	// cut off and a dry mix does not get half a minute of silence stapled on.
	const bool auto_tail = tail < 0.0;
	const int64_t tail_frames = (int64_t)((auto_tail ? kAutoTailMax : tail) * sr);
	int64_t written = 0;
	int64_t body_frames = 0;
	bool in_tail = false;
	int64_t tail_left = tail_frames;
	int quiet_blocks = 0;
	const int quiet_needed = (int)(0.25 * sr / blk) + 1;

	while (true) {
		if (!in_tail && beat_ >= end_beat) {
			in_tail = true;
			playing_ = false;
			body_frames = written;
		}
		if (in_tail && tail_left <= 0) break;
		render_block(L.data(), R.data(), blk, !in_tail);
		out.insert(out.end(), (size_t)blk * 2, 0.0f);
		float blk_peak = 0.0f;
		for (int i = 0; i < blk; i++) {
			out[(size_t)(written + i) * 2] = L[(size_t)i];
			out[(size_t)(written + i) * 2 + 1] = R[(size_t)i];
			blk_peak = std::max(blk_peak, std::max(std::fabs(L[(size_t)i]), std::fabs(R[(size_t)i])));
		}
		written += blk;
		if (in_tail) {
			tail_left -= blk;
			if (auto_tail) {
				// -84 dBFS: below the noise floor of a 16-bit file, so what is
				// being thrown away cannot be heard in the result.
				quiet_blocks = blk_peak < 0.00006f ? quiet_blocks + 1 : 0;
				if (quiet_blocks >= quiet_needed) break;
			}
		}
		if (progress) {
			*progress = in_tail ? 0.99f
					: (float)clampf((float)((beat_ - start_beat) / total_beats), 0.0f, 0.99f);
		}
		if (written > (int64_t)(sr * 3600)) break;   // an hour is a runaway
	}
	if (body_frames == 0) body_frames = written;

	// The tail, added back onto the front. What was still ringing when the
	// range ended is exactly what should already be ringing when it starts
	// again, so the file joins to itself with nothing to hear at the seam.
	if (loop_fold && written > body_frames) {
		for (int64_t i = body_frames; i < written; i++) {
			const int64_t dst = (i - body_frames) % body_frames;
			out[(size_t)dst * 2] += out[(size_t)i * 2];
			out[(size_t)dst * 2 + 1] += out[(size_t)i * 2 + 1];
		}
		written = body_frames;
	}

	if (normalize) {
		float peak = 0.0f;
		for (float x : out) peak = std::max(peak, std::fabs(x));
		if (peak > 0.0001f) {
			const float g2 = 0.98f / peak;
			for (float &x : out) x *= g2;
		}
	}

	playing_ = was_playing;
	beat_ = was_beat;
	loop_on_ = was_loop;
	mode_ = was_mode;
	offline_ = was_offline;
	if (progress) *progress = 1.0f;
	return wav_save(path, out.data(), (int)written, 2, (int)sr, bits);
}

bool Engine::render_stems(const std::string &dir, double start_beat, double end_beat, double tail, int bits) {
	// One pass per mixer track, soloing it: slower than a summing render but it
	// keeps every send, insert and routing decision exactly as you hear it.
	bool all_ok = true;
	std::vector<bool> saved;
	{
		std::lock_guard<std::mutex> g(mutex);
		for (auto &t : mixer_) saved.push_back(t.solo);
	}
	for (size_t i = 1; i < mixer_.size(); i++) {
		bool used = false;
		{
			std::lock_guard<std::mutex> g(mutex);
			for (const auto &c : channels_) if (c.mixer == (int)i) used = true;
			for (const auto &cl : clips_) if (cl.type == CLIP_AUDIO && cl.track == (int)i) used = true;
			if (used) {
				for (size_t k = 0; k < mixer_.size(); k++) mixer_[k].solo = (k == i);
			}
		}
		if (!used) continue;
		std::string name = mixer_[i].name;
		for (char &ch : name) if (ch == '/' || ch == ' ') ch = '_';
		char file[1024];
		snprintf(file, sizeof(file), "%s/%02d_%s.wav", dir.c_str(), (int)i, name.c_str());
		all_ok = render(file, start_beat, end_beat, tail, bits, false, nullptr) && all_ok;
	}
	{
		std::lock_guard<std::mutex> g(mutex);
		for (size_t k = 0; k < mixer_.size() && k < saved.size(); k++) mixer_[k].solo = saved[k];
	}
	return all_ok;
}

} // namespace cd
