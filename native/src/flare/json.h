// FLARE — a small JSON reader and writer.
//
// Presets are JSON so that they can be read, diffed and written by anything.
// Pulling in a library for that would be the largest dependency in the plugin
// by an order of magnitude, so this is the whole of it.
#pragma once

#include <map>
#include <string>
#include <vector>

namespace flare {

class Json {
public:
	enum Type { NUL, BOOL, NUM, STR, ARR, OBJ };

	Type type = NUL;
	bool b = false;
	double num = 0.0;
	std::string str;
	std::vector<Json> arr;
	std::vector<std::pair<std::string, Json>> obj;   // ordered, so files diff cleanly

	Json() {}
	static Json object() { Json j; j.type = OBJ; return j; }
	static Json array() { Json j; j.type = ARR; return j; }
	static Json string(const std::string &s) { Json j; j.type = STR; j.str = s; return j; }
	static Json number(double v) { Json j; j.type = NUM; j.num = v; return j; }
	static Json boolean(bool v) { Json j; j.type = BOOL; j.b = v; return j; }

	bool is_obj() const { return type == OBJ; }
	bool is_arr() const { return type == ARR; }
	bool has(const std::string &key) const { return find(key) != nullptr; }
	const Json *find(const std::string &key) const;
	/// Adds or replaces. Order of first insertion is kept.
	void set(const std::string &key, const Json &v);
	void push(const Json &v) { type = ARR; arr.push_back(v); }

	std::string as_string(const std::string &def = "") const { return type == STR ? str : def; }
	double as_number(double def = 0.0) const { return type == NUM ? num : (type == BOOL ? (b ? 1 : 0) : def); }
	bool as_bool(bool def = false) const { return type == BOOL ? b : (type == NUM ? num != 0.0 : def); }

	std::string get_str(const std::string &key, const std::string &def = "") const {
		const Json *j = find(key);
		return j ? j->as_string(def) : def;
	}
	double get_num(const std::string &key, double def = 0.0) const {
		const Json *j = find(key);
		return j ? j->as_number(def) : def;
	}

	std::string dump(int indent = 0) const;
	static bool parse(const std::string &text, Json &out);
};

} // namespace flare
