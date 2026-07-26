extends Node2D

const CARD_SIZE          : float = 240.0
const CLICK_THRESHOLD    : float = 8.0

# Main screen grid
const GRID_COLS          : int    = 4
const GRID_START         := Vector2(80, 80)
const GRID_PITCH         := Vector2(320, 320)

# Grid scrolling. The grid shows VISIBLE_ROWS rows at a time; scrolling shifts by
# whole rows — the exiting row swishes off one edge while the entering row rises
# in from the other. A shift fires once enough wheel input accumulates, and the
# accumulator decays so stale half-notches don't trigger a surprise scroll later.
const VISIBLE_ROWS         : int   = 3
const SCROLL_TICKS_PER_ROW : float = 1.5   # wheel notches needed per row shift
const SCROLL_DECAY         : float = 1.0   # accumulated notches that fade per second

# Fan-out layout
const FAN_SPREAD_MAX     : float = 1400.0
const FAN_CENTER_Y       : float = 540.0
const FAN_CARD_PITCH     : float = 260.0

# Player tab (right side)
const PLAYER_SLOT_POS    := Vector2(1620, 80)
const PLAYER_QUEUE_GAP   : float = 50.0

# Long-queue handling, two mechanisms that compose:
# 1) the sliver gap compresses (down to QUEUE_GAP_MIN) so the queue fits above
#    the progress bar; 2) if even that can't fit everything, the queue becomes
#    scrollable — wheel over the queue column shifts it, same feel as the grid.
const QUEUE_GAP_MIN      : float = 16.0
const QUEUE_BOTTOM_PAD   : float = 90.0   # queue keeps clear of the bar AND its
										  # title/timer text row (even when the
										  # hover fisheye nudges cards down 18px)

# Hover fisheye: cards after the hovered one nudge down to open a gap around
# the sliver the popped card vacated.
const HOVER_NUDGE        : float = 18.0

# Generous drop target for the slot
const SLOT_DROP_MARGIN   : float = 80.0

# Slot card hitbox split: inside this circle (from the card centre) = pick it up
# to move it; outside it but still on the card = grab to spin it.
const SLOT_INNER_RADIUS  : float = 70.0

# Retract offset when decks slide off-screen
const RETRACT_OFFSET_X   : float = 2400.0

# Hover-pop offset for queued cards
const HOVER_OFFSET       := Vector2(-260.0, 0.0)

# Progress bar — a full-width strip across the very bottom of the app. Always
# shows the CURRENT track's timeline; a track with chapters (a YouTube full-album
# video is one file with chapter splits) draws those splits as segments.
const BOTTOM_BAND        : float = 0   # dark scrim height behind the bar
const BAR_MARGIN_X       : float = 48.0    # left/right inset of the bar itself
const BAR_BOTTOM_OFFSET  : float = 34.0    # bar centre, measured up from the bottom
const BAR_HEIGHT         : float = 6.0     # bar thickness
const KNOB_RADIUS        : float = 8.0     # draggable playhead knob
const CHAPTER_GAP        : float = 4.0     # gap drawn between chapter segments
const BAR_HIT_HEIGHT     : float = 30.0    # click/scrub grab band around the bar
const TRACK_COLOR        := Color(1, 1, 1, 0.11)              # unplayed portion
const FILL_COLOR         := Color(0.001, 0.103, 0.146, 0.3)      # played portion (cyan)

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
var _slot_fx_card         = null    # card currently showing the 3D slot effect
var _rotating     : bool   = false  # spinning the slot card via its outer ring?
var _press_region : String = ""     # "inner"/"outer": where the slot card was grabbed
var _last_rot_x   : float  = 0.0    # mouse x last frame, used to measure spin delta

var _press_card           = null
var _press_pos  : Vector2 = Vector2.ZERO
var _drag_active : bool   = false

# Progress-bar scrubbing. While _scrubbing, the playhead follows the mouse and the
# bar shows _scrub_time; the actual audio seek happens once, on release.
var _scrubbing  : bool  = false
var _scrub_time : float = 0.0

# Grid scroll state: which row of the deck grid is at the top of the screen.
var scroll_row    : int   = 0
var _scroll_accum : float = 0.0   # signed wheel input building toward a row shift

