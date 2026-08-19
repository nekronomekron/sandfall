class_name CellGrid
extends RefCounted

## Der Speicher der Simulation: flache Arrays, eine Zelle ist ein Pixel.
##
## CHUNK-BEREITSCHAFT: Die Welt ist in Chunks organisiert und alle Iteration
## laeuft chunkweise. Fuer eine unendliche Welt muss spaeter nur das Backing -
## die flachen Arrays - durch eine Chunk-Map ersetzt werden. Simulation,
## Renderer und UI greifen ausschliesslich ueber [method index_of],
## [method in_bounds], [method set_cell] und [method wake_at] zu und kennen
## keine festen Weltgrenzen ausser an dieser einen Stelle.

## Bit-Flags pro Zelle.
const FLAG_STATIC := 1  ## Schwerkraft wirkt nicht, die Zelle bewegt sich nie.

## Bewegungs-FSM pro Zelle.
enum MoveState {
	REST,     ## Liegt. Wird gar nicht mehr simuliert, bis jemand sie weckt.
	FALLING,  ## Folgt der Gravitation.
	SLIDING,  ## Rutscht diagonal ab oder breitet sich seitlich aus.
}

## Sentinel fuer [method set_cell]: nimm die Vorgabe des Materials.
const USE_MATERIAL_TEMPERATURE := -99999.0

## Ein leeres Rechteck erkennt man daran, dass die linke Kante rechts von der
## rechten liegt.
const BOUNDS_EMPTY_MIN := 0x7FFFFFFF
const BOUNDS_EMPTY_MAX := -1

## Eintraege pro Chunk in den Bounds-Arrays: links, oben, rechts, unten.
const BOUNDS_STRIDE := 4

var width: int
var height: int
var cell_count: int

var chunk_size: int
var chunks_x: int
var chunks_y: int
var chunk_count: int

var ambient_celsius: float

# --- Zell-Arrays -------------------------------------------------------------
var material_id: PackedByteArray
var move_state: PackedByteArray
var cell_flags: PackedByteArray
## Generationsstempel: hoechstens eine Bewegung pro Zelle pro Frame.
var move_generation: PackedByteArray
## Bit-gepacktes Ruhe-Gedaechtnis fuer das seitliche Ausbreiten, siehe
## [SandSimulation].
var settle_state: PackedByteArray
var celsius: PackedFloat32Array
## Gecachtes Gravitationsfeld, gebacken von [GravityField].
var gravity: PackedVector2Array

# --- Chunk-Arrays ------------------------------------------------------------
var chunk_awake: PackedByteArray        ## In diesem Frame zu simulieren.
var chunk_awake_next: PackedByteArray   ## Im naechsten Frame zu simulieren.
var chunk_needs_heat: PackedByteArray   ## Temperatur weicht ab, Waermepass noetig.
var chunk_needs_redraw: PackedByteArray ## Pixel muessen neu gezeichnet werden.

## Betroffener Bereich je Chunk, in Weltkoordinaten und einschliesslich. Ein
## wacher Chunk wird nur innerhalb dieses Rechtecks simuliert statt auf voller
## Flaeche - bei lokal begrenzter Aktivitaet ist das der Unterschied zwischen
## ein paar tausend und ein paar hundert betrachteten Zellen.
var sim_bounds: PackedInt32Array
var sim_bounds_next: PackedInt32Array

## Dasselbe fuer den Renderer. Getrennt vom Simulations-Rechteck, weil der
## Renderer in seinem eigenen Takt leert: ein Chunk kann mehrere
## Simulationsschritte lang Aenderungen sammeln, bevor gezeichnet wird.
var redraw_bounds: PackedInt32Array

## Zellindex -> true fuer alle Zellen, die ein Gravitationsfeld abstrahlen.
## Damit kostet ein Feld-Rebuild O(Quellen) statt O(Weltgroesse).
var gravity_sources: Dictionary = {}
var gravity_dirty: bool = true

var _lookups: MaterialLookups


