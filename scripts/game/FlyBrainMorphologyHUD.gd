extends Control

# Real FlyWire neuron morphology viewer for Godot 3.6.x.
#
# This is VISUALIZATION ONLY:
#   - gameplay bridge remains on UDP 50555/50556
#   - this HUD listens on UDP 50557
#   - it never changes the fly's movement
#
# Controls:
#   left-drag = rotate
#   mouse wheel = zoom
#   R = reset camera
#   F9 = hide/show viewer

const HOST = "127.0.0.1"
const HUD_PORT = 50557
const STALE_MS = 750

const CACHE_PATH = "res://data/flybrain_visual/flybrain_policy_skeletons.json"

const PANEL_POS = Vector2(18, 18)
const PANEL_SIZE = Vector2(850, 620)
const VIEW_POS = Vector2(22, 66)
const VIEW_SIZE = Vector2(620, 510)

var udp = PacketPeerUDP.new()
var latest = {}
var last_packet_ms = -999999

var cache = {}
var neuron_meshes = {}
var neuron_info = {}
var loaded_neurons = 0
var loaded_segments = 0

var viewport_container
var brain_viewport
var brain_world
var brain_pivot
var brain_camera

var dragging = false
var rot_x = 0.08
var rot_y = -0.12
var camera_distance = 14.0

var active_kcs = {}
var winner_mbon = ""
var current_winner = "CENTERED"

var mat_kc_inactive
var mat_kc_active
var mat_mbon_inactive
var mat_mbon_winner

var bg = Color(0.012, 0.018, 0.028, 0.95)
var panel_line = Color(0.11, 0.30, 0.42, 0.85)
var text_main = Color(0.92, 0.97, 1.0, 1.0)
var text_dim = Color(0.48, 0.61, 0.70, 1.0)
var cyan = Color(0.08, 0.90, 1.0, 1.0)
var white_hot = Color(1.0, 1.0, 1.0, 1.0)
var magenta = Color(1.0, 0.34, 0.86, 1.0)
var warn = Color(1.0, 0.52, 0.30, 1.0)


func _ready():

    mouse_filter = Control.MOUSE_FILTER_IGNORE
    rect_min_size = PANEL_SIZE + Vector2(36, 36)
    rect_size = rect_min_size

    _make_materials()
    _build_3d_view()
    _load_morphology_cache()

    var err = udp.listen(
        HUD_PORT,
        HOST
    )

    if err == OK:
        print("[FlyBrainMorphologyHUD] UDP 50557 ready")
    else:
        print("[FlyBrainMorphologyHUD] UDP listen error: ", err)

    set_process(true)
    set_process_unhandled_input(true)
    update()


func _make_line_material(color, energy):

    var m = SpatialMaterial.new()
    m.flags_unshaded = true
    m.flags_transparent = true
    m.flags_no_depth_test = false
    m.params_blend_mode = SpatialMaterial.BLEND_MODE_ADD
    m.albedo_color = color
    m.emission_enabled = true
    m.emission = Color(color.r, color.g, color.b, 1.0)
    m.emission_energy = energy
    return m


func _make_materials():

    mat_kc_inactive = _make_line_material(
        Color(0.14, 0.22, 0.29, 0.24),
        0.20
    )

    mat_kc_active = _make_line_material(
        Color(0.05, 0.92, 1.0, 0.96),
        2.2
    )

    mat_mbon_inactive = _make_line_material(
        Color(0.50, 0.24, 0.50, 0.42),
        0.55
    )

    mat_mbon_winner = _make_line_material(
        Color(1.0, 0.96, 1.0, 1.0),
        3.2
    )


