extends Node2D

const CARD_SIZE          : float = 240.0
const CLICK_THRESHOLD    : float = 8.0
const DOUBLE_CLICK_TIME  : float = 0.30

# Main screen grid
const GRID_COLS          : int    = 4
const GRID_START         := Vector2(80, 80)
const GRID_PITCH         := Vector2(320, 320)

# Fan-out layout
const FAN_SPREAD_MAX     : float = 1400.0
const FAN_CENTER_Y       : float = 540.0
const FAN_CARD_PITCH     : float = 260.0

# Player tab (right side)
const PLAYER_SLOT_POS    := Vector2(1620, 80)
const PLAYER_QUEUE_GAP   : float = 50.0

# Generous drop target for the slot
const SLOT_DROP_MARGIN   : float = 80.0

# Retract offset when decks slide off-screen
const RETRACT_OFFSET_X   : float = 2400.0

# Hover-pop offset for queued cards
const HOVER_OFFSET       := Vector2(-260.0, 0.0)

var card_scene    : PackedScene
var card_sound    : AudioStream
var default_cover : Texture2D

var all_cards  : Array = []
var decks      : Array = []         # each: {name, artist, cards, home_pos, cover}

var fanned_deck           = null
var playing_deck          = null
var playing_index : int   = 0
var slot_card             = null
var hover_card            = null

var _press_card           = null
var _press_pos  : Vector2 = Vector2.ZERO
var _drag_active : bool   = false

var _audio_player : AudioStreamPlayer
var sound_queue   : Array = []


func _ready() -> void:
	card_scene    = preload("res://scenes/card.tscn")
	card_sound    = preload("res://assets/card.ogg")
	default_cover = preload("res://assets/card.png")

	_audio_player = AudioStreamPlayer.new()
	_audio_player.finished.connect(_on_song_finished)
	add_child(_audio_player)

	_build_decks()

	Engine.max_fps = 60


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Engine.max_fps = 15
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		Engine.max_fps = 60


# ── Scan & build ──────────────────────────────────────────────────────────────

func _build_decks() -> void:
	var albums = _scan_music()
	for i in albums.size():
		var info      = albums[i]
		var album_dir = "res://assets/music/" + info.name + "/"
		var cover     = _load_cover(album_dir)
		var meta      = _load_meta(album_dir)

		var deck = {
			"name":     meta.get("album", info.name),
			"artist":   meta.get("artist", ""),
			"cards":    [],
			"home_pos": _grid_pos(i),
			"cover":    cover,
		}
		for song in info.songs:
			var card = card_scene.instantiate()
			add_child(card)
			card.setup(deck.home_pos)
			card.set_cover(cover, Vector2(CARD_SIZE, CARD_SIZE))
			card.set_title(_parse_title(song.file, deck.artist))
			card.song_path = song.path
			card.deck = deck
			all_cards.append(card)
			deck.cards.append(card)
		decks.append(deck)


func _grid_pos(i: int) -> Vector2:
	var col := i % GRID_COLS
	var row := i / GRID_COLS
	return GRID_START + Vector2(col * GRID_PITCH.x, row * GRID_PITCH.y)


func _scan_music() -> Array:
	var albums := []
	var base   := "res://assets/music/"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(base)):
		return albums

	var dir_names : Array[String] = []
	for d in DirAccess.get_directories_at(base):
		dir_names.append(d)
	dir_names.sort_custom(func(a, b): return a.to_lower() < b.to_lower())

	for dir_name in dir_names:
		var dir_path := base + dir_name + "/"
		var files : Array[String] = []
		for f in DirAccess.get_files_at(dir_path):
			files.append(f)
		files.sort_custom(func(a, b): return a.to_lower() < b.to_lower())

		var songs := []
		for file in files:
			var ext := file.get_extension().to_lower()
			if ext in ["ogg", "mp3", "wav"]:
				songs.append({ "path": dir_path + file, "file": file })
		if songs.size() > 0:
			albums.append({ "name": dir_name, "songs": songs })
	return albums


