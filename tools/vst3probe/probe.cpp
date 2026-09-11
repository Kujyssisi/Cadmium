// A VST3 plugin that exists to be hosted.
//
// Cadmium's Windows build cannot be tested against a real plugin from here, so
// this is one: a gain effect with one parameter and an editor that paints a
// pattern nothing else would produce. Hosting it exercises the whole path --
// loading the module, the factory, the component, processing, and putting a
// plugin-drawn window inside one of ours -- and the pattern is what the test
// looks for when it reads the pixels back.
//
// Built for Windows by tools/vst3probe/build.sh; it is not part of the DAW.
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstevents.h"

#include <cstring>
#include <cstdio>
#include <cmath>

#if defined(_WIN32)
#include <windows.h>
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

// Written out rather than built with FUID, which lives in a source file of the
// SDK that nothing here compiles.
// The plugin's own class id. The "twin" build is a second copy of the same
// plugin under a different id, which answers getControllerClassId with that id
// rather than saying it has no separate controller -- the way FabFilter and a
// good number of others do. A host that takes that answer at face value builds
// a whole second instance and drives the interface with it, which is a thing
// worth having a plugin to catch.
#if defined(CD_PROBE_NOTES)
// An instrument rather than an effect, and a strict one: it stops a note only
// when the note-off carries the same note id the note-on did, which is what
// the specification allows and what several real instruments actually do. A
// host that invents an id for a note and then sends the note-off under a
// different one leaves this plugin -- and those -- sounding forever.
static const TUID kProbeCID = INLINE_UID(0x0CADCE03, 0x33336666, 0x8888BBBB, 0xAABBCCDF);
static const char *kProbeName = "Cadmium Probe Notes";
#elif defined(CD_PROBE_CTRL_CID)
static const TUID kProbeCID = INLINE_UID(0x0CADCE02, 0x22225555, 0x8888AAAA, 0xAABBCCDE);
static const char *kProbeName = "Cadmium Probe Twin";
#else
static const TUID kProbeCID = INLINE_UID(0x0CADCE01, 0x11114444, 0x88889999, 0xAABBCCDD);
static const char *kProbeName = "Cadmium Probe";
#endif

static bool same_iid(const TUID a, const TUID b) { return std::memcmp(a, b, 16) == 0; }

static void to_utf16(const char *src, char16_t *dst, int cap) {
	int i = 0;
	for (; src[i] && i < cap - 1; i++) dst[i] = (char16_t)(unsigned char)src[i];
	dst[i] = 0;
}

// ---------------------------------------------------------------------------
// The editor's window
// ---------------------------------------------------------------------------
#if defined(_WIN32)
static const wchar_t *kProbeClass = L"CdProbeView";

static void paint_probe(HDC dc, int w, int h) {
	// Four quarters in flat colours with a diagonal through them: nothing a
	// blank window or a failed attach could look like by accident.
	const COLORREF quads[4] = {RGB(220, 60, 60), RGB(60, 200, 90),
			RGB(60, 110, 220), RGB(230, 200, 60)};
	for (int q = 0; q < 4; q++) {
		RECT r{(q % 2) * w / 2, (q / 2) * h / 2, (q % 2 + 1) * w / 2, (q / 2 + 1) * h / 2};
		HBRUSH b = CreateSolidBrush(quads[q]);
		FillRect(dc, &r, b);
		DeleteObject(b);
	}
	HPEN pen = CreatePen(PS_SOLID, 3, RGB(255, 255, 255));
	HGDIOBJ old = SelectObject(dc, pen);
	MoveToEx(dc, 0, 0, nullptr);
	LineTo(dc, w, h);
	MoveToEx(dc, w, 0, nullptr);
	LineTo(dc, 0, h);
	SelectObject(dc, old);
	DeleteObject(pen);
}

