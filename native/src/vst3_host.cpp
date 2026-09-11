#include "vst3_host.h"

#include "crashlog.h"
#include "vst3_editor.h"

#include <cctype>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <dirent.h>
#include <map>
#include <set>
#include <mutex>
#include <sys/stat.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
#if defined(_WIN32)
/// Windows' byte-oriented file calls go through the local code page, so a path
/// with anything outside it in -- a plugin under a user folder with an accent
/// in the name -- would not be found. Everything here goes wide.
static std::wstring wide(const std::string &utf8) {
	if (utf8.empty()) return std::wstring();
	const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
	std::wstring w((size_t)std::max(0, n), L'\0');
	if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &w[0], n);
	return w;
}
static std::string narrow(const std::wstring &w) {
	if (w.empty()) return std::string();
	const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
	std::string s((size_t)std::max(0, n), '\0');
	if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
	return s;
}
#endif
} // namespace

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstpluginterfacesupport.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstunits.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace cd {

#if defined(_WIN32)
/// The path Windows itself would call this file: backslashes throughout (the
/// loader works the containing folder out by looking for the last one, and a
/// path written with forward slashes leaves it looking at the wrong folder),
/// links followed to whatever they point at, and no \\?\ in front of it,
/// which some plugins do not expect to see.
static std::wstring win_real_path(const std::string &utf8) {
	std::wstring w = wide(utf8);
	for (wchar_t &c : w) {
		if (c == L'/') c = L'\\';
	}
	HANDLE h = CreateFileW(w.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
	if (h == INVALID_HANDLE_VALUE) return w;
	std::wstring out(1024, L'\0');
	const DWORD n = GetFinalPathNameByHandleW(h, &out[0], (DWORD)out.size() - 1,
			FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
	CloseHandle(h);
	if (n == 0 || n >= out.size()) return w;
	out.resize(n);
	if (out.compare(0, 8, L"\\\\?\\UNC\\") == 0) out = L"\\\\" + out.substr(8);
	else if (out.compare(0, 4, L"\\\\?\\") == 0) out.erase(0, 4);
	return out;
}
#endif

static bool iid_eq(const TUID a, const TUID b) { return std::memcmp(a, b, 16) == 0; }

// Host-side COM objects outlive every plugin that holds them (they are members
// of Vst3Impl), so reference counting is a formality: never delete on release.
#define CD_UNKNOWN_REFS \
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; } \
	uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }

static void str_to_utf8(const char16_t *src, char *dst, size_t cap) {
	size_t o = 0;
	for (size_t i = 0; src && src[i] && o + 4 < cap; i++) {
		const unsigned int c = (unsigned int)src[i];
		if (c < 0x80) {
			dst[o++] = (char)c;
		} else if (c < 0x800) {
			dst[o++] = (char)(0xC0 | (c >> 6));
			dst[o++] = (char)(0x80 | (c & 0x3F));
		} else {
			dst[o++] = (char)(0xE0 | (c >> 12));
			dst[o++] = (char)(0x80 | ((c >> 6) & 0x3F));
			dst[o++] = (char)(0x80 | (c & 0x3F));
		}
	}
	dst[o] = 0;
}

static void utf8_to_str(const char *src, char16_t *dst, size_t cap) {
	size_t o = 0;
	for (size_t i = 0; src && src[i] && o + 1 < cap; i++) dst[o++] = (char16_t)(unsigned char)src[i];
	dst[o] = 0;
}

// ---------------------------------------------------------------------------
// Host-provided objects
// ---------------------------------------------------------------------------
class HostAttributeList : public IAttributeList {
public:
	std::vector<std::pair<std::string, int64>> ints;
	std::vector<std::pair<std::string, double>> floats;
	std::vector<std::pair<std::string, std::string>> strings;
	std::vector<std::pair<std::string, std::vector<char>>> bins;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IAttributeList_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	tresult PLUGIN_API setInt(AttrID id, int64 value) SMTG_OVERRIDE { ints.push_back({id, value}); return kResultOk; }
	tresult PLUGIN_API getInt(AttrID id, int64 &value) SMTG_OVERRIDE {
		for (auto &e : ints) if (e.first == id) { value = e.second; return kResultOk; }
		return kResultFalse;
	}
	tresult PLUGIN_API setFloat(AttrID id, double value) SMTG_OVERRIDE { floats.push_back({id, value}); return kResultOk; }
	tresult PLUGIN_API getFloat(AttrID id, double &value) SMTG_OVERRIDE {
		for (auto &e : floats) if (e.first == id) { value = e.second; return kResultOk; }
		return kResultFalse;
	}
	tresult PLUGIN_API setString(AttrID id, const TChar *string) SMTG_OVERRIDE {
		char buf[1024];
		str_to_utf8((const char16_t *)string, buf, sizeof(buf));
		strings.push_back({id, buf});
		return kResultOk;
	}
	tresult PLUGIN_API getString(AttrID id, TChar *string, uint32 sizeInBytes) SMTG_OVERRIDE {
		for (auto &e : strings) {
			if (e.first == id) {
				utf8_to_str(e.second.c_str(), (char16_t *)string, sizeInBytes / sizeof(TChar));
				return kResultOk;
			}
		}
		return kResultFalse;
	}
	tresult PLUGIN_API setBinary(AttrID id, const void *data, uint32 sizeInBytes) SMTG_OVERRIDE {
		std::vector<char> v((const char *)data, (const char *)data + sizeInBytes);
		bins.push_back({id, v});
		return kResultOk;
	}
	tresult PLUGIN_API getBinary(AttrID id, const void *&data, uint32 &sizeInBytes) SMTG_OVERRIDE {
		for (auto &e : bins) {
			if (e.first == id) { data = e.second.data(); sizeInBytes = (uint32)e.second.size(); return kResultOk; }
		}
		return kResultFalse;
	}
};

class HostMessage : public IMessage {
public:
	std::string id;
	HostAttributeList attrs;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IMessage_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++rc; }
	uint32 PLUGIN_API release() SMTG_OVERRIDE {
		const int32 r = --rc;
		if (r <= 0) { delete this; return 0; }
		return (uint32)r;
	}
	std::atomic<int32> rc{1};

	const char *PLUGIN_API getMessageID() SMTG_OVERRIDE { return id.c_str(); }
	void PLUGIN_API setMessageID(const char *mid) SMTG_OVERRIDE { id = mid ? mid : ""; }
	IAttributeList *PLUGIN_API getAttributes() SMTG_OVERRIDE { return &attrs; }
};

class HostApp : public IHostApplication, public IPlugInterfaceSupport {
public:
	// Plugins are allowed to ask the host context for a run loop before they
	// ever create a view, so it is offered here too.
	FUnknown *run_loop = nullptr;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IHostApplication_iid)) {
			*obj = static_cast<IHostApplication *>(this);
			return kResultOk;
		}
		// Asked by plugins that want to know what they may rely on before they
		// try it. Answering at all is worth more than the answers: a host that
		// does not know the question tends to be treated as an old one.
		if (iid_eq(_iid, IPlugInterfaceSupport_iid)) {
			*obj = static_cast<IPlugInterfaceSupport *>(this);
			return kResultOk;
		}
		if (run_loop && iid_eq(_iid, Steinberg::Linux::IRunLoop_iid)) return run_loop->queryInterface(_iid, obj);
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	// --- IPlugInterfaceSupport
	tresult PLUGIN_API isPlugInterfaceSupported(const TUID _iid) SMTG_OVERRIDE {
		const TUID *known[] = {
			&IComponent_iid, &IAudioProcessor_iid, &IEditController_iid,
			&IConnectionPoint_iid, &IPlugView_iid, &IUnitInfo_iid,
		};
		for (const TUID *k : known) {
			if (iid_eq(_iid, *k)) return kResultTrue;
		}
		return kResultFalse;
	}

	tresult PLUGIN_API getName(String128 name) SMTG_OVERRIDE {
		utf8_to_str("Cadmium", (char16_t *)name, 128);
		return kResultOk;
	}
	tresult PLUGIN_API createInstance(TUID cid, TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(cid, IMessage_iid) && iid_eq(_iid, IMessage_iid)) { *obj = new HostMessage(); return kResultOk; }
		if (iid_eq(cid, IAttributeList_iid) && iid_eq(_iid, IAttributeList_iid)) { *obj = new HostAttributeList(); return kResultOk; }
		*obj = nullptr;
		return kResultFalse;
	}
};