func _parse_title(filename: String, artist: String = "") -> String:
	var base := filename.get_basename()

	# Strip leading "NN - " (numeric playlist index from yt-dlp).
	var first_sep := base.find(" - ")
	if first_sep != -1 and base.substr(0, first_sep).strip_edges().is_valid_int():
		base = base.substr(first_sep + 3)

	# Strip leading "Artist - " if it matches the album's artist.
	if artist != "" and base.to_lower().begins_with(artist.to_lower() + " - "):
		base = base.substr(artist.length() + 3)

	# Strip common YouTube tail markers.
	for marker in [
		" (Official Audio)", " (Official Music Video)", " (Official Video)",
		" (Audio)", " (Music Video)", " (Lyrics)", " (Lyric Video)",
	]:
		if base.ends_with(marker):
			base = base.substr(0, base.length() - marker.length())
			break

	# Strip trailing " [video_id]".
	if base.ends_with("]"):
		var bracket := base.rfind(" [")
		if bracket != -1:
			base = base.substr(0, bracket)

	return base.strip_edges()


func _load_cover(album_dir: String) -> Texture2D:
	var exts : Array[String] = ["jpg", "jpeg", "png", "webp"]
	for ext in exts:
		var path : String = album_dir + "cover." + ext
		if FileAccess.file_exists(path):
			var img := Image.new()
			if img.load(ProjectSettings.globalize_path(path)) == OK:
				img = _trim_dark_borders(img)
				img = _center_square(img)
				return ImageTexture.create_from_image(img)
	return default_cover


func _trim_dark_borders(img: Image) -> Image:
	var w : int = img.get_width()
	var h : int = img.get_height()
	var max_trim_x : int = w / 3
	var max_trim_y : int = h / 3
	var top : int = 0
	var bottom : int = h - 1
	var left : int = 0
	var right : int = w - 1
	while top < max_trim_y and _row_dark(img, top, w):
		top += 1
	while bottom > h - 1 - max_trim_y and _row_dark(img, bottom, w):
		bottom -= 1
	while left < max_trim_x and _col_dark(img, left, h):
		left += 1
	while right > w - 1 - max_trim_x and _col_dark(img, right, h):
		right -= 1
	if top == 0 and bottom == h - 1 and left == 0 and right == w - 1:
		return img
	return img.get_region(Rect2i(left, top, right - left + 1, bottom - top + 1))


func _row_dark(img: Image, y: int, w: int) -> bool:
	var samples : int = 20
	for i in samples:
		var x : int = i * (w - 1) / (samples - 1)
		var c : Color = img.get_pixel(x, y)
		if c.r > 0.06 or c.g > 0.06 or c.b > 0.06:
			return false
	return true


func _col_dark(img: Image, x: int, h: int) -> bool:
	var samples : int = 20
	for i in samples:
		var y : int = i * (h - 1) / (samples - 1)
		var c : Color = img.get_pixel(x, y)
		if c.r > 0.06 or c.g > 0.06 or c.b > 0.06:
			return false
	return true


func _center_square(img: Image) -> Image:
	var w : int = img.get_width()
	var h : int = img.get_height()
	if w == h:
		return img
	var side : int = mini(w, h)
	var x : int = (w - side) / 2
	var y : int = (h - side) / 2
	return img.get_region(Rect2i(x, y, side, side))


func _load_meta(album_dir: String) -> Dictionary:
	var path := album_dir + "meta.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


# ── Per-card position / z / visibility ────────────────────────────────────────

func _compute_target(card) -> Vector2:
	var deck = card.deck

	if card == slot_card:
		return PLAYER_SLOT_POS

	if playing_deck != null and deck == playing_deck:
		var p := _player_queue_pos(card)
		if card == hover_card:
			p += HOVER_OFFSET
		return p

	if fanned_deck != null and deck == fanned_deck:
		return _fan_pos(card)

	if fanned_deck != null:
		var dir_sign := 1.0 if deck.home_pos.x >= fanned_deck.home_pos.x else -1.0
		return deck.home_pos + Vector2(dir_sign * RETRACT_OFFSET_X, 0)

	var i = deck.cards.find(card)
	return deck.home_pos + Vector2(-0.25, 0.25) * i


