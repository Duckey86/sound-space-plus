extends Control

# FlyBrainMiniHUD_Optimized.gd
# Godot 3.6.x
#
# Optimized live FlyWire morphology HUD.
#
# PERFORMANCE CHANGES:
# - The ~124k skeleton segments are no longer redrawn with hundreds of
#   draw_multiline() calls every HUD packet.
# - Inactive KCs are compiled ONCE into a single ArrayMesh.
# - Inactive background is lightly decimated for display only.
# - Active KC state meshes are built once per encountered state and cached.
# - MBONs are compiled into meshes once.
# - Pulse/fade changes only CanvasItem.modulate; it does not rebuild geometry.
# - UDP is polled at 120 Hz, not at the game's full frame rate.
#
# F9 = hide/show
#
# It does NOT change FlyBrainBridge.gd or the gameplay controller.

const HOST = "127.0.0.1"
const HUD_PORT = 50557
const CACHE_PATH = "res://data/flybrain_visual/flybrain_policy_skeletons.json"

const STALE_MS = 750

# HUD geometry
const PANEL_POS = Vector2(16, 16)
const PANEL_SIZE = Vector2(455, 292)
const HEADER_H = 38.0
const FOOTER_H = 31.0
const BRAIN_PAD = 12.0

# Performance knobs.
# 4 means the dim inactive background keeps 1 in every 4 anatomical segments.
# Active neurons stay full-detail.
const BACKGROUND_STRIDE = 4
const ACTIVE_STRIDE = 1
const MBON_STRIDE = 1

const UDP_POLL_HZ = 120.0
const ANIM_HZ = 30.0

# Activity afterglow
const FADE_SECONDS = 0.36
const FADE_LAYERS = 3
const KC_PULSE_HZ = 2.6
const MBON_PULSE_HZ = 3.4


var udp = PacketPeerUDP.new()

var latest = {}
var last_packet_ms = -999999
var last_stale = true

var poll_accum = 0.0
var anim_accum = 0.0
var pulse_phase = 0.0

# FlyWire root ID -> projected disconnected line pairs.
# [a0,b0,a1,b1,...]
var neuron_lines = {}
var neuron_info = {}

var loaded_neurons = 0
var loaded_segments = 0

var current_state = "CENTERED"
var current_winner = "CENTERED"
var winner_mbon = ""
var active_kcs = {}

# Geometry cache
var state_mesh_cache = {}
var mbon_mesh_cache = {}

# Render nodes
var background_instance = null
var mbon_background_instance = null
var active_instance = null
var winner_instance = null
var trail_slots = []
var trail_cursor = 0

# Colors
var panel_bg = Color(0.010, 0.016, 0.024, 0.92)
var panel_border = Color(0.13, 0.28, 0.37, 0.90)
var brain_bg = Color(0.015, 0.025, 0.034, 0.72)

var text_main = Color(0.91, 0.96, 1.0, 1.0)
var text_dim = Color(0.48, 0.61, 0.70, 1.0)

var kc_inactive = Color(0.18, 0.34, 0.43, 0.20)
var kc_active = Color(0.05, 0.92, 1.0, 0.96)

var mbon_inactive = Color(0.70, 0.25, 0.65, 0.30)
var mbon_winner_outer = Color(1.0, 0.25, 0.82, 0.95)
var mbon_winner_inner = Color(1.0, 1.0, 1.0, 1.0)

var live_color = Color(0.15, 1.0, 0.72, 1.0)
var waiting_color = Color(1.0, 0.55, 0.30, 1.0)


func _ready():
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    rect_min_size = PANEL_POS + PANEL_SIZE + Vector2(8, 8)
    rect_size = rect_min_size

    _create_render_nodes()
    _load_morphology_cache()
    _compile_static_geometry()

    var err = udp.listen(HUD_PORT, HOST)

    if err == OK:
        print("[FlyBrainMiniHUD] UDP 50557 ready")
    else:
        print("[FlyBrainMiniHUD] UDP listen error: ", err)

    set_process(true)
    set_process_unhandled_input(true)
    update()


