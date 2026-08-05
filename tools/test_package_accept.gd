extends SceneTree

# "Updating prop meshes to match the site" is the registry pass, and it is the
# slowest thing in the plugin when it has work: it content-hashes every prop,
# then downloads the model library's copy of each mismatch ONE AT A TIME.
#
# It is supposed to have almost nothing to do. index.json records the library
# hash the map package was accepted at, and matching entries short-circuit. What
# stamps that index is _accept_package_props.
#
# Two ways that guard failed, both of which turn the pass back on for the whole
# map:
#
#   it ran only on a REFRESH, so a partial fetch left everything it had just
#   written unaccepted
#   it REPLACED the index rather than merging, so a partial fetch erased every
#   entry accepted before it
#
# Against a pre-baked archive that is not merely slow, it is destructive: the
# library's copy overwrites the stripped glb that the .bctex and .geom.res
# belong to, so the map reverts to un-baked props with mismatched sidecars.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame

	# A stand-in model library. _accept_package_props only records props the
	# registry publishes, so these are the only names that can be accepted.
	HighpolyStore.mesh_remote = {
		"Alpha": {"hash": "aaa", "glb": "godot/Alpha.glb"},
		"Beta": {"hash": "bbb", "glb": "godot/Beta.glb"},
		"Gamma": {"hash": "ccc", "glb": "godot/Gamma.glb"},
	}
	mc._save_props_index({})

	# ---- a first, partial fetch ------------------------------------------
	mc._accept_package_props("MP_Test", ["Alpha.glb", "Alpha.bctex",
		"Alpha.glb.geom.res"])
	var idx: Dictionary = mc._props_index()
	_check("the fetched prop is accepted at the library's current hash",
		str(idx.get("Alpha", "")) == "aaa")
	_check("and its companions are not mistaken for props (%d entr(y/ies))"
		% idx.size(), idx.size() == 1)

	# ---- a second, separate partial fetch ---------------------------------
	# THE MERGE. Replacing the index here would drop Alpha, and the registry
	# pass would re-hash and re-download it on the next start.
	mc._accept_package_props("MP_Test", ["Beta.glb", "Beta.bctex"])
	idx = mc._props_index()
	_check("the second fetch is accepted too", str(idx.get("Beta", "")) == "bbb")
	_check("WITHOUT forgetting the first (%d entr(ies))" % idx.size(),
		str(idx.get("Alpha", "")) == "aaa" and idx.size() == 2)

	# ---- a prop nobody fetched --------------------------------------------
	_check("a prop that was never fetched is not claimed as accepted",
		not idx.has("Gamma"))

	# ---- and the library moving on still heals ----------------------------
	# Accepting must not disable the pass, only quieten it. When the library
	# republishes a prop its hash changes, the stamped entry stops matching,
	# and that prop is verified again exactly as before.
	HighpolyStore.mesh_remote["Alpha"] = {"hash": "aaa2",
		"glb": "godot/Alpha.glb"}
	idx = mc._props_index()
	_check("a prop the library has since republished no longer matches",
		str(idx.get("Alpha", "")) != str(
			(HighpolyStore.mesh_remote["Alpha"] as Dictionary)["hash"]))

	mc._save_props_index({})
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