func _build_3d_view():

    viewport_container = ViewportContainer.new()
    viewport_container.name = "MorphologyViewportContainer"
    viewport_container.rect_position = PANEL_POS + VIEW_POS
    viewport_container.rect_size = VIEW_SIZE
    viewport_container.mouse_filter = Control.MOUSE_FILTER_STOP
    viewport_container.connect("gui_input", self, "_on_view_gui_input")
    add_child(viewport_container)

    brain_viewport = Viewport.new()
    brain_viewport.name = "MorphologyViewport"
    brain_viewport.size = VIEW_SIZE
    brain_viewport.disable_3d = false
    brain_viewport.usage = Viewport.USAGE_3D
    brain_viewport.transparent_bg = false
    brain_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
    brain_viewport.msaa = Viewport.MSAA_4X
    viewport_container.add_child(brain_viewport)

    brain_world = Spatial.new()
    brain_world.name = "BrainWorld"
    brain_viewport.add_child(brain_world)

    var world_env = WorldEnvironment.new()
    world_env.name = "BrainEnvironment"
    var env = Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.004, 0.008, 0.014, 1.0)
    env.ambient_light_color = Color(0.04, 0.08, 0.12, 1.0)
    env.ambient_light_energy = 0.25
    # Glow is available in the GLES3 build used by your Rhythia debug window.
    env.glow_enabled = true
    env.glow_strength = 1.25
    env.glow_bloom = 0.18
    world_env.environment = env
    brain_world.add_child(world_env)

    brain_pivot = Spatial.new()
    brain_pivot.name = "BrainPivot"
    brain_world.add_child(brain_pivot)

    brain_camera = Camera.new()
    brain_camera.name = "BrainCamera"
    brain_camera.current = true
    brain_camera.fov = 46.0
    brain_world.add_child(brain_camera)

    _reset_camera()


func _reset_camera():

    rot_x = 0.08
    rot_y = -0.12
    camera_distance = 14.0

    if brain_pivot != null:
        brain_pivot.rotation = Vector3(rot_x, rot_y, 0.0)

    if brain_camera != null:
        brain_camera.translation = Vector3(0.0, 0.0, camera_distance)
        brain_camera.look_at(Vector3.ZERO, Vector3.UP)


func _load_morphology_cache():

    var f = File.new()

    if not f.file_exists(CACHE_PATH):
        print("[FlyBrainMorphologyHUD] Cache missing: ", CACHE_PATH)
        print("Run build_flywire_policy_skeletons.py first.")
        return

    var err = f.open(CACHE_PATH, File.READ)
    if err != OK:
        print("[FlyBrainMorphologyHUD] Could not open cache: ", err)
        return

    var raw = f.get_as_text()
    f.close()

    print(
        "[FlyBrainMorphologyHUD] Parsing real FlyWire morphology cache (",
        raw.length(),
        " bytes)..."
    )

    var parsed = JSON.parse(raw)
    if parsed.error != OK:
        print(
            "[FlyBrainMorphologyHUD] JSON error line ",
            parsed.error_line,
            ": ",
            parsed.error_string
        )
        return

    cache = parsed.result

    var neurons = cache.get("neurons", [])

    loaded_neurons = 0
    loaded_segments = 0

    for n in neurons:

        var rid = String(n.get("id", ""))
        var role = String(n.get("role", "KC"))
        var action = String(n.get("action", ""))
        var raw_vertices = n.get("vertices", [])

        if rid == "" or raw_vertices.size() < 6:
            continue

        var verts = PoolVector3Array()

        for i in range(0, raw_vertices.size(), 3):
            verts.append(
                Vector3(
                    float(raw_vertices[i]),
                    float(raw_vertices[i + 1]),
                    float(raw_vertices[i + 2])
                )
            )

        var arrays = []
        arrays.resize(ArrayMesh.ARRAY_MAX)
        arrays[ArrayMesh.ARRAY_VERTEX] = verts

        var mesh = ArrayMesh.new()
        mesh.add_surface_from_arrays(
            Mesh.PRIMITIVE_LINES,
            arrays
        )

        var mi = MeshInstance.new()
        mi.name = "N_" + rid
        mi.mesh = mesh

        if role == "MBON":
            mi.material_override = mat_mbon_inactive
        else:
            mi.material_override = mat_kc_inactive

        brain_pivot.add_child(mi)

        neuron_meshes[rid] = mi
        neuron_info[rid] = {
            "role": role,
            "action": action,
            "segments": int(n.get("segments", raw_vertices.size() / 6))
        }

        loaded_neurons += 1
        loaded_segments += int(n.get("segments", raw_vertices.size() / 6))

    print(
        "[FlyBrainMorphologyHUD] Loaded ",
        loaded_neurons,
        " real neurons / ",
        loaded_segments,
        " line segments"
    )

    _apply_activity()
    update()