class ParamQueue : public IParamValueQueue {
public:
	ParamID pid = 0;
	std::vector<std::pair<int32, ParamValue>> points;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IParamValueQueue_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	ParamID PLUGIN_API getParameterId() SMTG_OVERRIDE { return pid; }
	int32 PLUGIN_API getPointCount() SMTG_OVERRIDE { return (int32)points.size(); }
	tresult PLUGIN_API getPoint(int32 index, int32 &sampleOffset, ParamValue &value) SMTG_OVERRIDE {
		if (index < 0 || index >= (int32)points.size()) return kResultFalse;
		sampleOffset = points[(size_t)index].first;
		value = points[(size_t)index].second;
		return kResultOk;
	}
	tresult PLUGIN_API addPoint(int32 sampleOffset, ParamValue value, int32 &index) SMTG_OVERRIDE {
		// One value per moment. Two changes to the same parameter at the same
		// point in the block is a question with no answer -- a plugin is free
		// to read either -- and it happens whenever a knob is dragged, or a
		// control is put back and moved again in the same block. The later
		// value is the one that was meant.
		if (!points.empty() && points.back().first == sampleOffset) {
			points.back().second = value;
			index = (int32)points.size() - 1;
			return kResultOk;
		}
		points.push_back({sampleOffset, value});
		index = (int32)points.size() - 1;
		return kResultOk;
	}
};

class ParamChanges : public IParameterChanges {
public:
	std::vector<ParamQueue *> queues;
	int used = 0;

	~ParamChanges() { for (auto *q : queues) delete q; }
	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IParameterChanges_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	void clear() { used = 0; }
	int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE { return used; }
	IParamValueQueue *PLUGIN_API getParameterData(int32 index) SMTG_OVERRIDE {
		return (index >= 0 && index < used) ? queues[(size_t)index] : nullptr;
	}
	IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id, int32 &index) SMTG_OVERRIDE {
		for (int i = 0; i < used; i++) {
			if (queues[(size_t)i]->pid == id) { index = i; return queues[(size_t)i]; }
		}
		if (used >= (int)queues.size()) queues.push_back(new ParamQueue());
		ParamQueue *q = queues[(size_t)used];
		q->pid = id;
		q->points.clear();
		index = used++;
		return q;
	}
	void push(ParamID id, ParamValue v, int32 offset) {
		int32 idx = 0;
		IParamValueQueue *q = addParameterData(id, idx);
		int32 pt = 0;
		q->addPoint(offset, v, pt);
	}
};

class EventList : public IEventList {
public:
	std::vector<Event> events;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IEventList_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	int32 PLUGIN_API getEventCount() SMTG_OVERRIDE { return (int32)events.size(); }
	tresult PLUGIN_API getEvent(int32 index, Event &e) SMTG_OVERRIDE {
		if (index < 0 || index >= (int32)events.size()) return kResultFalse;
		e = events[(size_t)index];
		return kResultOk;
	}
	tresult PLUGIN_API addEvent(Event &e) SMTG_OVERRIDE { events.push_back(e); return kResultOk; }
};

class MemStream : public IBStream {
public:
	std::vector<char> buf;
	int64 pos = 0;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IBStream_iid)) { *obj = this; return kResultOk; }
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	tresult PLUGIN_API read(void *buffer, int32 numBytes, int32 *numBytesRead) SMTG_OVERRIDE {
		const int64 left = (int64)buf.size() - pos;
		const int32 n = (int32)std::min((int64)numBytes, std::max((int64)0, left));
		if (n > 0) std::memcpy(buffer, buf.data() + pos, (size_t)n);
		pos += n;
		if (numBytesRead) *numBytesRead = n;
		return kResultOk;
	}
	tresult PLUGIN_API write(void *buffer, int32 numBytes, int32 *numBytesWritten) SMTG_OVERRIDE {
		if (pos + numBytes > (int64)buf.size()) buf.resize((size_t)(pos + numBytes));
		std::memcpy(buf.data() + pos, buffer, (size_t)numBytes);
		pos += numBytes;
		if (numBytesWritten) *numBytesWritten = numBytes;
		return kResultOk;
	}
	tresult PLUGIN_API seek(int64 p, int32 mode, int64 *result) SMTG_OVERRIDE {
		if (mode == kIBSeekSet) pos = p;
		else if (mode == kIBSeekCur) pos += p;
		else pos = (int64)buf.size() + p;
		pos = std::max((int64)0, std::min((int64)buf.size(), pos));
		if (result) *result = pos;
		return kResultOk;
	}
	tresult PLUGIN_API tell(int64 *p) SMTG_OVERRIDE { if (p) *p = pos; return kResultOk; }
};

class Handler : public IComponentHandler, public IComponentHandler2 {
public:
	// Edits made inside the plugin's own editor, drained by the UI thread.
	std::vector<std::pair<ParamID, ParamValue>> edits;
	// The same edits on their way to the processor. A knob turned inside the
	// plugin's own interface is reported to the host and to nobody else: it is
	// the host's job to hand it to the audio side as a parameter change, and
	// until it does, the plugin's own controls do not affect what you hear.
	std::mutex to_processor_lock;
	std::vector<std::pair<ParamID, ParamValue>> to_processor;
	bool restart_requested = false;
	/// The plugin says its state has changed: read it back at the next undo
	/// point rather than assuming nothing moved.
	bool dirty = false;

	/// Called from the audio thread, at the top of a process block.
	void drain_to(ParamChanges &changes) {
		std::lock_guard<std::mutex> g(to_processor_lock);
		for (const auto &e : to_processor) changes.push(e.first, e.second, 0);
		to_processor.clear();
	}

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (iid_eq(_iid, FUnknown_iid) || iid_eq(_iid, IComponentHandler_iid)) {
			*obj = static_cast<IComponentHandler *>(this);
			return kResultOk;
		}
		// The second one is what a plugin asks for to say "I have been edited"
		// and to group a gesture into one undo step. Plenty of the bigger
		// instruments query it on the way up and take its absence as a host
		// that will not remember anything they do.
		if (iid_eq(_iid, IComponentHandler2_iid)) {
			*obj = static_cast<IComponentHandler2 *>(this);
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	CD_UNKNOWN_REFS

	// --- IComponentHandler2
	tresult PLUGIN_API setDirty(TBool state) SMTG_OVERRIDE {
		if (state) dirty = true;
		return kResultOk;
	}
	tresult PLUGIN_API requestOpenEditor(FIDString) SMTG_OVERRIDE { return kResultFalse; }
	tresult PLUGIN_API startGroupEdit() SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API finishGroupEdit() SMTG_OVERRIDE { return kResultOk; }

	tresult PLUGIN_API beginEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API performEdit(ParamID id, ParamValue v) SMTG_OVERRIDE {
		edits.push_back({id, v});
		{
			std::lock_guard<std::mutex> g(to_processor_lock);
			to_processor.push_back({id, v});
		}
		return kResultOk;
	}
	tresult PLUGIN_API endEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
	tresult PLUGIN_API restartComponent(int32) SMTG_OVERRIDE { restart_requested = true; return kResultOk; }
};

// ---------------------------------------------------------------------------
// Module loading
// ---------------------------------------------------------------------------
typedef IPluginFactory *(PLUGIN_API *GetFactoryProc)();
typedef bool (PLUGIN_API *ModuleEntryProc)(void *);
typedef bool (PLUGIN_API *ModuleExitProc)();

// The bundle layout and the module entry points differ per platform; the rest
// of the host does not care which one it got.
#if defined(_WIN32)
static const char *kBundleSubdir = "/Contents/x86_64-win";
static const char *kBundleExt = ".vst3";
static const char *kEntryName = "InitDll";
static const char *kExitName = "ExitDll";
#else
static const char *kBundleSubdir = "/Contents/x86_64-linux";
static const char *kBundleExt = ".so";
static const char *kEntryName = "ModuleEntry";
static const char *kExitName = "ModuleExit";
#endif

struct Module {
	void *handle = nullptr;
	IPluginFactory *factory = nullptr;
	ModuleExitProc exit_proc = nullptr;
	std::string so_path;
	/// Instances alive from this module. A scan opens every bundle it finds
	/// and creates nothing, and a hundred idle plugin libraries -- one of them
	/// a sample player with gigabytes mapped -- is not something to hold on to
	/// for the rest of the session.
	int instances = 0;

	~Module() { unload(); }

	static bool has_ext(const std::string &n, const std::string &ext) {
		return n.size() > ext.size() && n.compare(n.size() - ext.size(), ext.size(), ext) == 0;
	}