# Queue scroll state: how many upcoming cards are tucked away above the window.
# Only ever non-zero when the queue overflows even at QUEUE_GAP_MIN.
var queue_scroll  : int   = 0

var _audio_player : AudioStreamPlayer
var sound_queue   : Array = []

# Custom background wallpaper. background_tex is null until you pick one (press B),
# in which case _draw() paints it instead of the plain colour. The chosen path is
# remembered in user://settings.cfg so it comes back next time you open the app.
const SETTINGS_PATH := "user://settings.cfg"
const BACKGROUND_DIM := 0.4   # darkening over a wallpaper, 0 = none, 1 = solid black
var background_tex : Texture2D = null
var _bg_dialog     : FileDialog

# Idle/redraw control. We only repaint the background _draw when something it
# actually shows changes, and we freeze the slot spin/bob while the window is in
# the background — so the GPU goes idle instead of redrawing nothing 15x a second.
var _focused           := true
var _last_filled       := false
var _last_playing_deck = null
var _last_screen       := Vector2.ZERO


func _ready() -> void:
	card_scene    = preload("res://scenes/card.tscn")
	card_sound    = preload("res://assets/card.ogg")
	default_cover = preload("res://assets/card.png")

	_audio_player = AudioStreamPlayer.new()
	_audio_player.finished.connect(_on_song_finished)
	add_child(_audio_player)

	_build_decks()
	_setup_background_dialog()
	_load_background()

	Engine.max_fps = 120


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Engine.max_fps = 15
		_focused = false
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		Engine.max_fps = 120
		_focused = true
		queue_redraw()   # repaint once on return in case anything changed


# ── Scan & build ──────────────────────────────────────────────────────────────

func _build_decks() -> void:
	var albums = _scan_music()
	for i in albums.size():
		var info      = albums[i]
		var album_dir = "res://assets/music/" + info.name + "/"
		var cover     = _load_cover(album_dir)
		var meta      = _load_meta(album_dir)
		var chapters_map : Dictionary = meta.get("chapters", {})

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
			card.chapters = chapters_map.get(song.file, [])
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

	# Strip legacy album-prefix patterns like "<noise> (Track NN) - ".
	var track_re := RegEx.new()
	track_re.compile("^.*\\(Track\\s*\\d+\\)\\s*-\\s*")
	var track_m := track_re.search(base)
	if track_m:
		base = base.substr(track_m.get_end())

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
		elif hover_card != null and hover_card.deck == playing_deck \
				and _queue_offset(card) > _queue_offset(hover_card):
			# Fisheye: cards after the hovered one nudge down, opening a gap
			# around the sliver the popped card vacated.
			p.y += HOVER_NUDGE
		return p

	if fanned_deck != null and deck == fanned_deck:
		return _fan_pos(card)

	if fanned_deck != null:
		var dir_sign := 1.0 if deck.home_pos.x >= fanned_deck.home_pos.x else -1.0
		return _scrolled_home(deck) + Vector2(dir_sign * RETRACT_OFFSET_X, 0)

	# Home stack: every card sits flush at the same spot, so the deck reads as one
	# clean card. (Z-order in _compute_z still keeps the top card drawn on top.)
	return _scrolled_home(deck)


# A deck's on-screen home position given the current scroll. Rows inside the
# visible window sit on the grid; rows outside it park just off-screen (above or
# below), so scrolling animates the exiting row off one edge while the entering
# row swishes in from the other. Parking below also keeps overflow rows from
# peeking over the progress bar.
func _scrolled_home(deck) -> Vector2:
	var r  : int = roundi((deck.home_pos.y - GRID_START.y) / GRID_PITCH.y)
	var rd : int = r - scroll_row
	var y  : float
	if rd < 0:
		y = GRID_START.y - GRID_PITCH.y                  # just above the screen
	elif rd >= VISIBLE_ROWS:
		y = get_viewport_rect().size.y + 40.0            # just below the screen
	else:
		y = GRID_START.y + rd * GRID_PITCH.y
	return Vector2(deck.home_pos.x, y)


