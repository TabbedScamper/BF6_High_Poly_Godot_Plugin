@tool
extends SceneTree
# WHICH PLACED OBJECTS THE MATCHER CAN NAME, counted on a real builder scene.
#
# The overlay only skins a node it can put a key to. A node it cannot name keeps
# EA's low quality SDK proxy, silently, which is the one outcome this plugin
# exists to prevent - so "how many did we fail to name" is the number that says
# whether it is doing its job, and nothing measured it before.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_matchkey.gd -- <scene-under-res://levels>
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.
#
# MIRRORS scene_keys' WALK, and that is not a detail. The real walk stops at a
# matched node and never looks inside it, because instance-internal geometry is
# not a placeable object. A test that descends anyway reports every inner "Mesh"
# node as a match the real code would never even ask about: the first version of
# this file did exactly that and claimed 3,716 recovered objects, all of them
# named Mesh or Model. The number was an artefact of the harness.
#
# One knowing difference: _push_user_children needs an edited scene root and
# there is none headless, so a matched node's subtree is skipped entirely. Props
# a builder parented under another object are therefore NOT counted here. That
# undercounts both columns equally, so the comparison stands.

const LIB := preload("res://addons/highpoly_toggle/highpoly_lib.gd")


func _init() -> void:
	var scene := "MP_Aftermath"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			scene = str(a)
	var path := "res://levels/%s.tscn" % scene
	if not ResourceLoader.exists(path):
		print("no scene at %s" % path)
		quit(1)
		return
	var ps := load(path) as PackedScene
	if ps == null:
		print("could not load %s" % path)
		quit(1)
		return
	# EDIT STATE, so instanced children keep their scene_file_path. Without it
	# every node comes back with no instance path and the whole sfp branch of
	# the matcher goes untested.
	var root := ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if root == null:
		print("could not instantiate %s" % path)
		quit(1)
		return

	var ks: Dictionary = LIB.known()
	print("object scan: %d key(s)" % ks.size())

	var asked := 0
	var by_name := 0
	var by_mesh := 0
	var missed := 0
	var won: Dictionary = {}
	var miss: Dictionary = {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == LIB.HP_NODE or n.name == "_MAP_CONTEXT" \
				or n.name == LIB.COL_NODE:
			continue
		if n is Node3D:
			asked += 1
			var k: String = LIB._match_key(n, ks)
			if k != "":
				# Which half of the matcher answered. The name path is
				# everything that existed before the mesh fallback, so
				# by_mesh IS the change this test exists to size.
				if _name_key(n, ks) != "":
					by_name += 1
				else:
					by_mesh += 1
					var pair := "%s -> %s" % [String(n.name).split("@")[0], k]
					won[pair] = int(won.get(pair, 0)) + 1
				continue          # matched: the real walk does not look inside
			if n.scene_file_path != "":
				# An instance we could not name is a real miss. A bare Node3D
				# is usually a group, so it is walked rather than counted.
				missed += 1
				var lbl := String(n.name).split("@")[0]
				miss[lbl] = int(miss.get(lbl, 0)) + 1
		for c in n.get_children():
			stack.append(c)

	print("Node3D asked      %d" % asked)
	print("matched by NAME   %d" % by_name)
	print("matched by MESH   %d      <- what the fallback added" % by_mesh)
	print("instances missed  %d" % missed)
	_dump("what the MESH path claimed", won)
	_dump("instances still unmatched", miss)
	root.free()
	quit(0)


# The pre-fallback answer: the name rules only, so the test can tell which half
# of the matcher spoke without depending on the matcher to say.
static func _name_key(node: Node, ks: Dictionary) -> String:
	var sfp: String = node.scene_file_path
	if sfp != "":
		if not sfp.begins_with("res://objects/"):
			return ""
		var base := sfp.get_file().get_basename()
		return base if ks.has(base) else ""
	var n := String(node.name).split("@")[0]
	if ks.has(n):
		return n
	var m := n
	while m.length() > 0 and m[m.length() - 1] >= "0" and m[m.length() - 1] <= "9":
		m = m.substr(0, m.length() - 1)
		if ks.has(m):
			return m
	return ""


static func _dump(title: String, d: Dictionary) -> void:
	print("%s:" % title)
	var rows: Array = d.keys()
	rows.sort_custom(func(a, b): return int(d[a]) > int(d[b]))
	for i in range(mini(20, rows.size())):
		print("   %5d  %s" % [int(d[rows[i]]), rows[i]])
	if rows.is_empty():
		print("   (none)")
