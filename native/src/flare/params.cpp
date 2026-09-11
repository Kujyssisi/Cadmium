// FLARE — the parameter table, built once.
#include "params.h"

#include <cmath>
#include <cstdio>
#include <map>

namespace flare {

const char *MOD_SRC_NAMES =
	"--|Env 1 (Amp)|Env 2 (Filter)|Env 3|Env 4|LFO 1|LFO 2|LFO 3|"
	"Velocity|Key track|Mod wheel|Aftertouch|Pitch bend|Expression|"
	"Random|Random (uni)|Gate|Note order|"
	"Macro 1|Macro 2|Macro 3|Macro 4|Macro 5|Macro 6|Macro 7|Macro 8";

const char *MOD_DST_NAMES =
	"--|"
	"Pitch|A Pitch|B Pitch|C Pitch|"
	"A Level|B Level|C Level|Sub Level|Noise Level|"
	"A Position|B Position|C Position|"
	"A Warp|B Warp|C Warp|"
	"A Pan|B Pan|C Pan|"
	"A Fine|B Fine|C Fine|"
	"A Detune|FM Amount|Ring Mod|"
	"F1 Cutoff|F1 Reso|F1 Drive|F2 Cutoff|F2 Reso|F2 Drive|"
	"Amp|Pan|Sample Start|"
	"LFO 1 Rate|LFO 2 Rate|LFO 3 Rate|"
	"LFO 1 Depth|LFO 2 Depth|LFO 3 Depth|"
	"Env 2 Decay|Env 1 Decay|Env 1 Attack|"
	"FX Filter Cutoff|FX Drive|FX Chorus Depth|FX Phaser Rate|"
	"FX Delay Mix|FX Reverb Mix|FX Delay Feedback";

bool mod_dst_is_global(int dst) { return dst >= MD_FX_FILTER_CUT && dst < MD_COUNT; }

const char *SYNC_DIV_NAMES =
	"1/64|1/32T|1/32|1/16T|1/16|1/16.|1/8T|1/8|1/8.|1/4T|1/4|1/4.|1/2|1 bar|2 bars";

float sync_beats(int i) {
	static const float t[SYNC_DIV_COUNT] = {
		0.0625f, 0.08333f, 0.125f, 0.16667f, 0.25f, 0.375f, 0.33333f,
		0.5f, 0.75f, 0.66667f, 1.0f, 1.5f, 2.0f, 4.0f, 8.0f
	};
	return t[i < 0 ? 0 : (i >= SYNC_DIV_COUNT ? SYNC_DIV_COUNT - 1 : i)];
}

namespace {

// The wave lists. Analogue shapes first so an index means the same thing
// whichever source a part is set to; the wavetables that follow are the
// built-in bank, and a preset that loads its own table appends to it.
// One list, not two. A part used to carry a "source" that chose between an
// analogue bank and a wavetable bank and a "wave" that indexed whichever was
// current, which meant the same number named two different shapes and the
// choice list a host drew was right half the time. The banks are laid end to
// end instead: an index means one thing.
const char *ANALOG_WAVES =
	"Sine|Triangle|Saw|Square|Pulse 25|Pulse 12|Super Saw|Super Square|"
	"Double Saw|Half Saw|Trapezoid|Exponential|Log Saw|Rounded Square|"
	"Sine x2|Sine x3|Bright Sine|Organ|Hollow|Nasal";

// The morphing tables, in the order WaveBank builds them. Named here so the
// "Wave" choice reads correctly when a part is set to Wavetable.
const char *WAVETABLES =
	"Basic Shapes|Formant Sweep|Vocal|Harmonics|Additive Comb|Bell Partials|"
	"Digital Fold|Metallic|Reso Sweep|PWM|Sync Sweep|Growl|Glass|Wire|"
	"Chime|Reed|Vowel A-E-I|Fifths|Detuned Stack|Noise Bands|"
	// Appended, never inserted: a preset stores the index, so putting a new
	// table in the middle would silently repoint every patch after it.
	"Piano String|Tine|Struck Bar|Plucked String|Pipe";

/// The analogue shapes then the morphing tables, which is the order WaveBank
/// builds them in. WT_FIRST is where the second half starts.
std::string all_waves() {
	static const std::string s = std::string(ANALOG_WAVES) + "|" + WAVETABLES;
	return s;
}

struct Build {
	std::vector<ParamInfo> v;
	std::string page, group;

