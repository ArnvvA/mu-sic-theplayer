extends Node2D

const MOMENTUM     := 0.75
const MAX_VELOCITY := 40.0

# ── 3D slot effect (only the card in the player slot uses these) ──────────────
const IDLE_SPIN      := 0.55   # rad/sec — slow idle rotation while it plays
const PAUSED_SPIN    := 0.25    # rad/sec — even slower drift while the song is paused
const SPIN_FRICTION  := 1.5     # how fast a flick eases back toward the idle spin
const DRAG_SPIN_GAIN := 0.018   # mouse speed → spin speed while you turn it
const FACE_SLOWDOWN  := 0.3     # how much to linger when a face/back is toward you (0..1)

const BOB_SPEED        := 1.5   # bob clock rate while the song plays
const BOB_SPEED_PAUSED := 0.4   # slower bob clock while the song is paused

const SCRIM_STRENGTH   := 0.7   # how dark the bottom fade gets behind the title

var velocity   := Vector2.ZERO
var target_pos := Vector2.ZERO
var dragging   := false

var _slot_active := false              # is the 3D effect currently on this card?
var _angle       := 0.0                # current spin angle around the vertical axis
var _ang_vel     := 0.0                # current spin speed (radians / second)
var _bob_phase   := 0.0                # clock that drives the idle bob (slows when paused)
var _bob_speed   := BOB_SPEED          # current bob clock rate, eased by play/pause
var _slot_mat : ShaderMaterial         # the spin shader, created on first use
var _round_mat : ShaderMaterial        # the default rounded-corner shader
var _label_shown := false              # is this card's title currently visible?

var front_texture : Texture2D
var card_size     := Vector2.ZERO

var song_path       := ""
var song_title      := ""
var deck                         = null  # reference to deck dict in main.gd


func _ready() -> void:
	# Give every card softly rounded corners by default. The slot effect swaps this
	# out for the spin shader while a card plays, then set_slot_active puts it back.
	_round_mat = ShaderMaterial.new()
	_round_mat.shader = preload("res://shaders/card_round.gdshader")
	$Sprite2D.material = _round_mat

	# Start with the title hidden so it matches _label_shown (false). set_label_shown
	# skips work when nothing changed, so the initial state has to line up.
	$TitleLabel.visible = false


func setup(pos: Vector2) -> void:
	position   = pos
	target_pos = pos


func set_cover(tex: Texture2D, size: Vector2) -> void:
	if not tex:
		return
	front_texture = tex
	card_size     = size
	var sprite := $Sprite2D
	sprite.texture  = tex
	sprite.scale    = _fit_scale(tex, size)
	sprite.position = size / 2.0


func set_title(text: String) -> void:
	song_title = text
	var label := $TitleLabel
	label.text = text
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_font_size_override("font_size", 14)


# Show or hide this card's title. main.gd calls this every frame with whether the
# card should currently show its name. We toggle the text node and fade the bottom
# scrim in/out together so the darkening only appears where there's text to read.
func set_label_shown(shown: bool) -> void:
	if shown == _label_shown:
		return
	_label_shown = shown
	$TitleLabel.visible = shown
	_apply_scrim()


# Push the current scrim amount into whichever shaders exist. Setting it on both
# materials means the right value is already there no matter which one is active
# (plain card vs. spinning slot card).
func _apply_scrim() -> void:
	var amt := SCRIM_STRENGTH if _label_shown else 0.0
	if _round_mat != null:
		_round_mat.set_shader_parameter("scrim", amt)
	if _slot_mat != null:
		_slot_mat.set_shader_parameter("scrim", amt)


func move(dt: float) -> void:
	if position != target_pos or velocity != Vector2.ZERO:
		velocity.x = MOMENTUM * velocity.x + (1.0 - MOMENTUM) * (target_pos.x - position.x) * 30.0 * dt
		velocity.y = MOMENTUM * velocity.y + (1.0 - MOMENTUM) * (target_pos.y - position.y) * 30.0 * dt
		position += velocity
		var speed := velocity.length()
		if speed > MAX_VELOCITY:
			velocity = velocity * (MAX_VELOCITY / speed)