func _process(delta):

    var got_packet = false

    while udp.get_available_packet_count() > 0:

        var bytes = udp.get_packet()
        var text = bytes.get_string_from_utf8()
        var parsed = JSON.parse(text)

        if parsed.error == OK:
            latest = parsed.result
            last_packet_ms = OS.get_ticks_msec()
            got_packet = true

    if got_packet:
        _consume_live_packet()
        update()


func _consume_live_packet():

    active_kcs.clear()

    for rid in latest.get("active_kcs", []):
        active_kcs[String(rid)] = true

    winner_mbon = String(
        latest.get("winner_mbon", "")
    )

    current_winner = String(
        latest.get("winner", "CENTERED")
    )

    _apply_activity()


func _apply_activity():

    if neuron_meshes.empty():
        return

    for rid in neuron_meshes.keys():

        var mi = neuron_meshes[rid]
        var info = neuron_info.get(rid, {})
        var role = String(info.get("role", "KC"))

        if role == "MBON":
            if rid == winner_mbon and winner_mbon != "":
                mi.material_override = mat_mbon_winner
            else:
                mi.material_override = mat_mbon_inactive
        else:
            if active_kcs.has(rid):
                mi.material_override = mat_kc_active
            else:
                mi.material_override = mat_kc_inactive


func _on_view_gui_input(event):

    if event is InputEventMouseButton:

        if event.button_index == BUTTON_LEFT:
            dragging = event.pressed

        elif event.pressed and event.button_index == BUTTON_WHEEL_UP:
            camera_distance = max(5.5, camera_distance - 0.8)
            brain_camera.translation.z = camera_distance

        elif event.pressed and event.button_index == BUTTON_WHEEL_DOWN:
            camera_distance = min(30.0, camera_distance + 0.8)
            brain_camera.translation.z = camera_distance

    elif event is InputEventMouseMotion and dragging:

        rot_y -= event.relative.x * 0.006
        rot_x -= event.relative.y * 0.006
        rot_x = clamp(rot_x, -1.35, 1.35)

        brain_pivot.rotation = Vector3(
            rot_x,
            rot_y,
            0.0
        )


func _unhandled_input(event):

    if not (event is InputEventKey):
        return

    if not event.pressed or event.echo:
        return

    if event.scancode == KEY_R:
        _reset_camera()

    elif event.scancode == KEY_F9:
        visible = not visible


func _font():
    return get_font("font")


func _label(pos, value, color = Color(1, 1, 1, 1)):

    draw_string(
        _font(),
        pos,
        String(value),
        color
    )


func _score_fraction(scores, action):

    if scores.empty():
        return 0.0

    var vals = [
        float(scores.get("LEFT", 0.0)),
        float(scores.get("RIGHT", 0.0)),
        float(scores.get("UP", 0.0)),
        float(scores.get("DOWN", 0.0))
    ]

    var lo = vals[0]
    var hi = vals[0]

    for v in vals:
        lo = min(lo, v)
        hi = max(hi, v)

    var span = max(hi - lo, 0.000001)
    return (
        float(scores.get(action, 0.0))
        - lo
    ) / span