static LRESULT CALLBACK probe_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
	switch (msg) {
		case WM_PAINT: {
			PAINTSTRUCT ps;
			HDC dc = BeginPaint(hwnd, &ps);
			RECT r;
			GetClientRect(hwnd, &r);
			paint_probe(dc, r.right - r.left, r.bottom - r.top);
			EndPaint(hwnd, &ps);
			return 0;
		}
		case WM_PRINTCLIENT: {
			RECT r;
			GetClientRect(hwnd, &r);
			paint_probe((HDC)wp, r.right - r.left, r.bottom - r.top);
			return 0;
		}
		case WM_ERASEBKGND:
			return 1;
		default:
			return DefWindowProcW(hwnd, msg, wp, lp);
	}
}
#endif

// ---------------------------------------------------------------------------
class ProbeView : public IPlugView {
public:
	IPlugFrame *frame = nullptr;
	int w = 420, h = 260;
#if defined(_WIN32)
	HWND hwnd = nullptr;
#endif
	uint32 refs = 1;

	tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
		if (same_iid(iid, FUnknown_iid) || same_iid(iid, IPlugView_iid)) {
			*obj = this;
			refs++;
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++refs; }
	uint32 PLUGIN_API release() SMTG_OVERRIDE {
		if (--refs == 0) { delete this; return 0; }
		return refs;
	}

	tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
#if defined(_WIN32)
		return std::strcmp(type, kPlatformTypeHWND) == 0 ? kResultTrue : kResultFalse;
#else
		return std::strcmp(type, kPlatformTypeX11EmbedWindowID) == 0 ? kResultTrue : kResultFalse;
#endif
	}
	tresult PLUGIN_API attached(void *parent, FIDString) SMTG_OVERRIDE {
#if defined(_WIN32)
		WNDCLASSEXW wc{};
		wc.cbSize = sizeof(wc);
		wc.lpfnWndProc = probe_proc;
		wc.hInstance = GetModuleHandleW(nullptr);
		wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
		wc.lpszClassName = kProbeClass;
		RegisterClassExW(&wc);
		hwnd = CreateWindowExW(0, kProbeClass, L"", WS_CHILD | WS_VISIBLE, 0, 0, w, h,
				(HWND)parent, nullptr, GetModuleHandleW(nullptr), nullptr);
		return hwnd ? kResultOk : kResultFalse;
#else
		(void)parent;
		return kResultOk;
#endif
	}
	tresult PLUGIN_API removed() SMTG_OVERRIDE {
#if defined(_WIN32)
		if (hwnd) { DestroyWindow(hwnd); hwnd = nullptr; }
#endif
		return kResultOk;
	}
	tresult PLUGIN_API onWheel(float) SMTG_OVERRIDE { return kResultFalse; }
	tresult PLUGIN_API onKeyDown(char16, int16, int16) SMTG_OVERRIDE { return kResultFalse; }
	tresult PLUGIN_API onKeyUp(char16, int16, int16) SMTG_OVERRIDE { return kResultFalse; }
	tresult PLUGIN_API getSize(ViewRect *size) SMTG_OVERRIDE {
		if (!size) return kInvalidArgument;
		*size = ViewRect(0, 0, w, h);
		return kResultOk;
	}
	tresult PLUGIN_API onSize(ViewRect *r) SMTG_OVERRIDE {
		if (!r) return kInvalidArgument;
		w = r->getWidth();
		h = r->getHeight();
#if defined(_WIN32)
		if (hwnd) {
			SetWindowPos(hwnd, nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
			InvalidateRect(hwnd, nullptr, TRUE);
		}
#endif
		return kResultOk;
	}
	tresult PLUGIN_API onFocus(TBool) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API setFrame(IPlugFrame *f) SMTG_OVERRIDE { frame = f; return kResultOk; }
	tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }
	tresult PLUGIN_API checkSizeConstraint(ViewRect *r) SMTG_OVERRIDE {
		if (!r) return kInvalidArgument;
		// Rounded to eights, so a host that honours constraints can be seen to.
		int cw = r->getWidth() / 8 * 8;
		int ch = r->getHeight() / 8 * 8;
		if (cw < 200) cw = 200;
		if (ch < 120) ch = 120;
		*r = ViewRect(0, 0, cw, ch);
		return kResultTrue;
	}
};

// ---------------------------------------------------------------------------
class Probe : public IComponent, public IAudioProcessor, public IEditController {
public:
	uint32 refs = 1;
	double gain = 0.5;
	bool gate = false;
	int note_key = 60;
	int note_id = -1;
	double phase = 0.0;
	double rate = 48000.0;
	IComponentHandler *handler = nullptr;

	tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
		if (same_iid(iid, FUnknown_iid) || same_iid(iid, IComponent_iid) ||
				same_iid(iid, IPluginBase_iid)) {
			*obj = static_cast<IComponent *>(this);
		} else if (same_iid(iid, IAudioProcessor_iid)) {
			*obj = static_cast<IAudioProcessor *>(this);
		} else if (same_iid(iid, IEditController_iid)) {
			*obj = static_cast<IEditController *>(this);
		} else {
			*obj = nullptr;
			return kNoInterface;
		}
		refs++;
		return kResultOk;
	}
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++refs; }
	uint32 PLUGIN_API release() SMTG_OVERRIDE {
		if (--refs == 0) { delete this; return 0; }
		return refs;
	}

	// --- IPluginBase
	tresult PLUGIN_API initialize(FUnknown *) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API terminate() SMTG_OVERRIDE { return kResultOk; }

	// --- IComponent
	tresult PLUGIN_API getControllerClassId(TUID cid) SMTG_OVERRIDE {
#if defined(CD_PROBE_CTRL_CID)
		// "My controller is a class called <me>" -- true, and a trap: the host
		// has to notice it is being pointed back at the object it already has
		// rather than make another one.
		std::memcpy(cid, kProbeCID, sizeof(TUID));
		return kResultOk;
#else
		(void)cid;
		return kNotImplemented;
#endif
	}
	tresult PLUGIN_API setIoMode(IoMode) SMTG_OVERRIDE { return kNotImplemented; }
	int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) SMTG_OVERRIDE {
#if defined(CD_PROBE_NOTES)
		if (type == kEvent) return dir == kInput ? 1 : 0;
		return dir == kOutput ? 1 : 0;      // an instrument: notes in, audio out
#else
		(void)dir;
		return type == kAudio ? 1 : 0;
#endif
	}
	tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index,
			BusInfo &info) SMTG_OVERRIDE {
		if (index != 0) return kInvalidArgument;
#if defined(CD_PROBE_NOTES)
		if (type == kEvent) {
			if (dir != kInput) return kInvalidArgument;
			info.mediaType = kEvent;
			info.direction = dir;
			info.channelCount = 16;
			to_utf16("Notes", info.name, 128);
			info.busType = kMain;
			info.flags = BusInfo::kDefaultActive;
			return kResultOk;
		}
		if (dir != kOutput) return kInvalidArgument;
#endif
		if (type != kAudio) return kInvalidArgument;
		info.mediaType = kAudio;
		info.direction = dir;
		info.channelCount = 2;
		to_utf16(dir == kInput ? "In" : "Out", info.name, 128);
		info.busType = kMain;
		info.flags = BusInfo::kDefaultActive;
		return kResultOk;
	}
	tresult PLUGIN_API getRoutingInfo(RoutingInfo &, RoutingInfo &) SMTG_OVERRIDE {
		return kNotImplemented;
	}
	tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) SMTG_OVERRIDE {
		return kResultOk;
	}
	tresult PLUGIN_API setActive(TBool) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API setState(IBStream *s) SMTG_OVERRIDE {
		if (!s) return kInvalidArgument;
		int32 got = 0;
		double v = 0.0;
		if (s->read(&v, sizeof(v), &got) == kResultOk && got == (int32)sizeof(v)) gain = v;
		return kResultOk;
	}
	tresult PLUGIN_API getState(IBStream *s) SMTG_OVERRIDE {
		if (!s) return kInvalidArgument;
		int32 put = 0;
		s->write(&gain, sizeof(gain), &put);
		return kResultOk;
	}

	// --- IAudioProcessor
	tresult PLUGIN_API setBusArrangements(SpeakerArrangement *, int32,
			SpeakerArrangement *, int32) SMTG_OVERRIDE {
		return kResultOk;
	}
	tresult PLUGIN_API getBusArrangement(BusDirection, int32,
			SpeakerArrangement &arr) SMTG_OVERRIDE {
		arr = SpeakerArr::kStereo;
		return kResultOk;
	}
	tresult PLUGIN_API canProcessSampleSize(int32 sym) SMTG_OVERRIDE {
		return sym == kSample32 ? kResultTrue : kResultFalse;
	}
	uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE { return 0; }
	tresult PLUGIN_API setupProcessing(ProcessSetup &s) SMTG_OVERRIDE {
		rate = s.sampleRate > 0.0 ? s.sampleRate : 48000.0;
		return kResultOk;
	}
	tresult PLUGIN_API setProcessing(TBool) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API process(ProcessData &data) SMTG_OVERRIDE {
#if defined(CD_PROBE_NOTES)
		// Notes first. A note-off is only believed when it names the same note
		// id the note-on did -- unless it names none at all, which the
		// specification says means "whatever is playing at this pitch".
		if (data.inputEvents) {
			const int32 ne = data.inputEvents->getEventCount();
			for (int32 i = 0; i < ne; i++) {
				Event ev{};
				if (data.inputEvents->getEvent(i, ev) != kResultOk) continue;
				if (ev.type == Event::kNoteOnEvent) {
					gate = true;
					note_key = ev.noteOn.pitch;
					note_id = ev.noteOn.noteId;
				} else if (ev.type == Event::kNoteOffEvent) {
					const bool by_id = ev.noteOff.noteId >= 0 && ev.noteOff.noteId == note_id;
					// -1 is the value the specification gives for "no id, match
					// the pitch". Anything else negative is a host inventing
					// its own convention, and this plugin does not play along.
					const bool by_pitch = ev.noteOff.noteId == -1 && ev.noteOff.pitch == note_key;
					if (gate && (by_id || by_pitch)) {
						gate = false;
						note_id = -1;
					}
				}
			}
		}
#endif
		// Parameter changes first, so a host that automates it is obeyed.
		if (data.inputParameterChanges) {
			const int32 n = data.inputParameterChanges->getParameterCount();
			for (int32 i = 0; i < n; i++) {
				IParamValueQueue *q = data.inputParameterChanges->getParameterData(i);
				if (!q || q->getParameterId() != 0) continue;
				const int32 points = q->getPointCount();
				if (points > 0) {
					int32 off = 0;
					ParamValue v = 0.0;
					if (q->getPoint(points - 1, off, v) == kResultOk) gain = v;
				}
			}
		}
		if (data.numOutputs < 1 || data.numSamples <= 0) return kResultOk;
		const float g = (float)(gain * 2.0);
#if defined(CD_PROBE_NOTES)
		// A plain tone for as long as the note is held, and silence the
		// instant it is not: what the host does with note-offs is exactly what
		// this plugin is here to report.
		const double step = 2.0 * 3.14159265358979 * 440.0
				* std::pow(2.0, (note_key - 69) / 12.0) / (rate > 0.0 ? rate : 48000.0);
		for (int32 i = 0; i < data.numSamples; i++) {
			const float v = gate ? (float)std::sin(phase) * 0.3f * g : 0.0f;
			phase += step;
			for (int32 c = 0; c < data.outputs[0].numChannels; c++) {
				data.outputs[0].channelBuffers32[c][i] = v;
			}
		}
		return kResultOk;
#else
		for (int32 c = 0; c < data.outputs[0].numChannels; c++) {
			float *out = data.outputs[0].channelBuffers32[c];
			const float *in = (data.numInputs > 0 && c < data.inputs[0].numChannels)
					? data.inputs[0].channelBuffers32[c] : nullptr;
			for (int32 i = 0; i < data.numSamples; i++) out[i] = in ? in[i] * g : 0.0f;
		}
		return kResultOk;
#endif
	}
	uint32 PLUGIN_API getTailSamples() SMTG_OVERRIDE { return 0; }

	// --- IEditController
	tresult PLUGIN_API setComponentState(IBStream *s) SMTG_OVERRIDE { return setState(s); }
	int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE { return 1; }
	tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo &info) SMTG_OVERRIDE {
		if (index != 0) return kInvalidArgument;
		info.id = 0;
		to_utf16("Gain", info.title, 128);
		to_utf16("Gain", info.shortTitle, 128);
		to_utf16("", info.units, 128);
		info.stepCount = 0;
		info.defaultNormalizedValue = 0.5;
		info.unitId = 0;
		info.flags = ParameterInfo::kCanAutomate;
		return kResultOk;
	}
	tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue v, String128 out) SMTG_OVERRIDE {
		char buf[32];
		std::snprintf(buf, sizeof(buf), "%.2f", v);
		to_utf16(buf, out, 128);
		return kResultOk;
	}
	tresult PLUGIN_API getParamValueByString(ParamID, TChar *, ParamValue &) SMTG_OVERRIDE {
		return kNotImplemented;
	}
	ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue v) SMTG_OVERRIDE { return v; }
	ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue v) SMTG_OVERRIDE { return v; }
	ParamValue PLUGIN_API getParamNormalized(ParamID) SMTG_OVERRIDE { return gain; }
	tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue v) SMTG_OVERRIDE {
		if (id != 0) return kInvalidArgument;
		gain = v;
		return kResultOk;
	}
	tresult PLUGIN_API setComponentHandler(IComponentHandler *h) SMTG_OVERRIDE {
		handler = h;
		return kResultOk;
	}
	IPlugView *PLUGIN_API createView(FIDString name) SMTG_OVERRIDE {
		if (name && std::strcmp(name, ViewType::kEditor) == 0) return new ProbeView();
		return nullptr;
	}
};