func _create_render_nodes():
    background_instance = MeshInstance2D.new()
    background_instance.name = "FlyBrainInactiveKC"
    background_instance.z_index = 1
    add_child(background_instance)

    mbon_background_instance = MeshInstance2D.new()
    mbon_background_instance.name = "FlyBrainInactiveMBON"
    mbon_background_instance.z_index = 2
    add_child(mbon_background_instance)

    for i in range(FADE_LAYERS):
        var n = MeshInstance2D.new()
        n.name = "FlyBrainTrail" + String(i)
        n.z_index = 3
        n.visible = false
        add_child(n)

        trail_slots.append({
            "node": n,
            "time": 0.0
        })

    active_instance = MeshInstance2D.new()
    active_instance.name = "FlyBrainActiveKC"
    active_instance.z_index = 4
    active_instance.visible = false
    add_child(active_instance)

    winner_instance = MeshInstance2D.new()
    winner_instance.name = "FlyBrainWinnerMBON"
    winner_instance.z_index = 5
    winner_instance.visible = false
    add_child(winner_instance)


func _brain_rect():
    return Rect2(
        PANEL_POS + Vector2(BRAIN_PAD, HEADER_H),
        Vector2(
            PANEL_SIZE.x - BRAIN_PAD * 2.0,
            PANEL_SIZE.y - HEADER_H - FOOTER_H
        )
    )


func _load_morphology_cache():
    var f = File.new()

    if not f.file_exists(CACHE_PATH):
        print("[FlyBrainMiniHUD] Cache missing: ", CACHE_PATH)
        return

    var err = f.open(CACHE_PATH, File.READ)
    if err != OK:
        print("[FlyBrainMiniHUD] Could not open cache: ", err)
        return

    var raw_text = f.get_as_text()
    f.close()

    print(
        "[FlyBrainMiniHUD] Parsing morphology cache (",
        raw_text.length(),
        " bytes)..."
    )

    var parsed = JSON.parse(raw_text)

    if parsed.error != OK:
        print(
            "[FlyBrainMiniHUD] JSON error line ",
            parsed.error_line,
            ": ",
            parsed.error_string
        )
        return

    var cache = parsed.result
    var neurons = cache.get("neurons", [])

    var raw_projected = {}

    var min_x = INF
    var min_y = INF
    var max_x = -INF
    var max_y = -INF

    # Pass 1: 3D -> front-view 2D projection and global bounds.
    for n in neurons:
        var rid = String(n.get("id", ""))
        var role = String(n.get("role", "KC"))
        var action = String(n.get("action", ""))
        var vertices = n.get("vertices", [])

        if rid == "" or vertices.size() < 6:
            continue

        var pts = PoolVector2Array()

        for i in range(0, vertices.size(), 3):
            var x = float(vertices[i])
            var y = -float(vertices[i + 1])

            pts.append(Vector2(x, y))

            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)

        raw_projected[rid] = pts

        neuron_info[rid] = {
            "role": role,
            "action": action,
            "segments": int(n.get("segments", vertices.size() / 6))
        }

        loaded_neurons += 1
        loaded_segments += int(n.get("segments", vertices.size() / 6))

    if raw_projected.empty():
        print("[FlyBrainMiniHUD] No drawable neurons in cache.")
        return

    # Pass 2: fit the whole morphology inside the mini panel.
    var br = _brain_rect()

    var span_x = max(max_x - min_x, 0.000001)
    var span_y = max(max_y - min_y, 0.000001)

    var usable_w = br.size.x - 12.0
    var usable_h = br.size.y - 10.0

    var scale = min(
        usable_w / span_x,
        usable_h / span_y
    )

    var src_cx = (min_x + max_x) * 0.5
    var src_cy = (min_y + max_y) * 0.5

    var dst_center = br.position + br.size * 0.5

    for rid in raw_projected.keys():
        var src_pts = raw_projected[rid]
        var pool = PoolVector2Array()

        for p in src_pts:
            pool.append(
                Vector2(
                    dst_center.x + (p.x - src_cx) * scale,
                    dst_center.y + (p.y - src_cy) * scale
                )
            )

        neuron_lines[rid] = pool

    print(
        "[FlyBrainMiniHUD] Loaded ",
        loaded_neurons,
        " real neurons / ",
        loaded_segments,
        " segments"
    )


func _append_segments(dst, src, stride):
    if src == null:
        return

    var seg_count = int(src.size() / 2)
    var step_size = max(1, int(stride))

    for seg in range(0, seg_count, step_size):
        var i = seg * 2
        dst.append(src[i])
        dst.append(src[i + 1])


