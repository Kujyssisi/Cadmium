// FLARE — JSON.
#include "json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace flare {

const Json *Json::find(const std::string &key) const {
	if (type != OBJ) return nullptr;
	for (const auto &kv : obj) if (kv.first == key) return &kv.second;
	return nullptr;
}

void Json::set(const std::string &key, const Json &v) {
	type = OBJ;
	for (auto &kv : obj) {
		if (kv.first == key) { kv.second = v; return; }
	}
	obj.push_back({key, v});
}

namespace {

void escape(const std::string &s, std::string &out) {
	out.push_back('"');
	for (char c : s) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if ((unsigned char)c < 0x20) {
					char b[8];
					std::snprintf(b, sizeof(b), "\\u%04x", (unsigned)(unsigned char)c);
					out += b;
				} else {
					out.push_back(c);
				}
		}
	}
	out.push_back('"');
}

void num_text(double v, std::string &out) {
	char b[48];
	if (v == std::floor(v) && std::fabs(v) < 1e15) { std::snprintf(b, sizeof(b), "%.0f", v); out += b; return; }
	// The shortest spelling that reads back as the same number. Six digits is
	// what this used to write, and it quietly rounded a 20-second envelope
	// time by a few milliseconds every time a preset was saved -- small, but
	// it accumulated, and it meant a preset was never quite what was saved.
	for (int digits = 7; digits <= 17; digits++) {
		std::snprintf(b, sizeof(b), "%.*g", digits, v);
		if (std::strtod(b, nullptr) == v) break;
	}
	out += b;
}

void dump_into(const Json &j, int indent, int depth, std::string &out) {
	const bool pretty = indent > 0;
	const std::string pad = pretty ? std::string((size_t)(indent * (depth + 1)), ' ') : std::string();
	const std::string pad0 = pretty ? std::string((size_t)(indent * depth), ' ') : std::string();
	switch (j.type) {
		case Json::NUL: out += "null"; break;
		case Json::BOOL: out += j.b ? "true" : "false"; break;
		case Json::NUM: num_text(j.num, out); break;
		case Json::STR: escape(j.str, out); break;
		case Json::ARR: {
			if (j.arr.empty()) { out += "[]"; break; }
			out += '[';
			for (size_t i = 0; i < j.arr.size(); i++) {
				if (i) out += ',';
				if (pretty) { out += '\n'; out += pad; }
				dump_into(j.arr[i], indent, depth + 1, out);
			}
			if (pretty) { out += '\n'; out += pad0; }
			out += ']';
			break;
		}
		case Json::OBJ: {
			if (j.obj.empty()) { out += "{}"; break; }
			out += '{';
			for (size_t i = 0; i < j.obj.size(); i++) {
				if (i) out += ',';
				if (pretty) { out += '\n'; out += pad; }
				escape(j.obj[i].first, out);
				out += pretty ? ": " : ":";
				dump_into(j.obj[i].second, indent, depth + 1, out);
			}
			if (pretty) { out += '\n'; out += pad0; }
			out += '}';
			break;
		}
	}
}

struct Parser {
	const char *p, *end;
	bool ok = true;

	void ws() {
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	}
	bool lit(const char *s) {
		const char *q = p;
		while (*s) { if (q >= end || *q != *s) return false; q++; s++; }
		p = q;
		return true;
	}
	bool str(std::string &out) {
		if (p >= end || *p != '"') return false;
		p++;
		out.clear();
		while (p < end && *p != '"') {
			if (*p == '\\' && p + 1 < end) {
				p++;
				switch (*p) {
					case 'n': out.push_back('\n'); break;
					case 't': out.push_back('\t'); break;
					case 'r': out.push_back('\r'); break;
					case 'b': out.push_back('\b'); break;
					case 'f': out.push_back('\f'); break;
					case 'u': {
						if (p + 4 >= end) return false;
						char hex[5] = {p[1], p[2], p[3], p[4], 0};
						const unsigned cp = (unsigned)std::strtoul(hex, nullptr, 16);
						// UTF-8. Surrogate pairs are left as their replacement,
						// which is enough for preset names.
						if (cp < 0x80) out.push_back((char)cp);
						else if (cp < 0x800) {
							out.push_back((char)(0xC0 | (cp >> 6)));
							out.push_back((char)(0x80 | (cp & 0x3F)));
						} else {
							out.push_back((char)(0xE0 | (cp >> 12)));
							out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
							out.push_back((char)(0x80 | (cp & 0x3F)));
						}
						p += 4;
						break;
					}
					default: out.push_back(*p);
				}
				p++;
			} else {
				out.push_back(*p++);
			}
		}
		if (p >= end) return false;
		p++;
		return true;
	}
	bool value(Json &j) {
		ws();
		if (p >= end) return false;
		switch (*p) {
			case '{': {
				p++;
				j = Json::object();
				ws();
				if (p < end && *p == '}') { p++; return true; }
				for (;;) {
					ws();
					std::string key;
					if (!str(key)) return false;
					ws();
					if (p >= end || *p != ':') return false;
					p++;
					Json v;
					if (!value(v)) return false;
					j.obj.push_back({key, v});
					ws();
					if (p < end && *p == ',') { p++; continue; }
					if (p < end && *p == '}') { p++; return true; }
					return false;
				}
			}
			case '[': {
				p++;
				j = Json::array();
				ws();
				if (p < end && *p == ']') { p++; return true; }
				for (;;) {
					Json v;
					if (!value(v)) return false;
					j.arr.push_back(v);
					ws();
					if (p < end && *p == ',') { p++; continue; }
					if (p < end && *p == ']') { p++; return true; }
					return false;
				}
			}
			case '"': {
				std::string s;
				if (!str(s)) return false;
				j = Json::string(s);
				return true;
			}
			case 't': if (lit("true")) { j = Json::boolean(true); return true; } return false;
			case 'f': if (lit("false")) { j = Json::boolean(false); return true; } return false;
			case 'n': if (lit("null")) { j = Json(); return true; } return false;
			default: {
				char *stop = nullptr;
				const double v = std::strtod(p, &stop);
				if (stop == p) return false;
				p = stop;
				j = Json::number(v);
				return true;
			}
		}
	}
};

} // namespace

std::string Json::dump(int indent) const {
	std::string out;
	out.reserve(1024);
	dump_into(*this, indent, 0, out);
	return out;
}

bool Json::parse(const std::string &text, Json &out) {
	Parser ps;
	ps.p = text.c_str();
	ps.end = text.c_str() + text.size();
	// A byte order mark at the front of a file is not an error, it is Windows.
	if (text.size() >= 3 && (unsigned char)text[0] == 0xEF) ps.p += 3;
	if (!ps.value(out)) return false;
	ps.ws();
	return true;
}

} // namespace flare