func _fit_scale(tex: Texture2D, size: Vector2) -> Vector2:
	if size == Vector2.ZERO:
		return Vector2.ONE
	var tex_size := tex.get_size()
	var s := minf(size.x / tex_size.x, size.y / tex_size.y)
	return Vector2.ONE * s


# ── 3D slot effect ────────────────────────────────────────────────────────────

# Turn the tilt effect on or off. main.gd calls this when a card enters or leaves
# the player slot. Turning it on attaches the shader to the sprite; turning it off
# removes it so the card goes back to a plain, flat image.
func set_slot_active(active: bool) -> void:
	if active == _slot_active:
		return
	_slot_active = active
	if active:
		if _slot_mat == null:
			_slot_mat = ShaderMaterial.new()
			_slot_mat.shader = preload("res://shaders/card_tilt.gdshader")
		$Sprite2D.material = _slot_mat
		_angle   = 0.0          # start facing front
		_ang_vel = IDLE_SPIN    # begin the gentle idle rotation
		_apply_scrim()          # the freshly-made slot shader needs the scrim value
	else:
		$Sprite2D.material = _round_mat   # back to the plain rounded-corner card


# Called every frame by main.gd while this card owns the slot effect. Advances the
# spin — steered by your mouse while you're turning it, otherwise coasting toward
# the idle rotation (a slower drift when paused) — and hands the angle to the shader.
#   rotating  - true while you hold the OUTER ring and turn the card
#   mouse_dx  - how far the mouse moved horizontally since last frame (pixels)
#   playing   - true while the song is playing; false when paused/stopped
func update_slot_visual(dt: float, rotating: bool, mouse_dx: float, playing: bool) -> void:
	if not _slot_active:
		return

	# Advance the bob clock. Its rate eases between the playing speed and the
	# slower paused speed (same friction as the spin), so the up-down float
	# visibly relaxes when you pause instead of bobbing on at full pace.
	var bob_target := BOB_SPEED if playing else BOB_SPEED_PAUSED
	_bob_speed = lerpf(_bob_speed, bob_target, clampf(SPIN_FRICTION * dt, 0.0, 1.0))
	_bob_phase = wrapf(_bob_phase + _bob_speed * dt, 0.0, TAU)
	_slot_mat.set_shader_parameter("bob_phase", _bob_phase)

	if rotating:
		# Spin speed tracks how fast the mouse is moving: a quick flick spins it
		# fast, a slow drag turns it gently. Dividing by dt converts "pixels this
		# frame" into "pixels per second" so the feel is frame-rate independent.
		# Negated so the card turns AGAINST the drag — like your hand is gripping
		# the near edge and shoving it, the way you'd turn a real object.
		_ang_vel = -(mouse_dx / max(dt, 0.0001)) * DRAG_SPIN_GAIN
	else:
		# Let go: ease the spin speed toward its resting value. While the song
		# plays that's the gentle idle spin; while it's paused it's the slower
		# drift, so the card keeps turning but visibly eases down.
		var target := IDLE_SPIN if playing else PAUSED_SPIN
		_ang_vel = lerpf(_ang_vel, target, clampf(SPIN_FRICTION * dt, 0.0, 1.0))

	# Advance the angle and wrap it into 0..TAU so it can keep spinning forever.
	# Linger on the faces: |cos(angle)| is near 1 when a flat side (front or back)
	# is toward you and near 0 edge-on, so this eases the spin down on the faces
	# and lets it run full speed through the thin edge. Skipped while you're
	# directly turning it, so dragging stays a clean 1:1 with your mouse.
	var step := _ang_vel * dt
	if not rotating:
		var face := absf(cos(_angle))
		step *= 1.0 - face * FACE_SLOWDOWN
	_angle = wrapf(_angle + step, 0.0, TAU)
	_slot_mat.set_shader_parameter("spin", _angle)
