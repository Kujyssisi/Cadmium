// Cadmium — Prism: an image played as sound.
//
// The picture is a spectrogram read the way one is drawn: left to right is
// time, bottom to top is pitch, and how bright a pixel is decides how loud that
// partial is at that moment. A bank of sine oscillators, one per row, is what
// turns it back into sound.
#include "plugin.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace cd {

class Prism : public Plug {
	enum { P_SCAN, P_SYNC, P_DIV, P_LOW, P_OCTAVES, P_TILT, P_CONTRAST, P_FLOOR,
		P_STEREO, P_BLUR, P_DIRECTION, P_LOOP, P_KEYTRACK, P_ATTACK, P_RELEASE,
		P_VOL };

	// The picture, as bands x columns of 0..1 brightness, plus a left/right
	// balance per cell taken from the colour.
	std::vector<float> amp;
	std::vector<float> pan;
	int bands = 0, cols = 0;
	std::string image_path;

	struct Voice {
		VoiceHead h;
		double pos = 0.0;         // column, fractional
		float env = 0.0f;
		std::vector<float> phase;
		std::vector<float> level;  // smoothed per band, so columns do not click
		bool finished = false;
	};
	static const int VOICES = 4;
	Voice v[VOICES];
	uint64_t age = 0;
	// What the panel draws: the column being played, 0..1.
	float vis_pos = 0.0f;

public:
	void prepare() override {
		for (auto &x : v) {
			x = Voice();
			x.phase.assign((size_t)std::max(1, bands), 0.0f);
			x.level.assign((size_t)std::max(1, bands), 0.0f);
		}
	}
	void reset() override { prepare(); }

	bool set_string(const std::string &key, const std::string &value) override {
		if (key == "image") {
			image_path = value;
			return true;
		}
		return false;
	}
	std::string get_string(const std::string &key) const override {
		return key == "image" ? image_path : std::string();
	}

	/// The host decodes the picture -- it has an image loader and this does not
	/// -- and hands over `bands * cols` brightness values followed by the same
	/// many balance values.
	bool set_data(const std::string &key, const float *data, int n) override {
		if (key != "image" || n < 3) return false;
		const int w = (int)data[0];
		const int h = (int)data[1];
		const bool has_pan = data[2] > 0.5f;
		const int need = 3 + w * h * (has_pan ? 2 : 1);
		if (w <= 0 || h <= 0 || n < need) return false;
		cols = w;
		bands = h;
		amp.assign(data + 3, data + 3 + w * h);
		if (has_pan) {
			pan.assign(data + 3 + w * h, data + 3 + w * h * 2);
		} else {
			pan.assign((size_t)(w * h), 0.0f);
		}
		for (auto &x : v) {
			x.phase.assign((size_t)bands, 0.0f);
			x.level.assign((size_t)bands, 0.0f);
		}
		return true;
	}

	void note_on(int key, float vel, int id) override {
		if (bands <= 0) return;
		const int i = alloc_voice(v, VOICES, age);
		Voice &x = v[i];
		x.h.active = true; x.h.held = true; x.h.key = key; x.h.id = id;
		x.h.vel = vel; x.h.age = age++;
		x.pos = pi(P_DIRECTION) == 1 ? (double)(cols - 1) : 0.0;
		x.env = 0.0f;
		x.finished = false;
		std::fill(x.level.begin(), x.level.end(), 0.0f);
		for (size_t b = 0; b < x.phase.size(); b++) {
			// Random start phases: every partial starting at zero makes a click
			// and a comb.
			x.phase[b] = (float)((b * 2654435761u) % 1024u) / 1024.0f;
		}
	}
	void note_off(int key, int id) override {
		for (auto &x : v) {
			if (x.h.active && x.h.held && x.h.key == key && (id < 0 || x.h.id == id)) x.h.held = false;
		}
	}
	void all_notes_off() override { for (auto &x : v) x.h.active = false; }
	int active_voices() const override {
		int n = 0;
		for (const auto &x : v) if (x.h.active) n++;
		return n;
	}
	float tail() const override { return 4.0f; }

	int aux(int what, float *out, int max) override {
		if (what == 0 && max >= 3) {
			out[0] = vis_pos;
			out[1] = (float)cols;
			out[2] = (float)bands;
			return 3;
		}
		return 0;
	}