func _fan_pos(card) -> Vector2:
	var deck = card.deck
	var idx  = deck.cards.find(card)
	var n    = deck.cards.size()
	var effective_width : float = min(FAN_SPREAD_MAX, n * FAN_CARD_PITCH)
	var spacing : float = 0.0 if n <= 1 else (effective_width - CARD_SIZE) / float(n - 1)
	var start_x : float = (1920.0 - effective_width) / 2.0
	return Vector2(start_x + idx * spacing, FAN_CENTER_Y - CARD_SIZE / 2.0)


# ── Queue geometry ────────────────────────────────────────────────────────────

# 0 = current card, 1.. = position down the upcoming stack. playing_deck must
# be non-null (every caller guards).
func _queue_offset(card) -> int:
	var n : int = playing_deck.cards.size()
	var idx : int = playing_deck.cards.find(card)
	return (idx - playing_index + n) % n


func _queue_bottom_limit() -> float:
	return get_viewport_rect().size.y - QUEUE_BOTTOM_PAD


# The sliver gap, compressed so the whole queue fits above the progress bar,
# but never thinner than QUEUE_GAP_MIN — past that the queue scrolls instead.
func _queue_gap() -> float:
	if playing_deck == null or playing_deck.cards.size() <= 1:
		return PLAYER_QUEUE_GAP
	var avail : float = _queue_bottom_limit() - PLAYER_SLOT_POS.y - CARD_SIZE
	return clampf(avail / float(playing_deck.cards.size() - 1), QUEUE_GAP_MIN, PLAYER_QUEUE_GAP)


# How many queued cards (q >= 1) the on-screen window holds.
func _queue_visible_count() -> int:
	if playing_deck == null:
		return 0
	var n : int = playing_deck.cards.size()
	if _queue_gap() > QUEUE_GAP_MIN:
		return n - 1        # compression alone fits the whole queue
	var avail : float = _queue_bottom_limit() - PLAYER_SLOT_POS.y - CARD_SIZE
	return maxi(int(avail / QUEUE_GAP_MIN), 0)


func _queue_max_scroll() -> int:
	if playing_deck == null:
		return 0
	return maxi(playing_deck.cards.size() - 1 - _queue_visible_count(), 0)


func _player_queue_pos(card) -> Vector2:
	if playing_deck == null:
		return PLAYER_SLOT_POS
	var q : int = _queue_offset(card)
	if q == 0:
		return PLAYER_SLOT_POS
	var qd : int = q - queue_scroll
	if qd < 1:
		# Scrolled past: parked just above the screen, up the queue column.
		return Vector2(PLAYER_SLOT_POS.x, -CARD_SIZE - 40.0)
	if qd > _queue_visible_count():
		# Not yet in the window: parked just below the screen.
		return Vector2(PLAYER_SLOT_POS.x, get_viewport_rect().size.y + 40.0)
	return PLAYER_SLOT_POS + Vector2(0, qd * _queue_gap())


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


# Whether a card should actually be drawn. In a resting home stack only the top
# card is visible — the rest sit exactly behind it, so rendering them just stacks
# their anti-aliased rounded corners into a faint squared-off halo. Hiding them
# keeps the corners clean (and saves drawing cards nobody can see).
func _card_visible(card) -> bool:
	if card.dragging or card == slot_card or card == hover_card:
		return true
	var deck = card.deck
	if playing_deck != null and deck == playing_deck:
		return true
	if fanned_deck != null and deck == fanned_deck:
		return true
	if card != _home_top(deck):
		return false
	# Cull home stacks once they're (all but) fully off-screen — rows scrolled out
	# of the grid window, or decks retracted for a fan. The slight shrink matters:
	# the momentum easing only ever approaches the parked spot asymptotically, so
	# without it a hair-thin sliver would keep hugging the screen edge forever.
	var screen := Rect2(Vector2.ZERO, get_viewport_rect().size)
	return _card_rect(card).grow(-2.0).intersects(screen)


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
	if fanned_deck == null and card == _home_top(deck):
		# Long wrapped titles overflow past the card's bottom edge, so a parked
		# off-screen row could still poke text into view — show home labels only
		# while their row is inside the scroll window.
		return _row_in_view(deck)
	return false


func _row_in_view(deck) -> bool:
	var r : int = roundi((deck.home_pos.y - GRID_START.y) / GRID_PITCH.y)
	return r >= scroll_row and r < scroll_row + VISIBLE_ROWS


