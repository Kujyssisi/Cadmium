// FLARE — the few places the two platforms disagree.
#pragma once

#include <string>

#include <sys/stat.h>
#if defined(_WIN32)
#include <direct.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace flare {

/// Makes one directory. Windows spells it with one argument and no mode.
inline bool make_dir(const std::string &path) {
#if defined(_WIN32)
	return ::_mkdir(path.c_str()) == 0;
#else
	return ::mkdir(path.c_str(), 0755) == 0;
#endif
}

/// Makes a directory and everything above it, and does not mind what already
/// exists.
inline void make_dirs(const std::string &path) {
	std::string cur;
	for (size_t i = 0; i <= path.size(); i++) {
		if (i == path.size() || path[i] == '/' || path[i] == '\\') {
			if (cur.size() > 1) make_dir(cur);
		}
		if (i < path.size()) cur.push_back(path[i]);
	}
}

/// The folder the running program is in.
///
/// A build handed to somebody else has none of this machine's home directory
/// in it, so presets and content that travel with the application have to be
/// found relative to the application. Empty when it cannot be worked out,
/// which callers treat as "there is no such folder".
inline std::string executable_dir() {
#if defined(_WIN32)
	wchar_t wide[MAX_PATH];
	const DWORD n = ::GetModuleFileNameW(nullptr, wide, MAX_PATH);
	if (n == 0 || n >= MAX_PATH) return std::string();
	char narrow[MAX_PATH * 2];
	const int m = ::WideCharToMultiByte(CP_UTF8, 0, wide, (int)n, narrow,
			(int)sizeof(narrow), nullptr, nullptr);
	if (m <= 0) return std::string();
	std::string path(narrow, (size_t)m);
#else
	char buf[4096];
	const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
	if (n <= 0) return std::string();
	std::string path(buf, (size_t)n);
#endif
	const size_t cut = path.find_last_of("/\\");
	return cut == std::string::npos ? std::string() : path.substr(0, cut);
}

} // namespace flare
