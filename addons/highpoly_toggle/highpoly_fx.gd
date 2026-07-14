@tool
extends Object
class_name HighpolyFx
# Map FX layer: live GPU particles at the map's real FX spawn points
# (user://mapcontext/<map>/fx.json — mined + classified from the level EBX;
# Aftermath: 314 fires, 954 smokes, 166 electric in the base event layer).
# Parameters come from the EmitterGraph study (docs/EMITTERGRAPH-STUDY.md):
# spawn 1/s, particle life 5 s, Drag 0.3, flipbook grids 6x36 fire / 8x64
# smoke — mapped onto GPUParticles3D. Spark colour = Temperature 0.5 blackbody.
# Editor-only, owner=null. Distance-faded per site so ~hundreds of emitters
# stay cheap.

const NODE := "_MAP_FX"

static var _mats: Dictionary = {}       # class -> [ParticleProcessMaterial, Material]

static func clear(root: Node) -> void:
	if root == null: return
	# name-pattern sweep: plugin reloads orphan owner=null overlays, and a
	# rebuilt twin gets auto-RENAMED next to the orphan — a single
	# get_node_or_null() then deletes the wrong one ("FX won't turn off")
	for c in root.get_children():
		if String(c.name).contains(NODE):
			root.remove_child(c)
			c.queue_free()

static func apply(root: Node, map: String, on: bool) -> String:
	clear(root)
	if root == null: return "No scene open"
	if not on: return "FX off"
	var p := "user://mapcontext/%s/fx.json" % map
	if not FileAccess.file_exists(p):
		return "No FX data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "fx.json unreadable"
	var holder := Node3D.new()
	holder.name = NODE
	root.add_child(holder)
	holder.owner = null
	var counts := {"fire": 0, "smoke": 0, "electric": 0}
	for f in d.get("fx", []):
		if not (f is Dictionary): continue
		if str(f.get("source_class", "base")) != "base":
			continue                    # winter/gauntlet-only FX stay off
		var cls := str(f.get("class", ""))
		if not counts.has(cls): continue
		var pos: Array = f.get("pos", [0, 0, 0])
		var e := _emitter(cls)
		e.position = Vector3(pos[0], pos[1], pos[2])
		holder.add_child(e)
		e.owner = null
		counts[cls] += 1
	return "FX: %d fire, %d smoke, %d electric" % [
		counts["fire"], counts["smoke"], counts["electric"]]

static func _emitter(cls: String) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	var cfg := _class_mats(cls)
	g.process_material = cfg[0]
	g.draw_pass_1 = cfg[1]
	match cls:
		"fire":
			g.amount = 6
			g.lifetime = 5.0            # authored ParticleLifeSpan
			g.visibility_range_end = 300.0
		"smoke":
			g.amount = 6
			g.lifetime = 5.0
			g.visibility_range_end = 600.0   # columns read from far
		"electric":
			g.amount = 32
			g.lifetime = 0.6
			g.explosiveness = 0.15
			g.visibility_range_end = 220.0
	g.visibility_range_end_margin = 40.0
	g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	g.visibility_aabb = AABB(Vector3(-6, -1, -6), Vector3(12, 14, 12))
	g.set_meta("vr", g.visibility_range_end)   # class default, for set_range
	return g

# Range-slider tie-in: clamp every emitter's draw distance to the dock's
# Range value (never past its class default). 0 hides FX entirely.
static func set_range(root: Node, r: float) -> void:
	var h := root.get_node_or_null(NODE) if root != null else null
	if h == null: return
	for c in h.get_children():
		if c is GPUParticles3D:
			var g := c as GPUParticles3D
			if r <= 0.0:
				g.visible = false
			else:
				g.visible = true
				g.visibility_range_end = minf(float(g.get_meta("vr", 300.0)), r)

static func _class_mats(cls: String) -> Array:
	if _mats.has(cls): return _mats[cls]
	var pm := ParticleProcessMaterial.new()
	var qm := QuadMesh.new()
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.vertex_color_use_as_albedo = true
	var base := (HighpolyFx as Script).resource_path.get_base_dir() + "/fx_textures"
	match cls:
		"fire":
			pm.direction = Vector3(0, 1, 0)
			pm.initial_velocity_min = 0.4; pm.initial_velocity_max = 0.9
			pm.gravity = Vector3(0, 0.6, 0)      # Buoyancy-style rise
			pm.damping_min = 0.3; pm.damping_max = 0.3   # authored Drag
			pm.scale_min = 0.9; pm.scale_max = 1.6
			pm.anim_speed_min = 1.0; pm.anim_speed_max = 1.0
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			pm.emission_sphere_radius = 0.5
			dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			dm.albedo_texture = load(base + "/fire_6x36.png")
			dm.particles_anim_h_frames = 6
			dm.particles_anim_v_frames = 6
			dm.particles_anim_loop = true
			qm.size = Vector2(2.4, 2.4)
		"smoke":
			pm.direction = Vector3(0, 1, 0)
			pm.initial_velocity_min = 0.8; pm.initial_velocity_max = 1.6
			pm.gravity = Vector3(0, 0.9, 0)
			pm.damping_min = 0.3; pm.damping_max = 0.3
			pm.scale_min = 1.2; pm.scale_max = 2.4
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			pm.emission_sphere_radius = 0.8
			pm.color = Color(0.32, 0.31, 0.30, 0.75)
			dm.albedo_texture = load(base + "/smoke_8x64.png")
			dm.particles_anim_h_frames = 8
			dm.particles_anim_v_frames = 8
			dm.particles_anim_loop = true
			qm.size = Vector2(4.0, 4.0)
		"electric":
			pm.direction = Vector3(0, 1, 0)
			pm.spread = 70.0
			pm.initial_velocity_min = 2.5; pm.initial_velocity_max = 5.5
			pm.gravity = Vector3(0, -9.8, 0)
			pm.scale_min = 0.05; pm.scale_max = 0.12
			pm.color = Color(1.0, 0.72, 0.35)   # Temperature 0.5 blackbody
			dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			qm.size = Vector2(0.35, 0.35)
	qm.material = dm
	_mats[cls] = [pm, qm]
	return _mats[cls]