func _init(size: Vector2i, chunk_edge: int, lookups: MaterialLookups, ambient: float) -> void:
	width = size.x
	height = size.y
	cell_count = width * height
	chunk_size = chunk_edge
	chunks_x = ceili(float(width) / float(chunk_size))
	chunks_y = ceili(float(height) / float(chunk_size))
	chunk_count = chunks_x * chunks_y
	ambient_celsius = ambient
	_lookups = lookups

	material_id.resize(cell_count)
	move_state.resize(cell_count)
	cell_flags.resize(cell_count)
	move_generation.resize(cell_count)
	settle_state.resize(cell_count)
	celsius.resize(cell_count)
	gravity.resize(cell_count)

	chunk_awake.resize(chunk_count)
	chunk_awake_next.resize(chunk_count)
	chunk_needs_heat.resize(chunk_count)
	chunk_needs_redraw.resize(chunk_count)
	sim_bounds.resize(chunk_count * BOUNDS_STRIDE)
	sim_bounds_next.resize(chunk_count * BOUNDS_STRIDE)
	redraw_bounds.resize(chunk_count * BOUNDS_STRIDE)

	clear()


## Setzt die ganze Welt auf Luft zurueck.
func clear() -> void:
	material_id.fill(MaterialLibrary.EMPTY_ID)
	move_state.fill(MoveState.REST)
	cell_flags.fill(0)
	move_generation.fill(0)
	settle_state.fill(0)
	celsius.fill(ambient_celsius)
	gravity.fill(Vector2.DOWN)

	chunk_awake.fill(1)
	chunk_awake_next.fill(1)
	chunk_needs_heat.fill(0)
	chunk_needs_redraw.fill(1)
	for chunk in chunk_count:
		_fill_bounds(sim_bounds, chunk)
		_fill_bounds(sim_bounds_next, chunk)
		_fill_bounds(redraw_bounds, chunk)

	gravity_sources.clear()
	gravity_dirty = true

# --- Zugriff -----------------------------------------------------------------

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height


func index_of(x: int, y: int) -> int:
	return y * width + x