	// A VST3 is a folder on Linux and usually a folder on Windows too; a bare
	// DLL named *.vst3 is also legal there, so a plain file is accepted.
	static std::string binary_for(const std::string &bundle) {
#if defined(_WIN32)
		const DWORD at = GetFileAttributesW(wide(bundle).c_str());
		// A bare DLL named .vst3 is as legal as a bundle folder, and some
		// older plugins still ship that way.
		if (at != INVALID_FILE_ATTRIBUTES && !(at & FILE_ATTRIBUTE_DIRECTORY)) return bundle;
		const std::string dir = bundle + kBundleSubdir;
		WIN32_FIND_DATAW fd{};
		HANDLE h = FindFirstFileW(wide(dir + "/*").c_str(), &fd);
		if (h == INVALID_HANDLE_VALUE) return std::string();
		std::string found;
		do {
			const std::string n = narrow(fd.cFileName);
			if (has_ext(n, kBundleExt)) { found = dir + "/" + n; break; }
		} while (FindNextFileW(h, &fd));
		FindClose(h);
		return found;
#else
		struct stat st;
		if (stat(bundle.c_str(), &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG) return bundle;
		const std::string dir = bundle + kBundleSubdir;
		DIR *d = opendir(dir.c_str());
		if (!d) return std::string();
		std::string found;
		while (dirent *e = readdir(d)) {
			const std::string n = e->d_name;
			if (has_ext(n, kBundleExt)) { found = dir + "/" + n; break; }
		}
		closedir(d);
		return found;
#endif
	}

#if defined(_WIN32)
	/// Windows plugins expect the thread that loads them to have COM going:
	/// licensing, embedded browsers, the system's own dialogs and half of what
	/// a big commercial instrument does on the way up are COM. Steinberg's own
	/// hosting code does this before it loads anything, and a plugin that
	/// assumes it and finds it missing falls over inside its own code where
	/// nothing here can help it.
	///
	/// Asked for as a single-threaded apartment, which is what plugin
	/// interfaces want. If something else got there first with another idea,
	/// that is fine: it is initialised either way, which is what matters.
	static void ensure_com() {
		// Per thread, because that is what an apartment is: a thread that has
		// not called this has no COM, whatever some other thread did.
		static thread_local bool once = false;
		if (once) return;
		once = true;
		const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
		(void)hr;   // S_FALSE and RPC_E_CHANGED_MODE both mean "already going"
	}
#endif

	static void *open_lib(const std::string &path) {
#if defined(_WIN32)
		ensure_com();
		// Plugins routinely ship helper DLLs in the same folder as the module
		// and expect the loader to find them there. Without the altered search
		// path they load on the developer's machine and nowhere else.
		//
		// Which folder that is has to be the *real* one. A plugin installed on
		// a second drive is reached through a link left in the VST3 folder --
		// Roland Cloud installs that way, and so does anyone who moved a big
		// library off the system disk -- and the altered search path is worked
		// out from the name it was given, not from where the file turned out
		// to be. Handed the link, the loader looks for the plugin's own DLLs
		// beside the link and does not find them; the plugin then calls
		// through whatever it got back and takes the program down inside its
		// own code, on the way up, every time.
		return (void *)LoadLibraryExW(win_real_path(path).c_str(), nullptr,
				LOAD_WITH_ALTERED_SEARCH_PATH);
#else
		return dlopen(path.c_str(), RTLD_LOCAL | RTLD_NOW);
#endif
	}
	static void *sym(void *h, const char *name) {
#if defined(_WIN32)
		return (void *)GetProcAddress((HMODULE)h, name);
#else
		return dlsym(h, name);
#endif
	}
	static void close_lib(void *h) {
#if defined(_WIN32)
		FreeLibrary((HMODULE)h);
#else
		dlclose(h);
#endif
	}

	bool load(const std::string &bundle) {
		so_path = binary_for(bundle);
		if (so_path.empty()) return false;
		handle = open_lib(so_path);
		if (!handle) return false;
		auto entry = (ModuleEntryProc)sym(handle, kEntryName);
		exit_proc = (ModuleExitProc)sym(handle, kExitName);
#if defined(_WIN32)
		// InitDll takes no argument; the cast is safe because the ABI passes
		// the unused one in a register the callee ignores.
		if (entry && !((bool (PLUGIN_API *)())entry)()) { unload(); return false; }
#else
		if (entry && !entry(handle)) { unload(); return false; }
#endif
		auto get = (GetFactoryProc)sym(handle, "GetPluginFactory");
		if (!get) { unload(); return false; }
		factory = get();
		return factory != nullptr;
	}
	void unload() {
		if (factory) { factory->release(); factory = nullptr; }
		if (exit_proc) { exit_proc(); exit_proc = nullptr; }
		if (handle) { close_lib(handle); handle = nullptr; }
	}
};

// Modules are shared and never unloaded.
//
// A bundle holds process-wide state -- JUCE's singletons and its message
// thread, VSTGUI's shared resources -- so a second instance of the same plugin
// must not load it a second time, and *nobody* may call ModuleExit or dlclose
// while any instance is alive. Doing so is what made Cadmium die on quit after
// a plugin's editor had been open ("JUCE Assertion failure in juce_Singleton.h"
// followed by a segfault in the unloaded library's static destructors).
//
// Every real host does the same thing: load once per path, keep it for the life
// of the process, and let the operating system reclaim it at exit. The cost is
// one leaked handle per distinct plugin; the alternative is a crash.
static std::mutex g_module_lock;
static std::map<std::string, Module *> g_modules;

/// The module for `bundle`, loaded if this is the first time it is asked for.
/// Never null-checked against unloading: the pointer stays valid forever.
/// The context handed to a plugin *factory*. It must outlive every instance:
/// `IPluginFactory3::setHostContext` is factory-wide, and a factory given a
/// context that belongs to one instance keeps using it after that instance is
/// gone. Passing a per-instance one crashed DPF plugins (Dragonfly, ZaM*) the
/// moment a second copy of the same plugin was created.
static HostApp &factory_host() {
	static HostApp host;
	static bool once = false;
	if (!once) {
		once = true;
		host.run_loop = vst3_global_run_loop();
	}
	return host;
}

static Module *shared_module(const std::string &bundle) {
	std::lock_guard<std::mutex> g(g_module_lock);
	auto it = g_modules.find(bundle);
	if (it != g_modules.end()) return it->second;
	Module *m = new Module();
	if (!m->load(bundle)) {
		// A module that failed to initialise is safe to close, since nothing
		// of it is live yet.
		delete m;
		g_modules[bundle] = nullptr;
		return nullptr;
	}
	// Once per factory, with the context that lives as long as the module does.
	IPluginFactory3 *f3 = nullptr;
	if (m->factory->queryInterface(IPluginFactory3_iid, (void **)&f3) == kResultOk && f3) {
		f3->setHostContext(static_cast<FUnknown *>(static_cast<IHostApplication *>(&factory_host())));
		f3->release();
	}
	g_modules[bundle] = m;
	return m;
}

static std::string tuid_hex(const TUID id) {
	static const char *hex = "0123456789ABCDEF";
	std::string s;
	s.reserve(32);
	for (int i = 0; i < 16; i++) {
		s += hex[((unsigned char)id[i]) >> 4];
		s += hex[((unsigned char)id[i]) & 0xF];
	}
	return s;
}

static bool hex_tuid(const std::string &s, TUID out) {
	if (s.size() != 32) return false;
	for (int i = 0; i < 16; i++) {
		auto nib = [](char c) -> int {
			if (c >= '0' && c <= '9') return c - '0';
			if (c >= 'a' && c <= 'f') return c - 'a' + 10;
			if (c >= 'A' && c <= 'F') return c - 'A' + 10;
			return -1;
		};
		const int a = nib(s[(size_t)i * 2]), b = nib(s[(size_t)i * 2 + 1]);
		if (a < 0 || b < 0) return false;
		out[i] = (char)((a << 4) | b);
	}
	return true;
}

#if defined(_WIN32)
/// One string value out of the registry, empty if it is not there. Plugin
/// folders chosen during an install are recorded here and nowhere else.
static std::string reg_string(HKEY root, const char *key, const char *name) {
	HKEY h = nullptr;
	if (RegOpenKeyExA(root, key, 0, KEY_READ | KEY_WOW64_64KEY, &h) != ERROR_SUCCESS) return "";
	char buf[1024];
	DWORD len = sizeof(buf);
	DWORD type = 0;
	const LONG r = RegQueryValueExA(h, name, nullptr, &type, (LPBYTE)buf, &len);
	RegCloseKey(h);
	if (r != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) || len == 0) return "";
	return std::string(buf, strnlen(buf, sizeof(buf)));
}
#endif

std::vector<std::string> vst3_default_dirs() {
	std::vector<std::string> v;
#if defined(_WIN32)
	// The locations the specification names, and then the ones installers
	// actually use. Kilohearts, Spectrasonics and a good part of the rest put
	// their bundles in a folder of their own next to the standard one, and a
	// plugin nobody looks for is a plugin the user is told they do not have.
	const char *common = getenv("CommonProgramFiles");
	if (common) v.push_back(std::string(common) + "\\VST3");
	const char *common86 = getenv("CommonProgramFiles(x86)");
	if (common86) v.push_back(std::string(common86) + "\\VST3");
	const char *local = getenv("LOCALAPPDATA");
	if (local) {
		v.push_back(std::string(local) + "\\Programs\\Common\\VST3");
		v.push_back(std::string(local) + "\\VST3");
	}
	const char *appdata = getenv("APPDATA");
	if (appdata) v.push_back(std::string(appdata) + "\\VST3");
	const char *pf = getenv("ProgramFiles");
	if (pf) {
		v.push_back(std::string(pf) + "\\VST3");
		v.push_back(std::string(pf) + "\\Common Files\\VST3");
		v.push_back(std::string(pf) + "\\Steinberg\\VSTPlugins");
		v.push_back(std::string(pf) + "\\Steinberg\\VST3");
		v.push_back(std::string(pf) + "\\VSTPlugins");
		v.push_back(std::string(pf) + "\\Native Instruments");
	}
	const char *pf86 = getenv("ProgramFiles(x86)");
	if (pf86) {
		v.push_back(std::string(pf86) + "\\VST3");
		v.push_back(std::string(pf86) + "\\Common Files\\VST3");
		v.push_back(std::string(pf86) + "\\Steinberg\\VSTPlugins");
		v.push_back(std::string(pf86) + "\\VSTPlugins");
	}
	// The folder the user chose in some other host's installer, which is where
	// a good number of plugins actually live. Both hives, because an installer
	// run for one user writes the other one.
	for (const char *key : {"SOFTWARE\\VST3", "SOFTWARE\\VST"}) {
		for (HKEY root : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
			for (const char *name : {"VST3PluginsPath", "VSTPluginsPath", "Path"}) {
				const std::string p = reg_string(root, key, name);
				if (!p.empty()) v.push_back(p);
			}
		}
	}
	const char *sysdrive = getenv("SystemDrive");
	const std::string drive = sysdrive ? sysdrive : "C:";
	v.push_back(drive + "\\VST3");
	v.push_back(drive + "\\VSTPlugins");
	v.push_back(drive + "\\Program Files\\VST3");
#else
	const char *home = getenv("HOME");
	if (home) {
		v.push_back(std::string(home) + "/.vst3");
		v.push_back(std::string(home) + "/.local/share/vst3");
	}
	const char *xdg = getenv("XDG_DATA_HOME");
	if (xdg) v.push_back(std::string(xdg) + "/vst3");
	// The specification names the first two; the rest are where distributions
	// and sandboxes actually put them.
	v.push_back("/usr/lib/vst3");
	v.push_back("/usr/local/lib/vst3");
	v.push_back("/usr/lib64/vst3");
	v.push_back("/usr/lib/x86_64-linux-gnu/vst3");
	v.push_back("/usr/share/vst3");
	v.push_back("/usr/local/share/vst3");
	v.push_back("/app/extensions/Plugins/vst3");
#endif
	const char *env = getenv("VST3_PATH");
	if (env) {
		// A drive letter has a colon in it, so Windows separates its path
		// lists with a semicolon and the rest of the world with a colon.
#if defined(_WIN32)
		const char sep = ';';
#else
		const char sep = ':';
#endif
		std::string s(env);
		size_t start = 0;
		while (start < s.size()) {
			const size_t c = s.find(sep, start);
			const std::string part = s.substr(start, c == std::string::npos ? std::string::npos : c - start);
			if (!part.empty()) v.push_back(part);
			if (c == std::string::npos) break;
			start = c + 1;
		}
	}
	return v;
}

/// The names in a folder, without the dot entries. Wide on Windows so a path
/// with anything outside the local code page in it still lists.
static std::vector<std::string> list_dir(const std::string &dir) {
	std::vector<std::string> out;
#if defined(_WIN32)
	WIN32_FIND_DATAW fd{};
	HANDLE h = FindFirstFileW(wide(dir + "/*").c_str(), &fd);
	if (h == INVALID_HANDLE_VALUE) return out;
	do {
		const std::string n = narrow(fd.cFileName);
		if (n != "." && n != "..") out.push_back(n);
	} while (FindNextFileW(h, &fd));
	FindClose(h);
#else
	DIR *d = opendir(dir.c_str());
	if (!d) return out;
	while (dirent *e = readdir(d)) {
		const std::string n = e->d_name;
		if (n != "." && n != "..") out.push_back(n);
	}
	closedir(d);
#endif
	return out;
}

static bool is_dir(const std::string &path) {
#if defined(_WIN32)
	const DWORD at = GetFileAttributesW(wide(path).c_str());
	return at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_DIRECTORY);
#else
	struct stat st;
	return stat(path.c_str(), &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
#endif
}

static void scan_one(const std::string &bundle, std::vector<Vst3Info> &out) {
	Module *mp = shared_module(bundle);
	if (!mp) {
		// Reported rather than skipped: the usual causes are a 32-bit bundle
		// on a 64-bit host and a missing dependency next to the module, and
		// both of those are things the user can act on once they are told.
		Vst3Info bad;
		bad.path = bundle;
		bad.name = bundle.substr(bundle.find_last_of("/\\") + 1);
		bad.error = "could not be loaded (wrong architecture, or a missing dependency)";
		out.push_back(bad);
		return;
	}
	Module &m = *mp;
	PFactoryInfo fi;
	m.factory->getFactoryInfo(&fi);
	const int32 count = m.factory->countClasses();
	const size_t before = out.size();
	for (int32 i = 0; i < count; i++) {
		PClassInfo ci;
		if (m.factory->getClassInfo(i, &ci) != kResultOk) continue;
		if (std::strcmp(ci.category, kVstAudioEffectClass) != 0) continue;
		Vst3Info info;
		info.path = bundle;
		info.cid = tuid_hex(ci.cid);
		info.name = ci.name;
		info.vendor = fi.vendor;
		IPluginFactory2 *f2 = nullptr;
		if (m.factory->queryInterface(IPluginFactory2_iid, (void **)&f2) == kResultOk && f2) {
			PClassInfo2 ci2;
			if (f2->getClassInfo2(i, &ci2) == kResultOk) {
				info.category = ci2.subCategories;
				info.version = ci2.version;
				if (ci2.vendor[0]) info.vendor = ci2.vendor;
			}
			f2->release();
		}
		info.instrument = info.category.find("Instrument") != std::string::npos;
		out.push_back(info);
	}
	if (out.size() == before) {
		Vst3Info bad;
		bad.path = bundle;
		bad.name = bundle.substr(bundle.find_last_of("/\\") + 1);
		bad.vendor = fi.vendor;
		bad.error = count > 0
				? "loaded, but holds no audio plugin (a helper or resource bundle)"
				: "loaded, but its factory is empty";
		out.push_back(bad);
	}
}

/// How far below a plugin folder a bundle is still looked for. Installers do
/// not all drop bundles at the top: plenty make a folder for the company, some
/// a product folder inside that, and a few one more for the version. The
/// budget is only spent on folders that could hold a bundle -- a bundle's own
/// guts are stepped over -- so this costs a directory listing, not a plugin
/// load, and a folder nobody looks in reads exactly like an empty one.
static const int kScanDepth = 8;

static bool iequal(const std::string &a, const char *b) {
	size_t i = 0;
	for (; i < a.size() && b[i]; i++) {
		if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i])) return false;
	}
	return i == a.size() && b[i] == 0;
}

