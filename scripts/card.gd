extends Node2D

const MOMENTUM := 0.75
const MAX_VELOCITY := 10.0

var velocity := Vector2.ZERO
var target_pos := Vector2.ZERO
var dragging := false
var is_on_deck := true

# flip
var front_texture: Texture2D
var back_texture: Texture2D
var is_face_up := true
var last_flip_time := -10.0
const FLIP_COOLDOWN := 0.5

var last_click_time := 0.0
const DOUBLE_CLICK_TIME := 0.18

# stored so back texture and force_face_up can use the same scale
var card_size := Vector2.ZERO

var song_path := ""


func setup(pos: Vector2) -> void:
	position = pos
	target_pos = pos


func set_card_texture(path: String, size: Vector2) -> void:
	var tex = load(path)
	if not tex:
		return

	front_texture = tex
	card_size = size

	var card_sprite   := $Sprite2D
	var border_sprite := get_node_or_null("BorderSprite")

	card_sprite.texture = tex
	card_sprite.scale   = _fit_scale(tex, size)
	card_sprite.position = size / 2.0

	# Scale border based on its own texture size, not the card's
	if border_sprite and border_sprite.texture:
		border_sprite.scale    = _fit_scale(border_sprite.texture, size)
		border_sprite.position = size / 2.0
		border_sprite.z_index  = 1


func set_back_texture(path: String) -> void:
	back_texture = load(path)


func flip() -> void:
	if not back_texture or not front_texture:
		return

	var card_sprite := $Sprite2D
	is_face_up = not is_face_up

	if is_face_up:
		card_sprite.texture  = front_texture
		card_sprite.scale    = _fit_scale(front_texture, card_size)
		$TitleLabel.visible  = true
	else:
		card_sprite.texture  = back_texture
		card_sprite.scale    = _fit_scale(back_texture, card_size)
		$TitleLabel.visible  = false


func force_face_up() -> void:
	if not is_face_up and front_texture:
		var card_sprite      := $Sprite2D
		card_sprite.texture  = front_texture
		card_sprite.scale    = _fit_scale(front_texture, card_size)
		is_face_up           = true
		$TitleLabel.visible  = true


func handle_click() -> void:
	if dragging:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_flip_time < FLIP_COOLDOWN:
		return
	if now - last_click_time <= DOUBLE_CLICK_TIME:
		flip()
		last_flip_time  = now
		last_click_time = 0.0
	else:
		last_click_time = now


func set_title(text: String) -> void:
	var label := $TitleLabel
	label.text = text
	label.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	label.add_theme_font_size_override("font_size", 14)


func move(dt: float) -> void:
	if position != target_pos or velocity != Vector2.ZERO:
		velocity.x = MOMENTUM * velocity.x + (1.0 - MOMENTUM) * (target_pos.x - position.x) * 30.0 * dt
		velocity.y = MOMENTUM * velocity.y + (1.0 - MOMENTUM) * (target_pos.y - position.y) * 30.0 * dt
		position += velocity
		var speed := velocity.length()
		if speed > MAX_VELOCITY:
			velocity = velocity * (MAX_VELOCITY / speed)


# Returns a uniform scale that fits `tex` within `size`.
func _fit_scale(tex: Texture2D, size: Vector2) -> Vector2:
	if size == Vector2.ZERO:
		return Vector2.ONE
	var tex_size := tex.get_size()
	var s := minf(size.x / tex_size.x, size.y / tex_size.y)
	return Vector2.ONE * s
