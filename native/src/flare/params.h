// FLARE — the parameter table.
//
// One description of every control, shared by the Cadmium adapter, the VST3
// wrapper and the preset reader. Nothing else in the plugin is allowed to know
// a parameter's range or default: a host that disagrees with the engine about
// what 0.5 means is a preset that loads wrong, and it is impossible to find.
#pragma once

#include <string>
#include <vector>

namespace flare {

enum Kind {
	K_FLOAT = 0,  // plain number
	K_DB,         // decibels
	K_HZ,         // frequency, shown with a k suffix
	K_PCT,        // 0..1 shown as a percentage
	K_CHOICE,     // integer index into `choices`
	K_BOOL,
	K_SEMI,       // semitones
	K_CENT,
	K_MS,
	K_SEC,
	K_BEATS,      // index into the synced-division table
	K_Q,
	K_INT,
	K_PAN,        // -1..1 shown as L/C/R
};

struct ParamInfo {
	std::string id;       // stable, used by presets and by the hosts
	std::string name;     // what a human reads
	std::string group;    // panel heading
	std::string page;     // which tab of the interface it belongs to
	std::string choices;  // "Sine|Saw|Square" when kind is K_CHOICE
	float min = 0, max = 1, def = 0, skew = 1.0f;
	int kind = K_FLOAT;
	int steps = 0;        // 0 continuous
};

// ---------------------------------------------------------------------------
// Block layout
//
// Parameters are laid out in blocks -- three identical oscillator parts, four
// identical envelopes, sixteen identical modulation slots -- so an index is
// `base + n * stride + offset` and the engine can loop over a block instead of
// naming three hundred fields.
// ---------------------------------------------------------------------------

// --- Master
enum {
	MST_VOL = 0, MST_PAN, MST_VOICE_MODE, MST_POLY, MST_GLIDE, MST_GLIDE_MODE,
	MST_BEND_UP, MST_BEND_DN, MST_OCT, MST_SEMI, MST_TUNE, MST_VEL_VOL,
	MST_DRIFT, MST_QUALITY, MST_MONO_RETRIG,
	MST_COUNT
};

// --- Oscillator part, three of them
enum {
	PRT_ON = 0, PRT_SRC, PRT_WAVE, PRT_POS, PRT_WARP, PRT_WARP_MODE,
	PRT_LEVEL, PRT_PAN, PRT_OCT, PRT_SEMI, PRT_FINE,
	PRT_UNISON, PRT_DETUNE, PRT_SPREAD, PRT_BLEND, PRT_PHASE, PRT_PHASE_RAND,
	PRT_KEYTRACK, PRT_START, PRT_LOOP_MODE, PRT_FM, PRT_RM, PRT_FILTER, PRT_VEL,
	PRT_COUNT
};
static const int PART_N = 3;

/// What a part's Source choice means, and where the morphing tables begin in
/// the single wave list.
enum { SRC_WAVE = 0, SRC_SAMPLE = 1, SRC_MULTISAMPLE = 2, SRC_NOISE = 3 };
static const int WAVE_ANALOG_COUNT = 20;

// --- Sub oscillator
enum { SUB_ON = 0, SUB_WAVE, SUB_LEVEL, SUB_OCT, SUB_PAN, SUB_COUNT };

// --- Noise source
enum { NOI_ON = 0, NOI_TYPE, NOI_LEVEL, NOI_PAN, NOI_CUT, NOI_COUNT };

// --- Filter, two of them, plus a routing choice
enum {
	FLT_ON = 0, FLT_TYPE, FLT_CUT, FLT_RES, FLT_DRIVE, FLT_KEYTRK,
	FLT_ENV, FLT_ENV_SRC, FLT_LFO, FLT_LFO_SRC, FLT_MIX, FLT_PAN_SPREAD,
	FLT_COUNT
};
static const int FILTER_N = 2;

// --- Envelope, four of them. 0 is always the amplifier.
enum {
	ENV_DELAY = 0, ENV_ATTACK, ENV_HOLD, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE,
	ENV_ATK_C, ENV_DEC_C, ENV_REL_C, ENV_VEL, ENV_LOOP, ENV_KEYTRK,
	ENV_COUNT
};
static const int ENV_N = 4;

// --- LFO, three of them
enum {
	LFO_SHAPE = 0, LFO_RATE, LFO_SYNC, LFO_DIV, LFO_DEPTH, LFO_PHASE,
	LFO_DELAY, LFO_FADE, LFO_MODE, LFO_SMOOTH,
	LFO_COUNT
};
static const int LFO_N = 3;

// --- Modulation slot, sixteen of them
enum { MOD_SRC = 0, MOD_DST, MOD_AMT, MOD_CURVE, MOD_COUNT };
static const int MOD_N = 16;

static const int MACRO_N = 8;
static const int STEP_N = 16;

// --- Arpeggiator
enum { ARP_ON = 0, ARP_MODE, ARP_OCT, ARP_DIV, ARP_GATE, ARP_SWING, ARP_STEPS, ARP_LATCH, ARP_COUNT };

// --- Step gate: three controls then the sixteen step levels
enum { GAT_ON = 0, GAT_DIV, GAT_SMOOTH, GAT_COUNT };

// --- Effects rack, in the order it runs
enum { XFL_ON = 0, XFL_TYPE, XFL_CUT, XFL_RES, XFL_MIX, XFL_COUNT };
enum { XDS_ON = 0, XDS_TYPE, XDS_DRIVE, XDS_TONE, XDS_MIX, XDS_COUNT };
enum { XEQ_ON = 0, XEQ_LO_G, XEQ_LO_F, XEQ_MID_G, XEQ_MID_F, XEQ_MID_Q, XEQ_HI_G, XEQ_HI_F, XEQ_COUNT };
enum { XCH_ON = 0, XCH_RATE, XCH_DEPTH, XCH_VOICES, XCH_WIDTH, XCH_FB, XCH_MIX, XCH_COUNT };
enum { XPH_ON = 0, XPH_RATE, XPH_DEPTH, XPH_CENTRE, XPH_FB, XPH_STAGES, XPH_SPREAD, XPH_MIX, XPH_COUNT };
enum { XDL_ON = 0, XDL_SYNC, XDL_TIME, XDL_DIV, XDL_FB, XDL_PING, XDL_LOCUT, XDL_HICUT, XDL_WIDTH, XDL_MIX, XDL_COUNT };
enum { XRV_ON = 0, XRV_SIZE, XRV_DAMP, XRV_WIDTH, XRV_PREDELAY, XRV_LOCUT, XRV_DIFF, XRV_MIX, XRV_COUNT };
enum { XCP_ON = 0, XCP_THRESH, XCP_RATIO, XCP_ATTACK, XCP_RELEASE, XCP_MAKEUP, XCP_COUNT };
enum { XLM_ON = 0, XLM_CEIL, XLM_COUNT };

/// Where each block starts. Filled once, on first use, by params().
struct Layout {
	int master = 0;
	int part = 0;      // + n * PRT_COUNT
	int sub = 0;
	int noise = 0;
	int filter = 0;    // + n * FLT_COUNT
	int filter_route = 0;
	int env = 0;       // + n * ENV_COUNT
	int lfo = 0;       // + n * LFO_COUNT
	int mod = 0;       // + n * MOD_COUNT
	int macro = 0;     // + n
	int arp = 0;
	int gate = 0;
	int step = 0;      // + n
	int fx_filter = 0, fx_dist = 0, fx_eq = 0, fx_chorus = 0, fx_phaser = 0;
	int fx_delay = 0, fx_reverb = 0, fx_comp = 0, fx_limit = 0;
	int count = 0;
};

const Layout &layout();
const std::vector<ParamInfo> &params();
int param_count();
/// -1 when nothing has that id, so an old preset naming a control that no
/// longer exists is skipped rather than writing over whatever is at index 0.
int param_index(const std::string &id);

/// Text for a value, in the parameter's own units.
std::string param_text(int index, float value);

// --- Modulation sources and destinations
//
// Destinations are a curated list rather than "any parameter": a matrix that
// can point at the reverb mix per voice is a matrix nobody can read, and the
// per-sample cost is paid for every entry whether it is useful or not.
enum ModSrc {
	MS_NONE = 0, MS_ENV1, MS_ENV2, MS_ENV3, MS_ENV4,
	MS_LFO1, MS_LFO2, MS_LFO3,
	MS_VEL, MS_KEY, MS_MODWHEEL, MS_AFTERTOUCH, MS_BEND, MS_EXPRESSION,
	MS_RANDOM, MS_RANDOM_UNI, MS_GATE, MS_NOTE_ON_ORDER,
	MS_MACRO1, MS_MACRO2, MS_MACRO3, MS_MACRO4,
	MS_MACRO5, MS_MACRO6, MS_MACRO7, MS_MACRO8,
	MS_COUNT
};
extern const char *MOD_SRC_NAMES;

enum ModDst {
	MD_NONE = 0,
	MD_PITCH, MD_A_PITCH, MD_B_PITCH, MD_C_PITCH,
	MD_A_LEVEL, MD_B_LEVEL, MD_C_LEVEL, MD_SUB_LEVEL, MD_NOISE_LEVEL,
	MD_A_POS, MD_B_POS, MD_C_POS,
	MD_A_WARP, MD_B_WARP, MD_C_WARP,
	MD_A_PAN, MD_B_PAN, MD_C_PAN,
	MD_A_FINE, MD_B_FINE, MD_C_FINE,
	MD_A_UNISON_DETUNE, MD_FM, MD_RM,
	MD_F1_CUT, MD_F1_RES, MD_F1_DRIVE, MD_F2_CUT, MD_F2_RES, MD_F2_DRIVE,
	MD_AMP, MD_PAN, MD_START,
	MD_LFO1_RATE, MD_LFO2_RATE, MD_LFO3_RATE,
	MD_LFO1_DEPTH, MD_LFO2_DEPTH, MD_LFO3_DEPTH,
	MD_ENV2_DECAY, MD_ENV1_DECAY, MD_ENV1_ATTACK,
	MD_FX_FILTER_CUT, MD_FX_DIST_DRIVE, MD_FX_CHORUS_DEPTH, MD_FX_PHASER_RATE,
	MD_FX_DELAY_MIX, MD_FX_REVERB_MIX, MD_FX_DELAY_FB,
	MD_COUNT
};
extern const char *MOD_DST_NAMES;
/// True for destinations the FX rack applies once per block rather than the
/// voice applying per sample. A per-voice source pointed at one of these is
/// summed across sounding voices, which is the only thing it can mean.
bool mod_dst_is_global(int dst);

static const int SYNC_DIV_COUNT = 15;
float sync_beats(int i);
extern const char *SYNC_DIV_NAMES;

} // namespace flare