func _draw_score_bar(y, action, scores):

    var x = PANEL_POS.x + 672
    var w = 142.0
    var h = 12.0

    var frac = _score_fraction(scores, action)
    var is_winner = action == current_winner

    _label(
        Vector2(x, y - 2),
        action,
        white_hot if is_winner else text_dim
    )

    draw_rect(
        Rect2(x, y + 7, w, h),
        Color(0.08, 0.12, 0.16, 0.94),
        true
    )

    draw_rect(
        Rect2(x, y + 7, w * frac, h),
        magenta if is_winner else cyan,
        true
    )

    _label(
        Vector2(x, y + 39),
        "%.3f" % float(scores.get(action, 0.0)),
        text_main
    )


func _draw():

    draw_rect(
        Rect2(PANEL_POS, PANEL_SIZE),
        bg,
        true
    )

    draw_rect(
        Rect2(PANEL_POS, PANEL_SIZE),
        panel_line,
        false,
        1.0
    )

    var x = PANEL_POS.x + 22
    var y = PANEL_POS.y + 28

    _label(
        Vector2(x, y),
        "FLY BRAIN CONNECTOME — LIVE MORPHOLOGY",
        text_main
    )

    var stale = (
        OS.get_ticks_msec()
        - last_packet_ms
        > STALE_MS
    )

    var live_text = "LIVE" if not stale else "WAITING"
    var live_color = cyan if not stale else warn

    _label(
        Vector2(PANEL_POS.x + 765, y),
        live_text,
        live_color
    )

    # Viewer frame.
    draw_rect(
        Rect2(PANEL_POS + VIEW_POS, VIEW_SIZE),
        Color(0.03, 0.08, 0.10, 0.82),
        false,
        1.0
    )

    var sx = PANEL_POS.x + 672
    var sy = PANEL_POS.y + 82

    _label(Vector2(sx, sy), "REAL FLYWIRE v783", cyan)
    sy += 24

    _label(
        Vector2(sx, sy),
        "%d neurons" % loaded_neurons,
        text_main
    )
    sy += 20

    _label(
        Vector2(sx, sy),
        "%d segments" % loaded_segments,
        text_dim
    )
    sy += 33

    if cache.empty():
        _label(Vector2(sx, sy), "CACHE MISSING", warn)
        sy += 22
        _label(Vector2(sx, sy), "Run the Python", text_dim)
        sy += 18
        _label(Vector2(sx, sy), "skeleton builder.", text_dim)
        return

    var state = String(
        latest.get("state", "CENTERED")
    )

    _label(Vector2(sx, sy), "STATE", text_dim)
    sy += 21
    _label(Vector2(sx, sy), state, cyan)
    sy += 31

    _label(Vector2(sx, sy), "ACTIVE KCs", text_dim)
    sy += 21
    _label(
        Vector2(sx, sy),
        String(active_kcs.size()),
        text_main
    )
    sy += 31

    _label(Vector2(sx, sy), "MBON WINNER", text_dim)
    sy += 21
    _label(
        Vector2(sx, sy),
        current_winner,
        white_hot
    )
    sy += 40

    var scores = latest.get("scores", {})

    _label(Vector2(sx, sy), "MBON OUTPUTS", text_dim)
    sy += 22

    _draw_score_bar(sy, "LEFT", scores)
    sy += 63
    _draw_score_bar(sy, "RIGHT", scores)
    sy += 63
    _draw_score_bar(sy, "UP", scores)
    sy += 63
    _draw_score_bar(sy, "DOWN", scores)

    var footer_y = PANEL_POS.y + PANEL_SIZE.y - 18

    _label(
        Vector2(PANEL_POS.x + 26, footer_y),
        "drag: rotate   wheel: zoom   R: reset   F9: hide",
        text_dim
    )

    _label(
        Vector2(PANEL_POS.x + 665, footer_y),
        "FPS %d" % Engine.get_frames_per_second(),
        text_dim
    )
