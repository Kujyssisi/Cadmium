/* Cadmium — the external plugin interface.
 *
 * A shared library that exports cd_plugin_entry_v1() and returns one of these
 * is a Cadmium plugin: it appears in the picker, gets Cadmium's own knobs,
 * automation and preset handling, and is saved into projects by id.
 *
 * Plain C on purpose. The host and the plugin are separate binaries built at
 * different times, and a C++ interface between them is a promise about vtable
 * layout, exception ABI and standard library version that neither side can
 * keep. Everything here is a POD struct and a function pointer.
 *
 * The host owns nothing the plugin returns; the plugin owns nothing the host
 * passes in. Strings the plugin returns must stay valid until the next call
 * on the same instance.
 */
#ifndef CADMIUM_EXT_H
#define CADMIUM_EXT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CD_EXT_ABI 1

/* Mirrors cd::ParamKind. */
enum {
	CD_EXT_FLOAT = 0, CD_EXT_DB, CD_EXT_HZ, CD_EXT_PCT, CD_EXT_CHOICE,
	CD_EXT_BOOL, CD_EXT_SEMI, CD_EXT_MS, CD_EXT_SEC, CD_EXT_BEATS, CD_EXT_Q
};

/* Mirrors cd::PlugUI. DECLARED means "I will describe my own panel": the host
 * asks for the layout with get_string("ui") and draws it with its own widgets,
 * so the plugin gets a designed interface in the host's visual language
 * without the host knowing anything about the plugin. */
enum { CD_EXT_UI_GENERIC = 0, CD_EXT_UI_DECLARED = 37 };

typedef struct {
	const char *id;
	const char *name;
	const char *group;    /* panel heading, "" for ungrouped */
	const char *choices;  /* "Sine|Saw|Square" when kind is CHOICE */
	float min, max, def, skew;
	int kind;
	int steps;            /* 0 continuous */
	int readonly;
} CdExtParam;

typedef struct {
	const char *id;       /* stable; this is what a project file stores */
	const char *name;
	const char *vendor;
	const char *category; /* Synth / Drum / EQ / Delay / Reverb / ... */
	int instrument;
	int ui;
	int param_count;
	const CdExtParam *params;
} CdExtDesc;

typedef struct CdExtPlug CdExtPlug;

typedef struct {
	int abi;                  /* CD_EXT_ABI */
	const char *pack_name;    /* what to call the collection in a log line */
	const char *version;
	int desc_count;
	const CdExtDesc *descs;

	CdExtPlug *(*create)(const char *id, double sample_rate, int block);
	void (*destroy)(CdExtPlug *p);

	void (*prepare)(CdExtPlug *p, double sample_rate, int block);
	void (*reset)(CdExtPlug *p);

	void (*note_on)(CdExtPlug *p, int key, float velocity, int id);
	void (*note_off)(CdExtPlug *p, int key, int id);
	void (*all_notes_off)(CdExtPlug *p);
	void (*pitch_bend)(CdExtPlug *p, float semitones);
	void (*mod_wheel)(CdExtPlug *p, float v01);
	void (*aftertouch)(CdExtPlug *p, float v01);
	/* Per-note pan and detune, taken by the next note_on. */
	void (*expression)(CdExtPlug *p, float pan, float fine_semitones);

	void (*transport)(CdExtPlug *p, double bpm, double song_beat, int playing);
	/* Stereo, non-interleaved. Instruments overwrite; effects read and write. */
	void (*process)(CdExtPlug *p, float *left, float *right, int frames);
	void (*sidechain)(CdExtPlug *p, const float *left, const float *right, int frames);
	int (*wants_sidechain)(CdExtPlug *p);

	void (*set_param)(CdExtPlug *p, int index, float value);
	float (*get_param)(CdExtPlug *p, int index);
	/* The plugin's own spelling of a value, into a host buffer. */
	int (*param_text)(CdExtPlug *p, int index, float value, char *out, int max);

	int (*set_string)(CdExtPlug *p, const char *key, const char *value);
	/* Writes at most `max` bytes including the terminator and returns the
	 * length written, or the length needed when `out` is null. */
	int (*get_string)(CdExtPlug *p, const char *key, char *out, int max);

	int (*set_data)(CdExtPlug *p, const char *key, const float *data, int n);
	int (*aux)(CdExtPlug *p, int what, float *out, int max);

	int (*active_voices)(CdExtPlug *p);
	float (*tail)(CdExtPlug *p);

	/* --- the plugin's own interface.
	 *
	 * Optional: a plugin that leaves has_editor null gets the host's controls
	 * and nothing else. One that provides an editor is given a native window
	 * handle to put it inside -- an X11 Window id, or an HWND -- and is poked
	 * to draw by editor_idle, because the host's loop is the only loop there
	 * is. Everything here is called from the interface thread, never from the
	 * one making the sound. */
	int (*has_editor)(CdExtPlug *p);
	void (*editor_default_size)(CdExtPlug *p, int *w, int *h);
	int (*open_editor)(CdExtPlug *p, uint64_t parent, int x, int y, int w, int h);
	void (*close_editor)(CdExtPlug *p);
	int (*editor_is_open)(CdExtPlug *p);
	/* Pumps events and repaints. Called often, and must return quickly. */
	void (*editor_idle)(CdExtPlug *p);
	void (*editor_move)(CdExtPlug *p, int x, int y, int w, int h);
	void (*editor_focus)(CdExtPlug *p, int take);
	/* True once the editor has actually drawn something, so the host knows
	 * when to stop showing whatever it puts up while one is being built. */
	int (*editor_ready)(CdExtPlug *p);
	void (*editor_set_scale)(CdExtPlug *p, float factor);
	/* Brings the canvas in from wherever the plugin kept it while it was
	 * building, and says whether that has happened. A host that draws a
	 * placeholder needs both: a native child window is painted over anything
	 * the host draws, so the plugin has to keep it out of the way until the
	 * host says. A plugin that has nothing to keep out of the way can leave
	 * these null and be treated as always showing. */
	void (*editor_show)(CdExtPlug *p);
	int (*editor_showing)(CdExtPlug *p);
	int (*editor_can_resize)(CdExtPlug *p);
	void (*editor_constrain)(CdExtPlug *p, int *w, int *h);
	/* Parameter moves the plugin's own interface made since this was last
	 * called, as "index:value" lines, so the host records them for automation
	 * and undo instead of finding out at the next save. */
	int (*drain_edits)(CdExtPlug *p, char *out, int max);
} CdExtEntry;

/* The one exported symbol. */
const CdExtEntry *cd_plugin_entry_v1(void);

#ifdef __cplusplus
}
#endif
#endif