func _label_text(card) -> String:
	# Top of an unfanned, unplayed home stack shows album name; otherwise song title.
	var deck = card.deck
	if not card.dragging and card != slot_card \
			and (playing_deck == null or deck != playing_deck) \
			and (fanned_deck == null or deck != fanned_deck) \
			and card == _home_top(deck):
		return deck.name
	return card.song_title


# ── Per-frame ─────────────────────────────────────────────────────────────────

func _process(dt: float) -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	_update_hover(mouse_pos)

	# Let partial scroll input fade away so an old half-notch doesn't combine with
	# a fresh one minutes later into an unexpected row shift.
	_scroll_accum = move_toward(_scroll_accum, 0.0, SCROLL_DECAY * dt)

	for card in all_cards:
		if card.dragging:
			card.target_pos = mouse_pos - Vector2(CARD_SIZE, CARD_SIZE) / 2.0
		else:
			card.target_pos = _compute_target(card)
		card.move(dt)
		card.z_index = _compute_z(card)
		card.visible = _card_visible(card)
		var vis := _label_visible(card)
		card.set_label_shown(vis)
		if vis:
			card.get_node("TitleLabel").text = _label_text(card)

	_update_slot_fx(dt)

	var i := 0
	while i < sound_queue.size():
		sound_queue[i]["delay"] -= dt
		if sound_queue[i]["delay"] <= 0.0:
			_play_sound(sound_queue[i]["pitch"])
			sound_queue.remove_at(i)
		else:
			i += 1

	_refresh_background_if_changed()

	# Keep the progress bar live while a song actually plays (or is being scrubbed)
	# and the window is focused. Paused/stopped or in the background → no repaint,
	# so the idle optimisation still holds when nobody's watching.
	if _focused and _audio_player.stream != null \
			and (_scrubbing or not _audio_player.stream_paused):
		queue_redraw()


# Repaint the background _draw only when one of the things it actually shows has
# changed: whether the slot is filled, which deck is playing, or the canvas size
# (e.g. resize / fullscreen). The cards repaint themselves as they move, so we no
# longer redraw every frame — when nothing changes, the GPU has nothing to do.
func _refresh_background_if_changed() -> void:
	var filled := slot_card != null or playing_deck != null
	var screen : Vector2 = get_viewport_rect().size
	if filled != _last_filled \
			or playing_deck != _last_playing_deck \
			or screen != _last_screen:
		_last_filled       = filled
		_last_playing_deck = playing_deck
		_last_screen       = screen
		queue_redraw()


# ── Player-slot 3D effect ─────────────────────────────────────────────────────

# Which card is "in the slot" right now? Either a single song you dropped there
# (slot_card), or, when a whole deck is playing, the current track at the top of
# the queue. Returns null if the slot is empty.
func _slot_occupant():
	if slot_card != null:
		return slot_card
	if playing_deck != null:
		return playing_deck.cards[playing_index]
	return null