func _mesh_from_points(points):
    if points.size() < 2:
        return null

    var arrays = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = points

    var mesh = ArrayMesh.new()
    mesh.add_surface_from_arrays(
        Mesh.PRIMITIVE_LINES,
        arrays
    )

    return mesh


func _compile_static_geometry():
    var kc_points = PoolVector2Array()
    var mbon_points = PoolVector2Array()

    for rid in neuron_lines.keys():
        var info = neuron_info.get(rid, {})
        var role = String(info.get("role", "KC"))

        if role == "MBON":
            _append_segments(
                mbon_points,
                neuron_lines[rid],
                MBON_STRIDE
            )

            # Also cache each individual MBON for winner highlighting.
            mbon_mesh_cache[rid] = _mesh_for_ids([rid], MBON_STRIDE)
        else:
            _append_segments(
                kc_points,
                neuron_lines[rid],
                BACKGROUND_STRIDE
            )

    background_instance.mesh = _mesh_from_points(kc_points)
    background_instance.modulate = kc_inactive

    mbon_background_instance.mesh = _mesh_from_points(mbon_points)
    mbon_background_instance.modulate = mbon_inactive

    print(
        "[FlyBrainMiniHUD] Static background compiled: ",
        int(kc_points.size() / 2),
        " displayed KC segments (stride ",
        BACKGROUND_STRIDE,
        ")"
    )


func _mesh_for_ids(ids, stride):
    var pts = PoolVector2Array()

    for rid_any in ids:
        var rid = String(rid_any)

        if neuron_lines.has(rid):
            _append_segments(
                pts,
                neuron_lines[rid],
                stride
            )

    return _mesh_from_points(pts)


func _get_state_mesh(state_key):
    if state_key == "CENTERED":
        return null

    if state_mesh_cache.has(state_key):
        return state_mesh_cache[state_key]

    var ids = []

    for rid in active_kcs.keys():
        ids.append(rid)

    var mesh = _mesh_for_ids(ids, ACTIVE_STRIDE)
    state_mesh_cache[state_key] = mesh

    print(
        "[FlyBrainMiniHUD] Cached active mesh for ",
        state_key,
        ": ",
        ids.size(),
        " KCs"
    )

    return mesh


func _push_active_to_trail():
    if active_instance == null:
        return

    if not active_instance.visible or active_instance.mesh == null:
        return

    var slot = trail_slots[trail_cursor]
    trail_cursor = (trail_cursor + 1) % FADE_LAYERS

    var n = slot["node"]
    n.mesh = active_instance.mesh
    n.modulate = Color(
        kc_active.r,
        kc_active.g,
        kc_active.b,
        0.54
    )
    n.visible = true

    slot["time"] = FADE_SECONDS


func _set_active_state_mesh():
    _push_active_to_trail()

    var mesh = _get_state_mesh(current_state)

    if mesh == null:
        active_instance.mesh = null
        active_instance.visible = false
    else:
        active_instance.mesh = mesh
        active_instance.modulate = kc_active
        active_instance.visible = true


func _set_winner_mesh():
    if winner_mbon == "" or not neuron_lines.has(winner_mbon):
        winner_instance.mesh = null
        winner_instance.visible = false
        return

    if not mbon_mesh_cache.has(winner_mbon):
        mbon_mesh_cache[winner_mbon] = _mesh_for_ids(
            [winner_mbon],
            MBON_STRIDE
        )

    winner_instance.mesh = mbon_mesh_cache[winner_mbon]
    winner_instance.modulate = mbon_winner_inner
    winner_instance.visible = winner_instance.mesh != null


func _process(delta):
    poll_accum += delta
    anim_accum += delta

    # We do not need to poll UDP thousands of times per second just because
    # Rhythia itself is rendering at 1000-2000 FPS.
    if poll_accum >= 1.0 / UDP_POLL_HZ:
        poll_accum = 0.0
        _poll_udp()

    # Pulse/fade at 30 Hz. Geometry is never rebuilt here.
    if anim_accum >= 1.0 / ANIM_HZ:
        var step = anim_accum
        anim_accum = 0.0
        _animate_activity(step)

    var stale = OS.get_ticks_msec() - last_packet_ms > STALE_MS

    if stale != last_stale:
        last_stale = stale
        update()


