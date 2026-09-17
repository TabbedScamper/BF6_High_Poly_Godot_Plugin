@tool
extends Object
class_name HighpolySoldierRig
# THE SOLDIER AS A REAL SKINNED MESH, so it can be animated.
#
# HighpolyLoadout.build_soldier asks the core for a soldier and gets a static
# mesh already posed at one sampled frame. That is the right answer for a
# spawner marker and the wrong one for anything that moves: a posed vertex
# cannot be re-posed, so an animation would have nothing to drive.
#
# With "skinned":"1" the core hands back the BIND-pose vertices, the per-vertex
# skin binding and the rig instead, and this turns that into a Skeleton3D with a
# skinned MeshInstance3D under it. Nothing here decides anything about the
# character - the rig, the weights and the bone resolution all come from the
# core, so Unreal builds the same soldier from the same record.
#
# THE FIRST CHECKPOINT IS "NO VISIBLE CHANGE". Built at the rest pose this must
# look like the static soldier it replaces; the core's own soldier_skin_test
# already proves skinning at bind pose reproduces the mesh to 2.5e-07 m, so any
# difference that shows up here is this file's fault, not the record's. Only
# once that holds is an animation worth putting on top.
#
# The mesh is laid out exactly as HighpolyLoadout._from_record lays it out - one
# ArrayMesh, one surface and one material per section - so the two can be
# compared surface for surface. The skeleton is therefore built in full BEFORE
# any surface, because a MeshInstance3D has a single Skin that every surface
# indexes into.

const RECORD_MAGIC := 0x50574C42   # 'BLWP'
const CLIP_MAGIC := 0x41574C42     # 'BLWA'

# THE CLIP CARRIES NO FRAME RATE, but the rate is not a free choice. The reloc
# payload has no such field, so this is set here, once, and named - and it is
# 60 because the four ClipPlayer owners that select these clips author Fps=60
# in the current install, which is what the game's own menu plays them at. It
# was 30 first, a guess, and a guess here reads as a soldier moving at half
# speed rather than as a wrong number.
const CLIP_FPS := 60.0


# The 3x4 the core hands out: rows 0..2 are the right, up and forward AXES and
# row 3 is the translation, applied as v' = right*v.x + up*v.y + forward*v.z +
# trans. Those axes ARE Godot's basis vectors, so this is a direct read with no
# transpose - unlike the prop placement rows, which really are stored
# transposed. Getting that backwards produces a rig that is subtly mirrored.
static func _xform(m: Array) -> Transform3D:
	if m.size() < 12:
		return Transform3D()
	var t := Transform3D()
	t.basis.x = Vector3(float(m[0]), float(m[1]), float(m[2]))
	t.basis.y = Vector3(float(m[3]), float(m[4]), float(m[5]))
	t.basis.z = Vector3(float(m[6]), float(m[7]), float(m[8]))
	t.origin  = Vector3(float(m[9]), float(m[10]), float(m[11]))
	return t


static func _bone_xform(bone: Dictionary, key: String) -> Transform3D:
	return _xform(bone.get(key, []))


# Godot 4.3 gained Skeleton3D.set_bone_pose, which takes the whole transform.
# Before that a pose could only be set as position/rotation/scale, which throws
# away shear - invisible on the clip-driven bones, which are rigid, and not
# something to impose on the rest. Take the exact path where it exists.
static func _set_pose(skel: Skeleton3D, bone: int, t: Transform3D) -> void:
	if skel.has_method("set_bone_pose"):
		skel.call("set_bone_pose", bone, t)
		return
	skel.set_bone_pose_position(bone, t.origin)
	skel.set_bone_pose_rotation(bone, t.basis.get_rotation_quaternion())
	skel.set_bone_pose_scale(bone, t.basis.get_scale())


# Ask the core for the skinned record. {} fields: "record", "body", "error".
static func fetch(gs, request: Dictionary) -> Dictionary:
	var core = HighpolyLoadout.core_for(gs)
	if core == null or not core.has_method("loadout_soldier"):
		return {"error": "The game reader has no soldier support; update the add-on."}
	var req := request.duplicate()
	req["skinned"] = "1"
	var blob: PackedByteArray = core.call("loadout_soldier", JSON.stringify(req),
		HighpolyLoadout.attachment_enums_text())
	if blob.size() < 12 or blob.decode_u32(0) != RECORD_MAGIC:
		return {"error": "The configured soldier could not be read."}
	var json_len := blob.decode_u32(8)
	var parsed: Variant = JSON.parse_string(
		blob.slice(12, 12 + json_len).get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"error": "The configured soldier record is invalid."}
	var rec: Dictionary = parsed
	if str(rec.get("error", "")) != "":
		return {"error": str(rec["error"])}
	if rec.get("rig", []).is_empty():
		# A record with no rig means the core ignored "skinned" - i.e. this
		# add-on's native core predates the skinned mode. Say that, rather than
		# silently drawing an unanimatable soldier.
		return {"error": "This game reader cannot supply a soldier rig; update the add-on."}
	return {"record": rec, "blob": blob, "body": 12 + int(json_len), "error": ""}