# Hands the 3D tilt effect to whichever card should have it, and takes it away
# from any card that shouldn't. Runs once per frame from _process.
func _update_slot_fx(dt: float) -> void:
	# In the background, freeze the effect entirely. Nothing can change the slot
	# occupant without focus (that needs input), so we just stop advancing the
	# spin/bob — which stops the slot card requesting a redraw every frame.
	if not _focused:
		return

	var want = _slot_occupant()

	# Keep the effect on a card while you're physically dragging it. (Grabbing the
	# slot card clears slot_card immediately, so without this the effect would
	# vanish the instant you picked it up — but dragging it is exactly when we
	# most want the lean.)
	if _slot_fx_card != null and _slot_fx_card.dragging:
		want = _slot_fx_card

	# Hand-off: only touch cards when the owner actually changes.
	if want != _slot_fx_card:
		if _slot_fx_card != null:
			_slot_fx_card.set_slot_active(false)
		_slot_fx_card = want
		if _slot_fx_card != null:
			_slot_fx_card.set_slot_active(true)

	if _slot_fx_card == null:
		return

	# While the outer ring is held, measure how far the mouse moved horizontally
	# this frame and pass it on so the card turns to follow.
	var dx := 0.0
	if _rotating:
		var mx : float = get_viewport().get_mouse_position().x
		dx = mx - _last_rot_x
		_last_rot_x = mx

	# Is a song actually playing right now? (A loaded stream that isn't paused.)
	# The card spins at full idle speed when playing, slower when paused.
	var playing : bool = _audio_player.stream != null and not _audio_player.stream_paused
	_slot_fx_card.update_slot_visual(dt, _rotating, dx, playing)


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	# Use the real visible canvas size, not a hardcoded 1920x1080. With the
	# keep_height stretch the height stays 1080 but the width grows to match the
	# monitor, so this makes the wallpaper/background cover the whole screen.
	var screen : Vector2 = get_viewport_rect().size
	if background_tex != null:
		# "Cover" fit: scale the image so it fills the whole screen, then sample a
		# centred region the shape of the screen. This fills edge-to-edge with no
		# stretching — the overflow on the long side is simply cropped off.
		var ts : Vector2 = background_tex.get_size()
		var scale : float = maxf(screen.x / ts.x, screen.y / ts.y)
		var src_size : Vector2 = screen / scale
		var src_pos  : Vector2 = (ts - src_size) / 2.0
		draw_texture_rect_region(
			background_tex,
			Rect2(Vector2.ZERO, screen),
			Rect2(src_pos, src_size)
		)
		# Dim veil over the wallpaper so the cards stand out against busy images.
		draw_rect(Rect2(Vector2.ZERO, screen), Color(0, 0, 0, BACKGROUND_DIM))
	else:
		draw_rect(Rect2(Vector2.ZERO, screen), Color(0.88, 0.92, 0.88, 1.0))

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
		var ph := Rect2(_scrolled_home(playing_deck), Vector2(CARD_SIZE, CARD_SIZE))
		draw_rect(ph, Color(0, 0, 0, 0.04))
		draw_rect(ph, Color(0.4, 0.5, 0.4, 0.4), false, 1.5)

	_draw_progress_bar()


# ── Progress bar ──────────────────────────────────────────────────────────────

func _draw_progress_bar() -> void:
	var card = _slot_occupant()
	if card == null or _audio_player.stream == null:
		return
	var dur : float = _audio_player.stream.get_length()
	if dur <= 0.0:
		return
	var pos : float = _display_pos()

	var screen : Vector2 = get_viewport_rect().size
	var yc : float = screen.y - BAR_BOTTOM_OFFSET
	var x0 : float = BAR_MARGIN_X
	var x1 : float = screen.x - BAR_MARGIN_X
	var w  : float = x1 - x0

	# Dark scrim across the bottom so bar + text stay legible over any wallpaper.
	draw_rect(Rect2(0, screen.y - BOTTOM_BAND, screen.x, BOTTOM_BAND), Color(0, 0, 0, 0.32))

	# One or more segments: a plain track is a single 0..dur segment; a chaptered
	# track is one segment per chapter with a small gap between them.
	var segs := _current_segments(card, dur)
	var multi := segs.size() > 1
	for i in segs.size():
		var seg = segs[i]
		var xa : float = x0 + (seg.start / dur) * w
		var xb : float = x0 + (seg.end   / dur) * w
		if multi:
			if i > 0:            xa += CHAPTER_GAP * 0.5
			if i < segs.size()-1: xb -= CHAPTER_GAP * 0.5
		_draw_bar_piece(xa, xb, yc, TRACK_COLOR)
		var frac : float = clampf((pos - seg.start) / maxf(seg.end - seg.start, 0.001), 0.0, 1.0)
		if frac > 0.0:
			_draw_bar_piece(xa, xa + (xb - xa) * frac, yc, FILL_COLOR)

	# Playhead knob on the true (ungapped) timeline.
	var px : float = x0 + clampf(pos / dur, 0.0, 1.0) * w
	draw_circle(Vector2(px, yc), KNOB_RADIUS, Color.WHITE)

	# Current chapter/track title (left) and elapsed / total time (right).
	var font := ThemeDB.fallback_font
	var ty : float = yc - 20.0
	draw_string(font, Vector2(x0, ty), _current_title(card, pos, dur),
		HORIZONTAL_ALIGNMENT_LEFT, w, 18, Color(1, 1, 1, 0.92))
	draw_string(font, Vector2(x0, ty), _fmt_time(pos) + " / " + _fmt_time(dur),
		HORIZONTAL_ALIGNMENT_RIGHT, w, 16, Color(1, 1, 1, 0.7))