## Material an dieser Stelle, oder -1 ausserhalb der Welt. Bequem, aber langsam:
## die Schleifenkerne indizieren [member material_id] direkt.
func material_at(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return -1
	return material_id[y * width + x]


## Setzt eine Zelle mitsamt aller Nebenbuchhaltung: Chunks wecken,
## Gravitationsquellen registrieren, Nachbarn aufruetteln. Das ist der einzige
## legitime Schreibpfad von aussen.
##
## [param temperature] auf [constant USE_MATERIAL_TEMPERATURE] lassen, um die
## Materialvorgabe zu nehmen. So bringt Lava ihre 1200 Grad und Eis seine
## -60 Grad selbst mit, ohne dass der Aufrufer davon wissen muss.
func set_cell(x: int, y: int, new_material: int, make_static: bool,
		temperature: float = USE_MATERIAL_TEMPERATURE) -> void:
	if not in_bounds(x, y):
		return
	var cell := y * width + x

	if material_id[cell] != new_material:
		if gravity_sources.has(cell):
			gravity_sources.erase(cell)
			gravity_dirty = true
		if _lookups.is_gravity_source[new_material] == 1:
			gravity_sources[cell] = true
			gravity_dirty = true

	material_id[cell] = new_material
	cell_flags[cell] = FLAG_STATIC if make_static else 0
	settle_state[cell] = 0
	# Statische und unbewegliche Zellen starten direkt im Ruhezustand, sonst
	# meldet das HUD dauerhaft "fallend" fuer den Steinboden.
	var can_move := not make_static and _lookups.movable[new_material] == 1
	move_state[cell] = MoveState.FALLING if can_move else MoveState.REST
	if temperature == USE_MATERIAL_TEMPERATURE:
		celsius[cell] = _lookups.default_celsius[new_material]
	else:
		celsius[cell] = temperature

	wake_at(x, y)
	mark_heat_at(x, y)
	# Zeichnen und Radieren aendern die Unterlage der Nachbarn. Ohne das bliebe
	# Material haengen, unter dem gerade weggeradiert wurde.
	wake_neighbours(x, y)


## Fuehrt die Registrierung einer Gravitationsquelle mit, wenn ihre Zelle wandert.
func move_gravity_source(from_cell: int, to_cell: int) -> void:
	if not gravity_sources.has(from_cell):
		return
	gravity_sources.erase(from_cell)
	gravity_sources[to_cell] = true
	gravity_dirty = true

# --- Chunk-Verwaltung --------------------------------------------------------

## Weckt einen ganzen Chunk auf voller Flaeche.
func wake_chunk(chunk_x: int, chunk_y: int) -> void:
	if chunk_x < 0 or chunk_y < 0 or chunk_x >= chunks_x or chunk_y >= chunks_y:
		return
	var chunk := chunk_y * chunks_x + chunk_x
	chunk_awake_next[chunk] = 1
	chunk_needs_redraw[chunk] = 1
	_fill_bounds(sim_bounds_next, chunk)
	_fill_bounds(redraw_bounds, chunk)


## Weckt die Zelle - und den Nachbarchunk, wenn sie an dessen Rand liegt. Ohne
## das bliebe ruhender Sand jenseits einer Chunkgrenze haengen, wenn ihm die
## Stuetze weggenommen wird.
func wake_at(x: int, y: int) -> void:
	var chunk_x := x / chunk_size
	var chunk_y := y / chunk_size
	_wake_cell(chunk_x, chunk_y, x, y)
	var local_x := x % chunk_size
	var local_y := y % chunk_size
	if local_x == 0:
		_wake_cell(chunk_x - 1, chunk_y, x - 1, y)
	elif local_x == chunk_size - 1:
		_wake_cell(chunk_x + 1, chunk_y, x + 1, y)
	if local_y == 0:
		_wake_cell(chunk_x, chunk_y - 1, x, y - 1)
	elif local_y == chunk_size - 1:
		_wake_cell(chunk_x, chunk_y + 1, x, y + 1)


func mark_heat_chunk(chunk_x: int, chunk_y: int) -> void:
	if chunk_x < 0 or chunk_y < 0 or chunk_x >= chunks_x or chunk_y >= chunks_y:
		return
	chunk_needs_heat[chunk_y * chunks_x + chunk_x] = 1


## Wie [method wake_at], nur fuer den Waermepass.
func mark_heat_at(x: int, y: int) -> void:
	var chunk_x := x / chunk_size
	var chunk_y := y / chunk_size
	mark_heat_chunk(chunk_x, chunk_y)
	var local_x := x % chunk_size
	var local_y := y % chunk_size
	if local_x == 0:
		mark_heat_chunk(chunk_x - 1, chunk_y)
	elif local_x == chunk_size - 1:
		mark_heat_chunk(chunk_x + 1, chunk_y)
	if local_y == 0:
		mark_heat_chunk(chunk_x, chunk_y - 1)
	elif local_y == chunk_size - 1:
		mark_heat_chunk(chunk_x, chunk_y + 1)


## Uebernimmt die im letzten Frame geweckten Chunks als aktive Menge.
func begin_frame() -> void:
	var previously_awake := chunk_awake
	chunk_awake = chunk_awake_next
	chunk_awake_next = previously_awake
	chunk_awake_next.fill(0)

	var previous_bounds := sim_bounds
	sim_bounds = sim_bounds_next
	sim_bounds_next = previous_bounds
	for chunk in chunk_count:
		_clear_bounds(sim_bounds_next, chunk)


func awake_chunk_count() -> int:
	var awake := 0
	for chunk in chunk_count:
		if chunk_awake[chunk] != 0:
			awake += 1
	return awake


## Vom Renderer aufgerufen, nachdem ein Chunk gezeichnet wurde.
func clear_redraw_bounds(chunk: int) -> void:
	chunk_needs_redraw[chunk] = 0
	_clear_bounds(redraw_bounds, chunk)


## Ganzen Chunk zum Neuzeichnen vormerken - etwa weil sich die Waermetoenung
## ueber die volle Flaeche geaendert hat.
func mark_redraw_full(chunk: int) -> void:
	chunk_needs_redraw[chunk] = 1
	_fill_bounds(redraw_bounds, chunk)

# --- Ruhende Zellen aufwecken ------------------------------------------------

## Holt ruhende, bewegliche Nachbarn einer Zelle aus dem Ruhezustand. Noetig,
## wenn hier ein Loch entsteht - sonst bliebe darueberliegendes Material
## haengen, weil ruhende Zellen nicht mehr simuliert werden.
func wake_neighbours(x: int, y: int) -> void:
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			if offset_x == 0 and offset_y == 0:
				continue
			var neighbour_x := x + offset_x
			var neighbour_y := y + offset_y
			if not in_bounds(neighbour_x, neighbour_y):
				continue
			var neighbour := neighbour_y * width + neighbour_x
			if material_id[neighbour] == MaterialLibrary.EMPTY_ID:
				continue
			if (cell_flags[neighbour] & FLAG_STATIC) != 0:
				continue
			if _lookups.movable[material_id[neighbour]] == 0:
				continue
			move_state[neighbour] = MoveState.FALLING
			wake_at(neighbour_x, neighbour_y)


## Setzt einen ganzen Bereich in den aktiven Zustand zurueck. Noetig, wenn sich
## die Spielregeln aendern statt des Inhalts - etwa nach einem Umbau des
## Gravitationsfelds: ruhende Zellen muessen dann neu bewerten, wo unten ist.
func wake_region(x0: int, y0: int, x1: int, y1: int) -> void:
	var left := maxi(x0, 0)
	var top := maxi(y0, 0)
	var right := mini(x1, width - 1)
	var bottom := mini(y1, height - 1)
	for y in range(top, bottom + 1):
		var row := y * width
		for x in range(left, right + 1):
			var cell := row + x
			if material_id[cell] == MaterialLibrary.EMPTY_ID:
				continue
			if (cell_flags[cell] & FLAG_STATIC) != 0:
				continue
			move_state[cell] = MoveState.FALLING
			settle_state[cell] = 0

# --- Bounds-Rechtecke --------------------------------------------------------

func _wake_cell(chunk_x: int, chunk_y: int, x: int, y: int) -> void:
	if chunk_x < 0 or chunk_y < 0 or chunk_x >= chunks_x or chunk_y >= chunks_y:
		return
	var chunk := chunk_y * chunks_x + chunk_x
	chunk_awake_next[chunk] = 1
	chunk_needs_redraw[chunk] = 1
	_grow_bounds(sim_bounds_next, chunk, x, y)
	_grow_bounds(redraw_bounds, chunk, x, y)


## Setzt das Rechteck auf die volle Flaeche des Chunks.
func _fill_bounds(bounds: PackedInt32Array, chunk: int) -> void:
	var chunk_x := chunk % chunks_x
	var chunk_y := chunk / chunks_x
	var base := chunk * BOUNDS_STRIDE
	bounds[base] = chunk_x * chunk_size
	bounds[base + 1] = chunk_y * chunk_size
	bounds[base + 2] = mini((chunk_x + 1) * chunk_size, width) - 1
	bounds[base + 3] = mini((chunk_y + 1) * chunk_size, height) - 1


func _clear_bounds(bounds: PackedInt32Array, chunk: int) -> void:
	var base := chunk * BOUNDS_STRIDE
	bounds[base] = BOUNDS_EMPTY_MIN
	bounds[base + 1] = BOUNDS_EMPTY_MIN
	bounds[base + 2] = BOUNDS_EMPTY_MAX
	bounds[base + 3] = BOUNDS_EMPTY_MAX


func _grow_bounds(bounds: PackedInt32Array, chunk: int, x: int, y: int) -> void:
	var base := chunk * BOUNDS_STRIDE
	if x < bounds[base]:
		bounds[base] = x
	if y < bounds[base + 1]:
		bounds[base + 1] = y
	if x > bounds[base + 2]:
		bounds[base + 2] = x
	if y > bounds[base + 3]:
		bounds[base + 3] = y