func _fan_pos(card) -> Vector2:
	var deck = card.deck
	var idx  = deck.cards.find(card)
	var n    = deck.cards.size()
	var effective_width : float = min(FAN_SPREAD_MAX, n * FAN_CARD_PITCH)
	var spacing : float = 0.0 if n <= 1 else (effective_width - CARD_SIZE) / float(n - 1)
	var start_x : float = (1920.0 - effective_width) / 2.0
	return Vector2(start_x + idx * spacing, FAN_CENTER_Y - CARD_SIZE / 2.0)


func _player_queue_pos(card) -> Vector2:
	if playing_deck == null:
		return PLAYER_SLOT_POS
	var n = playing_deck.cards.size()
	var idx = playing_deck.cards.find(card)
	var q = (idx - playing_index + n) % n
	return PLAYER_SLOT_POS + Vector2(0, q * PLAYER_QUEUE_GAP)


func _compute_z(card) -> int:
	# Godot 4 clamps z_index to [-4096, 4096]; values outside silently fail and
	# leave the previous z in place, which causes queue cards to render in the
	# wrong order. Keep every band well below the cap.
	if card.dragging:
		return 4000

	if card == hover_card:
		return 3500

	if card == slot_card:
		return 3000

	var deck = card.deck

	if playing_deck != null and deck == playing_deck:
		var n = playing_deck.cards.size()
		var idx = playing_deck.cards.find(card)
		var q = (idx - playing_index + n) % n
		return 2900 - q

	if fanned_deck != null and deck == fanned_deck:
		return 2000 + deck.cards.find(card)

	if fanned_deck != null:
		return 100

	var i = deck.cards.find(card)
	return 1000 - i


func _label_visible(card) -> bool:
	if card == hover_card:
		return true
	if card.dragging or card == slot_card:
		return true
	var deck = card.deck
	if playing_deck != null and deck == playing_deck:
		return card == playing_deck.cards[playing_index]
	if fanned_deck != null and deck == fanned_deck:
		return true
	if fanned_deck == null and deck.cards[0] == card:
		return true
	return false


func _label_text(card) -> String:
	# Top of an unfanned, unplayed home stack shows album name; otherwise song title.
	var deck = card.deck
	if not card.dragging and card != slot_card \
			and (playing_deck == null or deck != playing_deck) \
			and (fanned_deck == null or deck != fanned_deck) \
			and deck.cards[0] == card:
		return deck.name
	return card.song_title


# ── Per-frame ─────────────────────────────────────────────────────────────────

func _process(dt: float) -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	_update_hover(mouse_pos)

	for card in all_cards:
		if card.dragging:
			card.target_pos = mouse_pos - Vector2(CARD_SIZE, CARD_SIZE) / 2.0
		else:
			card.target_pos = _compute_target(card)
		card.move(dt)
		card.z_index = _compute_z(card)
		var vis := _label_visible(card)
		card.get_node("TitleLabel").visible = vis
		card.get_node("TitlePanel").visible = vis
		if vis:
			card.get_node("TitleLabel").text = _label_text(card)

	var i := 0
	while i < sound_queue.size():
		sound_queue[i]["delay"] -= dt
		if sound_queue[i]["delay"] <= 0.0:
			_play_sound(sound_queue[i]["pitch"])
			sound_queue.remove_at(i)
		else:
			i += 1

	queue_redraw()


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(1920, 1080)), Color(0.88, 0.92, 0.88, 1.0))

	var slot_rect := Rect2(PLAYER_SLOT_POS, Vector2(CARD_SIZE, CARD_SIZE))
	var filled := slot_card != null or playing_deck != null
	var fill   := Color(0.015, 0.647, 0.898, 0.12) if filled else Color(0.5, 0.6, 0.5, 0.15)
	var border := Color(0.015, 0.647, 0.898, 0.9)  if filled else Color(0.4, 0.5, 0.4, 0.7)
	draw_rect(slot_rect, fill)
	draw_rect(slot_rect, border, false, 2.0)
	if not filled:
		var cx := PLAYER_SLOT_POS.x + CARD_SIZE / 2.0
		var cy := PLAYER_SLOT_POS.y + CARD_SIZE / 2.0
		draw_line(Vector2(cx - 22, cy), Vector2(cx + 22, cy), border, 2.0)
		draw_line(Vector2(cx, cy - 22), Vector2(cx, cy + 22), border, 2.0)

	if playing_deck != null:
		var ph := Rect2(playing_deck.home_pos, Vector2(CARD_SIZE, CARD_SIZE))
		draw_rect(ph, Color(0, 0, 0, 0.04))
		draw_rect(ph, Color(0.4, 0.5, 0.4, 0.4), false, 1.5)


