class_name SimWorld
extends RefCounted

## Speicher der Simulation: flache Arrays, eine Zelle = ein Pixel.
##
## CHUNK-BEREITSCHAFT: Die Welt ist bereits in Chunks von CHUNK x CHUNK
## organisiert und alle Iteration laeuft chunkweise. Fuer eine unendliche Welt
## muss spaeter nur das Backing (die flachen Arrays) durch eine Chunk-Map
## ersetzt werden - Simulation, Renderer und UI greifen ausschliesslich ueber
## idx() / in_bounds() / set_cell() / wake_at() zu und kennen keine festen
## Weltgrenzen ausser an dieser einen Stelle.

const CHUNK := 64
const AMBIENT := 20.0

## Bit-Flags pro Zelle
const F_STATIC := 1  ## Schwerkraft wirkt nicht, Zelle bewegt sich nie

## Bewegungs-FSM pro Zelle
enum MoveState { REST = 0, FALLING = 1, SLIDING = 2 }

var width: int
var height: int
var cx_count: int
var cy_count: int
var cell_count: int
var chunk_count: int

# --- Zell-Arrays -------------------------------------------------------------
var mat: PackedByteArray        ## Material-id
var state: PackedByteArray      ## MoveState
var flags: PackedByteArray      ## F_*
var gen: PackedByteArray        ## Generation: max. eine Bewegung pro Zelle pro Frame
## Zaehlt rein seitliche Ausweichbewegungen. Erreicht er die von der Reibung
## bestimmte Grenze, hoert die Zelle auf, sich seitlich auszubreiten - sonst
## kommt eine Fluessigkeitsoberflaeche nie zur Ruhe. Faellt die Zelle wieder
## (auch diagonal), wird er zurueckgesetzt.
var settle: PackedByteArray
var temp: PackedFloat32Array    ## Temperatur in Grad C
var grav: PackedVector2Array    ## gecachtes Gravitationsfeld

# --- Chunk-Arrays ------------------------------------------------------------
var chunk_awake: PackedByteArray       ## in diesem Frame zu simulieren
var chunk_awake_next: PackedByteArray  ## im naechsten Frame zu simulieren
var chunk_thermal: PackedByteArray     ## Temperatur weicht ab -> Waermepass noetig
var chunk_render: PackedByteArray      ## Pixel muessen neu gezeichnet werden

## Dirty-Rect je Chunk: 4 Eintraege (x0, y0, x1, y1) in Weltkoordinaten,
## einschliesslich. Ein wacher Chunk wird nur innerhalb dieses Rechtecks
## simuliert statt auf voller Flaeche - bei lokal begrenzter Aktivitaet ist das
## der Unterschied zwischen 4096 und ein paar hundert betrachteten Zellen.
## Leeres Rechteck: x0 > x1.
var chunk_rect: PackedInt32Array
var chunk_rect_next: PackedInt32Array

## Dasselbe fuer den Renderer: welcher Bereich eines Chunks muss neu gezeichnet
## werden. Getrennt vom Simulations-Rect, weil der Renderer in seinem eigenen
## Takt leert - ein Chunk kann mehrere Simulationsschritte lang Aenderungen
## sammeln, bevor gezeichnet wird.
var chunk_render_rect: PackedInt32Array

## Index -> true, fuer alle Zellen die ein Gravitationsfeld abstrahlen.
## Damit kostet ein Feld-Rebuild O(Quellen) statt O(Weltgroesse).
var grav_sources: Dictionary = {}
var gravity_dirty: bool = true

func _init(w: int, h: int) -> void:
	width = w
	height = h
	cell_count = w * h
	cx_count = int(ceil(float(w) / float(CHUNK)))
	cy_count = int(ceil(float(h) / float(CHUNK)))
	chunk_count = cx_count * cy_count

	mat.resize(cell_count)
	state.resize(cell_count)
	flags.resize(cell_count)
	gen.resize(cell_count)
	settle.resize(cell_count)
	temp.resize(cell_count)
	temp.fill(AMBIENT)
	grav.resize(cell_count)
	grav.fill(Vector2(0.0, 1.0))

	chunk_awake.resize(chunk_count)
	chunk_awake.fill(1)
	chunk_awake_next.resize(chunk_count)
	chunk_thermal.resize(chunk_count)
	chunk_render.resize(chunk_count)
	chunk_render.fill(1)
	chunk_rect.resize(chunk_count * 4)
	chunk_rect_next.resize(chunk_count * 4)
	chunk_render_rect.resize(chunk_count * 4)
	for ci in range(chunk_count):
		_set_rect_full(chunk_rect, ci)
		_clear_rect(chunk_rect_next, ci)
		_set_rect_full(chunk_render_rect, ci)