/// Windows filenames are not case sensitive and installers are not consistent:
/// .vst3, .VST3 and .Vst3 all turn up, and a plugin nobody looks for is a
/// plugin the user is told they do not have.
static bool is_bundle_name(const std::string &n) {
	if (n.size() <= 5) return false;
	const std::string ext = n.substr(n.size() - 5);
	return iequal(ext, ".vst3");
}

/// Folders that only ever hold a bundle's own guts, never another bundle, plus
/// the ones that hold enough files to make walking them a waste on their own.
static bool skip_folder(const std::string &n) {
	static const char *skip[] = {
		"Contents", "Resources", "Presets", "Documentation", "Samples",
		"Wavetables", "Impulses", "Manuals", "Skins", "Themes",
	};
	if (!n.empty() && n[0] == '.') return true;   // .git, .cache and friends
	for (const char *k : skip) {
		if (iequal(n, k)) return true;
	}
	return false;
}

/// Every bundle under `dir`, found but not opened.
static void list_bundles(const std::string &dir, int depth, std::vector<std::string> &out) {
	for (const std::string &n : list_dir(dir)) {
		const std::string path = dir + "/" + n;
		if (is_bundle_name(n)) {
			out.push_back(path);
		} else if (depth > 0 && !skip_folder(n) && is_dir(path)) {
			list_bundles(path, depth - 1, out);
		}
	}
}

std::vector<std::string> vst3_bundles(const std::vector<std::string> &dirs) {
	std::vector<std::string> out;
	std::set<std::string> seen;
	for (const std::string &dir : dirs) {
		std::vector<std::string> here;
		list_bundles(dir, kScanDepth, here);
		// The same folder reaches the scanner twice often enough -- through
		// %CommonProgramFiles% and through a hand-added path -- and opening a
		// plugin twice is the slowest way to find nothing new.
		for (const std::string &b : here) {
			if (seen.insert(b).second) out.push_back(b);
		}
	}
	return out;
}

std::vector<Vst3Info> vst3_scan_bundle(const std::string &bundle) {
	cd::crash_note("looking at the plugin " + bundle);
	std::vector<Vst3Info> out;
	scan_one(bundle, out);
	cd::crash_note("");
	return out;
}

