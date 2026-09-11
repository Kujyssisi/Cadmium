#include "sf2.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>

namespace cd {

float sf2_timecents(int16_t tc) {
	if (tc <= -32000) return 0.0f;
	return std::pow(2.0f, (float)tc / 1200.0f);
}

float sf2_abs_cents_hz(float cents) {
	return 8.176f * std::pow(2.0f, cents / 1200.0f);
}

static uint32_t rd32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t *p) { return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)); }

bool Sf2File::load(const std::string &file) {
	FILE *f = fopen(file.c_str(), "rb");
	if (!f) return false;
	fseek(f, 0, SEEK_END);
	const long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (len < 64) { fclose(f); return false; }
	std::vector<uint8_t> buf((size_t)len);
	const size_t got = fread(buf.data(), 1, (size_t)len, f);
	fclose(f);
	if (got != (size_t)len) return false;
	if (memcmp(buf.data(), "RIFF", 4) != 0 || memcmp(buf.data() + 8, "sfbk", 4) != 0) return false;

	const uint8_t *smpl = nullptr;
	size_t smpl_len = 0;
	const uint8_t *tab[9] = {nullptr};
	size_t tab_len[9] = {0};
	static const char *tab_id[9] = {"phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr"};

	// Walk the top-level LISTs, then the chunks inside each.
	size_t pos = 12;
	while (pos + 8 <= buf.size()) {
		const char *id = (const char *)(buf.data() + pos);
		const uint32_t sz = rd32(buf.data() + pos + 4);
		const size_t body = pos + 8;
		if (body + sz > buf.size()) break;
		if (memcmp(id, "LIST", 4) == 0) {
			const char *lid = (const char *)(buf.data() + body);
			size_t q = body + 4;
			while (q + 8 <= body + sz) {
				const char *cid = (const char *)(buf.data() + q);
				const uint32_t csz = rd32(buf.data() + q + 4);
				const size_t cbody = q + 8;
				if (cbody + csz > buf.size()) break;
				if (memcmp(lid, "sdta", 4) == 0 && memcmp(cid, "smpl", 4) == 0) {
					smpl = buf.data() + cbody;
					smpl_len = csz;
				} else if (memcmp(lid, "pdta", 4) == 0) {
					for (int i = 0; i < 9; i++) {
						if (memcmp(cid, tab_id[i], 4) == 0) { tab[i] = buf.data() + cbody; tab_len[i] = csz; }
					}
				} else if (memcmp(lid, "INFO", 4) == 0 && memcmp(cid, "INAM", 4) == 0) {
					name.assign((const char *)(buf.data() + cbody), strnlen((const char *)(buf.data() + cbody), csz));
				}
				q = cbody + csz + (csz & 1);
			}
		}
		pos = body + sz + (sz & 1);
	}
	if (!smpl || !tab[0] || !tab[8]) return false;

	pcm.resize(smpl_len / 2);
	memcpy(pcm.data(), smpl, pcm.size() * 2);

	// phdr — the terminal record only marks the end of the last preset's bags.
	const int np = (int)(tab_len[0] / 38);
	presets.clear();
	for (int i = 0; i < np; i++) {
		const uint8_t *r = tab[0] + (size_t)i * 38;
		Sf2Preset p;
		p.name.assign((const char *)r, strnlen((const char *)r, 20));
		p.program = rd16(r + 20);
		p.bank = rd16(r + 22);
		p.bag_start = rd16(r + 24);
		presets.push_back(p);
	}
	for (int i = 0; i + 1 < (int)presets.size(); i++) presets[i].bag_end = presets[i + 1].bag_start;
	if (!presets.empty()) presets.pop_back();   // drop EOP

	pbag.resize(tab_len[1] / 4);
	for (size_t i = 0; i < pbag.size(); i++) {
		pbag[i].gen = rd16(tab[1] + i * 4);
		pbag[i].mod = rd16(tab[1] + i * 4 + 2);
	}
	pgen.resize(tab_len[3] / 4);
	for (size_t i = 0; i < pgen.size(); i++) {
		pgen[i].first = rd16(tab[3] + i * 4);
		pgen[i].second = (int16_t)rd16(tab[3] + i * 4 + 2);
	}
	const int ni = (int)(tab_len[4] / 22);
	insts.clear();
	for (int i = 0; i < ni; i++) {
		const uint8_t *r = tab[4] + (size_t)i * 22;
		Inst in;
		in.name.assign((const char *)r, strnlen((const char *)r, 20));
		in.bag_start = rd16(r + 20);
		insts.push_back(in);
	}
	for (int i = 0; i + 1 < (int)insts.size(); i++) insts[i].bag_end = insts[i + 1].bag_start;
	if (!insts.empty()) insts.pop_back();

	ibag.resize(tab_len[5] / 4);
	for (size_t i = 0; i < ibag.size(); i++) {
		ibag[i].gen = rd16(tab[5] + i * 4);
		ibag[i].mod = rd16(tab[5] + i * 4 + 2);
	}
	igen.resize(tab_len[7] / 4);
	for (size_t i = 0; i < igen.size(); i++) {
		igen[i].first = rd16(tab[7] + i * 4);
		igen[i].second = (int16_t)rd16(tab[7] + i * 4 + 2);
	}
	const int ns = (int)(tab_len[8] / 46);
	samples.clear();
	for (int i = 0; i < ns; i++) {
		const uint8_t *r = tab[8] + (size_t)i * 46;
		Sf2Sample s;
		s.name.assign((const char *)r, strnlen((const char *)r, 20));
		s.start = rd32(r + 20);
		s.end = rd32(r + 24);
		s.loop_start = rd32(r + 28);
		s.loop_end = rd32(r + 32);
		s.rate = rd32(r + 36);
		s.root = r[40];
		s.correction = (int8_t)r[41];
		s.link = rd16(r + 42);
		s.type = rd16(r + 44);
		samples.push_back(s);
	}
	if (!samples.empty()) samples.pop_back();   // EOS
	path = file;
	if (name.empty()) name = file;
	return !presets.empty() && !samples.empty();
}