# A rounded (capsule-ended) horizontal bar piece from x=a to x=b, centred on yc.
func _draw_bar_piece(a: float, b: float, yc: float, color: Color) -> void:
	if b <= a:
		return
	var r : float = BAR_HEIGHT * 0.5
	draw_rect(Rect2(a, yc - r, b - a, BAR_HEIGHT), color)
	draw_circle(Vector2(a, yc), r, color)
	draw_circle(Vector2(b, yc), r, color)


# Segments in seconds for the current track. No chapters → a single full-length
# segment. A trailing chapter with a null end falls back to the song duration.
func _current_segments(card, dur: float) -> Array:
	if card.chapters.is_empty():
		return [{ "start": 0.0, "end": dur }]
	var out := []
	for ch in card.chapters:
		var e = ch.get("end")
		out.append({
			"start": float(ch.get("start", 0.0)),
			"end":   float(e) if e != null else dur,
		})
	return out


func _current_title(card, pos: float, dur: float) -> String:
	if card.chapters.is_empty():
		return card.song_title
	for ch in card.chapters:
		var e = ch.get("end")
		var ef : float = float(e) if e != null else dur
		if pos >= float(ch.get("start", 0.0)) and pos < ef:
			return String(ch.get("title", card.song_title))
	return card.song_title


func _display_pos() -> float:
	if _scrubbing:
		return _scrub_time
	return _audio_player.get_playback_position()


func _fmt_time(t: float) -> String:
	var s := int(t)
	return "%d:%02d" % [s / 60, s % 60]


# The full-width band you can click/drag to seek, a bit taller than the bar line.
func _bar_hit_rect() -> Rect2:
	var screen : Vector2 = get_viewport_rect().size
	var yc : float = screen.y - BAR_BOTTOM_OFFSET
	return Rect2(
		BAR_MARGIN_X - KNOB_RADIUS,
		yc - BAR_HIT_HEIGHT * 0.5,
		(screen.x - 2 * BAR_MARGIN_X) + KNOB_RADIUS * 2,
		BAR_HIT_HEIGHT
	)


func _seek_time_from_x(x: float) -> float:
	var screen : Vector2 = get_viewport_rect().size
	var x0 : float = BAR_MARGIN_X
	var w  : float = (screen.x - BAR_MARGIN_X) - x0
	var dur : float = _audio_player.stream.get_length()
	return clampf((x - x0) / w, 0.0, 1.0) * dur


# ── Background wallpaper ──────────────────────────────────────────────────────

# Create the file picker once, up front. Pressing B later just pops it open.
func _setup_background_dialog() -> void:
	_bg_dialog = FileDialog.new()
	_bg_dialog.access           = FileDialog.ACCESS_FILESYSTEM   # browse the whole disk
	_bg_dialog.file_mode        = FileDialog.FILE_MODE_OPEN_FILE # pick one existing file
	_bg_dialog.use_native_dialog = true                         # the real Windows picker
	_bg_dialog.filters = PackedStringArray([
		"*.png, *.jpg, *.jpeg, *.webp, *.bmp ; Images"
	])
	_bg_dialog.file_selected.connect(_on_background_chosen)
	add_child(_bg_dialog)


# Runs when you actually pick a file in the dialog. Loads it, shows it, saves it.
func _on_background_chosen(path: String) -> void:
	if _apply_background(path):
		_save_background(path)


# Load an image from anywhere on disk and turn it into our background texture.
# Returns true on success so callers know whether to remember the path.
func _apply_background(path: String) -> bool:
	var img := Image.new()
	if img.load(path) != OK:
		return false
	background_tex = ImageTexture.create_from_image(img)
	queue_redraw()   # ask Godot to repaint so the new wallpaper shows immediately
	return true


func _save_background(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)            # keep any other settings already in the file
	cfg.set_value("background", "path", path)
	cfg.save(SETTINGS_PATH)


func _load_background() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var path : String = cfg.get_value("background", "path", "")
	if path != "" and FileAccess.file_exists(path):
		_apply_background(path)