func _set_rect_full(arr: PackedInt32Array, ci: int) -> void:
	var cx := ci % cx_count
	var cy := ci / cx_count
	var b := ci * 4
	arr[b] = cx * CHUNK
	arr[b + 1] = cy * CHUNK
	arr[b + 2] = mini((cx + 1) * CHUNK, width) - 1
	arr[b + 3] = mini((cy + 1) * CHUNK, height) - 1

func _clear_rect(arr: PackedInt32Array, ci: int) -> void:
	var b := ci * 4
	arr[b] = 0x7FFFFFFF
	arr[b + 1] = 0x7FFFFFFF
	arr[b + 2] = -1
	arr[b + 3] = -1

# --- Zugriff -----------------------------------------------------------------

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height

func idx(x: int, y: int) -> int:
	return y * width + x

func chunk_idx(x: int, y: int) -> int:
	return (y / CHUNK) * cx_count + (x / CHUNK)

func get_mat(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return -1
	return mat[y * width + x]

func is_static_at(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return true
	return (flags[y * width + x] & F_STATIC) != 0

## Setzt eine Zelle inklusive aller Nebenbuchhaltung (Chunks wecken,
## Gravitationsquellen registrieren). Einziger legitimer Schreibpfad von aussen.
## `temperature` = USE_DEFAULT nimmt die Materialvorgabe (default_temp). So
## bringt Lava ihre 1200 Grad und Eis seine -60 Grad selbst mit, ohne dass der
## Aufrufer davon wissen muss.
const USE_DEFAULT := -99999.0

func set_cell(x: int, y: int, material_id: int, make_static: bool, temperature: float = USE_DEFAULT) -> void:
	if not in_bounds(x, y):
		return
	var i := y * width + x
	var def := MaterialDB.get_def(material_id)
	var old := mat[i]
	if old != material_id:
		if grav_sources.has(i):
			grav_sources.erase(i)
			gravity_dirty = true
		if def.is_grav_source():
			grav_sources[i] = true
			gravity_dirty = true
	mat[i] = material_id
	flags[i] = F_STATIC if make_static else 0
	settle[i] = 0
	# Statische und unbewegliche Zellen starten direkt im Ruhezustand der
	# Bewegungs-FSM, sonst meldet das HUD dauerhaft "FALLEND" fuer den Boden.
	if make_static or not def.is_movable():
		state[i] = MoveState.REST
	else:
		state[i] = MoveState.FALLING
	temp[i] = def.default_temp if temperature == USE_DEFAULT else temperature
	wake_at(x, y)
	mark_thermal_at(x, y)
	# Zeichnen und Radieren aendern die Unterlage der Nachbarn. Ohne das bliebe
	# Material haengen, unter dem gerade weggeradiert wurde.
	revive_neighbors(x, y)

## Verschiebt die Gravitationsquellen-Registrierung mit, wenn eine Zelle wandert.
func move_grav_source(from_i: int, to_i: int) -> void:
	if grav_sources.has(from_i):
		grav_sources.erase(from_i)
		grav_sources[to_i] = true
		gravity_dirty = true

# --- Chunk-Verwaltung --------------------------------------------------------

## Weckt einen ganzen Chunk (volle Flaeche im naechsten Frame).
func wake_chunk(cx: int, cy: int) -> void:
	if cx < 0 or cy < 0 or cx >= cx_count or cy >= cy_count:
		return
	var ci := cy * cx_count + cx
	chunk_awake_next[ci] = 1
	chunk_render[ci] = 1
	var b := ci * 4
	chunk_rect_next[b] = cx * CHUNK
	chunk_rect_next[b + 1] = cy * CHUNK
	chunk_rect_next[b + 2] = mini((cx + 1) * CHUNK, width) - 1
	chunk_rect_next[b + 3] = mini((cy + 1) * CHUNK, height) - 1
	_set_rect_full(chunk_render_rect, ci)

func _wake_cell(cx: int, cy: int, x: int, y: int) -> void:
	if cx < 0 or cy < 0 or cx >= cx_count or cy >= cy_count:
		return
	var ci := cy * cx_count + cx
	chunk_awake_next[ci] = 1
	chunk_render[ci] = 1
	var b := ci * 4
	var rect := chunk_rect_next
	if x < rect[b]:
		rect[b] = x
	if y < rect[b + 1]:
		rect[b + 1] = y
	if x > rect[b + 2]:
		rect[b + 2] = x
	if y > rect[b + 3]:
		rect[b + 3] = y
	var rr := chunk_render_rect
	if x < rr[b]:
		rr[b] = x
	if y < rr[b + 1]:
		rr[b + 1] = y
	if x > rr[b + 2]:
		rr[b + 2] = x
	if y > rr[b + 3]:
		rr[b + 3] = y

## Weckt die Zelle - und den Nachbarchunk, wenn sie an dessen Rand liegt. Ohne
## das bliebe ruhender Sand jenseits einer Chunkgrenze haengen, wenn ihm die
## Stuetze weggenommen wird.
func wake_at(x: int, y: int) -> void:
	var cx := x / CHUNK
	var cy := y / CHUNK
	_wake_cell(cx, cy, x, y)
	var lx := x % CHUNK
	var ly := y % CHUNK
	if lx == 0:
		_wake_cell(cx - 1, cy, x - 1, y)
	elif lx == CHUNK - 1:
		_wake_cell(cx + 1, cy, x + 1, y)
	if ly == 0:
		_wake_cell(cx, cy - 1, x, y - 1)
	elif ly == CHUNK - 1:
		_wake_cell(cx, cy + 1, x, y + 1)

func mark_thermal_chunk(cx: int, cy: int) -> void:
	if cx < 0 or cy < 0 or cx >= cx_count or cy >= cy_count:
		return
	chunk_thermal[cy * cx_count + cx] = 1

func mark_thermal_at(x: int, y: int) -> void:
	var cx := x / CHUNK
	var cy := y / CHUNK
	mark_thermal_chunk(cx, cy)
	var lx := x % CHUNK
	var ly := y % CHUNK
	if lx == 0:
		mark_thermal_chunk(cx - 1, cy)
	elif lx == CHUNK - 1:
		mark_thermal_chunk(cx + 1, cy)
	if ly == 0:
		mark_thermal_chunk(cx, cy - 1)
	elif ly == CHUNK - 1:
		mark_thermal_chunk(cx, cy + 1)

## Uebernimmt die im letzten Frame geweckten Chunks als aktive Menge.
func begin_frame() -> void:
	var tmp := chunk_awake
	chunk_awake = chunk_awake_next
	chunk_awake_next = tmp
	chunk_awake_next.fill(0)
	var tmp_rect := chunk_rect
	chunk_rect = chunk_rect_next
	chunk_rect_next = tmp_rect
	for ci in range(chunk_count):
		_clear_rect(chunk_rect_next, ci)

func awake_chunk_count() -> int:
	var n := 0
	for i in range(chunk_count):
		if chunk_awake[i] != 0:
			n += 1
	return n

func clear() -> void:
	mat.fill(0)
	state.fill(0)
	flags.fill(0)
	gen.fill(0)
	settle.fill(0)
	temp.fill(AMBIENT)
	grav.fill(Vector2(0.0, 1.0))
	chunk_awake.fill(1)
	chunk_awake_next.fill(1)
	chunk_thermal.fill(0)
	chunk_render.fill(1)
	for ci in range(chunk_count):
		_set_rect_full(chunk_rect, ci)
		_set_rect_full(chunk_rect_next, ci)
		_set_rect_full(chunk_render_rect, ci)
	grav_sources.clear()
	gravity_dirty = true

## Vom Renderer aufgerufen, nachdem ein Chunk gezeichnet wurde.
func clear_render_rect(ci: int) -> void:
	chunk_render[ci] = 0
	_clear_rect(chunk_render_rect, ci)

## Ganzen Chunk zum Neuzeichnen vormerken (Waermetoenung, Ansichtswechsel).
func mark_render_full(ci: int) -> void:
	chunk_render[ci] = 1
	_set_rect_full(chunk_render_rect, ci)

## Holt ruhende, bewegliche Nachbarn einer Zelle aus dem Ruhezustand. Wird
## gebraucht, wenn hier ein Loch entsteht (geloescht, weggeflossen) - sonst
## bliebe darueberliegendes Material haengen, weil ruhende Zellen nicht mehr
## simuliert werden.
func revive_neighbors(x: int, y: int) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var ax := x + dx
			var ay := y + dy
			if not in_bounds(ax, ay):
				continue
			var ai := ay * width + ax
			if mat[ai] == 0:
				continue
			if (flags[ai] & F_STATIC) != 0:
				continue
			if not MaterialDB.get_def(mat[ai]).is_movable():
				continue
			state[ai] = MoveState.FALLING
			wake_at(ax, ay)

## Setzt einen ganzen Bereich zurueck in den aktiven Zustand. Noetig, wenn sich
## die Spielregeln aendern statt der Inhalt - etwa nach einem Umbau des
## Gravitationsfelds: ruhende Zellen muessen dann neu bewerten, wohin unten ist.
func revive_region(x0: int, y0: int, x1: int, y1: int) -> void:
	var ax0 := maxi(x0, 0)
	var ay0 := maxi(y0, 0)
	var ax1 := mini(x1, width - 1)
	var ay1 := mini(y1, height - 1)
	for y in range(ay0, ay1 + 1):
		var row := y * width
		for x in range(ax0, ax1 + 1):
			var i := row + x
			if mat[i] == 0:
				continue
			if (flags[i] & F_STATIC) != 0:
				continue
			state[i] = MoveState.FALLING
			settle[i] = 0