# Build the skinned soldier. {} fields: "node", "skeleton", "error".
static func build(gs, request: Dictionary) -> Dictionary:
	var got := fetch(gs, request)
	if str(got.get("error", "")) != "":
		return {"error": got["error"]}
	var rec: Dictionary = got["record"]
	var blob: PackedByteArray = got["blob"]
	var body: int = got["body"]
	var rig: Array = rec["rig"]
	var sections: Array = rec.get("sections", [])

	# ---- the skeleton, in full, before any surface --------------------------
	var skel := Skeleton3D.new()
	skel.name = "Rig"
	for b in rig:
		var bone: Dictionary = b
		var idx := skel.add_bone(str(bone.get("name", "bone")))
		var parent := int(bone.get("parent", -1))
		if parent >= 0 and parent < idx:
			skel.set_bone_parent(idx, parent)
		# `local` is the bind pose relative to the parent, which is exactly what
		# Godot calls a bone's REST.
		skel.set_bone_rest(idx, _bone_xform(bone, "local"))
	var base_bones := skel.get_bone_count()
	var posed: Array[Transform3D] = []
	for b in rig:
		posed.append(_bone_xform(b, "posed"))

	# Each section appends its OWN renderbones on top of that shared base, and a
	# skin index at or above `base_bones` addresses its section's list. Where
	# each section's appendix landed has to be remembered for the remap below.
	var rb_first := PackedInt32Array()
	rb_first.resize(sections.size())
	for si in range(sections.size()):
		var rb: Array = sections[si].get("renderbones", [])
		rb_first[si] = skel.get_bone_count()
		for ri in range(rb.size()):
			var bone: Dictionary = rb[ri]
			# Skeleton3D refuses duplicate bone names and the same renderbone
			# name recurs across meshes, so the skeleton index disambiguates.
			var idx := skel.add_bone("%s#%d" % [str(bone.get("name", "rb")), rb_first[si] + ri])
			# A RENDERBONE'S PARENT INDEXES THE COMPOSED RIG, not this skeleton,
			# so it takes the same shift as a skin index: below the base count
			# it names a shared bone, at or above it names another renderbone in
			# this same appendix.
			var parent := int(bone.get("parent", -1))
			if parent >= base_bones:
				parent = rb_first[si] + (parent - base_bones)
			if parent >= 0 and parent < idx:
				skel.set_bone_parent(idx, parent)
			skel.set_bone_rest(idx, _bone_xform(bone, "local"))
			posed.append(_bone_xform(bone, "posed"))
	skel.reset_bone_poses()

	# THE SAMPLED IDLE FRAME, so the skinned soldier stands the way the static
	# one does. Without this the character renders in its bind stance, and
	# "the pose looks wrong" and "the skinning is wrong" become the same
	# symptom. The core's soldier_skin_test proves these transforms reproduce
	# the static soldier to 7.2e-07 m, so any difference on screen is this
	# file's doing.
	for i in range(mini(posed.size(), skel.get_bone_count())):
		_set_pose(skel, i, posed[i])

	# ---- one skin over the whole skeleton -----------------------------------
	# `inverse` is the bind model pose inverted, which is precisely what a Godot
	# Skin bind is.
	var skin := Skin.new()
	for i in range(rig.size()):
		skin.add_bind(i, _bone_xform(rig[i], "inverse"))
	for si in range(sections.size()):
		var rb: Array = sections[si].get("renderbones", [])
		for ri in range(rb.size()):
			skin.add_bind(rb_first[si] + ri, _bone_xform(rb[ri], "inverse"))

	# ---- the mesh -----------------------------------------------------------
	#
	# Two destinations. Skinned sections go on one ArrayMesh under the skeleton.
	# A section naming an attach_bone is RIGID - the weapon has no skin binding
	# of its own - and its geometry is already in that bone's frame, so it goes
	# on a mesh hung off a BoneAttachment3D and rides the bone from there.
	var am := ArrayMesh.new()
	var attached := {}       # bone index -> ArrayMesh
	var unskinned := 0
	# Which record section each built surface came from. Surfaces are not a 1:1
	# map onto sections here - empty ones are dropped and the weapon's are
	# diverted - so anything checking this mesh against the static soldier needs
	# to be told the correspondence rather than assume it.
	var surface_section := PackedInt32Array()
	for si in range(sections.size()):
		var sec: Dictionary = sections[si]
		var vc := int(sec.get("vertex_count", 0))
		var ic := int(sec.get("index_count", 0))
		if vc <= 0 or ic <= 0:
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		var p := body + int(sec.get("positions", 0)) * 4
		arr[Mesh.ARRAY_VERTEX] = blob.slice(p, p + vc * 12).to_vector3_array()
		if int(sec.get("normals", -1)) >= 0:
			var n := body + int(sec["normals"]) * 4
			arr[Mesh.ARRAY_NORMAL] = blob.slice(n, n + vc * 12).to_vector3_array()
		if int(sec.get("uvs", -1)) >= 0:
			var u := body + int(sec["uvs"]) * 4
			arr[Mesh.ARRAY_TEX_UV] = blob.slice(u, u + vc * 8).to_vector2_array()
		var i_at := body + int(sec.get("indices", 0)) * 4
		arr[Mesh.ARRAY_INDEX] = blob.slice(i_at, i_at + ic * 4).to_int32_array()

		var infl := int(sec.get("influences", 0))
		var sb_off := int(sec.get("skin_bones", -1))
		var sw_off := int(sec.get("skin_weights", -1))
		var bone := int(sec.get("attach_bone", -1))
		var flags := 0
		if bone >= 0 and bone < skel.get_bone_count():
			var rigid: ArrayMesh = attached.get(bone, null)
			if rigid == null:
				rigid = ArrayMesh.new()
				attached[bone] = rigid
			rigid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			rigid.surface_set_material(rigid.get_surface_count() - 1,
				HighpolyLoadout.section_material(gs, sec))
			continue
		if infl > 0 and sb_off >= 0 and sw_off >= 0:
			# Indices arrive ALREADY resolved against the composed rig, so the
			# only remap is this section's appendix, which sits at rb_first[si]
			# in this skeleton rather than at `base_bones`.
			var lanes := vc * infl
			var raw := blob.slice(body + sb_off * 4,
				body + sb_off * 4 + lanes * 4).to_int32_array()
			var bones := PackedInt32Array()
			bones.resize(lanes)
			var shift := rb_first[si] - base_bones
			for k in range(lanes):
				var id := raw[k]
				bones[k] = id if id < base_bones else id + shift
			arr[Mesh.ARRAY_BONES] = bones
			arr[Mesh.ARRAY_WEIGHTS] = blob.slice(
				body + sw_off * 4, body + sw_off * 4 + lanes * 4).to_float32_array()
			# EIGHT INFLUENCES NEEDS SAYING SO. Godot assumes four lanes unless
			# told otherwise, and a silent truncation to four would drop weight
			# the game put in the upper lanes, so part of the mesh would deform
			# wrongly while the rest looked right.
			if infl == 8:
				flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		else:
			# A rigid section (a weapon, an attachment) carries no binding. It
			# still belongs in the mesh; it simply will not follow the rig.
			unskinned += 1
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, flags)
		am.surface_set_material(am.get_surface_count() - 1,
			HighpolyLoadout.section_material(gs, sec))
		surface_section.append(si)

	if am.get_surface_count() == 0:
		skel.queue_free()
		return {"error": "The configured soldier has no drawable geometry."}

	var root := Node3D.new()
	root.name = "HP_SoldierRig_%s" % str(request.get("character", ""))
	root.add_child(skel)
	var mi := MeshInstance3D.new()
	mi.name = "Soldier"
	mi.mesh = am
	skel.add_child(mi)
	mi.skin = skin
	mi.skeleton = mi.get_path_to(skel)

	# THE SKELETON IS PLACED, NOT THE GEOMETRY. Skinned vertices stay in rig
	# space, which is the only space the palette accepts them in, so the
	# feet-on-the-origin offset the static path bakes into the vertices is
	# applied here instead.
	var r: Array = rec.get("root", [])
	if r.size() >= 3:
		skel.position = Vector3(float(r[0]), float(r[1]), float(r[2]))

	# The weapon, hung off the hand so it rides the pose rather than sitting
	# where one sampled frame left it.
	for bone in attached:
		var att := BoneAttachment3D.new()
		att.name = "Attach_%s" % skel.get_bone_name(bone)
		skel.add_child(att)
		att.bone_idx = bone
		var wm := MeshInstance3D.new()
		wm.name = "Weapon"
		wm.mesh = attached[bone]
		att.add_child(wm)

	var anchors := {}
	var raw_anchors: Variant = rec.get("anchors", {})
	if raw_anchors is Dictionary:
		for slot in raw_anchors:
			var a: Array = raw_anchors[slot]
			anchors[slot] = Vector3(float(a[0]), float(a[1]), float(a[2]))
	root.set_meta("hp_slot_anchors", anchors)
	root.set_meta("hp_rig_bones", skel.get_bone_count())
	root.set_meta("hp_rig_base_bones", base_bones)
	root.set_meta("hp_rig_unskinned", unskinned)
	root.set_meta("hp_rig_attached", attached.size())
	root.set_meta("hp_rig_surface_section", surface_section)
	root.set_meta("hp_rig_role", str(request.get("role", "assault")))
	root.set_meta("hp_rig_seed", str(request.get("role_seed", "")))
	return {"node": root, "skeleton": skel, "anchors": anchors, "error": ""}