# ── Input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_escape()
		return
	# B opens the wallpaper picker. not event.echo ignores key-repeat while held.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_B:
		_bg_dialog.popup_centered(Vector2i(1000, 700))
		return
	# Space toggles play/pause, same as clicking the slot card. _toggle_pause
	# already does nothing when no song is loaded, so this is safe any time.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_SPACE:
		_toggle_pause()
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
	if event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_WHEEL_DOWN
				or event.button_index == MOUSE_BUTTON_WHEEL_UP):
		var dir := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1.0
		_on_scroll(dir, event.factor if event.factor > 0.0 else 1.0)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventMouseMotion:
		_on_motion(event.position)


# Accumulate wheel input; once it crosses the threshold, shift whichever thing
# the mouse is pointing at — the queue column or the deck grid — by one step.
# A direction flip clears what's built up, so wiggling never fights itself.
func _on_scroll(dir: float, amount: float) -> void:
	if fanned_deck != null:
		return
	if _scroll_accum != 0.0 and signf(_scroll_accum) != signf(dir):
		_scroll_accum = 0.0
	_scroll_accum += dir * amount
	if absf(_scroll_accum) >= SCROLL_TICKS_PER_ROW:
		var step := 1 if _scroll_accum > 0.0 else -1
		if _over_queue():
			_shift_queue(step)
		else:
			_shift_rows(step)
		_scroll_accum = 0.0


# Wheel context: only pointing at the queue stack itself scrolls the queue —
# the card-width column of visible slivers, from just below the slot card down
# to the bottom of the last visible queue card. Everywhere else, the grid.
func _over_queue() -> bool:
	if playing_deck == null:
		return false
	var vis : int = _queue_visible_count()
	if vis < 1:
		return false
	var stack := Rect2(
		PLAYER_SLOT_POS.x,
		PLAYER_SLOT_POS.y + CARD_SIZE,
		CARD_SIZE,
		vis * _queue_gap()
	)
	return stack.has_point(get_viewport().get_mouse_position())


func _shift_queue(dir: int) -> void:
	queue_scroll = clampi(queue_scroll + dir, 0, _queue_max_scroll())


func _shift_rows(dir: int) -> void:
	var rows : int = ceili(decks.size() / float(GRID_COLS))
	var new_row : int = clampi(scroll_row + dir, 0, maxi(rows - VISIBLE_ROWS, 0))
	if new_row == scroll_row:
		return
	scroll_row = new_row
	queue_redraw()   # the playing-deck home highlight moves with the grid


func _update_hover(pos: Vector2) -> void:
	if playing_deck == null:
		hover_card = null
		return

	# Sticky: keep current hover while mouse is anywhere in the card's hover
	# footprint — the popped-out rect, the corridor back to the queue, or its
	# original strip. Prevents the card from sliding back the moment the cursor
	# follows it left, and prevents oscillation when the shift exposes whatever
	# card was beneath.
	if hover_card != null and hover_card.deck == playing_deck \
			and hover_card != playing_deck.cards[playing_index]:
		if _hover_region_has(hover_card, pos):
			return

	var n : int = playing_deck.cards.size()
	for q in range(1, n):
		var card = playing_deck.cards[(playing_index + q) % n]
		if _queue_strip_rect(card).has_point(pos):
			hover_card = card
			return
	hover_card = null


# A queued card's full hover footprint: its current (animating) rect, its
# original visible sliver in the queue, and the full-height corridor between the
# popped-out spot and the queue column. The corridor stays left of the queue's
# x, so it never steals hover from the slivers of neighbouring queue cards.
func _hover_region_has(card, pos: Vector2) -> bool:
	if _card_rect(card).has_point(pos):
		return true
	if _queue_strip_rect(card).has_point(pos):
		return true
	var base : Vector2 = _player_queue_pos(card)
	var corridor := Rect2(base + HOVER_OFFSET, Vector2(-HOVER_OFFSET.x, CARD_SIZE))
	return corridor.has_point(pos)


