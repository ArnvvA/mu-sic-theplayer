extends Node2D

const CARD_WIDTH  := 200
const CARD_HEIGHT := 280

var deck_pos  := Vector2(960 - CARD_WIDTH / 2, 540 - CARD_HEIGHT / 2)
var deck_rect : Rect2

var all_cards  : Array = []
var deck_cards : Array = []
var sound_queue: Array = []

var card_scene : PackedScene
var card_sound : AudioStream

var back_path = "res://assets/card_back.webp"

# Player slot
const SLOT_POS    := Vector2(1640, 400)
var _slot_rect    : Rect2
var _slot_card            = null
var _audio_player : AudioStreamPlayer


func _ready() -> void:
	card_scene = preload("res://scenes/card.tscn")
	card_sound = preload("res://assets/card.ogg")

	deck_rect  = Rect2(deck_pos, Vector2(CARD_WIDTH, CARD_HEIGHT))
	_slot_rect = Rect2(SLOT_POS, Vector2(CARD_WIDTH, CARD_HEIGHT))

	_audio_player = AudioStreamPlayer.new()
	add_child(_audio_player)

	for song in _scan_music():
		var card = card_scene.instantiate()
		add_child(card)
		card.setup(deck_pos)
		card.set_card_texture("res://assets/card.png", Vector2(CARD_WIDTH, CARD_HEIGHT))
		card.set_back_texture(back_path)
		card.set_title(song["title"])
		card.song_path = song["path"]
		all_cards.append(card)
		deck_cards.append(card)


# ── Music scanning ────────────────────────────────────────────────────────────

func _scan_music() -> Array:
	var songs := []
	var base   := "res://assets/music/"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(base)):
		return songs

	for dir_name in DirAccess.get_directories_at(base):
		var dir_path := base + dir_name + "/"
		var files : Array[String] = []
		for f in DirAccess.get_files_at(dir_path):
			files.append(f)
		files.sort_custom(func(a, b): return a.to_lower() < b.to_lower())
		files.reverse()
		for file in files:
			var ext := file.get_extension().to_lower()
			if ext in ["ogg", "mp3", "wav"]:
				songs.append({
					"path":  dir_path + file,
					"title": _parse_title(file),
					"album": dir_name
				})
	return songs


func _parse_title(filename: String) -> String:
	var base    := filename.get_basename()
	var parts   := base.split(" - ", false, 1)
	var title   := parts[-1] if parts.size() > 1 else parts[0]
	var bracket := title.find(" [")
	if bracket != -1:
		title = title.substr(0, bracket)
	return title.strip_edges()


# ── Card layout ───────────────────────────────────────────────────────────────

func _align() -> void:
	var offset := Vector2(-0.25, 0.25)
	for i in deck_cards.size():
		var card = deck_cards[i]
		if not card.dragging:
			card.target_pos = deck_pos + offset * i


# ── Per-frame ─────────────────────────────────────────────────────────────────

func _process(dt: float) -> void:
	var mouse_pos := get_viewport().get_mouse_position()

	for card in all_cards:
		if card.dragging:
			card.target_pos = mouse_pos - Vector2(CARD_WIDTH / 2.0, CARD_HEIGHT / 2.0)
		card.move(dt)

	_align()

	for i in deck_cards.size():
		deck_cards[i].z_index = i
		deck_cards[i].get_node("TitleLabel").visible = (i == deck_cards.size() - 1)
	var off_z := deck_cards.size()
	for card in all_cards:
		if not card.is_on_deck and not card.dragging:
			card.z_index = off_z
			off_z += 1
	for card in all_cards:
		if card.dragging:
			card.z_index = off_z

	var i := 0
	while i < sound_queue.size():
		sound_queue[i]["delay"] -= dt
		if sound_queue[i]["delay"] <= 0.0:
			_play_sound(sound_queue[i]["pitch"])
			sound_queue.remove_at(i)
		else:
			i += 1

	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(1920.0, 1080.0)), Color(0.88, 0.92, 0.88, 1.0))

	# Player slot
	var slot_fill   := Color(0.5, 0.6, 0.5, 0.15) if _slot_card == null else Color(0.015, 0.647, 0.898, 0.12)
	var slot_border := Color(0.4, 0.5, 0.4, 0.7)  if _slot_card == null else Color(0.015, 0.647, 0.898, 0.9)
	draw_rect(_slot_rect, slot_fill)
	draw_rect(_slot_rect, slot_border, false, 2.0)
	if _slot_card == null:
		var cx := SLOT_POS.x + CARD_WIDTH  / 2.0
		var cy := SLOT_POS.y + CARD_HEIGHT / 2.0
		draw_line(Vector2(cx - 22, cy), Vector2(cx + 22, cy), slot_border, 2.0)
		draw_line(Vector2(cx, cy - 22), Vector2(cx, cy + 22), slot_border, 2.0)


# ── Input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release()


func _on_press(pos: Vector2) -> void:
	var sorted := all_cards.duplicate()
	sorted.sort_custom(func(a, b): return a.z_index > b.z_index)

	for card in sorted:
		if Rect2(card.position, Vector2(CARD_WIDTH, CARD_HEIGHT)).has_point(pos):
			card.handle_click()
			card.dragging = true
			if card == _slot_card:
				_slot_card = null
				_audio_player.stop()
			return


func _on_release() -> void:
	for card in all_cards:
		if card.dragging:
			card.dragging = false
			_play_sound(1.0)

			var center: Vector2 = card.position + Vector2(CARD_WIDTH / 2.0, CARD_HEIGHT / 2.0)
			if _slot_rect.has_point(center):
				_dock_card(card)
			elif deck_rect.has_point(center):
				card.is_on_deck = true
				if not deck_cards.has(card):
					deck_cards.append(card)
				card.force_face_up()
			else:
				card.is_on_deck = false
				deck_cards.erase(card)
			break


func _dock_card(card) -> void:
	if _slot_card != null and _slot_card != card:
		_slot_card.is_on_deck = false

	_slot_card      = card
	card.is_on_deck = false
	deck_cards.erase(card)
	card.target_pos = SLOT_POS
	card.force_face_up()

	var stream = load(card.song_path) as AudioStream
	if stream:
		_audio_player.stream = stream
		_audio_player.play()
	else:
		push_warning("Cannot play '%s' — convert to .ogg or .mp3 for Godot audio support." % card.song_path)


func _play_sound(pitch: float) -> void:
	var player := AudioStreamPlayer.new()
	add_child(player)
	player.stream = card_sound
	player.pitch_scale = pitch
	player.play()
	player.finished.connect(player.queue_free)
