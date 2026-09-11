// FLARE — sampled content: zone selection and playback.
#include "sample.h"

#include "dsp.h"
#include "wav.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>

namespace flare {

int MultiSample::frames_total() const {
	int n = 0;
	for (const auto &d : pool) n += d ? d->frames() : 0;
	return n;
}

void MultiSample::select(int key, int vel, std::vector<const Zone *> &out) const {
	out.clear();
	for (const Zone &z : zones) {
		if (key < z.lo_key || key > z.hi_key) continue;
		if (vel < z.lo_vel || vel > z.hi_vel) continue;
		if (!z.data || z.data->pcm.empty()) continue;
		out.push_back(&z);
	}
	// Nothing covers this note: rather than silence, reach for the nearest
	// zone by root. A library with gaps is normal, and a keyboard with dead
	// notes in the middle of it reads as a broken plugin.
	if (out.empty() && !zones.empty()) {
		const Zone *best = nullptr;
		int nearest = 1 << 30;
		for (const Zone &z : zones) {
			if (!z.data || z.data->pcm.empty()) continue;
			if (vel < z.lo_vel || vel > z.hi_vel) continue;
			const int d = std::abs(z.root_key - key);
			if (d < nearest) { nearest = d; best = &z; }
		}
		if (best) out.push_back(best);
	}
}

void MultiSample::key_range(int &lo, int &hi) const {
	lo = 127; hi = 0;
	for (const Zone &z : zones) {
		lo = std::min(lo, z.lo_key);
		hi = std::max(hi, z.hi_key);
	}
	if (lo > hi) { lo = 0; hi = 127; }
}

float zone_pitch_offset(const Zone &z, float key) {
	return (key - (float)z.root_key) * z.key_track + z.tune;
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------
void SampleReader::start(const Zone *zone, double sr, float start01) {
	z = zone;
	done = false;
	reverse = false;
	in_loop = false;
	released = false;
	if (!z || !z->data) { done = true; return; }
	rate_ratio = (double)z->data->rate / sr;
	const int last = z->end > 0 ? z->end : z->data->frames();
	const double span = std::max(0.0, (double)(last - z->start));
	pos = (double)z->start + span * (double)clampf(start01, 0.0f, 0.999f);
}

void SampleReader::release() {
	released = true;
	// A sustain loop holds only while the key is down; once it is not, the
	// reader runs on into whatever follows the loop.
	if (z && z->loop_mode == 3) in_loop = false;
}

void SampleReader::next(double step, float &l, float &r) {
	l = r = 0.0f;
	if (done || !z || !z->data) return;
	const SampleData &d = *z->data;
	const int frames = d.frames();
	if (frames < 2) { done = true; return; }

	const int last = (z->end > 0 && z->end <= frames) ? z->end : frames;
	const bool loops = z->loop_mode != 0 && z->loop_start >= 0
			&& z->loop_end > z->loop_start + 1 && z->loop_end <= frames
			&& !(z->loop_mode == 3 && released);

	int i = (int)pos;
	if (i < 0) i = 0;
	if (i >= frames - 1) {
		if (!loops) { done = true; return; }
		i = z->loop_start;
		pos = (double)i;
	}
	const float f = (float)(pos - (double)i);
	if (d.channels == 1) {
		l = r = lerpf(d.pcm[(size_t)i], d.pcm[(size_t)i + 1], f);
	} else {
		const size_t a = (size_t)i * (size_t)d.channels;
		const size_t b = a + (size_t)d.channels;
		l = lerpf(d.pcm[a], d.pcm[b], f);
		r = lerpf(d.pcm[a + 1], d.pcm[b + 1], f);
	}

	const double adv = step * rate_ratio * (reverse ? -1.0 : 1.0);
	pos += adv;

	if (loops) {
		if (z->loop_mode == 2) {
			// Ping-pong: turn round at each end rather than jumping, which is
			// the only way a loop in a sustained pad does not tick.
			if (pos >= (double)z->loop_end) { pos = (double)z->loop_end - (pos - (double)z->loop_end); reverse = true; }
			else if (pos <= (double)z->loop_start) { pos = (double)z->loop_start + ((double)z->loop_start - pos); reverse = false; }
		} else if (pos >= (double)z->loop_end) {
			const double len = (double)(z->loop_end - z->loop_start);
			pos -= len * std::floor((pos - (double)z->loop_start) / len);
		}
	} else if (pos >= (double)last - 1.0 || pos < 0.0) {
		done = true;
	}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------
int key_from_name(const std::string &raw) {
	// A bare number first: "36.wav", "Kick 36".
	{
		int digits = 0, value = 0;
		bool seen = false;
		for (int i = (int)raw.size() - 1; i >= 0; i--) {
			const char c = raw[(size_t)i];
			if (std::isdigit((unsigned char)c)) {
				value += (c - '0') * (int)std::pow(10.0, digits);
				digits++;
				seen = true;
			} else if (seen) {
				break;
			}
		}
		// Only when nothing that looks like a note name is present, since
		// "C4" would otherwise be read as 4.
		bool has_letter = false;
		for (size_t i = 0; i + 1 < raw.size(); i++) {
			const char c = (char)std::toupper((unsigned char)raw[i]);
			if (c >= 'A' && c <= 'G') {
				const char n = raw[i + 1];
				if (std::isdigit((unsigned char)n) || n == '#' || n == 'b' || n == '-') {
					has_letter = true;
					break;
				}
			}
		}
		if (!has_letter && seen && digits <= 3 && value >= 0 && value <= 127) return value;
	}
	// A note name: scan from the right so "Piano_C#3_v90" finds C#3, not the P.
	static const int STEP[7] = {9, 11, 0, 2, 4, 5, 7};   // A B C D E F G
	for (int i = (int)raw.size() - 1; i >= 0; i--) {
		const char c = (char)std::toupper((unsigned char)raw[(size_t)i]);
		if (c < 'A' || c > 'G') continue;
		size_t j = (size_t)i + 1;
		int semi = STEP[c - 'A'];
		if (j < raw.size() && (raw[j] == '#' || raw[j] == 's')) { semi++; j++; }
		else if (j < raw.size() && raw[j] == 'b') { semi--; j++; }
		bool neg = false;
		if (j < raw.size() && raw[j] == '-') { neg = true; j++; }
		if (j >= raw.size() || !std::isdigit((unsigned char)raw[j])) continue;
		int oct = 0, n = 0;
		while (j < raw.size() && std::isdigit((unsigned char)raw[j]) && n < 2) {
			oct = oct * 10 + (raw[j] - '0');
			j++; n++;
		}
		if (neg) oct = -oct;
		const int key = (oct + 1) * 12 + semi;
		if (key >= 0 && key <= 127) return key;
	}
	return -1;
}

namespace {

/// The velocity a filename asks for, or -1. "v90", "_127_", "vel64".
int vel_from_name(const std::string &raw) {
	for (size_t i = 0; i + 1 < raw.size(); i++) {
		if ((raw[i] == 'v' || raw[i] == 'V') && std::isdigit((unsigned char)raw[i + 1])) {
			if (i + 3 < raw.size() && (raw[i + 1] == 'e' || raw[i + 2] == 'l')) continue;
			int v = 0;
			size_t j = i + 1;
			while (j < raw.size() && std::isdigit((unsigned char)raw[j]) && j - i <= 3) {
				v = v * 10 + (raw[j] - '0');
				j++;
			}
			if (v >= 1 && v <= 127) return v;
		}
	}
	return -1;
}

std::shared_ptr<SampleData> adopt(const AudioFile &f, const std::string &name) {
	auto d = std::make_shared<SampleData>();
	d->name = name;
	d->channels = f.channels;
	d->rate = f.rate;
	d->pcm = f.data;
	return d;
}

std::string base_name(const std::string &path) {
	const size_t s = path.find_last_of("/\\");
	std::string f = s == std::string::npos ? path : path.substr(s + 1);
	const size_t d = f.find_last_of('.');
	return d == std::string::npos ? f : f.substr(0, d);
}

bool ends_with_ci(const std::string &s, const char *suffix) {
	const size_t n = std::strlen(suffix);
	if (s.size() < n) return false;
	for (size_t i = 0; i < n; i++) {
		if (std::tolower((unsigned char)s[s.size() - n + i]) != std::tolower((unsigned char)suffix[i]))
			return false;
	}
	return true;
}

} // namespace

bool multisample_from_wav(const std::string &path, MultiSample &out) {
	AudioFile f;
	if (!wav_load(path, f) || !f.valid()) return false;
	out.clear();
	out.name = base_name(path);
	auto d = adopt(f, out.name);
	out.pool.push_back(d);

	Zone z;
	z.data = d;
	z.lo_key = 0; z.hi_key = 127;
	int root = f.root_key;
	if (root < 0 || root > 127) root = key_from_name(out.name);
	z.root_key = root >= 0 ? root : 60;
	z.tune = (float)f.fine_cents * 0.01f;
	if (f.loop_start >= 0 && f.loop_end > f.loop_start) {
		z.loop_start = f.loop_start;
		z.loop_end = f.loop_end;
		z.loop_mode = 1;
	}
	out.zones.push_back(z);
	return true;
}

bool multisample_from_folder(const std::string &dir, MultiSample &out) {
	DIR *dp = ::opendir(dir.c_str());
	if (!dp) return false;
	struct Entry { std::string path, name; int key, vel; };
	std::vector<Entry> files;
	while (struct dirent *e = ::readdir(dp)) {
		if (e->d_name[0] == '.') continue;
		const std::string name = e->d_name;
		if (!ends_with_ci(name, ".wav")) continue;
		const std::string full = dir + "/" + name;
		struct stat st;
		if (::stat(full.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
		Entry en;
		en.path = full;
		en.name = base_name(name);
		en.key = key_from_name(en.name);
		en.vel = vel_from_name(en.name);
		files.push_back(en);
	}
	::closedir(dp);
	if (files.empty()) return false;

	std::sort(files.begin(), files.end(), [](const Entry &a, const Entry &b) {
		if (a.key != b.key) return a.key < b.key;
		return a.vel < b.vel;
	});

	out.clear();
	{
		const size_t s = dir.find_last_of("/\\");
		out.name = s == std::string::npos ? dir : dir.substr(s + 1);
	}

	// Group by velocity layer, then split the keyboard inside each layer at the
	// midpoint between neighbouring roots -- the standard way a library that
	// only names its roots is turned into zones that cover everything.
	std::map<int, std::vector<const Entry *>> layers;
	for (const Entry &e : files) layers[e.vel < 0 ? 127 : e.vel].push_back(&e);

	std::vector<int> vels;
	for (const auto &kv : layers) vels.push_back(kv.first);
	std::sort(vels.begin(), vels.end());

	for (size_t li = 0; li < vels.size(); li++) {
		const int lo_vel = li == 0 ? 0 : vels[li - 1] + 1;
		const int hi_vel = li + 1 == vels.size() ? 127 : vels[li];
		std::vector<const Entry *> &group = layers[vels[li]];
		for (size_t i = 0; i < group.size(); i++) {
			AudioFile f;
			if (!wav_load(group[i]->path, f) || !f.valid()) continue;
			auto d = adopt(f, group[i]->name);
			out.pool.push_back(d);

			Zone z;
			z.data = d;
			int root = f.root_key;
			if (root < 0 || root > 127) root = group[i]->key;
			z.root_key = root >= 0 ? root : 60;
			z.lo_vel = lo_vel;
			z.hi_vel = hi_vel;
			if (group[i]->key < 0) {
				z.lo_key = 0; z.hi_key = 127;
			} else {
				const int prev = i > 0 && group[i - 1]->key >= 0 ? group[i - 1]->key : -1;
				const int next = i + 1 < group.size() && group[i + 1]->key >= 0 ? group[i + 1]->key : -1;
				z.lo_key = prev < 0 ? 0 : (prev + group[i]->key) / 2 + 1;
				z.hi_key = next < 0 ? 127 : (next + group[i]->key) / 2;
			}
			z.tune = (float)f.fine_cents * 0.01f;
			if (f.loop_start >= 0 && f.loop_end > f.loop_start) {
				z.loop_start = f.loop_start;
				z.loop_end = f.loop_end;
				z.loop_mode = 1;
			}
			out.zones.push_back(z);
		}
	}
	return !out.zones.empty();
}

} // namespace flare