func _queue_strip_rect(card) -> Rect2:
	# The visible sliver at the bottom of each stacked queue card — its height is
	# the (possibly compressed) gap. Cards outside the scroll window have no
	# strip, so they can't be hovered until scrolled in. Deliberately derived
	# from the un-nudged layout: the fisheye nudge is visual only, so hover
	# detection never chases moving targets.
	var qd : int = _queue_offset(card) - queue_scroll
	if qd < 1 or qd > _queue_visible_count():
		return Rect2()
	var gap : float = _queue_gap()
	return Rect2(
		PLAYER_SLOT_POS.x,
		PLAYER_SLOT_POS.y + qd * gap + (CARD_SIZE - gap),
		CARD_SIZE,
		gap,
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
	# Progress bar takes priority: if a song is loaded and you press on the bottom
	# strip, start scrubbing instead of hitting a card.
	if _slot_occupant() != null and _audio_player.stream != null \
			and _bar_hit_rect().has_point(pos):
		_scrubbing  = true
		_scrub_time = _seek_time_from_x(pos.x)
		_press_card = null
		return

	# A popped-out queue card owns its whole hover footprint: pressing anywhere
	# in it (popped card, corridor, or its original sliver) targets that card —
	# without this, its sliver would hit whatever card is stacked beneath, since
	# the popped card's actual rect has left the queue.
	if hover_card != null and _hover_region_has(hover_card, pos):
		_press_card   = hover_card
		_press_pos    = pos
		_drag_active  = false
		_press_region = ""
		return

	var sorted := all_cards.duplicate()
	sorted.sort_custom(func(a, b): return a.z_index > b.z_index)

	for card in sorted:
		if _card_rect(card).has_point(pos):
			_press_card   = card
			_press_pos    = pos
			_drag_active  = false
			# Only the slot card cares about inner vs outer; everything else is "".
			_press_region = _slot_region(card, pos) if card == _slot_occupant() else ""
			return

	_press_card = null
	if fanned_deck != null:
		fanned_deck = null


func _on_motion(pos: Vector2) -> void:
	if _scrubbing:
		_scrub_time = _seek_time_from_x(pos.x)
		return
	if _press_card == null or _drag_active:
		return
	if pos.distance_to(_press_pos) < CLICK_THRESHOLD:
		return

	var card = _press_card

	# Slot card grabbed by the OUTER ring → spin it in place. Don't pick it up,
	# don't clear the slot, don't stop the music — just start rotating.
	if card == _slot_occupant() and _press_region == "outer":
		_drag_active = true
		_rotating    = true
		_last_rot_x  = pos.x
		return

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
	# Finishing a scrub: commit the seek once, here — not on every drag frame, so
	# the audio jumps a single time instead of stuttering. A plain click on the bar
	# also lands here (press set _scrub_time, no motion needed).
	if _scrubbing:
		_scrubbing = false
		_scrub_time = _seek_time_from_x(pos.x)
		_audio_player.seek(_scrub_time)
		return

	# Finishing a spin: just stop steering it. The card keeps whatever spin
	# momentum it had and coasts back to the idle rotation. This is not a click,
	# so it must not toggle pause.
	if _rotating:
		_rotating    = false
		_drag_active = false
		_press_card  = null
		return

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
			queue_scroll = 0
			_snap_descending(card)
			_play_current()
		return

	var deck = card.deck

	# Fanned deck → tap a card to play it on its own.
	if fanned_deck != null and deck == fanned_deck:
		_play_single(card)
		return

	# Home stack → tap the top card to fan the deck open.
	if fanned_deck == null and card == _home_top(deck):
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


# The card actually sitting on top of a deck's home stack. Usually cards[0], but
# when the first song is playing as a single it has flown to the player slot, so
# the next card is the real top. Returns null only if every card has left home.
func _home_top(deck):
	for c in deck.cards:
		if c != slot_card:
			return c
	return null


func _slot_region(card, pos: Vector2) -> String:
	# Which zone of the slot card was grabbed: the centre circle (pick up / move)
	# or the ring around it (spin). Decided by distance from the card's centre.
	var center : Vector2 = card.position + Vector2(CARD_SIZE, CARD_SIZE) / 2.0
	return "inner" if pos.distance_to(center) <= SLOT_INNER_RADIUS else "outer"


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
	queue_scroll = 0
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
	queue_scroll = 0
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
	queue_scroll = 0
	_audio_player.stop()


func _play_sound(pitch: float) -> void:
	var p := AudioStreamPlayer.new()
	add_child(p)
	p.stream = card_sound
	p.pitch_scale = pitch
	p.play()
	p.finished.connect(p.queue_free)
