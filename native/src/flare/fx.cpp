// FLARE — the effects rack.
#include "fx.h"

#include "params.h"

#include <cmath>
#include <cstring>

namespace flare {

namespace {

// Freeverb's tunings, at 44.1k, scaled to whatever rate we run at.
const int COMB_LEN[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
const int AP_LEN[4] = {556, 441, 341, 225};
const int STEREO_SPREAD = 23;

/// The three formant filters a vowel is, moved by one control.
void vowel_at(float t, float f[3], float q[3], float g[3]) {
	// A -> E -> I -> O -> U, as five corners.
	static const float F1[5] = {730, 530, 270, 570, 300};
	static const float F2[5] = {1090, 1840, 2290, 840, 870};
	static const float F3[5] = {2440, 2480, 3010, 2410, 2240};
	const float u = clampf(t, 0.0f, 1.0f) * 4.0f;
	const int a = (int)u;
	const int b = a >= 4 ? 4 : a + 1;
	const float m = u - (float)a;
	f[0] = lerpf(F1[a], F1[b], m);
	f[1] = lerpf(F2[a], F2[b], m);
	f[2] = lerpf(F3[a], F3[b], m);
	q[0] = 8.0f; q[1] = 10.0f; q[2] = 12.0f;
	g[0] = 1.0f; g[1] = 0.6f; g[2] = 0.35f;
}

} // namespace

void FxRack::prepare(double sr) {
	sr_ = sr;
	const float scale = (float)sr / 44100.0f;
	for (int c = 0; c < 2; c++) {
		cho_[c].alloc((int)(sr * 0.06) + 8);
		dly_[c].alloc((int)(sr * 4.2) + 8);
		rv_pre_[c].alloc((int)(sr * 0.3) + 8);
		for (int i = 0; i < 8; i++)
			rv_comb_[c][i].alloc((int)((float)COMB_LEN[i] * scale) + (c ? STEREO_SPREAD : 0) + 8);
		for (int i = 0; i < 4; i++)
			rv_ap_[c][i].alloc((int)((float)AP_LEN[i] * scale) + (c ? STEREO_SPREAD : 0) + 8);
		lim_look_[c].assign((size_t)std::max(8, (int)(sr * 0.002)), 0.0f);
		dly_time_[c].set_time(60.0f, sr);
		dly_time_[c].snap(0.35f * (float)sr);
	}
	reset();
}

void FxRack::reset() {
	for (int c = 0; c < 2; c++) {
		fl_[c].reset();
		for (int i = 0; i < 3; i++) form_[c][i].reset();
		dist_tone_lp_[c] = OnePole();
		dist_dc_[c] = DCBlock();
		eq_lo_[c].reset(); eq_mid_[c].reset(); eq_hi_[c].reset();
		cho_[c].clear();
		dly_[c].clear();
		rv_pre_[c].clear();
		for (int i = 0; i < 8; i++) { rv_comb_[c][i].clear(); rv_damp_[c][i] = 0.0f; }
		for (int i = 0; i < 4; i++) rv_ap_[c][i].clear();
		std::memset(ap_z_[c], 0, sizeof(ap_z_[c]));
		ap_fb_[c] = 0.0f;
		std::fill(lim_look_[c].begin(), lim_look_[c].end(), 0.0f);
	}
	form_cut_ = -1.0f;
	std::memset(eq_cache_, 0, sizeof(eq_cache_));
	comp_env_ = 0.0f;
	lim_env_ = 1.0f;
	gr_db_ = 0.0f;
	cho_phase_ = ph_phase_ = crush_phase_ = 0.0f;
	lim_w_ = 0;
}

void FxRack::process(float *L, float *R, int n, const FxParams &p, double bpm) {
	if (p.filter_on) do_filter(L, R, n, p);
	if (p.dist_on) do_dist(L, R, n, p);
	if (p.eq_on) do_eq(L, R, n, p);
	if (p.chorus_on) do_chorus(L, R, n, p);
	if (p.phaser_on) do_phaser(L, R, n, p);
	if (p.delay_on) do_delay(L, R, n, p, bpm);
	if (p.reverb_on) do_reverb(L, R, n, p);
	if (p.comp_on) do_comp(L, R, n, p); else gr_db_ = 0.0f;
	if (p.limit_on) do_limit(L, R, n, p);
}

// ---------------------------------------------------------------------------
void FxRack::do_filter(float *L, float *R, int n, const FxParams &p) {
	if (p.filter_type == 4) {
		// Formant: three peaks moved by the cutoff control, which is what a
		// vowel filter's one knob has to be.
		if (std::fabs(p.filter_cut - form_cut_) > 0.5f) {
			form_cut_ = p.filter_cut;
			const float t = std::log2(clampf(p.filter_cut, 20.0f, 20000.0f) / 20.0f) / 10.0f;
			float f[3], q[3], g[3];
			vowel_at(t, f, q, g);
			for (int c = 0; c < 2; c++)
				for (int i = 0; i < 3; i++)
					form_[c][i].peaking(f[i], 14.0f * g[i] * (0.4f + p.filter_res), q[i], sr_);
		}
		for (int i = 0; i < n; i++) {
			float a = L[i], b = R[i];
			for (int k = 0; k < 3; k++) { a = form_[0][k].next(a); b = form_[1][k].next(b); }
			L[i] = lerpf(L[i], a * 0.5f, p.filter_mix);
			R[i] = lerpf(R[i], b * 0.5f, p.filter_mix);
		}
		return;
	}
	fl_[0].set(p.filter_cut, p.filter_res, sr_);
	fl_[1].set(p.filter_cut, p.filter_res, sr_);
	for (int i = 0; i < n; i++) {
		float lp, bp, hp, out[2];
		for (int c = 0; c < 2; c++) {
			fl_[c].tick(c ? R[i] : L[i], lp, bp, hp);
			switch (p.filter_type) {
				case 0: out[c] = lp; break;
				case 1: out[c] = hp; break;
				case 2: out[c] = bp; break;
				default: out[c] = lp + hp; break;
			}
		}
		L[i] = lerpf(L[i], out[0], p.filter_mix);
		R[i] = lerpf(R[i], out[1], p.filter_mix);
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_dist(float *L, float *R, int n, const FxParams &p) {
	const float drive = 1.0f + p.dist_drive * p.dist_drive * 48.0f;
	// Loud settings get quieter on their own, so turning drive up does not
	// just turn the plugin up.
	const float comp = 1.0f / (1.0f + p.dist_drive * 2.2f);
	const float tone_hz = p.dist_tone >= 0.0f
			? lerpf(3000.0f, 18000.0f, p.dist_tone)
			: lerpf(3000.0f, 400.0f, -p.dist_tone);
	dist_tone_lp_[0].set_hz(tone_hz, sr_);
	dist_tone_lp_[1].set_hz(tone_hz, sr_);

	const int bits = (int)lerpf(16.0f, 2.0f, p.dist_drive);
	const float steps = std::pow(2.0f, (float)bits) * 0.5f;
	const float sr_div = lerpf(1.0f, 40.0f, p.dist_drive);

	for (int i = 0; i < n; i++) {
		if (p.dist_type == 6) {
			crush_phase_ += 1.0f / sr_div;
			if (crush_phase_ >= 1.0f) { crush_phase_ -= 1.0f; crush_hold_[0] = L[i]; crush_hold_[1] = R[i]; }
		}
		for (int c = 0; c < 2; c++) {
			float *buf = c ? R : L;
			const float dry = buf[i];
			float x = dry * drive;
			float y;
			switch (p.dist_type) {
				case 0: y = tanh_fast(x); break;
				case 1: y = clampf(x, -1.0f, 1.0f); break;
				case 2:
					// Asymmetric: the even harmonics are the point.
					y = x >= 0.0f ? tanh_fast(x) : tanh_fast(x * 0.7f) * 0.85f;
					break;
				case 3: {
					// Wavefolder.
					y = x;
					for (int k = 0; k < 4; k++) {
						if (y > 1.0f) y = 2.0f - y;
						else if (y < -1.0f) y = -2.0f - y;
						else break;
					}
					break;
				}
				case 4: y = soft_clip(x * 1.6f) * (1.0f + 0.4f * std::sin(x * 3.0f)); break;
				case 5: y = std::round(clampf(x, -1.0f, 1.0f) * steps) / steps; break;
				case 6: y = crush_hold_[c] * drive; y = clampf(y, -1.0f, 1.0f); break;
				default: y = std::fabs(x) * 2.0f - 1.0f; break;
			}
			y = dist_dc_[c].next(y * comp);
			y = dist_tone_lp_[c].lp(y);
			buf[i] = lerpf(dry, y, p.dist_mix);
		}
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_eq(float *L, float *R, int n, const FxParams &p) {
	const float want[7] = {p.eq_lo_g, p.eq_lo_f, p.eq_mid_g, p.eq_mid_f, p.eq_mid_q, p.eq_hi_g, p.eq_hi_f};
	bool changed = false;
	for (int i = 0; i < 7; i++) if (eq_cache_[i] != want[i]) changed = true;
	if (changed) {
		std::memcpy(eq_cache_, want, sizeof(want));
		for (int c = 0; c < 2; c++) {
			eq_lo_[c].low_shelf(p.eq_lo_f, p.eq_lo_g, sr_);
			eq_mid_[c].peaking(p.eq_mid_f, p.eq_mid_g, p.eq_mid_q, sr_);
			eq_hi_[c].high_shelf(p.eq_hi_f, p.eq_hi_g, sr_);
		}
	}
	for (int i = 0; i < n; i++) {
		L[i] = eq_hi_[0].next(eq_mid_[0].next(eq_lo_[0].next(L[i])));
		R[i] = eq_hi_[1].next(eq_mid_[1].next(eq_lo_[1].next(R[i])));
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_chorus(float *L, float *R, int n, const FxParams &p) {
	const float inc = p.chorus_rate / (float)sr_;
	const float base = 0.012f * (float)sr_;
	const float sweep = p.chorus_depth * 0.008f * (float)sr_;
	const int voices = p.chorus_voices < 2 ? 2 : (p.chorus_voices > 6 ? 6 : p.chorus_voices);
	const float norm = 1.0f / (float)voices;

	for (int i = 0; i < n; i++) {
		cho_phase_ += inc;
		if (cho_phase_ >= 1.0f) cho_phase_ -= 1.0f;
		float wet[2] = {0.0f, 0.0f};
		for (int v = 0; v < voices; v++) {
			const float off = (float)v / (float)voices;
			const float lfo_l = std::sin(TWO_PI_F * (cho_phase_ + off));
			// The right side rides the same LFO a quarter turn away, which is
			// where the width comes from without a second set of delay lines.
			const float lfo_r = std::sin(TWO_PI_F * (cho_phase_ + off + 0.25f * p.chorus_width));
			wet[0] += cho_[0].read(base + sweep * (0.5f + 0.5f * lfo_l));
			wet[1] += cho_[1].read(base + sweep * (0.5f + 0.5f * lfo_r));
		}
		wet[0] *= norm;
		wet[1] *= norm;
		cho_[0].write(L[i] + wet[0] * p.chorus_fb);
		cho_[1].write(R[i] + wet[1] * p.chorus_fb);
		L[i] = lerpf(L[i], wet[0], p.chorus_mix);
		R[i] = lerpf(R[i], wet[1], p.chorus_mix);
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_phaser(float *L, float *R, int n, const FxParams &p) {
	const float inc = p.phaser_rate / (float)sr_;
	const int stages = p.phaser_stages < 2 ? 2 : (p.phaser_stages > 12 ? 12 : p.phaser_stages);
	for (int i = 0; i < n; i++) {
		ph_phase_ += inc;
		if (ph_phase_ >= 1.0f) ph_phase_ -= 1.0f;
		for (int c = 0; c < 2; c++) {
			const float off = c ? p.phaser_spread * 0.5f : 0.0f;
			const float lfo = 0.5f + 0.5f * std::sin(TWO_PI_F * (ph_phase_ + off));
			const float hz = p.phaser_centre * std::pow(2.0f, (lfo * 2.0f - 1.0f) * p.phaser_depth * 3.0f);
			const float g = std::tan(PI_F * clampf(hz, 20.0f, (float)sr_ * 0.45f) / (float)sr_);
			const float a = (g - 1.0f) / (g + 1.0f);
			float *buf = c ? R : L;
			const float dry = buf[i];
			float x = dry + ap_fb_[c] * p.phaser_fb;
			for (int s = 0; s < stages; s++) {
				const float y = a * x + ap_z_[c][s];
				ap_z_[c][s] = flush(x - a * y);
				x = y;
			}
			ap_fb_[c] = flush(x);
			buf[i] = lerpf(dry, (dry + x) * 0.5f, p.phaser_mix);
		}
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_delay(float *L, float *R, int n, const FxParams &p, double bpm) {
	float samples;
	if (p.delay_sync) {
		const double beats = (double)sync_beats(p.delay_div);
		samples = (float)(beats * 60.0 / std::max(20.0, bpm) * sr_);
	} else {
		samples = p.delay_time * 0.001f * (float)sr_;
	}
	samples = clampf(samples, 8.0f, (float)(dly_[0].size - 4));
	// Ping-pong runs one side half a beat behind the other.
	dly_time_[0].to(samples);
	dly_time_[1].to(samples * lerpf(1.0f, 0.5f, p.delay_ping));

	dly_lp_[0].set_hz(p.delay_hicut, sr_);
	dly_lp_[1].set_hz(p.delay_hicut, sr_);
	dly_hp_[0].set_hz(p.delay_locut, sr_);
	dly_hp_[1].set_hz(p.delay_locut, sr_);
	const float fb = clampf(p.delay_fb, 0.0f, 1.05f);

	for (int i = 0; i < n; i++) {
		const float tl = dly_time_[0].next(), tr = dly_time_[1].next();
		float wl = dly_[0].read(tl);
		float wr = dly_[1].read(tr);
		wl = dly_hp_[0].hp(dly_lp_[0].lp(wl));
		wr = dly_hp_[1].hp(dly_lp_[1].lp(wr));
		// Crossed feedback is what makes it bounce; straight feedback is a
		// plain stereo delay. The control moves between the two.
		const float in_l = L[i] + lerpf(wl, wr, p.delay_ping) * fb;
		const float in_r = R[i] + lerpf(wr, wl, p.delay_ping) * fb;
		dly_[0].write(in_l);
		dly_[1].write(in_r);
		const float mid = (wl + wr) * 0.5f;
		const float sl = lerpf(mid, wl, p.delay_width);
		const float sr2 = lerpf(mid, wr, p.delay_width);
		L[i] = lerpf(L[i], sl, p.delay_mix);
		R[i] = lerpf(R[i], sr2, p.delay_mix);
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_reverb(float *L, float *R, int n, const FxParams &p) {
	const float room = 0.72f + p.reverb_size * 0.276f;
	const float damp = p.reverb_damp * 0.4f;
	const float pre = clampf(p.reverb_predelay * 0.001f * (float)sr_, 1.0f, (float)(rv_pre_[0].size - 4));
	rv_hp_[0].set_hz(p.reverb_locut, sr_);
	rv_hp_[1].set_hz(p.reverb_locut, sr_);
	const float ap_g = 0.3f + p.reverb_diffuse * 0.4f;

	for (int i = 0; i < n; i++) {
		const float in = (L[i] + R[i]) * 0.5f * 0.015f;
		rv_pre_[0].write(in);
		const float x = rv_pre_[0].read(pre);

		float wet[2] = {0.0f, 0.0f};
		for (int c = 0; c < 2; c++) {
			for (int k = 0; k < 8; k++) {
				const float d = (float)(rv_comb_[c][k].size - 2);
				const float y = rv_comb_[c][k].read(d);
				rv_damp_[c][k] = flush(y * (1.0f - damp) + rv_damp_[c][k] * damp);
				rv_comb_[c][k].write(x + rv_damp_[c][k] * room);
				wet[c] += y;
			}
			for (int k = 0; k < 4; k++) {
				const float d = (float)(rv_ap_[c][k].size - 2);
				const float y = rv_ap_[c][k].read(d);
				const float v = wet[c] + y * ap_g;
				rv_ap_[c][k].write(v);
				wet[c] = y - v * ap_g;
			}
			wet[c] = rv_hp_[c].hp(wet[c]);
		}
		const float mid = (wet[0] + wet[1]) * 0.5f;
		L[i] = lerpf(L[i], lerpf(mid, wet[0], p.reverb_width), p.reverb_mix);
		R[i] = lerpf(R[i], lerpf(mid, wet[1], p.reverb_width), p.reverb_mix);
	}
}

// ---------------------------------------------------------------------------
void FxRack::do_comp(float *L, float *R, int n, const FxParams &p) {
	const float thr = db_to_gain(p.comp_thresh);
	const float ratio = std::max(1.0f, p.comp_ratio);
	const float atk = 1.0f - std::exp(-1.0f / std::max(1.0f, p.comp_attack * 0.001f * (float)sr_));
	const float rel = 1.0f - std::exp(-1.0f / std::max(1.0f, p.comp_release * 0.001f * (float)sr_));
	const float makeup = db_to_gain(p.comp_makeup);
	float worst = 0.0f;

	for (int i = 0; i < n; i++) {
		const float det = std::max(std::fabs(L[i]), std::fabs(R[i]));
		comp_env_ += (det - comp_env_) * (det > comp_env_ ? atk : rel);
		float g = 1.0f;
		if (comp_env_ > thr && comp_env_ > 1e-6f) {
			const float over_db = gain_to_db(comp_env_ / thr);
			const float cut_db = over_db - over_db / ratio;
			g = db_to_gain(-cut_db);
			worst = std::max(worst, cut_db);
		}
		L[i] *= g * makeup;
		R[i] *= g * makeup;
	}
	gr_db_ = worst;
}

// ---------------------------------------------------------------------------
void FxRack::do_limit(float *L, float *R, int n, const FxParams &p) {
	const float ceil = db_to_gain(p.limit_ceiling);
	const int look = (int)lim_look_[0].size();
	for (int i = 0; i < n; i++) {
		// A short look-ahead so the gain is already down when the peak lands,
		// rather than a moment after it.
		const float dl = lim_look_[0][(size_t)lim_w_];
		const float dr = lim_look_[1][(size_t)lim_w_];
		lim_look_[0][(size_t)lim_w_] = L[i];
		lim_look_[1][(size_t)lim_w_] = R[i];
		lim_w_ = (lim_w_ + 1) % look;

		const float peak = std::max(std::fabs(L[i]), std::fabs(R[i]));
		const float want = peak > ceil ? ceil / peak : 1.0f;
		if (want < lim_env_) lim_env_ = want;                   // instant down
		else lim_env_ += (want - lim_env_) * 0.0006f;           // slow back up
		L[i] = clampf(dl * lim_env_, -ceil, ceil);
		R[i] = clampf(dr * lim_env_, -ceil, ceil);
	}
}

} // namespace flare
