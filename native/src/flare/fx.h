// FLARE — the effects rack.
//
// A fixed chain in a fixed order, the way the preset-driven synths people
// reach for do it: every preset gets the same nine slots, so a macro pointed
// at "reverb mix" means the same thing in every one of them.
#pragma once

#include "dsp.h"

#include <vector>

namespace flare {

struct FxParams {
	// Filter
	bool filter_on = false;
	int filter_type = 0;
	float filter_cut = 20000.0f, filter_res = 0.1f, filter_mix = 1.0f;
	// Distortion
	bool dist_on = false;
	int dist_type = 0;
	float dist_drive = 0.3f, dist_tone = 0.0f, dist_mix = 1.0f;
	// EQ
	bool eq_on = false;
	float eq_lo_g = 0, eq_lo_f = 120, eq_mid_g = 0, eq_mid_f = 1200, eq_mid_q = 1.0f;
	float eq_hi_g = 0, eq_hi_f = 6000;
	// Chorus
	bool chorus_on = false;
	float chorus_rate = 0.6f, chorus_depth = 0.4f, chorus_width = 0.8f;
	float chorus_fb = 0.0f, chorus_mix = 0.35f;
	int chorus_voices = 3;
	// Phaser
	bool phaser_on = false;
	float phaser_rate = 0.3f, phaser_depth = 0.6f, phaser_centre = 800.0f;
	float phaser_fb = 0.4f, phaser_spread = 0.5f, phaser_mix = 0.5f;
	int phaser_stages = 6;
	// Delay
	bool delay_on = false, delay_sync = true;
	float delay_time = 350.0f, delay_fb = 0.4f, delay_ping = 0.0f;
	float delay_locut = 180.0f, delay_hicut = 8000.0f, delay_width = 1.0f, delay_mix = 0.25f;
	int delay_div = 7;
	// Reverb
	bool reverb_on = false;
	float reverb_size = 0.6f, reverb_damp = 0.4f, reverb_width = 1.0f;
	float reverb_predelay = 12.0f, reverb_locut = 200.0f, reverb_diffuse = 0.7f, reverb_mix = 0.25f;
	// Compressor
	bool comp_on = false;
	float comp_thresh = -12.0f, comp_ratio = 3.0f, comp_attack = 8.0f;
	float comp_release = 120.0f, comp_makeup = 0.0f;
	// Limiter
	bool limit_on = true;
	float limit_ceiling = -0.3f;
};

class FxRack {
public:
	void prepare(double sr);
	void reset();
	/// In place, stereo. `bpm` drives the synced delay.
	void process(float *L, float *R, int n, const FxParams &p, double bpm);
	/// How much the compressor is pulling down, in dB, for a meter.
	float gain_reduction() const { return gr_db_; }

private:
	double sr_ = 48000.0;
	float gr_db_ = 0.0f;

	// Filter
	SVF fl_[2];
	Biquad form_[2][3];
	float form_cut_ = -1.0f;
	// Distortion
	OnePole dist_tone_lp_[2];
	DCBlock dist_dc_[2];
	float crush_hold_[2] = {0, 0};
	float crush_phase_ = 0.0f;
	// EQ
	Biquad eq_lo_[2], eq_mid_[2], eq_hi_[2];
	float eq_cache_[7] = {0};
	// Chorus
	DelayLine cho_[2];
	float cho_phase_ = 0.0f;
	// Phaser
	float ap_z_[2][12] = {{0}};
	float ap_fb_[2] = {0, 0};
	float ph_phase_ = 0.0f;
	// Delay
	DelayLine dly_[2];
	OnePole dly_lp_[2], dly_hp_[2];
	Smoothed dly_time_[2];
	// Reverb — eight combs and four allpasses a side, Schroeder/Freeverb shape
	DelayLine rv_comb_[2][8], rv_ap_[2][4], rv_pre_[2];
	float rv_damp_[2][8] = {{0}};
	OnePole rv_hp_[2];
	// Compressor
	float comp_env_ = 0.0f;
	// Limiter
	float lim_env_ = 0.0f;
	std::vector<float> lim_look_[2];
	int lim_w_ = 0;

	void do_filter(float *L, float *R, int n, const FxParams &p);
	void do_dist(float *L, float *R, int n, const FxParams &p);
	void do_eq(float *L, float *R, int n, const FxParams &p);
	void do_chorus(float *L, float *R, int n, const FxParams &p);
	void do_phaser(float *L, float *R, int n, const FxParams &p);
	void do_delay(float *L, float *R, int n, const FxParams &p, double bpm);
	void do_reverb(float *L, float *R, int n, const FxParams &p);
	void do_comp(float *L, float *R, int n, const FxParams &p);
	void do_limit(float *L, float *R, int n, const FxParams &p);
};

} // namespace flare
