extends Node

const HOST = "127.0.0.1"

const STATE_PORT = 50555
const COMMAND_PORT = 50556

const SEND_INTERVAL_MS = 16
const MOVE_INTERVAL_MS = 4

# Maximum movement on EACH axis in one movement tick.
# A diagonal command can move both axes in the same tick.
const MAX_MOVE_STEP = 0.25

# If Python disappears, stop the cursor automatically.
const COMMAND_TIMEOUT_MS = 100

var state_udp = PacketPeerUDP.new()
var command_udp = PacketPeerUDP.new()

var spawn
var cursor

var fly_enabled = false
var f10_was_down = false

var last_send_ms = 0
var last_move_ms = 0

var last_command_ms = -999999
var last_action = "CENTERED"
var last_vector = Vector2(0, 0)


func _ready():

	spawn = get_parent().get_node("Spawn")
	cursor = spawn.get_node("Cursor")

	# Godot -> Python
	state_udp.set_dest_address(
		HOST,
		STATE_PORT
	)

	# Python -> Godot
	var err = command_udp.listen(
		COMMAND_PORT,
		HOST
	)

	print("[FlyBrain] vector bridge ready")

	if err != OK:
		print(
			"[FlyBrain] ERROR listening on command port: ",
			err
		)

	print("[FlyBrain] F10 toggles fly control")


func _process(delta):

	handle_toggle()
	receive_commands()
	send_state()
	apply_fly_movement()


func handle_toggle():

	var down = Input.is_key_pressed(KEY_F10)

	if down and not f10_was_down:

		fly_enabled = not fly_enabled

		# Stop your physical mouse from controlling Cursor.gd
		# while the fly is enabled.
		cursor.set_process_input(
			not fly_enabled
		)

		if fly_enabled:
			print("========== FLY CONTROL ON ==========")

		else:
			print("========== FLY CONTROL OFF ==========")

	f10_was_down = down


func action_to_vector(action):

	match action:

		"LEFT":
			return Vector2(-1, 0)

		"RIGHT":
			return Vector2(1, 0)

		"UP":
			return Vector2(0, -1)

		"DOWN":
			return Vector2(0, 1)

		_:
			return Vector2(0, 0)


func receive_commands():

	# Throw away old commands and keep newest.
	while command_udp.get_available_packet_count() > 0:

		var bytes = command_udp.get_packet()
		var text = bytes.get_string_from_utf8()
		var parsed = JSON.parse(text)

		if parsed.error != OK:
			continue

		var command = parsed.result

		# New vector protocol.
		if command.has("vx") and command.has("vy"):

			last_vector = Vector2(
				float(command["vx"]),
				float(command["vy"])
			)

			last_action = "VECTOR"
			last_command_ms = OS.get_ticks_msec()

		# Backwards-compatible old four-action protocol.
		elif command.has("action"):

			last_action = String(
				command["action"]
			)

			last_vector = action_to_vector(
				last_action
			)

			last_command_ms = OS.get_ticks_msec()


func apply_fly_movement():

	if not fly_enabled:
		return

	var now = OS.get_ticks_msec()

	if now - last_command_ms > COMMAND_TIMEOUT_MS:
		return

	if now - last_move_ms < MOVE_INTERVAL_MS:
		return

	last_move_ms = now

	var i = find_next_note()

	if i < 0:
		return

	var target = spawn.notes[i][0]
	var c = cursor.transform.origin

	var current = Vector2(
		c.x,
		c.y
	)

	var error = target - current
	var drive = last_vector

	# Accept arbitrary vector sizes from Python,
	# but scale so largest component is at most 1.
	var largest = max(
		abs(drive.x),
		abs(drive.y)
	)

	if largest <= 0.000001:
		return

	if largest > 1.0:
		drive = drive / largest

	var step_x = min(
		MAX_MOVE_STEP * abs(drive.x),
		abs(error.x)
	)

	var step_y = min(
		MAX_MOVE_STEP * abs(drive.y),
		abs(error.y)
	)

	if drive.x < 0:
		step_x = -step_x

	if drive.y < 0:
		step_y = -step_y

	# Never let a stale / noisy component
	# move away from the target.
	if error.x * drive.x <= 0:
		step_x = 0

	if error.y * drive.y >= 0:
		step_y = 0

	cursor.move_cursor(
		Vector2(
			step_x,
			step_y
		)
	)


func send_state():

	if not spawn.notes_loaded:
		return

	if spawn.notes.size() == 0:
		return

	var now = OS.get_ticks_msec()

	if (
		now - last_send_ms
		< SEND_INTERVAL_MS
	):
		return

	last_send_ms = now

	var i = find_next_note()

	if i < 0:
		return

	var note = spawn.notes[i]
	var target = note[0]
	var note_ms = note[1]

	var c = cursor.transform.origin

	var current = Vector2(
		c.x,
		c.y
	)

	var error = target - current

	var packet = {

		"note": i,

		"time_to_note":
			note_ms - spawn.ms,

		"cursor_x":
			current.x,

		"cursor_y":
			current.y,

		"target_x":
			target.x,

		"target_y":
			target.y,

		"dx":
			error.x,

		"dy":
			error.y,

		"fly_enabled":
			fly_enabled
	}

	state_udp.put_packet(
		JSON.print(packet).to_utf8()
	)


func find_next_note():

	for i in range(
		max(
			spawn.current_note,
			0
		),
		spawn.notes.size()
	):

		if (
			spawn.notes[i][2]
			== Globals.NSTATE_ACTIVE
		):

			return i

	return -1