	void process(float *L, float *R, int n) override {
		if (bands <= 0 || cols <= 0) {
			std::fill(L, L + n, 0.0f);
			std::fill(R, R + n, 0.0f);
			return;
		}
		const float low = p(P_LOW);
		const float octaves = p(P_OCTAVES);
		const float tilt = p(P_TILT);
		const float contrast = p(P_CONTRAST);
		const float floor_db = p(P_FLOOR);
		const float floor_lin = db_to_gain(floor_db);
		const float stereo = p(P_STEREO);
		const bool loop = pb(P_LOOP);
		const int dir = pi(P_DIRECTION);
		const float keytrack = p(P_KEYTRACK);
		const float vol = p(P_VOL) / std::sqrt((float)bands);
		// Columns per second, either free or locked to the tempo.
		double cps;
		if (pb(P_SYNC)) {
			const double bars = (double)sync_beats(pi(P_DIV));
			cps = (double)cols / std::max(0.01, bars * 60.0 / std::max(20.0, bpm));
		} else {
			cps = (double)cols / std::max(0.02f, p(P_SCAN));
		}
		const double step = cps / sr;
		const float atk = ADSR::rate(sr, p(P_ATTACK));
		const float rel = ADSR::rate(sr, p(P_RELEASE));
		// Smoothing between columns: without it every column edge is a click.
		const float smooth = 1.0f - std::exp(-1.0f / (float)(sr * (double)std::max(0.0005f, p(P_BLUR) * 0.05f)));

		std::fill(L, L + n, 0.0f);
		std::fill(R, R + n, 0.0f);

		for (auto &x : v) {
			if (!x.h.active) continue;
			// Key tracks the whole picture up and down, so it plays like an
			// instrument rather than a one-shot.
			const float shift = std::pow(2.0f, ((float)x.h.key - 60.0f) / 12.0f * keytrack);
			for (int i = 0; i < n; i++) {
				const float want = x.h.held && !x.finished ? 1.0f : 0.0f;
				x.env += (want - x.env) * (want > x.env ? atk : rel);
				if (x.env < 0.0002f && want == 0.0f) { x.h.active = false; break; }

				// Where in the picture we are, and the two columns either side.
				const double c = x.pos;
				const int c0 = std::max(0, std::min(cols - 1, (int)c));
				const int c1 = std::max(0, std::min(cols - 1, c0 + 1));
				const float cf = (float)(c - (double)c0);
				float l = 0.0f, r = 0.0f;
				for (int b = 0; b < bands; b++) {
					const float a0 = amp[(size_t)b * (size_t)cols + (size_t)c0];
					const float a1 = amp[(size_t)b * (size_t)cols + (size_t)c1];
					float a = a0 + (a1 - a0) * cf;
					// Contrast pushes the quiet parts of the picture down and
					// the bright parts up, which is what makes it musical
					// rather than a wash.
					a = std::pow(a, 1.0f + contrast * 3.0f);
					if (a < floor_lin) a = 0.0f;
					x.level[(size_t)b] += (a - x.level[(size_t)b]) * smooth;
					const float lv = x.level[(size_t)b];
					if (lv < 1e-5f) continue;
					// Rows are spread over the chosen span of octaves.
					const float t = bands > 1 ? (float)b / (float)(bands - 1) : 0.0f;
					const float hz = low * std::pow(2.0f, t * octaves) * shift;
					if (hz >= (float)sr * 0.48f) continue;
					const float inc = hz / (float)sr;
					float ph = x.phase[(size_t)b] + inc;
					if (ph >= 1.0f) ph -= std::floor(ph);
					x.phase[(size_t)b] = ph;
					// Tilt is a gentle slope across the spectrum, for taming
					// the top of a bright picture.
					const float slope = std::pow(10.0f, -tilt * t * 0.05f);
					const float s = std::sin((float)TAU * ph) * lv * slope;
					const float pn = pan[(size_t)b * (size_t)cols + (size_t)c0] * stereo;
					l += s * std::sqrt(0.5f * (1.0f - pn));
					r += s * std::sqrt(0.5f * (1.0f + pn));
				}
				const float g = x.env * (0.35f + x.h.vel * 0.65f) * vol;
				L[i] += l * g;
				R[i] += r * g;

				x.pos += dir == 1 ? -step : step;
				if (dir == 2) {
					// Back and forth.
					if (x.pos >= (double)(cols - 1)) { x.pos = (double)(cols - 1); }
				}
				if (x.pos >= (double)cols || x.pos < 0.0) {
					if (loop) {
						x.pos = dir == 1 ? (double)(cols - 1) : 0.0;
					} else {
						x.pos = std::max(0.0, std::min((double)(cols - 1), x.pos));
						x.finished = true;
					}
				}
			}
			vis_pos = cols > 1 ? (float)(x.pos / (double)(cols - 1)) : 0.0f;
		}
		for (int i = 0; i < n; i++) {
			L[i] = tanh_fast(L[i]);
			R[i] = tanh_fast(R[i]);
		}
	}
};

static Plug *make_prism() { return new Prism(); }

void register_spectral(std::vector<PlugDesc> &out) {
	out.push_back({"cd.prism", "Prism", "Cadmium", "Synth", true, UI_PRISM, {
		{"scan", "Scan", 0.05f, 30, 4, P_SEC, "Scan", nullptr, 0.4f},
		{"sync", "Sync", 0, 1, 0, P_BOOL, "Scan", nullptr, 1},
		{"div", "Length", 0, 12, 11, P_CHOICE, "Scan", SYNC_NAMES, 1},
		{"low", "Lowest", 20, 2000, 80, P_HZ, "Range", nullptr, 0.3f},
		{"octaves", "Octaves", 1, 9, 6, P_PCT, "Range", nullptr, 1},
		{"tilt", "Tilt", 0, 24, 6, P_DB, "Range", nullptr, 1},
		{"contrast", "Contrast", 0, 1, 0.35f, P_PCT, "Picture", nullptr, 1},
		{"floor", "Floor", -90, -6, -48, P_DB, "Picture", nullptr, 1},
		{"stereo", "Colour Width", 0, 1, 0.6f, P_PCT, "Picture", nullptr, 1},
		{"blur", "Smear", 0.01f, 1, 0.12f, P_PCT, "Picture", nullptr, 1},
		{"direction", "Direction", 0, 1, 0, P_CHOICE, "Scan", "Forward|Reverse", 1},
		{"loop", "Loop", 0, 1, 1, P_BOOL, "Scan", nullptr, 1},
		{"keytrack", "Key Follow", 0, 1, 1, P_PCT, "Range", nullptr, 1},
		{"attack", "Attack", 0.001f, 4, 0.02f, P_SEC, "Envelope", nullptr, 0.4f},
		{"release", "Release", 0.005f, 6, 0.4f, P_SEC, "Envelope", nullptr, 0.4f},
		{"vol", "Volume", 0, 2, 1.0f, P_PCT, "Output", nullptr, 1},
	}, make_prism});
}

} // namespace cd