void Sf2File::apply_zone(const std::vector<std::pair<uint16_t, int16_t>> &gens, int from, int to,
		Sf2Zone &z, bool preset_level) const {
	for (int g = from; g < to && g < (int)gens.size(); g++) {
		const uint16_t op = gens[(size_t)g].first;
		if (op >= GEN_COUNT) continue;
		const int16_t v = gens[(size_t)g].second;
		if (preset_level) {
			// Preset generators are offsets added to the instrument's value.
			if (op == GEN_KEY_RANGE || op == GEN_VEL_RANGE || op == GEN_SAMPLE_ID || op == GEN_INSTRUMENT) {
				z.gen[op] = v;
				z.has[op] = true;
			} else {
				z.gen[op] = (int16_t)std::max(-32768, std::min(32767, (int)z.gen[op] + (int)v));
				z.has[op] = true;
			}
		} else {
			z.gen[op] = v;
			z.has[op] = true;
		}
	}
}

static void zone_defaults(Sf2Zone &z) {
	memset(z.gen, 0, sizeof(z.gen));
	memset(z.has, 0, sizeof(z.has));
	z.gen[GEN_FILTER_FC] = 13500;
	z.gen[GEN_DELAY_VOLENV] = -12000;
	z.gen[GEN_ATTACK_VOLENV] = -12000;
	z.gen[GEN_HOLD_VOLENV] = -12000;
	z.gen[GEN_DECAY_VOLENV] = -12000;
	z.gen[GEN_RELEASE_VOLENV] = -12000;
	z.gen[GEN_DELAY_MODENV] = -12000;
	z.gen[GEN_ATTACK_MODENV] = -12000;
	z.gen[GEN_HOLD_MODENV] = -12000;
	z.gen[GEN_DECAY_MODENV] = -12000;
	z.gen[GEN_RELEASE_MODENV] = -12000;
	z.gen[GEN_DELAY_MODLFO] = -12000;
	z.gen[GEN_DELAY_VIBLFO] = -12000;
	z.gen[GEN_SCALE_TUNING] = 100;
	z.gen[GEN_ROOT_KEY] = -1;
	z.gen[GEN_KEY_RANGE] = (int16_t)((127 << 8) | 0);
	z.gen[GEN_VEL_RANGE] = (int16_t)((127 << 8) | 0);
}

