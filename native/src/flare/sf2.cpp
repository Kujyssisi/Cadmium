// FLARE — SoundFont 2 reader.
#include "sf2.h"

#include "dsp.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace flare {

namespace {

// The generator operators FLARE understands. The rest are read and ignored.
enum {
	G_START_OFS = 0, G_END_OFS = 1, G_STARTLOOP_OFS = 2, G_ENDLOOP_OFS = 3,
	G_START_COARSE = 4, G_FILTER_FC = 8, G_FILTER_Q = 9, G_END_COARSE = 12,
	G_PAN = 17, G_DELAY_VOLENV = 33, G_ATTACK_VOLENV = 34, G_HOLD_VOLENV = 35,
	G_DECAY_VOLENV = 36, G_SUSTAIN_VOLENV = 37, G_RELEASE_VOLENV = 38,
	G_INSTRUMENT = 41, G_KEY_RANGE = 43, G_VEL_RANGE = 44, G_STARTLOOP_COARSE = 45,
	G_KEYNUM = 46, G_VELOCITY = 47, G_ATTENUATION = 48, G_ENDLOOP_COARSE = 50,
	G_COARSE_TUNE = 51, G_FINE_TUNE = 52, G_SAMPLE_ID = 53, G_SAMPLE_MODES = 54,
	G_SCALE_TUNING = 56, G_EXCLUSIVE = 57, G_ROOT_KEY = 58,
	G_COUNT = 60
};

struct Merged {
	int16_t gen[G_COUNT];
	bool has[G_COUNT];
	Merged() { std::memset(gen, 0, sizeof(gen)); std::memset(has, 0, sizeof(has)); }
};

inline uint32_t rd32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
inline uint16_t rd16(const uint8_t *p) { return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)); }

std::string rd_name(const uint8_t *p, int n) {
	std::string s;
	for (int i = 0; i < n && p[i]; i++) s.push_back((char)p[i]);
	while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.pop_back();
	return s;
}

} // namespace

namespace {
/// The open files, weakly held: a soundfont stays in memory for as long as a
/// part is playing it and not a moment longer.
std::vector<std::pair<std::string, std::weak_ptr<Sf2>>> g_open;
std::mutex g_open_lock;
} // namespace

std::shared_ptr<Sf2> sf2_get(const std::string &path) {
	std::lock_guard<std::mutex> guard(g_open_lock);
	for (auto &kv : g_open) {
		if (kv.first != path) continue;
		if (std::shared_ptr<Sf2> live = kv.second.lock()) return live;
	}
	auto sf = std::make_shared<Sf2>();
	if (!sf->load(path)) return nullptr;
	for (auto &kv : g_open) {
		if (kv.second.expired()) { kv = {path, sf}; return sf; }
	}
	g_open.push_back({path, sf});
	return sf;
}

void sf2_forget_unused() {
	std::lock_guard<std::mutex> guard(g_open_lock);
	for (size_t i = 0; i < g_open.size();) {
		if (g_open[i].second.expired()) g_open.erase(g_open.begin() + (long)i);
		else i++;
	}
}

float sf2_timecents(int16_t tc) {
	if (tc <= -12000) return 0.0f;
	return std::pow(2.0f, (float)tc / 1200.0f);
}

float sf2_abs_cents_hz(float cents) {
	return 8.176f * std::pow(2.0f, cents / 1200.0f);
}

