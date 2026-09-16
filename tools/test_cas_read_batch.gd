extends SceneTree
# Parity: bf6_cas_read_batch (C++, parallel) against BF6Source.get_chunk for every
# first-choice texture chunk in a map's recorded texture order.
#   -- <install> <level>
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var install := str(args[0])
	var level := str(args[1])
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		quit(3)
		return
	var path := Source.texture_order_path(level)
	var lines := FileAccess.get_file_as_string(path).split("\n", false)
	if lines.size() < 2:
		push_error("no texture order recorded for " + level)
		quit(4)
		return
	var core: Object = ClassDB.instantiate("BF6Core")
	var tex := BF6Texture.new()
	var forms := PackedStringArray()
	var spec := PackedStringArray()
	for i in range(1, lines.size()):
		var n := lines[i]
		var res: PackedByteArray = gs.src.get_res(n.get_slice("@", 0))
		var hdr := tex.header(res)
		if hdr.is_empty():
			continue
		for which in ["streamed", "embedded"]:
			for form in BF6Texture.chunk_forms(str(hdr[which])):
				var loc: Array = gs.src.chunk_location(str(form))
				if not loc.is_empty():
					forms.append(str(form))
					spec.append("%s\t%d\t%d" % loc)
					break
	var t0 := Time.get_ticks_usec()
	var mismatches := 0
	var bytes := 0
	var batch_us := 0
	var live_us := 0
	for start in range(0, spec.size(), 128):
		var window := spec.slice(start, mini(start + 128, spec.size()))
		var tb := Time.get_ticks_usec()
		var b: PackedByteArray = core.cas_read_batch(install, "\n".join(window))
		batch_us += Time.get_ticks_usec() - tb
		var at := 8
		for k in range(window.size()):
			var len := int(b.decode_u32(at))
			var got := b.slice(at + 4, at + 4 + len)
			at += 4 + ((len + 3) & ~3)
			var tl := Time.get_ticks_usec()
			var want: PackedByteArray = gs.src.get_chunk(forms[start + k])
			live_us += Time.get_ticks_usec() - tl
			bytes += want.size()
			if got != want:
				mismatches += 1
				if mismatches <= 10:
					print("MISMATCH %s: %d vs %d bytes" % [forms[start + k], got.size(), want.size()])
	print("chunks %d, %.1f MB, mismatches %d; batch %.2f s, live %.2f s" % [spec.size(), bytes / 1048576.0, mismatches, batch_us / 1e6, live_us / 1e6])
	var ok := spec.size() > 0 and mismatches == 0
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