# ------------------------------------------------------------- the animation

# The role's front-end idle as a Godot Animation over `skel`, ready to play.
# {} fields: "animation", "frames", "bones", "clip", "error".
#
# Frame 0 of this is the record's `posed`, which the core's own gate checks
# exactly, so a soldier built by build() and then driven by this starts where it
# was already standing rather than snapping on the first frame.
static func animation(gs, skel: Skeleton3D, role: String = "assault") -> Dictionary:
	var core = HighpolyLoadout.core_for(gs)
	if core == null or not core.has_method("loadout_soldier_clip"):
		return {"error": "This game reader cannot read animation clips; update the add-on."}
	var blob: PackedByteArray = core.call("loadout_soldier_clip",
		JSON.stringify({"role": role}))
	if blob.size() < 12 or blob.decode_u32(0) != CLIP_MAGIC:
		return {"error": "The soldier's idle animation could not be read."}
	var json_len := blob.decode_u32(8)
	var parsed: Variant = JSON.parse_string(
		blob.slice(12, 12 + json_len).get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"error": "The soldier's idle animation record is invalid."}
	var rec: Dictionary = parsed
	if str(rec.get("error", "")) != "":
		return {"error": str(rec["error"])}
	var frames := int(rec.get("frames", 0))
	var tracks: Array = rec.get("tracks", [])
	if frames < 2 or tracks.is_empty():
		return {"error": "The soldier's idle animation carries no movement."}
	var body := 12 + int(json_len)

	var anim := Animation.new()
	anim.length = float(frames - 1) / CLIP_FPS
	anim.loop_mode = Animation.LOOP_LINEAR
	var made := 0
	for t in tracks:
		var track: Dictionary = t
		var bone := int(track.get("bone", -1))
		var at := int(track.get("track", -1))
		if bone < 0 or bone >= skel.get_bone_count() or at < 0:
			continue
		var name := skel.get_bone_name(bone)
		# Godot wants position, rotation and scale as SEPARATE tracks, so the
		# one transform per frame the core ships is split three ways here
		# rather than three times in the core.
		var pos := anim.add_track(Animation.TYPE_POSITION_3D)
		var rot := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(pos, ":%s" % name)
		anim.track_set_path(rot, ":%s" % name)
		for f in range(frames):
			var off := body + (at + f * 12) * 4
			var m := blob.slice(off, off + 48).to_float32_array()
			var x := _xform(Array(m))
			var time := float(f) / CLIP_FPS
			anim.position_track_insert_key(pos, time, x.origin)
			anim.rotation_track_insert_key(rot, time, x.basis.get_rotation_quaternion())
		made += 1
	if made == 0:
		return {"error": "No animation track matched a bone on this skeleton."}
	return {"animation": anim, "frames": frames, "bones": made,
		"clip": str(rec.get("clip", "")), "error": ""}