void vst3_release_unused_modules() {
	std::lock_guard<std::mutex> g(g_module_lock);
	for (auto it = g_modules.begin(); it != g_modules.end();) {
		if (it->second != nullptr && it->second->instances == 0) {
			delete it->second;
			it = g_modules.erase(it);
		} else {
			++it;
		}
	}
}

std::vector<Vst3Info> vst3_scan(const std::vector<std::string> &dirs) {
	std::vector<Vst3Info> out;
	for (const std::string &b : vst3_bundles(dirs)) scan_one(b, out);
	vst3_release_unused_modules();
	return out;
}

// ---------------------------------------------------------------------------
// The adapter
// ---------------------------------------------------------------------------
class Vst3Impl {
public:
	Module *module = nullptr;
	IComponent *component = nullptr;
	IAudioProcessor *processor = nullptr;
	IEditController *controller = nullptr;
	IConnectionPoint *cp_comp = nullptr, *cp_ctrl = nullptr;
	/// The controller is an object of its own rather than the component
	/// wearing a second interface. See where it is acquired.
	bool ctrl_separate = false;
	HostApp host;
	Vst3Editor editor;
	Handler handler;
	EventList events;
	ParamChanges in_changes, out_changes;
	ProcessContext ctx{};
	std::string err;
	bool ready = false;
	bool is_instrument = false;
	std::string bundle, cid, class_name;

	/// Notes played by hand, and the id each was given. See note_on.
	std::vector<std::pair<int, int>> live_ids;

	std::vector<ParamID> pids;
	std::vector<float> pnorm;

	int in_channels = 0, out_channels = 0;
	std::vector<std::vector<float>> in_buf, out_buf;
	std::vector<float *> in_ptr, out_ptr;
	/// Somewhere for every other bus to write.
	///
	/// A big instrument has eight or sixteen output buses -- Omnisphere's
	/// parts, a drum machine's separate outs -- and Cadmium only wants the
	/// first. Switching the rest off is allowed and is what we ask for, but a
	/// plugin is free to ignore it, and one that does reaches for the buffers
	/// of buses the host never described and writes into whatever is there.
	/// So every bus it has gets real memory, whether or not anything is going
	/// to listen to it: it costs a few kilobytes and it cannot fault.
	struct SpareBus {
		std::vector<std::vector<float>> ch;
		std::vector<float *> ptr;
	};
	std::vector<SpareBus> spare_in, spare_out;
	std::vector<AudioBusBuffers> in_bb, out_bb;
	int max_block = 512;
	double rate = 48000.0;
	int note_id = 1;

	~Vst3Impl() { teardown(); }

	void teardown() {
		// The view belongs to the controller that created it, so it has to be
		// let go of first. Releasing it afterwards is a use-after-free: it took
		// ZaMaximX2 (and every other DPF plugin) down on quit, inside the
		// plugin's own library, once its editor had been opened.
		editor.destroy();
		if (processor) { processor->setProcessing(false); }
		if (component) { component->setActive(false); }
		if (cp_comp && cp_ctrl) { cp_comp->disconnect(cp_ctrl); cp_ctrl->disconnect(cp_comp); }
		if (cp_comp) { cp_comp->release(); cp_comp = nullptr; }
		if (cp_ctrl) { cp_ctrl->release(); cp_ctrl = nullptr; }
		if (controller) {
			controller->setComponentHandler(nullptr);
			// Only when it is an object of its own: terminating the component
			// through its controller interface and then again as a component
			// is one termination too many.
			if (ctrl_separate) controller->terminate();
			controller->release();
			controller = nullptr;
		}
		if (processor) { processor->release(); processor = nullptr; }
		if (component) { component->terminate(); component->release(); component = nullptr; }
		// The module itself is deliberately left loaded; see shared_module().
		// The count is what keeps a scan from giving back a library something
		// is still playing through.
		if (module) {
			std::lock_guard<std::mutex> g(g_module_lock);
			if (module->instances > 0) module->instances--;
		}
		module = nullptr;
		ready = false;
	}
};

Vst3Plug::Vst3Plug() : d(new Vst3Impl()) {}
Vst3Plug::~Vst3Plug() {}

bool Vst3Plug::ok() const { return d && d->ready; }
const std::string &Vst3Plug::error() const { return d->err; }