bool Sf2::load(const std::string &file) {
	FILE *f = std::fopen(file.c_str(), "rb");
	if (!f) return false;
	std::fseek(f, 0, SEEK_END);
	const long len = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	if (len < 64) { std::fclose(f); return false; }
	std::vector<uint8_t> b((size_t)len);
	const size_t got = std::fread(b.data(), 1, (size_t)len, f);
	std::fclose(f);
	if (got != (size_t)len) return false;

	if (std::memcmp(b.data(), "RIFF", 4) != 0 || std::memcmp(b.data() + 8, "sfbk", 4) != 0) return false;
	path_ = file;

	const uint8_t *sm16 = nullptr, *sm24 = nullptr;
	size_t sm_bytes = 0;

	// Walk the three top-level LISTs and every chunk inside them.
	size_t p = 12;
	while (p + 8 <= b.size()) {
		const char *id = (const char *)(b.data() + p);
		const uint32_t sz = rd32(b.data() + p + 4);
		const size_t body = p + 8;
		if (body + sz > b.size()) break;

		if (std::memcmp(id, "LIST", 4) == 0) {
			const char *kind = (const char *)(b.data() + body);
			size_t q = body + 4;
			const size_t stop = body + sz;
			while (q + 8 <= stop) {
				const char *cid = (const char *)(b.data() + q);
				const uint32_t csz = rd32(b.data() + q + 4);
				const uint8_t *c = b.data() + q + 8;
				if (q + 8 + csz > b.size()) break;

				if (std::memcmp(kind, "INFO", 4) == 0 && std::memcmp(cid, "INAM", 4) == 0) {
					name_ = rd_name(c, (int)csz);
				} else if (std::memcmp(cid, "smpl", 4) == 0) {
					sm16 = c;
					sm_bytes = csz;
				} else if (std::memcmp(cid, "sm24", 4) == 0) {
					sm24 = c;
				} else if (std::memcmp(cid, "phdr", 4) == 0) {
					const uint32_t n = csz / 38;
					for (uint32_t i = 0; i < n; i++) {
						const uint8_t *r = c + (size_t)i * 38;
						Preset pr;
						pr.name = rd_name(r, 20);
						pr.program = rd16(r + 20);
						pr.bank = rd16(r + 22);
						pr.bag_start = rd16(r + 24);
						presets_.push_back(pr);
					}
					// Each record's bag range ends where the next one begins;
					// the last is the terminal record and is dropped.
					for (size_t i = 0; i + 1 < presets_.size(); i++)
						presets_[i].bag_end = presets_[i + 1].bag_start;
					if (!presets_.empty()) presets_.pop_back();
				} else if (std::memcmp(cid, "pbag", 4) == 0) {
					const uint32_t n = csz / 4;
					for (uint32_t i = 0; i < n; i++) {
						Bag g;
						g.gen = rd16(c + (size_t)i * 4);
						g.mod = rd16(c + (size_t)i * 4 + 2);
						pbag_.push_back(g);
					}
				} else if (std::memcmp(cid, "pgen", 4) == 0) {
					const uint32_t n = csz / 4;
					for (uint32_t i = 0; i < n; i++)
						pgen_.push_back({rd16(c + (size_t)i * 4), (int16_t)rd16(c + (size_t)i * 4 + 2)});
				} else if (std::memcmp(cid, "inst", 4) == 0) {
					const uint32_t n = csz / 22;
					for (uint32_t i = 0; i < n; i++) {
						const uint8_t *r = c + (size_t)i * 22;
						Inst in;
						in.name = rd_name(r, 20);
						in.bag_start = rd16(r + 20);
						insts_.push_back(in);
					}
					for (size_t i = 0; i + 1 < insts_.size(); i++)
						insts_[i].bag_end = insts_[i + 1].bag_start;
					if (!insts_.empty()) insts_.pop_back();
				} else if (std::memcmp(cid, "ibag", 4) == 0) {
					const uint32_t n = csz / 4;
					for (uint32_t i = 0; i < n; i++) {
						Bag g;
						g.gen = rd16(c + (size_t)i * 4);
						g.mod = rd16(c + (size_t)i * 4 + 2);
						ibag_.push_back(g);
					}
				} else if (std::memcmp(cid, "igen", 4) == 0) {
					const uint32_t n = csz / 4;
					for (uint32_t i = 0; i < n; i++)
						igen_.push_back({rd16(c + (size_t)i * 4), (int16_t)rd16(c + (size_t)i * 4 + 2)});
				} else if (std::memcmp(cid, "shdr", 4) == 0) {
					const uint32_t n = csz / 46;
					for (uint32_t i = 0; i < n; i++) {
						const uint8_t *r = c + (size_t)i * 46;
						Sample s;
						s.name = rd_name(r, 20);
						s.start = rd32(r + 20);
						s.end = rd32(r + 24);
						s.loop_start = rd32(r + 28);
						s.loop_end = rd32(r + 32);
						s.rate = rd32(r + 36);
						s.root = r[40];
						s.correction = (int8_t)r[41];
						s.link = rd16(r + 42);
						s.type = rd16(r + 44);
						samples_.push_back(s);
					}
					if (!samples_.empty()) samples_.pop_back();
				}
				q += 8 + csz + (csz & 1u);
			}
		}
		p = body + sz + (sz & 1u);
	}

	if (!sm16 || sm_bytes == 0 || samples_.empty() || presets_.empty()) return false;

	// The whole sample block, once, as floats. sm24 holds the low byte of a
	// 24-bit soundfont; without it the file is plain 16-bit.
	const size_t n = sm_bytes / 2;
	pcm_.resize(n);
	for (size_t i = 0; i < n; i++) {
		const int16_t hi = (int16_t)rd16(sm16 + i * 2);
		if (sm24) {
			const int32_t v = ((int32_t)hi << 8) | (int32_t)sm24[i];
			pcm_[i] = (float)v * (1.0f / 8388608.0f);
		} else {
			pcm_[i] = (float)hi * (1.0f / 32768.0f);
		}
	}
	if (name_.empty()) {
		const size_t s = file.find_last_of("/\\");
		name_ = s == std::string::npos ? file : file.substr(s + 1);
	}
	// The public list. Sorted by bank then program, which is the order every
	// other program shows a soundfont's presets in.
	info_.clear();
	for (const Preset &pr : presets_) {
		Sf2PresetInfo i;
		i.name = pr.name;
		i.bank = pr.bank;
		i.program = pr.program;
		info_.push_back(i);
	}
	return true;
}