# ── Input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_escape()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		var mode := DisplayServer.window_get_mode()
		print("F11 pressed, current mode: ", mode)
		if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
				or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_size(Vector2i(1600, 900))
			var screen_size : Vector2i = DisplayServer.screen_get_size()
			DisplayServer.window_set_position(
				Vector2i((screen_size.x - 1600) / 2, (screen_size.y - 900) / 2)
			)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		print("after change, mode: ", DisplayServer.window_get_mode())
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventMouseMotion:
		_on_motion(event.position)


func _update_hover(pos: Vector2) -> void:
	if playing_deck == null:
		hover_card = null
		return

	# Sticky: keep current hover while mouse is over its shifted rect OR its
	# original queue strip. Prevents the card from sliding back the moment the
	# cursor follows it left, and prevents oscillation when the shift exposes
	# whatever card was beneath.
	if hover_card != null and hover_card.deck == playing_deck \
			and hover_card != playing_deck.cards[playing_index]:
		if _card_rect(hover_card).has_point(pos):
			return
		if _queue_strip_rect(hover_card).has_point(pos):
			return

	var n : int = playing_deck.cards.size()
	for q in range(1, n):
		var card = playing_deck.cards[(playing_index + q) % n]
		if _queue_strip_rect(card).has_point(pos):
			hover_card = card
			return
	hover_card = null


func _queue_strip_rect(card) -> Rect2:
	# The 50px sliver at the bottom of each stacked queue card — the only part
	# actually visible in the stack.
	var n : int = playing_deck.cards.size()
	var idx : int = playing_deck.cards.find(card)
	var q : int = (idx - playing_index + n) % n
	return Rect2(
		PLAYER_SLOT_POS.x,
		PLAYER_SLOT_POS.y + q * PLAYER_QUEUE_GAP + (CARD_SIZE - PLAYER_QUEUE_GAP),
		CARD_SIZE,
		PLAYER_QUEUE_GAP,
	)


func _on_escape() -> void:
	if fanned_deck != null:
		fanned_deck = null
	elif playing_deck != null:
		_stop_deck()
	elif slot_card != null:
		slot_card = null
		_audio_player.stop()


func _on_press(pos: Vector2) -> void:
	var sorted := all_cards.duplicate()
	sorted.sort_custom(func(a, b): return a.z_index > b.z_index)

	for card in sorted:
		if _card_rect(card).has_point(pos):
			_press_card  = card
			_press_pos   = pos
			_drag_active = false
			return

	_press_card = null
	if fanned_deck != null:
		fanned_deck = null


func _on_motion(pos: Vector2) -> void:
	if _press_card == null or _drag_active:
		return
	if pos.distance_to(_press_pos) < CLICK_THRESHOLD:
		return

	var card = _press_card

	# Queued (non-current) cards aren't draggable — cancel the gesture.
	if playing_deck != null and card.deck == playing_deck:
		var idx : int = playing_deck.cards.find(card)
		if idx != playing_index:
			_press_card = null
			return

	_drag_active  = true
	card.dragging = true

	if card == slot_card:
		slot_card = null
		_audio_player.stop()
	elif playing_deck != null and card.deck == playing_deck:
		_stop_deck()