bool Vst3Plug::load(const std::string &bundle, const std::string &cid_hex, double rate, int blk) {
	// The riskiest thing a host does, and the thing a report most needs to
	// name: whose code was running when it stopped.
	// Every step of it named separately. A plugin that stops the program on
	// the way up stops it inside one particular call, and which one it was is
	// the whole difference between a report that can be acted on and a report
	// that says "it broke somewhere in here".
	const std::string opening = "opening the plugin " + bundle;
	auto step = [&opening](const char *phase) { cd::crash_note(opening + " -- " + phase); };
	step("loading its library");
	d->bundle = bundle;
	d->cid = cid_hex;
	d->rate = rate;
	d->max_block = std::max(64, blk);
	sr = rate;
	block = blk;

	d->host.run_loop = d->editor.run_loop_context();
	d->module = shared_module(bundle);
	if (!d->module) { d->err = "cannot load bundle"; return false; }
	{
		std::lock_guard<std::mutex> g(g_module_lock);
		d->module->instances++;
	}
	TUID cid;
	if (!hex_tuid(cid_hex, cid)) { d->err = "bad class id"; return false; }

	step("creating it");
	if (d->module->factory->createInstance(cid, IComponent_iid, (void **)&d->component) != kResultOk || !d->component) {
		d->err = "createInstance failed";
		return false;
	}
	// The factory's context was set once, when the module was loaded.
	step("starting it up");
	if (d->component->initialize(static_cast<FUnknown *>(static_cast<IHostApplication *>(&d->host))) != kResultOk) { d->err = "component initialize failed"; return false; }
	if (d->component->queryInterface(IAudioProcessor_iid, (void **)&d->processor) != kResultOk || !d->processor) {
		d->err = "no IAudioProcessor";
		return false;
	}

	// The controller. A plugin is allowed to put the processing and the
	// interface in one object -- a "single component effect", which is what
	// FabFilter and plenty of others ship -- or to keep them in two classes
	// and name the second one.
	//
	// The component is asked first, and this order matters more than it looks:
	// a single-component plugin still answers getControllerClassId, with its
	// own class id, so making a controller from that id builds a whole second
	// copy of the plugin. The interface then belongs to one instance and the
	// audio to another, and nothing you touch in the plugin's own window has
	// any effect on what you hear.
	step("asking it for its controls");
	d->ctrl_separate = false;
	if (d->component->queryInterface(IEditController_iid, (void **)&d->controller) != kResultOk) {
		d->controller = nullptr;
	}
	if (!d->controller) {
		TUID ctrl_cid;
		if (d->component->getControllerClassId(ctrl_cid) == kResultOk
				&& d->module->factory->createInstance(ctrl_cid, IEditController_iid,
						(void **)&d->controller) == kResultOk && d->controller) {
			d->ctrl_separate = true;
			d->controller->initialize(static_cast<FUnknown *>(static_cast<IHostApplication *>(&d->host)));
		}
	}
	if (d->controller) {
		d->controller->setComponentHandler(&d->handler);
		if (d->ctrl_separate) {
			// Two objects have to be introduced to each other: a connection for
			// what they say to each other, and then the state the component
			// starts with. One object needs neither.
			//
			// The connection goes first, and the order is not a detail. A
			// controller handed its component's state routinely answers by
			// sending the component a message -- that is what the connection is
			// for -- and one that finds no connection there yet reaches for
			// something that does not exist. Steinberg's own host connects
			// first for exactly this reason; doing it the other way round is
			// what stopped Cadmium dead on Roland's Zenology, inside the
			// plugin, every single time.
			step("connecting its two halves");
			if (d->component->queryInterface(IConnectionPoint_iid, (void **)&d->cp_comp) == kResultOk &&
					d->controller->queryInterface(IConnectionPoint_iid, (void **)&d->cp_ctrl) == kResultOk &&
					d->cp_comp && d->cp_ctrl) {
				d->cp_comp->connect(d->cp_ctrl);
				d->cp_ctrl->connect(d->cp_comp);
			}
			step("handing its settings to its controls");
			MemStream st;
			if (d->component->getState(&st) == kResultOk) {
				st.seek(0, IBStream::kIBSeekSet, nullptr);
				d->controller->setComponentState(&st);
			}
		}
	}

	// Buses: activate the main audio pair and the event input.
	step("asking about its inputs and outputs");
	const int32 in_buses = d->component->getBusCount(kAudio, kInput);
	const int32 out_buses = d->component->getBusCount(kAudio, kOutput);
	const int32 ev_in = d->component->getBusCount(kEvent, kInput);
	for (int32 i = 0; i < in_buses; i++) d->component->activateBus(kAudio, kInput, i, i == 0);
	for (int32 i = 0; i < out_buses; i++) d->component->activateBus(kAudio, kOutput, i, i == 0);
	for (int32 i = 0; i < ev_in; i++) d->component->activateBus(kEvent, kInput, i, i == 0);

	// A stereo pair on the first bus and nothing on the rest, which is what
	// Cadmium actually wants. A plugin is entitled to refuse that -- some
	// insist on all of their outputs -- so if it does, it is asked for stereo
	// everywhere instead, and either way what it settled on is read back
	// rather than assumed.
	step("agreeing on an audio format");
	const SpeakerArrangement stereo = SpeakerArr::kStereo;
	std::vector<SpeakerArrangement> ins((size_t)std::max<int32>(in_buses, 0), SpeakerArr::kEmpty);
	std::vector<SpeakerArrangement> outs((size_t)std::max<int32>(out_buses, 0), SpeakerArr::kEmpty);
	if (!ins.empty()) ins[0] = stereo;
	if (!outs.empty()) outs[0] = stereo;
	if (d->processor->setBusArrangements(ins.empty() ? nullptr : ins.data(), in_buses,
			outs.empty() ? nullptr : outs.data(), out_buses) != kResultTrue) {
		std::fill(ins.begin(), ins.end(), stereo);
		std::fill(outs.begin(), outs.end(), stereo);
		d->processor->setBusArrangements(ins.empty() ? nullptr : ins.data(), in_buses,
				outs.empty() ? nullptr : outs.data(), out_buses);
	}

	BusInfo bi;
	d->in_channels = 0;
	d->out_channels = 0;
	if (in_buses > 0 && d->component->getBusInfo(kAudio, kInput, 0, bi) == kResultOk) d->in_channels = bi.channelCount;
	if (out_buses > 0 && d->component->getBusInfo(kAudio, kOutput, 0, bi) == kResultOk) d->out_channels = bi.channelCount;
	// What the plugin says it is actually going to write, which is the number
	// that decides how many buffers it will reach for.
	SpeakerArrangement got = 0;
	if (in_buses > 0 && d->processor->getBusArrangement(kInput, 0, got) == kResultOk) {
		const int n = (int)SpeakerArr::getChannelCount(got);
		if (n > 0) d->in_channels = n;
	}
	if (out_buses > 0 && d->processor->getBusArrangement(kOutput, 0, got) == kResultOk) {
		const int n = (int)SpeakerArr::getChannelCount(got);
		if (n > 0) d->out_channels = n;
	}
	d->in_channels = std::max(0, std::min(8, d->in_channels));
	d->out_channels = std::max(0, std::min(8, d->out_channels));

	step("setting it up for playback");
	ProcessSetup setup{};
	setup.processMode = kRealtime;
	setup.symbolicSampleSize = kSample32;
	setup.maxSamplesPerBlock = d->max_block;
	setup.sampleRate = rate;
	if (d->processor->setupProcessing(setup) != kResultOk) { d->err = "setupProcessing refused"; return false; }
	step("switching it on");
	d->component->setActive(true);
	d->processor->setProcessing(true);

	d->in_buf.assign((size_t)std::max(1, d->in_channels), std::vector<float>((size_t)d->max_block, 0.0f));
	d->out_buf.assign((size_t)std::max(1, d->out_channels), std::vector<float>((size_t)d->max_block, 0.0f));
	d->in_ptr.resize(d->in_buf.size());
	d->out_ptr.resize(d->out_buf.size());

	// And one of these for every bus the plugin says it has, so that a plugin
	// which writes to a bus we asked it not to writes somewhere harmless.
	auto make_spares = [&](BusDirection dir, int32 count, std::vector<Vst3Impl::SpareBus> &into) {
		into.clear();
		into.resize((size_t)std::max<int32>(0, count));
		for (int32 b = 0; b < count; b++) {
			BusInfo info{};
			int channels = 2;
			if (d->component->getBusInfo(kAudio, dir, b, info) == kResultOk) {
				channels = std::max(0, std::min(16, (int)info.channelCount));
			}
			into[(size_t)b].ch.assign((size_t)std::max(1, channels),
					std::vector<float>((size_t)d->max_block, 0.0f));
			into[(size_t)b].ptr.resize(into[(size_t)b].ch.size());
			for (size_t c = 0; c < into[(size_t)b].ch.size(); c++) {
				into[(size_t)b].ptr[c] = into[(size_t)b].ch[c].data();
			}
		}
	};
	make_spares(kInput, in_buses, d->spare_in);
	make_spares(kOutput, out_buses, d->spare_out);
	d->in_bb.assign(d->spare_in.size(), AudioBusBuffers{});
	d->out_bb.assign(d->spare_out.size(), AudioBusBuffers{});

	d->is_instrument = (d->in_channels == 0) || (d->component->getBusCount(kEvent, kInput) > 0);

	step("reading its name");
	// The factory is the only place the class name lives.
	{
		const int32 count = d->module->factory->countClasses();
		for (int32 i = 0; i < count; i++) {
			PClassInfo ci;
			if (d->module->factory->getClassInfo(i, &ci) != kResultOk) continue;
			if (iid_eq(ci.cid, cid)) { d->class_name = ci.name; break; }
		}
	}

	// Build the descriptor the UI draws from.
	dyn.id = d->cid.c_str();
	dyn.vendor = "VST3";
	dyn.category = "VST3";
	dyn.ui = UI_GENERIC;
	dyn.make = nullptr;
	dyn.params.clear();
	d->pids.clear();

	// Unit names, so a 2000-parameter synth arrives grouped the way its own
	// editor groups it instead of as one endless wall of knobs.
	step("reading how its parameters are grouped");
	std::map<int32, std::string> unit_names;
	if (d->controller) {
		IUnitInfo *units = nullptr;
		if (d->controller->queryInterface(IUnitInfo_iid, (void **)&units) == kResultOk && units) {
			const int32 n = units->getUnitCount();
			std::map<int32, std::pair<std::string, int32>> raw;
			for (int32 i = 0; i < n; i++) {
				UnitInfo ui{};
				if (units->getUnitInfo(i, ui) != kResultOk) continue;
				char nm[256];
				str_to_utf8((const char16_t *)ui.name, nm, sizeof(nm));
				raw[ui.id] = {nm, ui.parentUnitId};
			}
			for (auto &kv : raw) {
				// Walk up to the root so nested units read as "Osc 1 / Filter".
				std::string path = kv.second.first;
				int32 parent = kv.second.second;
				int guard = 0;
				while (parent > 0 && raw.count(parent) && guard++ < 6) {
					path = raw[parent].first + " / " + path;
					parent = raw[parent].second;
				}
				unit_names[kv.first] = path;
			}
			units->release();
		}
	}

	step("reading its parameters");
	if (d->controller) {
		const int32 n = d->controller->getParameterCount();
		name_pool.reserve((size_t)n);
		id_pool.reserve((size_t)n);
		for (int32 i = 0; i < n; i++) {
			ParameterInfo pi{};
			if (d->controller->getParameterInfo(i, pi) != kResultOk) continue;
			if (pi.flags & ParameterInfo::kIsProgramChange) continue;
			char title[256];
			str_to_utf8((const char16_t *)pi.title, title, sizeof(title));
			if (!title[0]) {
				// Some plugins leave whole ranges unnamed; an id beats a blank.
				snprintf(title, sizeof(title), "Param %u", (unsigned)pi.id);
			}
			name_pool.push_back(title);
			char idbuf[32];
			snprintf(idbuf, sizeof(idbuf), "p%u", (unsigned)pi.id);
			id_pool.push_back(idbuf);
			auto un = unit_names.find(pi.unitId);
			group_pool.push_back(un != unit_names.end() && !un->second.empty()
					? un->second : std::string("Parameters"));
			ParamDesc pd{};
			pd.id = id_pool.back().c_str();
			pd.name = name_pool.back().c_str();
			pd.min = 0.0f;
			pd.max = 1.0f;
			pd.def = (float)pi.defaultNormalizedValue;
			pd.kind = (pi.stepCount == 1) ? P_BOOL : P_PCT;
			pd.group = nullptr;   // repointed below, once the pool stops moving
			pd.choices = nullptr;
			pd.skew = 1.0f;
			pd.steps = (int)pi.stepCount;
			pd.readonly = (pi.flags & ParameterInfo::kIsReadOnly) != 0;
			dyn.params.push_back(pd);
			d->pids.push_back(pi.id);
		}
	}
	// The pools may have reallocated while filling; repoint every c_str().
	for (size_t i = 0; i < dyn.params.size(); i++) {
		dyn.params[i].id = id_pool[i].c_str();
		dyn.params[i].name = name_pool[i].c_str();
		dyn.params[i].group = group_pool[i].c_str();
	}
	dyn.name = d->class_name.c_str();
	dyn.category = d->is_instrument ? "VST3 Instrument" : "VST3 Effect";

	step("reading what its parameters are set to");
	d->pnorm.assign(dyn.params.size(), 0.0f);
	for (size_t i = 0; i < dyn.params.size(); i++) {
		d->pnorm[i] = d->controller ? (float)d->controller->getParamNormalized(d->pids[i]) : dyn.params[i].def;
	}
	dyn.instrument = d->is_instrument;
	d->ready = true;
	cd::crash_note("");   // it came up; whatever happens next is not this

	// Plug::init would overwrite pv from defaults; take the live values instead.
	desc = &dyn;
	pv.assign(d->pnorm.begin(), d->pnorm.end());
	return true;
}