static bool in_range(int16_t packed, int v) {
	const int lo = packed & 0xFF;
	const int hi = (packed >> 8) & 0xFF;
	return v >= lo && v <= hi;
}

void Sf2File::zones_for(int preset_index, int key, int vel, std::vector<Sf2Zone> &out) const {
	out.clear();
	if (preset_index < 0 || preset_index >= (int)presets.size()) return;
	const Sf2Preset &pr = presets[(size_t)preset_index];

	Sf2Zone pglobal;
	zone_defaults(pglobal);
	bool have_pglobal = false;

	for (int pb = pr.bag_start; pb < pr.bag_end && pb < (int)pbag.size(); pb++) {
		const int gs = pbag[(size_t)pb].gen;
		const int ge = (pb + 1 < (int)pbag.size()) ? pbag[(size_t)(pb + 1)].gen : (int)pgen.size();
		Sf2Zone pz;
		zone_defaults(pz);
		apply_zone(pgen, gs, ge, pz, false);
		if (!pz.has[GEN_INSTRUMENT]) {
			// A zone with no instrument is the preset's global zone.
			pglobal = pz;
			have_pglobal = true;
			continue;
		}
		if (!in_range(pz.has[GEN_KEY_RANGE] ? pz.gen[GEN_KEY_RANGE] : (int16_t)0x7F00, key)) continue;
		if (!in_range(pz.has[GEN_VEL_RANGE] ? pz.gen[GEN_VEL_RANGE] : (int16_t)0x7F00, vel)) continue;

		const int inst_i = pz.gen[GEN_INSTRUMENT];
		if (inst_i < 0 || inst_i >= (int)insts.size()) continue;
		const Inst &in = insts[(size_t)inst_i];

		Sf2Zone iglobal;
		zone_defaults(iglobal);
		for (int ib = in.bag_start; ib < in.bag_end && ib < (int)ibag.size(); ib++) {
			const int igs = ibag[(size_t)ib].gen;
			const int ige = (ib + 1 < (int)ibag.size()) ? ibag[(size_t)(ib + 1)].gen : (int)igen.size();
			Sf2Zone iz = iglobal;
			apply_zone(igen, igs, ige, iz, false);
			if (!iz.has[GEN_SAMPLE_ID]) { iglobal = iz; continue; }
			if (!in_range(iz.has[GEN_KEY_RANGE] ? iz.gen[GEN_KEY_RANGE] : (int16_t)0x7F00, key)) continue;
			if (!in_range(iz.has[GEN_VEL_RANGE] ? iz.gen[GEN_VEL_RANGE] : (int16_t)0x7F00, vel)) continue;

			// Merge: instrument zone is absolute, preset zone adds on top.
			Sf2Zone z = iz;
			for (int g = 0; g < GEN_COUNT; g++) {
				if (g == GEN_INSTRUMENT || g == GEN_SAMPLE_ID || g == GEN_KEY_RANGE || g == GEN_VEL_RANGE) continue;
				int add = 0;
				if (have_pglobal && pglobal.has[g]) add += pglobal.gen[g];
				if (pz.has[g]) add += pz.gen[g];
				if (add) z.gen[g] = (int16_t)std::max(-32768, std::min(32767, (int)z.gen[g] + add));
			}
			z.sample = z.gen[GEN_SAMPLE_ID];
			if (z.sample >= 0 && z.sample < (int)samples.size()) out.push_back(z);
		}
	}
}

// ---------------------------------------------------------------------------
static std::map<std::string, std::weak_ptr<Sf2File>> g_cache;

std::shared_ptr<Sf2File> sf2_get(const std::string &path) {
	auto it = g_cache.find(path);
	if (it != g_cache.end()) {
		if (auto sp = it->second.lock()) return sp;
	}
	auto sp = std::make_shared<Sf2File>();
	if (!sp->load(path)) return nullptr;
	g_cache[path] = sp;
	return sp;
}

void sf2_forget_unused() {
	for (auto it = g_cache.begin(); it != g_cache.end();) {
		if (it->second.expired()) it = g_cache.erase(it); else ++it;
	}
}

} // namespace cd