func _on_release(pos: Vector2) -> void:
	if _press_card == null:
		return
	var card = _press_card
	_press_card = null
	var was_drag := _drag_active
	_drag_active = false

	_play_sound(1.0)

	if was_drag:
		card.dragging = false
		_handle_drop(card, pos)
	else:
		_handle_click(card)


func _handle_click(card) -> void:
	# Player slot → toggle pause.
	if card == slot_card:
		_toggle_pause()
		return

	# Playing deck: tap current → pause; tap queued → jump (rotate earlier cards behind).
	if playing_deck != null and card.deck == playing_deck:
		var idx : int = playing_deck.cards.find(card)
		if idx == playing_index:
			_toggle_pause()
		else:
			playing_index = idx
			_snap_descending(card)
			_play_current()
		return

	var now       : float = Time.get_ticks_msec() / 1000.0
	var is_double : bool  = (now - card.last_click_time) < DOUBLE_CLICK_TIME
	card.last_click_time = 0.0 if is_double else now

	var deck = card.deck

	if fanned_deck != null and deck == fanned_deck:
		if is_double:
			_play_deck(deck, deck.cards.find(card))
		else:
			_play_single(card)
		return

	if fanned_deck == null and deck.cards[0] == card:
		if is_double:
			_play_deck(deck, 0)
		else:
			fanned_deck = deck


func _toggle_pause() -> void:
	if _audio_player.stream != null:
		_audio_player.stream_paused = not _audio_player.stream_paused


func _handle_drop(card, pos: Vector2) -> void:
	if _slot_drop_rect().has_point(pos):
		var deck = card.deck
		if fanned_deck != null and deck == fanned_deck:
			_play_single(card)
		else:
			_play_deck(deck, deck.cards.find(card))


func _card_rect(card) -> Rect2:
	return Rect2(card.position, Vector2(CARD_SIZE, CARD_SIZE))


func _slot_drop_rect() -> Rect2:
	return Rect2(
		PLAYER_SLOT_POS - Vector2(SLOT_DROP_MARGIN, SLOT_DROP_MARGIN),
		Vector2(CARD_SIZE, CARD_SIZE) + Vector2(SLOT_DROP_MARGIN, SLOT_DROP_MARGIN) * 2.0
	)


# ── Playback ──────────────────────────────────────────────────────────────────

func _play_single(card) -> void:
	if playing_deck != null:
		_stop_deck()
	slot_card = card
	var stream = load(card.song_path) as AudioStream
	if stream:
		_audio_player.stream = stream
		_audio_player.stream_paused = false
		_audio_player.play()


func _play_deck(deck, start_index: int) -> void:
	slot_card    = null
	fanned_deck  = null
	playing_deck = deck
	playing_index = start_index
	_play_current()


func _play_current() -> void:
	if playing_deck == null:
		return
	var card = playing_deck.cards[playing_index]
	var stream = load(card.song_path) as AudioStream
	if stream:
		_audio_player.stream = stream
		_audio_player.stream_paused = false
		_audio_player.play()
	else:
		_advance()


func _on_song_finished() -> void:
	if playing_deck != null:
		_advance()


func _advance() -> void:
	if playing_deck == null:
		return
	playing_index = (playing_index + 1) % playing_deck.cards.size()
	_snap_descending(playing_deck.cards[playing_index])
	_play_current()


func _snap_descending(except_card) -> void:
	# Cards rotating to a lower queue position (target.y > current.y) have a
	# lower target z, so animating them through the stack draws them behind the
	# others. Snap them straight to their new spot; let upward movers animate.
	if playing_deck == null:
		return
	for c in playing_deck.cards:
		if c == except_card:
			continue
		var t : Vector2 = _player_queue_pos(c)
		if t.y > c.position.y + 1.0:
			c.position   = t
			c.target_pos = t
			c.velocity   = Vector2.ZERO


func _stop_deck() -> void:
	playing_deck = null
	playing_index = 0
	_audio_player.stop()


func _play_sound(pitch: float) -> void:
	var p := AudioStreamPlayer.new()
	add_child(p)
	p.stream = card_sound
	p.pitch_scale = pitch
	p.play()
	p.finished.connect(p.queue_free)