void Vst3Plug::prepare() {}

void Vst3Plug::reset() {
	if (d->processor) {
		d->processor->setProcessing(false);
		d->processor->setProcessing(true);
	}
}

void Vst3Plug::note_on(int key, float vel, int id) {
	if (!d->ready) return;
	// A note the sequencer plays comes with an id of its own. One played by
	// hand does not, so the plugin is given one made up here -- and it has to
	// be remembered, because the note-off must name the same one. A plugin is
	// entitled to stop only the note whose id it recognises, and several do:
	// forget the id and the note plays for ever.
	int note = id;
	if (note < 0) {
		note = d->note_id++;
		d->live_ids.push_back({key, note});
	}
	Event e{};
	e.type = Event::kNoteOnEvent;
	e.sampleOffset = 0;
	e.noteOn.channel = 0;
	e.noteOn.pitch = (int16)key;
	e.noteOn.velocity = clampf(vel, 0.0f, 1.0f);
	e.noteOn.noteId = note;
	e.noteOn.length = 0;
	e.noteOn.tuning = 0.0f;
	d->events.addEvent(e);
}

void Vst3Plug::note_off(int key, int id) {
	if (!d->ready) return;
	int note = id;
	if (note < 0) {
		// The most recent hand-played note at this pitch, so a key pressed
		// twice before either release is let go of in the right order.
		note = -1;
		for (size_t i = d->live_ids.size(); i-- > 0;) {
			if (d->live_ids[i].first == key) {
				note = d->live_ids[i].second;
				d->live_ids.erase(d->live_ids.begin() + (long)i);
				break;
			}
		}
	}
	Event e{};
	e.type = Event::kNoteOffEvent;
	e.sampleOffset = 0;
	e.noteOff.channel = 0;
	e.noteOff.pitch = (int16)key;
	e.noteOff.velocity = 0.0f;
	e.noteOff.noteId = note;
	e.noteOff.tuning = 0.0f;
	d->events.addEvent(e);
}

void Vst3Plug::all_notes_off() {
	if (!d->ready) return;
	// By id for everything played by hand, since that is the only way a plugin
	// that goes by ids will hear it, and then by pitch across the keyboard for
	// anything else still sounding.
	while (!d->live_ids.empty()) {
		const auto held = d->live_ids.back();
		d->live_ids.pop_back();
		Event e{};
		e.type = Event::kNoteOffEvent;
		e.sampleOffset = 0;
		e.noteOff.channel = 0;
		e.noteOff.pitch = (int16)held.first;
		e.noteOff.velocity = 0.0f;
		e.noteOff.noteId = held.second;
		e.noteOff.tuning = 0.0f;
		d->events.addEvent(e);
	}
	for (int k = 0; k < 128; k++) note_off(k, -1);
}

void Vst3Plug::pitch_bend(float semis) {
	(void)semis;   // routed as a MIDI CC by hosts; skipped until mapping is wired
}
void Vst3Plug::mod_wheel(float v) { (void)v; }

void Vst3Plug::set_param(int i, float v) {
	cd::CrashStep step("moving a plugin's parameter", d->bundle.c_str());
	if (i < 0 || i >= (int)pv.size()) return;
	pv[(size_t)i] = v;
	if (!d->ready) return;
	d->pnorm[(size_t)i] = v;
	if (d->controller) d->controller->setParamNormalized(d->pids[(size_t)i], v);
	d->in_changes.push(d->pids[(size_t)i], v, 0);
}

void Vst3Plug::process(float *L, float *R, int n) {
	cd::CrashStep step("processing audio through a plugin", d->bundle.c_str());
	if (!d->ready) {
		std::memset(L, 0, sizeof(float) * (size_t)n);
		std::memset(R, 0, sizeof(float) * (size_t)n);
		return;
	}
	int done = 0;
	while (done < n) {
		const int chunk = std::min(n - done, d->max_block);
		// Feed input (effects) — instruments simply ignore it.
		for (int c = 0; c < d->in_channels; c++) {
			float *dst = d->in_buf[(size_t)c].data();
			const float *src = (c == 0) ? L + done : R + done;
			std::memcpy(dst, src, sizeof(float) * (size_t)chunk);
			d->in_ptr[(size_t)c] = dst;
		}
		for (int c = 0; c < d->out_channels; c++) {
			std::memset(d->out_buf[(size_t)c].data(), 0, sizeof(float) * (size_t)chunk);
			d->out_ptr[(size_t)c] = d->out_buf[(size_t)c].data();
		}

		// Bus zero is the one that carries the sound; the rest are handed over
		// pointing at their own scratch so that nothing the plugin does with
		// them can land anywhere it should not.
		for (size_t b = 0; b < d->in_bb.size(); b++) {
			const bool main = (b == 0 && d->in_channels > 0);
			d->in_bb[b].numChannels = main ? d->in_channels
					: (int32)d->spare_in[b].ptr.size();
			d->in_bb[b].channelBuffers32 = main
					? (d->in_ptr.empty() ? nullptr : d->in_ptr.data())
					: d->spare_in[b].ptr.data();
			d->in_bb[b].silenceFlags = 0;
		}
		for (size_t b = 0; b < d->out_bb.size(); b++) {
			const bool main = (b == 0 && d->out_channels > 0);
			if (!main) {
				for (auto &c : d->spare_out[b].ch) {
					std::memset(c.data(), 0, sizeof(float) * (size_t)chunk);
				}
			}
			d->out_bb[b].numChannels = main ? d->out_channels
					: (int32)d->spare_out[b].ptr.size();
			d->out_bb[b].channelBuffers32 = main
					? (d->out_ptr.empty() ? nullptr : d->out_ptr.data())
					: d->spare_out[b].ptr.data();
			d->out_bb[b].silenceFlags = 0;
		}

		ProcessContext &ctx = d->ctx;
		ctx.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid |
				ProcessContext::kProjectTimeMusicValid | ProcessContext::kSystemTimeValid |
				(playing ? ProcessContext::kPlaying : 0);
		ctx.sampleRate = sr;
		ctx.projectTimeSamples = (TSamples)(song_beat * 60.0 / std::max(1.0, bpm) * sr);
		ctx.projectTimeMusic = song_beat;
		ctx.barPositionMusic = std::floor(song_beat / 4.0) * 4.0;
		ctx.tempo = bpm;
		ctx.timeSigNumerator = 4;
		ctx.timeSigDenominator = 4;

		// Anything the plugin's own interface changed since the last block,
		// on its way to the audio side.
		d->handler.drain_to(d->in_changes);

		ProcessData data{};
		data.processMode = kRealtime;
		data.symbolicSampleSize = kSample32;
		data.numSamples = chunk;
		data.numInputs = (int32)d->in_bb.size();
		data.numOutputs = (int32)d->out_bb.size();
		data.inputs = d->in_bb.empty() ? nullptr : d->in_bb.data();
		data.outputs = d->out_bb.empty() ? nullptr : d->out_bb.data();
		data.inputParameterChanges = &d->in_changes;
		data.outputParameterChanges = &d->out_changes;
		data.inputEvents = &d->events;
		data.outputEvents = nullptr;
		data.processContext = &ctx;

		d->processor->process(data);

		for (int s = 0; s < chunk; s++) {
			L[done + s] = d->out_channels > 0 ? d->out_buf[0][(size_t)s] : 0.0f;
			R[done + s] = d->out_channels > 1 ? d->out_buf[1][(size_t)s]
					: (d->out_channels > 0 ? d->out_buf[0][(size_t)s] : 0.0f);
		}
		// Events and parameter ramps belong to the block that consumed them.
		d->events.events.clear();
		d->in_changes.clear();
		d->out_changes.clear();
		done += chunk;
	}
}

bool Vst3Plug::set_string(const std::string &key, const std::string &value) {
	cd::CrashStep step("giving a plugin its saved state back", d->bundle.c_str());
	if (key == "state") return restore_base64(value);
	return false;
}

std::string Vst3Plug::get_string(const std::string &key) const {
	cd::CrashStep step("asking a plugin for its state", d->bundle.c_str());
	if (key == "state") return state_base64();
	if (key == "path") return d->bundle;
	if (key == "cid") return d->cid;
	if (key == "error") return d->err;
	if (key == "edits") return const_cast<Vst3Plug *>(this)->drain_edits();
	return std::string();
}