// ---------------------------------------------------------------------------
// The factory
// ---------------------------------------------------------------------------
class Factory : public IPluginFactory2 {
public:
	tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
		if (same_iid(iid, FUnknown_iid) || same_iid(iid, IPluginFactory_iid) ||
				same_iid(iid, IPluginFactory2_iid)) {
			*obj = this;
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; }
	uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }

	tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) SMTG_OVERRIDE {
		if (!info) return kInvalidArgument;
		std::strcpy(info->vendor, "Cadmium");
		std::strcpy(info->url, "");
		std::strcpy(info->email, "");
		info->flags = PFactoryInfo::kUnicode;
		return kResultOk;
	}
	int32 PLUGIN_API countClasses() SMTG_OVERRIDE { return 1; }
	tresult PLUGIN_API getClassInfo(int32 index, PClassInfo *info) SMTG_OVERRIDE {
		if (index != 0 || !info) return kInvalidArgument;
		std::memcpy(info->cid, kProbeCID, sizeof(TUID));
		info->cardinality = PClassInfo::kManyInstances;
		std::strcpy(info->category, kVstAudioEffectClass);
		std::strcpy(info->name, kProbeName);
		return kResultOk;
	}
	tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2 *info) SMTG_OVERRIDE {
		if (index != 0 || !info) return kInvalidArgument;
		std::memcpy(info->cid, kProbeCID, sizeof(TUID));
		info->cardinality = PClassInfo::kManyInstances;
		std::strcpy(info->category, kVstAudioEffectClass);
		std::strcpy(info->name, kProbeName);
		info->classFlags = 0;
		std::strcpy(info->subCategories, "Fx");
		std::strcpy(info->vendor, "Cadmium");
		std::strcpy(info->version, "1.0.0");
		std::strcpy(info->sdkVersion, "VST 3.7");
		return kResultOk;
	}
	tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) SMTG_OVERRIDE {
		if (!cid || !obj) return kInvalidArgument;
		if (std::memcmp(cid, kProbeCID, sizeof(TUID)) != 0) return kNoInterface;
		Probe *p = new Probe();
		const tresult r = p->queryInterface(iid, obj);
		p->release();
		return r;
	}
};

static Factory g_factory;

extern "C" {

#if defined(_WIN32)
__declspec(dllexport) bool PLUGIN_API InitDll() { return true; }
__declspec(dllexport) bool PLUGIN_API ExitDll() { return true; }
__declspec(dllexport) IPluginFactory *PLUGIN_API GetPluginFactory() { return &g_factory; }
#else
bool ModuleEntry(void *) { return true; }
bool ModuleExit() { return true; }
IPluginFactory *GetPluginFactory() { return &g_factory; }
#endif

}
