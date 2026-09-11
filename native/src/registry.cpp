// Cadmium — the stock plugin table.
#include "ext_plugins.h"
#include "plugin.h"

namespace cd {

const std::vector<PlugDesc> &registry() {
	static std::vector<PlugDesc> r;
	if (r.empty()) {
		register_synths(r);
		register_synths2(r);
		register_spectral(r);
		register_drums(r);
		register_samplers(r);
		register_effects(r);
		register_effects2(r);
		register_effects3(r);
		register_effects4(r);
		register_effects5(r);
		register_flare(r);
		// Last, so a plugin in the folder can never take an id the program
		// already uses; register_external checks and reports the clash.
		register_external(r);
	}
	return r;
}

const PlugDesc *find_desc(const std::string &id) {
	for (const PlugDesc &d : registry()) {
		if (id == d.id) return &d;
	}
	return nullptr;
}

Plug *make_plug(const std::string &id, double sr, int block) {
	const PlugDesc *d = find_desc(id);
	if (!d) return nullptr;
	if (!d->make) {
		// An external descriptor: its library, not a function pointer in the
		// table, is what knows how to build one.
		Plug *p = make_external(id, sr, block);
		if (p) p->init(d, sr, block);
		return p;
	}
	Plug *p = d->make();
	p->init(d, sr, block);
	return p;
}

} // namespace cd