namespace {

void apply(const std::vector<std::pair<uint16_t, int16_t>> &gens, int from, int to,
		Merged &m, bool preset_level) {
	for (int i = from; i < to && i < (int)gens.size(); i++) {
		const uint16_t op = gens[(size_t)i].first;
		if (op >= G_COUNT) continue;
		if (preset_level && m.has[op] && op != G_KEY_RANGE && op != G_VEL_RANGE) {
			// Preset generators are offsets on top of the instrument's, except
			// the ranges, which replace.
			m.gen[op] = (int16_t)(m.gen[op] + gens[(size_t)i].second);
		} else {
			m.gen[op] = gens[(size_t)i].second;
		}
		m.has[op] = true;
	}
}

} // namespace

bool Sf2::build(int preset_index, MultiSample &out) {
	if (!loaded()) return false;
	if (preset_index < 0 || preset_index >= (int)presets_.size()) return false;
	out.clear();
	const Preset &pr = presets_[(size_t)preset_index];
	out.name = pr.name;

	if (!shared_) {
		shared_ = std::make_shared<SampleData>();
		shared_->name = name_;
		shared_->channels = 1;
		shared_->rate = 44100;   // per zone below; the block itself is mixed rate
		// Moved, not copied. Holding the samples once as int16 and again as
		// float was three hundred megabytes for a General MIDI font, and the
		// first copy was never read again.
		shared_->pcm = std::move(pcm_);
	}
	out.pool.push_back(shared_);

	for (int pb = pr.bag_start; pb < pr.bag_end && pb < (int)pbag_.size(); pb++) {
		const int pg_from = pbag_[(size_t)pb].gen;
		const int pg_to = pb + 1 < (int)pbag_.size() ? pbag_[(size_t)pb + 1].gen : (int)pgen_.size();

		// The preset zone's own generators, which apply to every instrument
		// zone underneath it.
		Merged pz;
		apply(pgen_, pg_from, pg_to, pz, false);
		if (!pz.has[G_INSTRUMENT]) continue;   // the global zone
		const int inst = pz.gen[G_INSTRUMENT];
		if (inst < 0 || inst >= (int)insts_.size()) continue;
		const Inst &in = insts_[(size_t)inst];

		// An instrument's first bag is its global zone when it names no sample.
		Merged iglobal;
		bool have_global = false;
		{
			const int ig_from = ibag_[(size_t)in.bag_start].gen;
			const int ig_to = in.bag_start + 1 < (int)ibag_.size()
					? ibag_[(size_t)in.bag_start + 1].gen : (int)igen_.size();
			Merged g;
			apply(igen_, ig_from, ig_to, g, false);
			if (!g.has[G_SAMPLE_ID]) { iglobal = g; have_global = true; }
		}

		for (int ib = in.bag_start + (have_global ? 1 : 0); ib < in.bag_end && ib < (int)ibag_.size(); ib++) {
			const int ig_from = ibag_[(size_t)ib].gen;
			const int ig_to = ib + 1 < (int)ibag_.size() ? ibag_[(size_t)ib + 1].gen : (int)igen_.size();

			Merged m = have_global ? iglobal : Merged();
			apply(igen_, ig_from, ig_to, m, false);
			if (!m.has[G_SAMPLE_ID]) continue;
			// Now the preset layer, added on top.
			apply(pgen_, pg_from, pg_to, m, true);

			const int sid = m.gen[G_SAMPLE_ID];
			if (sid < 0 || sid >= (int)samples_.size()) continue;
			const Sample &s = samples_[(size_t)sid];

			Zone z;
			z.data = shared_;
			z.start = (int)s.start + m.gen[G_START_OFS] + m.gen[G_START_COARSE] * 32768;
			z.end = (int)s.end + m.gen[G_END_OFS] + m.gen[G_END_COARSE] * 32768;
			z.loop_start = (int)s.loop_start + m.gen[G_STARTLOOP_OFS] + m.gen[G_STARTLOOP_COARSE] * 32768;
			z.loop_end = (int)s.loop_end + m.gen[G_ENDLOOP_OFS] + m.gen[G_ENDLOOP_COARSE] * 32768;
			const int modes = m.has[G_SAMPLE_MODES] ? m.gen[G_SAMPLE_MODES] : 0;
			z.loop_mode = (modes == 1) ? 1 : (modes == 3 ? 3 : 0);

			if (m.has[G_KEY_RANGE]) {
				z.lo_key = m.gen[G_KEY_RANGE] & 0xFF;
				z.hi_key = (m.gen[G_KEY_RANGE] >> 8) & 0xFF;
			}
			if (m.has[G_VEL_RANGE]) {
				z.lo_vel = m.gen[G_VEL_RANGE] & 0xFF;
				z.hi_vel = (m.gen[G_VEL_RANGE] >> 8) & 0xFF;
			}
			if (z.lo_key > z.hi_key) std::swap(z.lo_key, z.hi_key);
			if (z.lo_vel > z.hi_vel) std::swap(z.lo_vel, z.hi_vel);

			z.root_key = m.has[G_ROOT_KEY] && m.gen[G_ROOT_KEY] >= 0 ? m.gen[G_ROOT_KEY] : (int)s.root;
			z.tune = (float)m.gen[G_COARSE_TUNE]
					+ ((float)m.gen[G_FINE_TUNE] + (float)s.correction) * 0.01f;
			// The zone's own sample rate rides on the tuning, since every zone
			// shares one buffer and the reader has a single rate for it.
			if (s.rate > 0 && s.rate != 44100)
				z.tune += 12.0f * std::log2((float)s.rate / 44100.0f);
			z.key_track = m.has[G_SCALE_TUNING] ? (float)m.gen[G_SCALE_TUNING] * 0.01f : 1.0f;
			if (m.has[G_KEYNUM] && m.gen[G_KEYNUM] >= 0) {
				// A fixed key: drums. Play the root whatever is pressed.
				z.root_key = m.gen[G_KEYNUM];
				z.key_track = 0.0f;
			}
			z.gain = db_to_gain(-(float)m.gen[G_ATTENUATION] * 0.1f);
			z.pan = clampf((float)m.gen[G_PAN] * 0.002f, -1.0f, 1.0f);
			z.exclusive = m.gen[G_EXCLUSIVE];

			z.has_env = true;
			z.delay = m.has[G_DELAY_VOLENV] ? sf2_timecents(m.gen[G_DELAY_VOLENV]) : 0.0f;
			z.attack = m.has[G_ATTACK_VOLENV] ? sf2_timecents(m.gen[G_ATTACK_VOLENV]) : 0.001f;
			z.hold = m.has[G_HOLD_VOLENV] ? sf2_timecents(m.gen[G_HOLD_VOLENV]) : 0.0f;
			z.decay = m.has[G_DECAY_VOLENV] ? sf2_timecents(m.gen[G_DECAY_VOLENV]) : 0.0f;
			z.sustain = m.has[G_SUSTAIN_VOLENV]
					? clampf(1.0f - (float)m.gen[G_SUSTAIN_VOLENV] * 0.001f, 0.0f, 1.0f) : 1.0f;
			z.release = m.has[G_RELEASE_VOLENV] ? sf2_timecents(m.gen[G_RELEASE_VOLENV]) : 0.1f;
			// A zone with no decay never reaches sustain; treat it as held.
			if (z.decay <= 0.0f) z.sustain = 1.0f;

			if (m.has[G_FILTER_FC] && m.gen[G_FILTER_FC] < 13500) {
				z.has_filter = true;
				z.filter_hz = sf2_abs_cents_hz((float)m.gen[G_FILTER_FC]);
				z.filter_q = std::pow(10.0f, (float)m.gen[G_FILTER_Q] * 0.05f * 0.1f);
				z.filter_q = clampf(z.filter_q, 0.5f, 8.0f);
			}

			// From the shared buffer, not from pcm_: the samples were moved
			// into it the first time a preset was built, so measuring pcm_
			// gives nothing and clamps every zone to no length at all.
			const int frames = (int)shared_->pcm.size();
			if (z.start < 0) z.start = 0;
			if (z.end > frames) z.end = frames;
			if (z.end <= z.start) continue;
			if (z.loop_end > frames || z.loop_start < z.start || z.loop_end <= z.loop_start + 1)
				z.loop_mode = 0;
			out.zones.push_back(z);
		}
	}
	return !out.zones.empty();
}

} // namespace flare