// ---------------------------------------------------------------------------
static const char *B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string b64_encode(const std::vector<char> &in) {
	std::string out;
	out.reserve((in.size() + 2) / 3 * 4);
	for (size_t i = 0; i < in.size(); i += 3) {
		const unsigned int a = (unsigned char)in[i];
		const unsigned int b = i + 1 < in.size() ? (unsigned char)in[i + 1] : 0;
		const unsigned int c = i + 2 < in.size() ? (unsigned char)in[i + 2] : 0;
		const unsigned int v = (a << 16) | (b << 8) | c;
		out += B64[(v >> 18) & 63];
		out += B64[(v >> 12) & 63];
		out += (i + 1 < in.size()) ? B64[(v >> 6) & 63] : '=';
		out += (i + 2 < in.size()) ? B64[v & 63] : '=';
	}
	return out;
}

static std::vector<char> b64_decode(const std::string &s) {
	auto val = [](char c) -> int {
		if (c >= 'A' && c <= 'Z') return c - 'A';
		if (c >= 'a' && c <= 'z') return c - 'a' + 26;
		if (c >= '0' && c <= '9') return c - '0' + 52;
		if (c == '+') return 62;
		if (c == '/') return 63;
		return -1;
	};
	std::vector<char> out;
	int buf = 0, bits = 0;
	for (char c : s) {
		const int v = val(c);
		if (v < 0) continue;
		buf = (buf << 6) | v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out.push_back((char)((buf >> bits) & 0xFF));
		}
	}
	return out;
}

std::string Vst3Plug::state_base64() const {
	if (!d->ready) return std::string();
	MemStream cs, es;
	d->component->getState(&cs);
	if (d->controller) d->controller->getState(&es);
	// [4 bytes component size][component][controller]
	std::vector<char> all;
	const uint32_t n = (uint32_t)cs.buf.size();
	all.push_back((char)(n & 0xFF));
	all.push_back((char)((n >> 8) & 0xFF));
	all.push_back((char)((n >> 16) & 0xFF));
	all.push_back((char)((n >> 24) & 0xFF));
	all.insert(all.end(), cs.buf.begin(), cs.buf.end());
	all.insert(all.end(), es.buf.begin(), es.buf.end());
	return b64_encode(all);
}

bool Vst3Plug::restore_base64(const std::string &s) {
	if (!d->ready || s.empty()) return false;
	std::vector<char> all = b64_decode(s);
	if (all.size() < 4) return false;
	const uint32_t n = (uint32_t)(unsigned char)all[0] | ((uint32_t)(unsigned char)all[1] << 8) |
			((uint32_t)(unsigned char)all[2] << 16) | ((uint32_t)(unsigned char)all[3] << 24);
	if (4 + n > all.size()) return false;
	MemStream cs;
	cs.buf.assign(all.begin() + 4, all.begin() + 4 + (long)n);
	cs.pos = 0;
	d->component->setState(&cs);
	cs.pos = 0;
	if (d->controller) {
		// One object has already taken this through setState above; telling it
		// again is at best wasted work and at worst a second patch load.
		if (d->ctrl_separate) d->controller->setComponentState(&cs);
		if (all.size() > 4 + n) {
			MemStream es;
			es.buf.assign(all.begin() + 4 + (long)n, all.end());
			es.pos = 0;
			d->controller->setState(&es);
		}
		for (size_t i = 0; i < d->pids.size(); i++) {
			d->pnorm[i] = (float)d->controller->getParamNormalized(d->pids[i]);
			pv[i] = d->pnorm[i];
		}
	}
	return true;
}

std::string Vst3Plug::param_display(int i, float normalized) const {
	cd::CrashStep step("asking a plugin how to spell a value", d->bundle.c_str());
	if (!d->ready || !d->controller || i < 0 || i >= (int)d->pids.size()) return std::string();
	String128 out{};
	if (d->controller->getParamStringByValue(d->pids[(size_t)i], normalized, out) != kResultOk) return std::string();
	char buf[256];
	str_to_utf8((const char16_t *)out, buf, sizeof(buf));
	return buf;
}

std::string Vst3Plug::drain_edits() {
	cd::CrashStep step("reading what a plugin changed by itself", d->bundle.c_str());
	std::string s;
	if (!d->ready) return s;
	for (auto &e : d->handler.edits) {
		for (size_t i = 0; i < d->pids.size(); i++) {
			if (d->pids[i] == e.first) {
				char b[64];
				snprintf(b, sizeof(b), "%d:%.6f\n", (int)i, e.second);
				s += b;
				pv[i] = (float)e.second;
				d->pnorm[i] = (float)e.second;
				break;
			}
		}
	}
	d->handler.edits.clear();
	return s;
}

bool Vst3Plug::has_editor() {
	if (!d->ready || !d->controller) return false;
	return d->editor.create(d->controller);
}

bool Vst3Plug::open_editor(uint64_t parent, int x, int y, int w, int h) {
	cd::CrashStep step("opening a plugin's own interface", d->bundle.c_str());
	if (!has_editor()) return false;
	return d->editor.open(parent, x, y, w, h);
}

void Vst3Plug::close_editor() {
	cd::CrashStep step("closing a plugin's own interface", d->bundle.c_str());
	d->editor.close();
}

void Vst3Plug::editor_idle() {
	// Every frame, for every plugin: this is the plugin's own timers and event
	// handlers running, which is other people's code on our main thread.
	cd::CrashStep step("ticking a plugin's own interface", d->bundle.c_str());
	d->editor.idle();
}

bool Vst3Plug::editor_open() const { return d->editor.is_open(); }

void Vst3Plug::editor_size(int &w, int &h) {
	cd::CrashStep step("asking a plugin how big its interface is", d->bundle.c_str());
	// Closing an editor lets go of its view, so make sure there is one before
	// asking how big it wants to be -- otherwise the window that is about to
	// open is sized from a default instead of from the plugin.
	has_editor();
	d->editor.size(w, h);
}

void Vst3Plug::editor_move(int x, int y, int w, int h) { d->editor.move(x, y, w, h); }

bool Vst3Plug::editor_take_resize(int &w, int &h) { return d->editor.take_resize(w, h); }

bool Vst3Plug::editor_can_resize() const { return d->editor.can_resize(); }

void Vst3Plug::editor_constrain(int &w, int &h) const { d->editor.constrain(w, h); }

void Vst3Plug::editor_focus() { d->editor.focus(); }
void Vst3Plug::editor_unfocus() { d->editor.unfocus(); }
bool Vst3Plug::editor_has_keys() const { return d->editor.has_keyboard(); }
bool Vst3Plug::editor_ready() const { return d->editor.ready(); }
bool Vst3Plug::editor_started() const { return d->editor.started(); }

bool Vst3Plug::single_component() const {
	if (!d->component) return false;
	IEditController *c = nullptr;
	if (d->component->queryInterface(IEditController_iid, (void **)&c) != kResultOk || !c) return false;
	c->release();
	return true;
}

bool Vst3Plug::take_restart() {
	if (!d->handler.restart_requested) return false;
	d->handler.restart_requested = false;
	// Everything it publishes, read back: a preset chosen inside the plugin
	// moves every parameter at once and reports none of them one by one.
	if (d->controller) {
		for (size_t i = 0; i < d->pids.size(); i++) {
			d->pnorm[i] = (float)d->controller->getParamNormalized(d->pids[i]);
			pv[i] = d->pnorm[i];
		}
	}
	return true;
}

void Vst3Plug::simulate_gui_edit(int i, float v) {
	if (!d->ready || i < 0 || i >= (int)d->pids.size()) return;
	// Exactly what a plugin does when one of its own knobs is turned: it moves
	// its own copy of the value, and tells the host between a begin and an end.
	const ParamID pid = d->pids[(size_t)i];
	if (d->controller) d->controller->setParamNormalized(pid, (ParamValue)v);
	d->handler.beginEdit(pid);
	d->handler.performEdit(pid, (ParamValue)v);
	d->handler.endEdit(pid);
}

bool Vst3Plug::controller_is_component() const {
	return d->controller != nullptr && !d->ctrl_separate;
}
void Vst3Plug::editor_show() { d->editor.show(); }
bool Vst3Plug::editor_showing() const { return d->editor.showing(); }

float Vst3Plug::param_live(int i) const {
	cd::CrashStep step("asking a plugin what a parameter stands at", d->bundle.c_str());
	if (!d->controller || i < 0 || i >= (int)d->pids.size()) return -1.0f;
	return (float)d->controller->getParamNormalized(d->pids[(size_t)i]);
}

void Vst3Plug::editor_set_scale(float factor) { d->editor.set_scale(factor); }

bool Vst3Plug::editor_grab(std::vector<unsigned char> &rgb, int &w, int &h) const {
	return d->editor.grab(rgb, w, h);
}

std::string Vst3Plug::editor_debug() { return d->editor.debug(); }

} // namespace cd
