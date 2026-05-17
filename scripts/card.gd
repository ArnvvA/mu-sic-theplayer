extends Node2D

const MOMENTUM     := 0.75
const MAX_VELOCITY := 40.0

var velocity   := Vector2.ZERO
var target_pos := Vector2.ZERO
var dragging   := false

var front_texture : Texture2D
var card_size     := Vector2.ZERO

var song_path       := ""
var song_title      := ""
var deck                         = null  # reference to deck dict in main.gd
var last_click_time : float     = 0.0


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