func _poll_udp():
    var got_packet = false
    var newest = null

    # Consume all queued packets, but only apply the newest one.
    while udp.get_available_packet_count() > 0:
        var bytes = udp.get_packet()
        var text = bytes.get_string_from_utf8()
        var parsed = JSON.parse(text)

        if parsed.error == OK:
            newest = parsed.result

    if newest == null:
        return

    latest = newest
    last_packet_ms = OS.get_ticks_msec()
    got_packet = true

    if got_packet:
        _consume_live_packet()


func _consume_live_packet():
    var new_state = String(latest.get("state", "CENTERED"))
    var new_winner = String(latest.get("winner", "CENTERED"))
    var new_winner_mbon = String(latest.get("winner_mbon", ""))

    var state_changed = new_state != current_state
    var winner_changed = (
        new_winner != current_winner
        or new_winner_mbon != winner_mbon
    )

    # Only rebuild the dictionary when a new packet has arrived.
    active_kcs.clear()

    for rid in latest.get("active_kcs", []):
        active_kcs[String(rid)] = true

    current_state = new_state
    current_winner = new_winner
    winner_mbon = new_winner_mbon

    if state_changed:
        _set_active_state_mesh()

    # Handles first packet too, even if it happens to say CENTERED.
    elif active_instance.mesh == null and current_state != "CENTERED":
        _set_active_state_mesh()

    if winner_changed:
        _set_winner_mesh()

    update()


func _animate_activity(step):
    pulse_phase += step

    # Active KCs gently breathe.
    if active_instance != null and active_instance.visible:
        var p = 0.88 + 0.12 * sin(
            pulse_phase * TAU * KC_PULSE_HZ
        )

        active_instance.modulate = Color(
            kc_active.r,
            kc_active.g,
            kc_active.b,
            kc_active.a * p
        )

    # Previous KC populations fade over ~360 ms.
    for slot in trail_slots:
        var n = slot["node"]
        var t = float(slot["time"])

        if t <= 0.0:
            if n.visible:
                n.visible = false
            continue

        t = max(0.0, t - step)
        slot["time"] = t

        var a = 0.42 * (t / FADE_SECONDS)

        n.modulate = Color(
            kc_active.r,
            kc_active.g,
            kc_active.b,
            a
        )

        if t <= 0.0:
            n.visible = false

    # Winner MBON gets the stronger pulse.
    if winner_instance != null and winner_instance.visible:
        var p2 = 0.72 + 0.28 * (
            0.5 + 0.5 * sin(
                pulse_phase * TAU * MBON_PULSE_HZ
            )
        )

        winner_instance.modulate = Color(
            mbon_winner_inner.r,
            0.58 + 0.42 * p2,
            0.78 + 0.22 * p2,
            0.82 + 0.18 * p2
        )


func _unhandled_input(event):
    if not (event is InputEventKey):
        return

    if not event.pressed or event.echo:
        return

    if event.scancode == KEY_F9:
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


func _draw():
    var panel = Rect2(PANEL_POS, PANEL_SIZE)
    var br = _brain_rect()

    draw_rect(panel, panel_bg, true)
    draw_rect(panel, panel_border, false, 1.0)
    draw_rect(br, brain_bg, true)

    _label(
        PANEL_POS + Vector2(14, 23),
        "FLY BRAIN — LIVE NEURONS",
        text_main
    )

    var stale = OS.get_ticks_msec() - last_packet_ms > STALE_MS
    var status = "WAITING" if stale else "LIVE"
    var status_color = waiting_color if stale else live_color

    draw_circle(
        PANEL_POS + Vector2(PANEL_SIZE.x - 58, 18),
        3.0,
        status_color
    )

    _label(
        PANEL_POS + Vector2(PANEL_SIZE.x - 48, 23),
        status,
        status_color
    )

    var footer_y = PANEL_POS.y + PANEL_SIZE.y - 11

    _label(
        Vector2(PANEL_POS.x + 13, footer_y),
        "state: " + current_state,
        kc_active
    )

    _label(
        Vector2(PANEL_POS.x + 214, footer_y),
        "KCs: " + String(active_kcs.size()),
        text_dim
    )

    _label(
        Vector2(PANEL_POS.x + 287, footer_y),
        "MBON: " + current_winner,
        text_main
    )