	void P(const char *id, const char *name, float mn, float mx, float df,
			int kind, float skew = 1.0f, const char *choices = "", int steps = 0) {
		ParamInfo p;
		p.id = id; p.name = name; p.group = group; p.page = page;
		p.min = mn; p.max = mx; p.def = df; p.kind = kind; p.skew = skew;
		p.choices = choices; p.steps = steps;
		v.push_back(p);
	}
	/// A choice, sized from its own list so adding a wave never means also
	/// remembering to bump a number somewhere else.
	void C(const char *id, const char *name, const char *choices, int def) {
		int n = 1;
		for (const char *c = choices; *c; c++) if (*c == '|') n++;
		ParamInfo p;
		p.id = id; p.name = name; p.group = group; p.page = page;
		p.min = 0; p.max = (float)(n - 1); p.def = (float)def;
		p.kind = K_CHOICE; p.choices = choices; p.steps = n - 1;
		v.push_back(p);
	}
	void B(const char *id, const char *name, bool def) {
		ParamInfo p;
		p.id = id; p.name = name; p.group = group; p.page = page;
		p.min = 0; p.max = 1; p.def = def ? 1.0f : 0.0f; p.kind = K_BOOL; p.steps = 1;
		v.push_back(p);
	}
	std::string tag(const char *fmt, int n) {
		char b[96];
		std::snprintf(b, sizeof(b), fmt, n);
		return std::string(b);
	}
};

Layout g_layout;
std::vector<ParamInfo> g_params;
std::map<std::string, int> g_index;

void build_master(Build &b) {
	b.page = "Main"; b.group = "Master";
	b.P("master.vol", "Volume", -60.0f, 12.0f, -6.0f, K_DB);
	b.P("master.pan", "Pan", -1.0f, 1.0f, 0.0f, K_PAN);
	b.C("master.mode", "Voice Mode", "Poly|Mono|Legato|Unison Mono", 0);
	b.P("master.poly", "Polyphony", 1.0f, 32.0f, 16.0f, K_INT, 1.0f, "", 31);
	b.P("master.glide", "Glide", 0.0f, 2000.0f, 0.0f, K_MS, 0.4f);
	b.C("master.glide_mode", "Glide Mode", "Always|Legato Only|Off", 1);
	b.P("master.bend_up", "Bend Up", 0.0f, 24.0f, 2.0f, K_SEMI, 1.0f, "", 24);
	b.P("master.bend_dn", "Bend Down", 0.0f, 24.0f, 2.0f, K_SEMI, 1.0f, "", 24);
	b.P("master.octave", "Octave", -4.0f, 4.0f, 0.0f, K_INT, 1.0f, "", 8);
	b.P("master.semi", "Semitone", -12.0f, 12.0f, 0.0f, K_SEMI, 1.0f, "", 24);
	b.P("master.tune", "Fine Tune", -100.0f, 100.0f, 0.0f, K_CENT);
	b.P("master.vel_vol", "Velocity", 0.0f, 1.0f, 0.7f, K_PCT);
	b.P("master.drift", "Analog Drift", 0.0f, 1.0f, 0.15f, K_PCT);
	b.C("master.quality", "Quality", "Draft|Normal|High|Ultra", 1);
	b.B("master.mono_retrig", "Mono Retrigger", true);
}

void build_parts(Build &b) {
	static const char *LETTER[PART_N] = {"A", "B", "C"};
	static const float DEF_LEVEL[PART_N] = {0.0f, -90.0f, -90.0f};
	static std::vector<std::string> ids;
	static std::vector<std::string> names;
	static std::vector<std::string> groups;
	ids.reserve(PART_N * PRT_COUNT * 1);
	for (int n = 0; n < PART_N; n++) {
		b.page = "Osc";
		groups.push_back(std::string("Osc ") + LETTER[n]);
		b.group = groups.back();
		const std::string pre = std::string("osc") + (char)('a' + n) + ".";
		auto id = [&](const char *s) {
			ids.push_back(pre + s);
			return ids.back().c_str();
		};
		auto nm = [&](const char *s) {
			names.push_back(std::string(LETTER[n]) + " " + s);
			return names.back().c_str();
		};
		b.B(id("on"), nm("On"), n == 0);
		b.C(id("src"), nm("Source"), "Wave|Sample|Multisample|Noise", 0);
		b.C(id("wave"), nm("Wave"), all_waves().c_str(), 2);
		b.P(id("pos"), nm("Position"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.P(id("warp"), nm("Warp"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.C(id("warp_mode"), nm("Warp Mode"), "Off|Pulse Width|Sync|Bend|Mirror|Fold|Quantize|Phase Dist", 0);
		b.P(id("level"), nm("Level"), -90.0f, 12.0f, DEF_LEVEL[n], K_DB);
		b.P(id("pan"), nm("Pan"), -1.0f, 1.0f, 0.0f, K_PAN);
		b.P(id("octave"), nm("Octave"), -4.0f, 4.0f, 0.0f, K_INT, 1.0f, "", 8);
		b.P(id("semi"), nm("Semi"), -24.0f, 24.0f, 0.0f, K_SEMI, 1.0f, "", 48);
		b.P(id("fine"), nm("Fine"), -100.0f, 100.0f, 0.0f, K_CENT);
		b.P(id("unison"), nm("Unison"), 1.0f, 9.0f, 1.0f, K_INT, 1.0f, "", 8);
		b.P(id("detune"), nm("Detune"), 0.0f, 1.0f, 0.2f, K_PCT);
		b.P(id("spread"), nm("Spread"), 0.0f, 1.0f, 0.6f, K_PCT);
		b.P(id("blend"), nm("Blend"), 0.0f, 1.0f, 0.75f, K_PCT);
		b.P(id("phase"), nm("Phase"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.P(id("phase_rand"), nm("Phase Rand"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.B(id("keytrack"), nm("Key Track"), true);
		b.P(id("start"), nm("Start"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.C(id("loop_mode"), nm("Loop"), "One Shot|Forward|Ping-Pong|Sustain Loop", 1);
		b.P(id("fm"), nm("FM"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.P(id("rm"), nm("Ring Mod"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.C(id("filter"), nm("Filter Route"), "Filter 1|Filter 2|Both|Bypass", 0);
		b.P(id("vel"), nm("Vel Sens"), 0.0f, 1.0f, 0.0f, K_PCT);
	}
}

void build_sub_noise(Build &b) {
	b.page = "Osc"; b.group = "Sub";
	b.B("sub.on", "Sub On", false);
	b.C("sub.wave", "Sub Wave", "Sine|Triangle|Square|Saw|Pulse", 0);
	b.P("sub.level", "Sub Level", -90.0f, 12.0f, -12.0f, K_DB);
	b.P("sub.octave", "Sub Octave", -3.0f, 0.0f, -1.0f, K_INT, 1.0f, "", 3);
	b.P("sub.pan", "Sub Pan", -1.0f, 1.0f, 0.0f, K_PAN);

	b.group = "Noise";
	b.B("noise.on", "Noise On", false);
	b.C("noise.type", "Noise Type", "White|Pink|Brown|Blue|Vinyl|Digital", 1);
	b.P("noise.level", "Noise Level", -90.0f, 12.0f, -18.0f, K_DB);
	b.P("noise.pan", "Noise Pan", -1.0f, 1.0f, 0.0f, K_PAN);
	b.P("noise.cut", "Noise Colour", 20.0f, 20000.0f, 20000.0f, K_HZ, 0.3f);
}

void build_filters(Build &b) {
	static const char *TYPES =
		"LP 12|LP 24|LP Ladder|HP 12|HP 24|BP 12|BP 24|Notch|Peak|"
		"Low Shelf|High Shelf|Comb+|Comb-|Formant|Phaser|Bypass";
	static std::vector<std::string> ids, names, groups;
	for (int n = 0; n < FILTER_N; n++) {
		b.page = "Filter";
		groups.push_back("Filter " + std::to_string(n + 1));
		b.group = groups.back();
		const std::string pre = "filter" + std::to_string(n + 1) + ".";
		auto id = [&](const char *s) { ids.push_back(pre + s); return ids.back().c_str(); };
		auto nm = [&](const char *s) {
			names.push_back("F" + std::to_string(n + 1) + " " + s);
			return names.back().c_str();
		};
		b.B(id("on"), nm("On"), n == 0);
		b.C(id("type"), nm("Type"), TYPES, n == 0 ? 1 : 3);
		b.P(id("cutoff"), nm("Cutoff"), 20.0f, 20000.0f, n == 0 ? 20000.0f : 20.0f, K_HZ, 0.3f);
		b.P(id("reso"), nm("Reso"), 0.0f, 1.0f, 0.15f, K_PCT);
		b.P(id("drive"), nm("Drive"), 0.0f, 24.0f, 0.0f, K_DB);
		b.P(id("keytrack"), nm("Key Track"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.P(id("env"), nm("Env Amount"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.C(id("env_src"), nm("Env Source"), "Env 1|Env 2|Env 3|Env 4", 1);
		b.P(id("lfo"), nm("LFO Amount"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.C(id("lfo_src"), nm("LFO Source"), "LFO 1|LFO 2|LFO 3", 0);
		b.P(id("mix"), nm("Mix"), 0.0f, 1.0f, 1.0f, K_PCT);
		b.P(id("pan_spread"), nm("Stereo Offset"), -1.0f, 1.0f, 0.0f, K_FLOAT);
	}
	b.group = "Routing";
	b.C("filter.routing", "Filter Routing", "Serial|Parallel|Split", 0);
}

void build_envs(Build &b) {
	static const char *ENV_LABEL[ENV_N] = {"Amp", "Filter", "Mod 1", "Mod 2"};
	static std::vector<std::string> ids, names, groups;
	for (int n = 0; n < ENV_N; n++) {
		b.page = "Mod";
		groups.push_back("Env " + std::to_string(n + 1) + " (" + ENV_LABEL[n] + ")");
		b.group = groups.back();
		const std::string pre = "env" + std::to_string(n + 1) + ".";
		auto id = [&](const char *s) { ids.push_back(pre + s); return ids.back().c_str(); };
		auto nm = [&](const char *s) {
			names.push_back("E" + std::to_string(n + 1) + " " + s);
			return names.back().c_str();
		};
		b.P(id("delay"), nm("Delay"), 0.0f, 5000.0f, 0.0f, K_MS, 0.35f);
		b.P(id("attack"), nm("Attack"), 0.0f, 20000.0f, n == 0 ? 2.0f : 5.0f, K_MS, 0.3f);
		b.P(id("hold"), nm("Hold"), 0.0f, 5000.0f, 0.0f, K_MS, 0.35f);
		b.P(id("decay"), nm("Decay"), 0.0f, 20000.0f, 400.0f, K_MS, 0.3f);
		b.P(id("sustain"), nm("Sustain"), 0.0f, 1.0f, n == 0 ? 1.0f : 0.5f, K_PCT);
		b.P(id("release"), nm("Release"), 0.0f, 20000.0f, n == 0 ? 120.0f : 200.0f, K_MS, 0.3f);
		b.P(id("atk_curve"), nm("Attack Curve"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.P(id("dec_curve"), nm("Decay Curve"), -1.0f, 1.0f, -0.4f, K_FLOAT);
		b.P(id("rel_curve"), nm("Release Curve"), -1.0f, 1.0f, -0.4f, K_FLOAT);
		b.P(id("vel"), nm("Velocity"), 0.0f, 1.0f, n == 0 ? 0.0f : 0.0f, K_PCT);
		b.B(id("loop"), nm("Loop"), false);
		b.P(id("keytrack"), nm("Key Track"), -1.0f, 1.0f, 0.0f, K_FLOAT);
	}
}

void build_lfos(Build &b) {
	static const char *SHAPES =
		"Sine|Triangle|Saw Up|Saw Down|Square|Pulse|Sample & Hold|Smooth Random|"
		"Steps|Exp Up|Exp Down|Chaos|Trapezoid";
	static std::vector<std::string> ids, names, groups;
	for (int n = 0; n < LFO_N; n++) {
		b.page = "Mod";
		groups.push_back("LFO " + std::to_string(n + 1));
		b.group = groups.back();
		const std::string pre = "lfo" + std::to_string(n + 1) + ".";
		auto id = [&](const char *s) { ids.push_back(pre + s); return ids.back().c_str(); };
		auto nm = [&](const char *s) {
			names.push_back("L" + std::to_string(n + 1) + " " + s);
			return names.back().c_str();
		};
		b.C(id("shape"), nm("Shape"), SHAPES, 0);
		b.P(id("rate"), nm("Rate"), 0.01f, 60.0f, 2.0f, K_HZ, 0.35f);
		b.B(id("sync"), nm("Sync"), true);
		b.C(id("div"), nm("Division"), SYNC_DIV_NAMES, 10);
		b.P(id("depth"), nm("Depth"), 0.0f, 1.0f, 1.0f, K_PCT);
		b.P(id("phase"), nm("Phase"), 0.0f, 1.0f, 0.0f, K_PCT);
		b.P(id("delay"), nm("Delay"), 0.0f, 5000.0f, 0.0f, K_MS, 0.35f);
		b.P(id("fade"), nm("Fade In"), 0.0f, 5000.0f, 0.0f, K_MS, 0.35f);
		b.C(id("mode"), nm("Mode"), "Poly Retrig|Mono Retrig|Free Run|One Shot|Envelope", 0);
		b.P(id("smooth"), nm("Smooth"), 0.0f, 1.0f, 0.0f, K_PCT);
	}
}

void build_matrix(Build &b) {
	static std::vector<std::string> ids, names, groups;
	for (int n = 0; n < MOD_N; n++) {
		b.page = "Matrix";
		groups.push_back("Slot " + std::to_string(n + 1));
		b.group = groups.back();
		const std::string pre = "mod" + std::to_string(n + 1) + ".";
		auto id = [&](const char *s) { ids.push_back(pre + s); return ids.back().c_str(); };
		auto nm = [&](const char *s) {
			names.push_back(std::to_string(n + 1) + " " + s);
			return names.back().c_str();
		};
		b.C(id("src"), nm("Source"), MOD_SRC_NAMES, 0);
		b.C(id("dst"), nm("Target"), MOD_DST_NAMES, 0);
		b.P(id("amount"), nm("Amount"), -1.0f, 1.0f, 0.0f, K_FLOAT);
		b.P(id("curve"), nm("Curve"), -1.0f, 1.0f, 0.0f, K_FLOAT);
	}
}

void build_macros(Build &b) {
	static std::vector<std::string> ids, names;
	b.page = "Main"; b.group = "Macros";
	for (int n = 0; n < MACRO_N; n++) {
		ids.push_back("macro" + std::to_string(n + 1));
		names.push_back("Macro " + std::to_string(n + 1));
		b.P(ids.back().c_str(), names.back().c_str(), 0.0f, 1.0f, n == 0 ? 0.5f : 0.0f, K_PCT);
	}
}

void build_arp_gate(Build &b) {
	b.page = "Arp"; b.group = "Arpeggiator";
	b.B("arp.on", "Arp On", false);
	b.C("arp.mode", "Arp Mode", "Up|Down|Up-Down|Down-Up|Up&Down|Random|As Played|Chord", 0);
	b.P("arp.octaves", "Octaves", 1.0f, 4.0f, 1.0f, K_INT, 1.0f, "", 3);
	b.C("arp.div", "Rate", SYNC_DIV_NAMES, 4);
	b.P("arp.gate", "Gate", 0.05f, 1.5f, 0.7f, K_PCT);
	b.P("arp.swing", "Swing", -0.5f, 0.5f, 0.0f, K_FLOAT);
	b.P("arp.steps", "Length", 1.0f, 32.0f, 16.0f, K_INT, 1.0f, "", 31);
	b.B("arp.latch", "Latch", false);

	b.group = "Step Gate";
	b.B("gate.on", "Gate On", false);
	b.C("gate.div", "Gate Rate", SYNC_DIV_NAMES, 4);
	b.P("gate.smooth", "Smooth", 0.0f, 1.0f, 0.2f, K_PCT);
	static std::vector<std::string> ids, names;
	for (int n = 0; n < STEP_N; n++) {
		ids.push_back("gate.step" + std::to_string(n + 1));
		names.push_back("Step " + std::to_string(n + 1));
		b.P(ids.back().c_str(), names.back().c_str(), 0.0f, 1.0f, 1.0f, K_PCT);
	}
}

void build_fx(Build &b) {
	b.page = "FX";

	b.group = "FX Filter";
	b.B("fx.filter.on", "Filter On", false);
	b.C("fx.filter.type", "Filter Type", "Low Pass|High Pass|Band Pass|Notch|Formant", 0);
	b.P("fx.filter.cutoff", "Filter Cutoff", 20.0f, 20000.0f, 20000.0f, K_HZ, 0.3f);
	b.P("fx.filter.reso", "Filter Reso", 0.0f, 1.0f, 0.1f, K_PCT);
	b.P("fx.filter.mix", "Filter Mix", 0.0f, 1.0f, 1.0f, K_PCT);

	b.group = "Distortion";
	b.B("fx.dist.on", "Dist On", false);
	b.C("fx.dist.type", "Dist Type", "Soft|Hard|Tube|Fold|Fuzz|Bit Crush|Sample Rate|Rectify", 0);
	b.P("fx.dist.drive", "Dist Drive", 0.0f, 1.0f, 0.3f, K_PCT);
	b.P("fx.dist.tone", "Dist Tone", -1.0f, 1.0f, 0.0f, K_FLOAT);
	b.P("fx.dist.mix", "Dist Mix", 0.0f, 1.0f, 1.0f, K_PCT);

	b.group = "EQ";
	b.B("fx.eq.on", "EQ On", false);
	b.P("fx.eq.lo_gain", "Low Gain", -18.0f, 18.0f, 0.0f, K_DB);
	b.P("fx.eq.lo_freq", "Low Freq", 30.0f, 800.0f, 120.0f, K_HZ, 0.4f);
	b.P("fx.eq.mid_gain", "Mid Gain", -18.0f, 18.0f, 0.0f, K_DB);
	b.P("fx.eq.mid_freq", "Mid Freq", 200.0f, 8000.0f, 1200.0f, K_HZ, 0.4f);
	b.P("fx.eq.mid_q", "Mid Q", 0.2f, 8.0f, 1.0f, K_Q, 0.5f);
	b.P("fx.eq.hi_gain", "High Gain", -18.0f, 18.0f, 0.0f, K_DB);
	b.P("fx.eq.hi_freq", "High Freq", 1500.0f, 18000.0f, 6000.0f, K_HZ, 0.4f);

	b.group = "Chorus";
	b.B("fx.chorus.on", "Chorus On", false);
	b.P("fx.chorus.rate", "Chorus Rate", 0.01f, 10.0f, 0.6f, K_HZ, 0.4f);
	b.P("fx.chorus.depth", "Chorus Depth", 0.0f, 1.0f, 0.4f, K_PCT);
	b.P("fx.chorus.voices", "Chorus Voices", 2.0f, 6.0f, 3.0f, K_INT, 1.0f, "", 4);
	b.P("fx.chorus.width", "Chorus Width", 0.0f, 1.0f, 0.8f, K_PCT);
	b.P("fx.chorus.feedback", "Chorus Feedback", -0.9f, 0.9f, 0.0f, K_FLOAT);
	b.P("fx.chorus.mix", "Chorus Mix", 0.0f, 1.0f, 0.35f, K_PCT);

	b.group = "Phaser";
	b.B("fx.phaser.on", "Phaser On", false);
	b.P("fx.phaser.rate", "Phaser Rate", 0.01f, 10.0f, 0.3f, K_HZ, 0.4f);
	b.P("fx.phaser.depth", "Phaser Depth", 0.0f, 1.0f, 0.6f, K_PCT);
	b.P("fx.phaser.centre", "Phaser Centre", 100.0f, 8000.0f, 800.0f, K_HZ, 0.4f);
	b.P("fx.phaser.feedback", "Phaser Feedback", -0.95f, 0.95f, 0.4f, K_FLOAT);
	b.P("fx.phaser.stages", "Phaser Stages", 2.0f, 12.0f, 6.0f, K_INT, 1.0f, "", 10);
	b.P("fx.phaser.spread", "Phaser Spread", 0.0f, 1.0f, 0.5f, K_PCT);
	b.P("fx.phaser.mix", "Phaser Mix", 0.0f, 1.0f, 0.5f, K_PCT);

	b.group = "Delay";
	b.B("fx.delay.on", "Delay On", false);
	b.B("fx.delay.sync", "Delay Sync", true);
	b.P("fx.delay.time", "Delay Time", 1.0f, 4000.0f, 350.0f, K_MS, 0.35f);
	b.C("fx.delay.div", "Delay Division", SYNC_DIV_NAMES, 7);
	b.P("fx.delay.feedback", "Delay Feedback", 0.0f, 1.1f, 0.4f, K_PCT);
	b.P("fx.delay.ping", "Ping-Pong", 0.0f, 1.0f, 0.0f, K_PCT);
	b.P("fx.delay.locut", "Delay Low Cut", 20.0f, 2000.0f, 180.0f, K_HZ, 0.4f);
	b.P("fx.delay.hicut", "Delay High Cut", 500.0f, 20000.0f, 8000.0f, K_HZ, 0.4f);
	b.P("fx.delay.width", "Delay Width", 0.0f, 1.0f, 1.0f, K_PCT);
	b.P("fx.delay.mix", "Delay Mix", 0.0f, 1.0f, 0.25f, K_PCT);

	b.group = "Reverb";
	b.B("fx.reverb.on", "Reverb On", false);
	b.P("fx.reverb.size", "Reverb Size", 0.0f, 1.0f, 0.6f, K_PCT);
	b.P("fx.reverb.damp", "Reverb Damp", 0.0f, 1.0f, 0.4f, K_PCT);
	b.P("fx.reverb.width", "Reverb Width", 0.0f, 1.0f, 1.0f, K_PCT);
	b.P("fx.reverb.predelay", "Pre-Delay", 0.0f, 250.0f, 12.0f, K_MS);
	b.P("fx.reverb.locut", "Reverb Low Cut", 20.0f, 2000.0f, 200.0f, K_HZ, 0.4f);
	b.P("fx.reverb.diffuse", "Diffusion", 0.0f, 1.0f, 0.7f, K_PCT);
	b.P("fx.reverb.mix", "Reverb Mix", 0.0f, 1.0f, 0.25f, K_PCT);

	b.group = "Compressor";
	b.B("fx.comp.on", "Comp On", false);
	b.P("fx.comp.thresh", "Comp Threshold", -48.0f, 0.0f, -12.0f, K_DB);
	b.P("fx.comp.ratio", "Comp Ratio", 1.0f, 20.0f, 3.0f, K_FLOAT, 0.5f);
	b.P("fx.comp.attack", "Comp Attack", 0.1f, 200.0f, 8.0f, K_MS, 0.4f);
	b.P("fx.comp.release", "Comp Release", 5.0f, 2000.0f, 120.0f, K_MS, 0.4f);
	b.P("fx.comp.makeup", "Comp Makeup", 0.0f, 24.0f, 0.0f, K_DB);

	b.group = "Limiter";
	b.B("fx.limit.on", "Limiter On", true);
	b.P("fx.limit.ceiling", "Ceiling", -12.0f, 0.0f, -0.3f, K_DB);
}

void build_all() {
	Build b;
	Layout &L = g_layout;

	L.master = (int)b.v.size(); build_master(b);
	L.part = (int)b.v.size(); build_parts(b);
	L.sub = (int)b.v.size(); build_sub_noise(b);
	L.noise = L.sub + SUB_COUNT;
	L.filter = (int)b.v.size(); build_filters(b);
	L.filter_route = L.filter + FILTER_N * FLT_COUNT;
	L.env = (int)b.v.size(); build_envs(b);
	L.lfo = (int)b.v.size(); build_lfos(b);
	L.mod = (int)b.v.size(); build_matrix(b);
	L.macro = (int)b.v.size(); build_macros(b);
	L.arp = (int)b.v.size(); build_arp_gate(b);
	L.gate = L.arp + ARP_COUNT;
	L.step = L.gate + GAT_COUNT;
	L.fx_filter = (int)b.v.size(); build_fx(b);
	L.fx_dist = L.fx_filter + XFL_COUNT;
	L.fx_eq = L.fx_dist + XDS_COUNT;
	L.fx_chorus = L.fx_eq + XEQ_COUNT;
	L.fx_phaser = L.fx_chorus + XCH_COUNT;
	L.fx_delay = L.fx_phaser + XPH_COUNT;
	L.fx_reverb = L.fx_delay + XDL_COUNT;
	L.fx_comp = L.fx_reverb + XRV_COUNT;
	L.fx_limit = L.fx_comp + XCP_COUNT;
	L.count = (int)b.v.size();

	g_params.swap(b.v);
	for (int i = 0; i < (int)g_params.size(); i++) g_index[g_params[(size_t)i].id] = i;
}

} // namespace

const std::vector<ParamInfo> &params() {
	if (g_params.empty()) build_all();
	return g_params;
}

const Layout &layout() {
	if (g_params.empty()) build_all();
	return g_layout;
}

int param_count() { return (int)params().size(); }

int param_index(const std::string &id) {
	params();
	auto it = g_index.find(id);
	return it == g_index.end() ? -1 : it->second;
}

std::string param_text(int index, float v) {
	const std::vector<ParamInfo> &p = params();
	if (index < 0 || index >= (int)p.size()) return std::string();
	const ParamInfo &d = p[(size_t)index];
	char buf[128];
	switch (d.kind) {
		case K_BOOL: return v > 0.5f ? "On" : "Off";
		case K_CHOICE: {
			const int want = (int)std::lround(v);
			int n = 0;
			size_t start = 0;
			for (size_t i = 0; i <= d.choices.size(); i++) {
				if (i == d.choices.size() || d.choices[i] == '|') {
					if (n == want) return d.choices.substr(start, i - start);
					n++;
					start = i + 1;
				}
			}
			return std::to_string(want);
		}
		case K_BEATS: {
			const int i = (int)std::lround(v);
			int n = 0;
			std::string all(SYNC_DIV_NAMES);
			size_t start = 0;
			for (size_t k = 0; k <= all.size(); k++) {
				if (k == all.size() || all[k] == '|') {
					if (n == i) return all.substr(start, k - start);
					n++;
					start = k + 1;
				}
			}
			return std::string();
		}
		case K_DB:
			if (v <= d.min + 0.01f && d.min <= -60.0f) return "-inf";
			std::snprintf(buf, sizeof(buf), "%.1f dB", v);
			return buf;
		case K_HZ:
			if (v >= 1000.0f) std::snprintf(buf, sizeof(buf), "%.2f kHz", v * 0.001f);
			else std::snprintf(buf, sizeof(buf), "%.1f Hz", v);
			return buf;
		case K_PCT: std::snprintf(buf, sizeof(buf), "%.0f%%", v * 100.0f); return buf;
		case K_SEMI: std::snprintf(buf, sizeof(buf), "%+.0f st", v); return buf;
		case K_CENT: std::snprintf(buf, sizeof(buf), "%+.0f ct", v); return buf;
		case K_MS:
			if (v >= 1000.0f) std::snprintf(buf, sizeof(buf), "%.2f s", v * 0.001f);
			else std::snprintf(buf, sizeof(buf), "%.1f ms", v);
			return buf;
		case K_SEC: std::snprintf(buf, sizeof(buf), "%.2f s", v); return buf;
		case K_Q: std::snprintf(buf, sizeof(buf), "%.2f", v); return buf;
		case K_INT: std::snprintf(buf, sizeof(buf), "%d", (int)std::lround(v)); return buf;
		case K_PAN:
			if (std::fabs(v) < 0.005f) return "C";
			std::snprintf(buf, sizeof(buf), "%c %.0f", v < 0.0f ? 'L' : 'R', std::fabs(v) * 100.0f);
			return buf;
		default:
			// A control that runs equally either side of zero reads as a
			// percentage off centre; only a genuinely one-sided number is
			// worth three decimal places.
			if (d.min < -0.0001f && d.max > 0.0001f && std::fabs(d.min + d.max) < 0.001f) {
				std::snprintf(buf, sizeof(buf), "%+.0f%%", v / d.max * 100.0f);
				return buf;
			}
			std::snprintf(buf, sizeof(buf), "%.2f", v);
			return buf;
	}
}

} // namespace flare
