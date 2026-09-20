extends SceneTree
## Headless engine check: builds a small song in memory, renders it to a WAV and
## reports what came out. Run with
##   godot-beta --headless --path ~/Cadmium --script res://tools/engine_test.gd

func _initialize() -> void:
	var eng := CdEngine.new()
	get_root().add_child(eng)
	eng.start_audio()
	print("sample rate: ", eng.sample_rate())

	var stock: Array = eng.stock_plugins()
	print("stock plugins: ", stock.size())
	for p in stock:
		print("  %-14s %-11s %s" % [p.id, p.category, p.name])

	eng.set_bpm(140.0)
	eng.set_mode(1)

	# Channel 0: Ember playing a chord stab, into insert 1.
	var ch0 := eng.add_channel("Ember")
	var h0 := eng.create_plugin("cd.ember")
	eng.set_channel_instrument(ch0, h0)
	eng.set_channel(ch0, 0.8, 0.0, false, false, 1, 0)

	# Channel 1: Pulse kick, into insert 2.
	var ch1 := eng.add_channel("Kick")
	var h1 := eng.create_plugin("cd.pulse")
	eng.set_channel_instrument(ch1, h1)
	eng.set_channel(ch1, 0.9, 0.0, false, false, 2, 0)

	# Reverb on insert 3, fed from insert 1 by a send.
	var rev := eng.create_plugin("cd.reverb")
	eng.set_insert(3, 0, rev)
	eng.set_send(1, 0, 3, 0.35, false, false)
	# A compressor on the master, sidechained from the kick.
	var comp := eng.create_plugin("cd.comp")
	eng.set_insert(0, 0, comp)
	eng.plugin_set_param(comp, 7, 1.0)   # sc_ext
	eng.set_send(2, 0, 0, 1.0, true, true)

	var notes := PackedFloat32Array()
	for bar in range(4):
		var b := float(bar) * 4.0
		for k in [48, 55, 60, 63]:
			notes.append_array([0.0, b, 1.8, float(k), 0.8, 0.0])
		for step in range(4):
			notes.append_array([1.0, b + float(step), 0.2, 36.0, 0.95, 0.0])
	eng.set_pattern(0, notes, 16.0)

	var clips := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 16.0, 0.0, 1.0, 0.0, 0.0])
	eng.set_playlist(clips)

	var out := OS.get_user_data_dir().path_join("engine_test.wav")
	var t0 := Time.get_ticks_msec()
	var ok := eng.render(out, 0.0, 16.0, 2.0, 24, false)
	var ms := Time.get_ticks_msec() - t0
	print("render ok=%s in %d ms -> %s" % [ok, ms, out])
	quit()