# Hang an AnimationPlayer off the built soldier and load the role's idle into
# it. Returns the same fields as animation(), plus "player".
static func add_idle(gs, built: Dictionary) -> Dictionary:
	var skel: Skeleton3D = built.get("skeleton")
	var root: Node3D = built.get("node")
	if skel == null or root == null:
		return {"error": "There is no built soldier to animate."}
	var got := animation(gs, skel, str(root.get_meta("hp_rig_role", "assault")))
	if str(got.get("error", "")) != "":
		return got
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", got["animation"])
	# HighpolyIdlePlayer, not a bare AnimationPlayer: the editor does not tick
	# the scene it is editing, so autoplay and play() leave the soldier standing
	# on frame 0. It keeps its own clock in a @tool _process instead.
	var player := HighpolyIdlePlayer.new()
	player.name = "Idle"
	root.add_child(player)
	# The player addresses bones by path RELATIVE TO ITS ROOT, and the tracks
	# are written as ":<bone>", so that root has to be the skeleton itself.
	player.root_node = player.get_path_to(skel)
	player.add_animation_library("", lib)
	# A PHASE PER SOLDIER. Started together, every spawner in a row breathes in
	# lockstep, which reads as one animation played many times rather than as
	# people standing about. The seed is the same stable one the random pose
	# uses, so a given spawner always starts at the same point in the clip.
	var phase := float(HighpolyLoadout.seed_of(
		str(root.get_meta("hp_rig_seed", root.name))) % 997) / 997.0
	player.drive("idle", phase)
	got["player"] = player
	return got
