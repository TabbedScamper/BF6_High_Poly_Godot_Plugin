extends SceneTree

# Is the SDK's ground decal hidden while Extended Terrain is on, and — the part
# that actually matters — is it ALWAYS put back?
#
# Their decal is a node the user owns and saved. We only hide it, and every way
# out of that state has to restore it: Extended Terrain switched off, the scene
# changed, the plugin disabled. A path that forgets leaves a piece of someone's
# level invisible with nothing on screen to explain why, and they will save it
# that way.
#
# The nastier failure is the remembered value. Hiding twice in a row must not
# record `false` as the thing to restore — that turns a temporary hide into a
# permanent one, and it survives a restore, which is the worst kind.
#
#   godot --headless --path <proj> --script test_sdkdecal.gd

const MapCtx := preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")


func _init() -> void:
	await process_frame
	var fails := 0

	# A stand-in for a level scene: root named MP_*, with Static/<name>_Decal
	# exactly where sdk_decal() looks for it.
	var root := Node3D.new()
	root.name = "MP_Dumbo"
	var st := Node3D.new()
	st.name = "Static"
	root.add_child(st)
	var dec := Decal.new()
	dec.name = "MP_Dumbo_Decal"
	st.add_child(dec)
	get_root().add_child(root)

	var mc = MapCtx.new()
	mc.restore_sdk_decals()      # a clean slate, whatever a previous test left

	if mc.sdk_decal(root) != dec:
		print("FAIL: sdk_decal did not find the decal where the SDK saves it")
		fails += 1

	# ---- hide, restore ---------------------------------------------------
	fails += _check(mc, root, dec, "starts visible", true)
	mc._set_sdk_decal_shown(root, false)
	fails += _check(mc, root, dec, "hidden with Extended Terrain on", false)
	mc._set_sdk_decal_shown(root, true)
	fails += _check(mc, root, dec, "restored with Extended Terrain off", true)

	# ---- hidden twice, then restored -------------------------------------
	# The regression this exists for: the second hide must not overwrite the
	# remembered value with the value it is about to write.
	mc._set_sdk_decal_shown(root, false)
	mc._set_sdk_decal_shown(root, false)
	mc._set_sdk_decal_shown(root, true)
	fails += _check(mc, root, dec, "restored after being hidden twice", true)

	# ---- a decal the user had already hidden ------------------------------
	# Their off must survive our on. If someone turned their own decal off, an
	# Extended Terrain toggle must not switch it back on for them.
	dec.visible = false
	mc._set_sdk_decal_shown(root, false)
	mc._set_sdk_decal_shown(root, true)
	fails += _check(mc, root, dec, "a user-hidden decal stays hidden", false)
	dec.visible = true

	# ---- the teardown path ------------------------------------------------
	mc._set_sdk_decal_shown(root, false)
	fails += _check(mc, root, dec, "hidden again", false)
	mc.restore_sdk_decals()
	fails += _check(mc, root, dec, "restore_sdk_decals puts it back", true)

	# ---- a freed scene must not throw ------------------------------------
	mc._set_sdk_decal_shown(root, false)
	root.get_parent().remove_child(root)
	root.free()
	mc.restore_sdk_decals()      # the decal is gone; this must be a no-op
	print("   ok    restoring a freed scene did not throw")

	print("\n%s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)


func _check(mc, root: Node, dec: Decal, what: String, want: bool) -> int:
	var got := dec.visible
	print("   %-5s %-44s visible=%s" % ["ok" if got == want else "FAIL", what, got])
	return 0 if got == want else 1
