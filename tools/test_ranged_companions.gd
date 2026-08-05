extends SceneTree

# A prop ships as three files and the ranged fetch asked for one of them.
#
# That path picks entries out of the archive individually rather than unpacking
# it, so anything it does not name by hand is never downloaded. When the shipped
# archive gained .bctex and .geom.res companions, the fetch kept asking only for
# glbs — "2761 of 8215 entries needed" — and every prop in the map arrived with
# no pixels in it and rendered flat white.
#
# Nothing failed. The download succeeded, the counts looked plausible, the map
# built, and the log said so. The only signal was on screen.
#
# Worse, it could not heal: _props_missing tested for the glb, the glb WAS
# there, so nothing re-downloaded on any later load either.
#
# Both halves are covered here, and the second one is the one that matters —
# a fix that only works after a purge leaves everyone already broken, broken.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const BcTex = preload("res://addons/highpoly_toggle/highpoly_bctex.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var tmp := "user://__companions"  # kept for the index fixtures only
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(tmp))
	var dir := ProjectSettings.globalize_path(tmp)

	# ---- what the fetch asks for -----------------------------------------
	var present := {}
	for n in ["Foo.glb", "Foo.bctex", "Foo.glb.geom.res",
			"Bar.glb", "Bar.bctex", "Bar.glb.geom.p0.res", "Bar.glb.geom.p1.res",
			"Old.glb"]:
		present[n] = true

	var want := {"Foo.glb": true}
	MC._want_companions("Foo.glb", present, want)
	_check("a single-mesh prop asks for its sidecar and its bake (%d files)"
		% want.size(),
		want.has("Foo.glb") and want.has("Foo.bctex")
			and want.has("Foo.glb.geom.res"))

	want = {"Bar.glb": true}
	MC._want_companions("Bar.glb", present, want)
	_check("a SPLIT prop asks for every numbered part (%d files)" % want.size(),
		want.has("Bar.glb.geom.p0.res") and want.has("Bar.glb.geom.p1.res"))

	# An older archive has neither companion, and a map is perfectly valid that
	# way. Asking for files the archive does not hold would fail the fetch.
	want = {"Old.glb": true}
	MC._want_companions("Old.glb", present, want)
	_check("a prop with no companions in the archive asks for nothing extra",
		want.size() == 1)

	# ---- and what counts as already here ---------------------------------
	# PROPS_CACHE is a const, so the fixtures go into the real shared cache
	# under names nothing else could produce, and are removed at the end.
	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	HighpolyStore.ensure_dir(mc.PROPS_CACHE)
	var cache := ProjectSettings.globalize_path(mc.PROPS_CACHE)
	var made: Array = []

	_write_stripped(cache + "/__t_Stripped.glb"); made.append("__t_Stripped.glb")
	_write_textured(cache + "/__t_Textured.glb"); made.append("__t_Textured.glb")
	_write_stripped(cache + "/__t_Paired.glb"); made.append("__t_Paired.glb")
	var f := FileAccess.open(cache + "/__t_Paired" + BcTex.EXT, FileAccess.WRITE)
	f.store_string("not a real sidecar, but present")
	f.close()
	made.append("__t_Paired" + BcTex.EXT)

	_check("a prop that is not there at all counts as missing",
		mc._prop_incomplete("__t_Absent"))
	# THE REGRESSION. The glb is present, so the old test passed it and the
	# prop stayed white through every reload.
	_check("a STRIPPED glb with no sidecar counts as missing",
		mc._prop_incomplete("__t_Stripped"))
	_check("the same glb WITH its sidecar counts as complete",
		not mc._prop_incomplete("__t_Paired"))
	# Props that carry their own images are how every archive used to work and
	# must not suddenly all re-download.
	_check("a prop that carries its own images counts as complete",
		not mc._prop_incomplete("__t_Textured"))

	# 68 of Dumbo's 2,761 props have no textures at all and get no sidecar,
	# correctly. Judged on the sidecar alone every one of them looks incomplete
	# and re-downloads on every load, forever — the bake is what proves the
	# prop came from a pre-baked archive and is simply untextured.
	_write_stripped(cache + "/__t_NoTex.glb"); made.append("__t_NoTex.glb")
	var g := FileAccess.open(cache + "/__t_NoTex.glb.geom.res", FileAccess.WRITE)
	g.store_string("a bake, standing in for the real one")
	g.close()
	made.append("__t_NoTex.glb.geom.res")
	_check("an untextured prop with a bake and no sidecar counts as complete",
		not mc._prop_incomplete("__t_NoTex"))

	for n in made:
		DirAccess.remove_absolute(cache + "/" + str(n))
	_check("the fixtures are cleaned up",
		not FileAccess.file_exists(cache + "/__t_Stripped.glb"))
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


# Minimal glbs: only the JSON chunk is read, so only it has to be right.
func _write_stripped(p: String) -> void:
	_write_glb(p, '{"asset":{"version":"2.0"},"meshes":[],"materials":[]}')


func _write_textured(p: String) -> void:
	_write_glb(p, '{"asset":{"version":"2.0"},"images":[{"mimeType":"image/webp"}]}')


func _write_glb(p: String, js: String) -> void:
	var j := js.to_utf8_buffer()
	while j.size() % 4 != 0:
		j.append(0x20)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_32(0x46546C67)                 # "glTF"
	f.store_32(2)
	f.store_32(12 + 8 + j.size())
	f.store_32(j.size())
	f.store_32(0x4E4F534A)                 # "JSON"
	f.store_buffer(j)
	f.close()


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
