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

## Die Schwerkraft, die ueberall gilt, wo das Level nichts anderes vorgibt.
var base_gravity: Vector2

# --- Zell-Arrays -------------------------------------------------------------
var material_id: PackedByteArray
var move_state: PackedByteArray
var cell_flags: PackedByteArray
## Generationsstempel: hoechstens eine Bewegung pro Zelle pro Frame.
var move_generation: PackedByteArray
## Bit-gepacktes Ruhe-Gedaechtnis fuer das seitliche Ausbreiten, siehe
## [SandSimulation].
var settle_state: PackedByteArray
## Fortschritt einer laufenden Umwandlung, 0 bis 255. Geteilt von Brand und
## Druck: eine Zelle brennt (dann liegt sie frei) oder steht unter Last (dann
## ist sie begraben) - beides ist "wie weit ist die Umwandlung gediehen".
## Ein gemeinsames Byte spart ein zweites Array ueber die ganze Welt.
var conversion_progress: PackedByteArray
var celsius: PackedFloat32Array
## Das Gravitationsfeld, ein Vektor je Zelle. Es ist STATISCH: gesetzt wird es
## beim Aufbau des Levels ueber [method set_gravity_area], danach ruehrt es
## niemand mehr an. Es darf sich also innerhalb der Karte unterscheiden - eine
## Halle mit umgekehrter Schwerkraft, ein schwereloser Schacht - aber es gibt
## keine Materialien mehr, die zur Laufzeit ein eigenes Feld abstrahlen.
##
## Ein voller Vektor je Zelle statt einer Zonenliste, weil der Schleifenkern
## der Bewegung fuer jede wache Zelle genau einen Zugriff braucht; eine Liste
## muesste er pro Zelle durchsuchen.
var gravity: PackedVector2Array

# --- Chunk-Arrays ------------------------------------------------------------
var chunk_awake: PackedByteArray        ## In diesem Frame zu simulieren.
var chunk_awake_next: PackedByteArray   ## Im naechsten Frame zu simulieren.
var chunk_needs_heat: PackedByteArray   ## Temperatur weicht ab, Waermepass noetig.
var chunk_needs_redraw: PackedByteArray ## Pixel muessen neu gezeichnet werden.
## Hier liegt druckempfindliches Material. Der [PressurePass] sieht sich nur
## Spalten an, in denen mindestens ein Chunk das gesetzt hat - ohne Holz oder
## Kohle in der Welt kostet der ganze Pass deshalb nichts.
var chunk_has_pressure: PackedByteArray

## Hat das Level irgendwo eine von [member base_gravity] abweichende
## Schwerkraft gesetzt? Wenn nicht, spart sich der [PressurePass] die Pruefung
## pro Zelle.
var has_gravity_zones: bool = false

## Betroffener Bereich je Chunk, in Weltkoordinaten und einschliesslich. Ein
## wacher Chunk wird nur innerhalb dieses Rechtecks simuliert statt auf voller
## Flaeche - bei lokal begrenzter Aktivitaet ist das der Unterschied zwischen
## ein paar tausend und ein paar hundert betrachteten Zellen.
var sim_bounds: PackedInt32Array
var sim_bounds_next: PackedInt32Array

## Und dasselbe fuer den Waermepass. Waerme wandert pro Durchlauf hoechstens
## eine Zelle weit (sie leitet nur zu den vier direkten Nachbarn), deshalb ist
## das Rechteck vom letzten Durchlauf, um eine Zelle erweitert, garantiert eine
## Obermenge dessen, was jetzt warm sein kann. Ohne dieses Rechteck rechnete
## der Pass die volle Chunkflaeche durch, auch wenn nur ein paar Zellen heiss
## waren - bei Lava der groesste Einzelposten.
var heat_bounds: PackedInt32Array

## Dasselbe fuer den Renderer. Getrennt vom Simulations-Rechteck, weil der
## Renderer in seinem eigenen Takt leert: ein Chunk kann mehrere
## Simulationsschritte lang Aenderungen sammeln, bevor gezeichnet wird.
var redraw_bounds: PackedInt32Array

var _lookups: MaterialLookups


func _init(size: Vector2i, chunk_edge: int, lookups: MaterialLookups, ambient: float,
		gravity_vector := Vector2.DOWN) -> void:
	width = size.x
	height = size.y
	cell_count = width * height
	chunk_size = chunk_edge
	chunks_x = ceili(float(width) / float(chunk_size))
	chunks_y = ceili(float(height) / float(chunk_size))
	chunk_count = chunks_x * chunks_y
	ambient_celsius = ambient
	base_gravity = gravity_vector
	_lookups = lookups

	material_id.resize(cell_count)
	move_state.resize(cell_count)
	cell_flags.resize(cell_count)
	move_generation.resize(cell_count)
	settle_state.resize(cell_count)
	conversion_progress.resize(cell_count)
	celsius.resize(cell_count)
	gravity.resize(cell_count)

	chunk_awake.resize(chunk_count)
	chunk_awake_next.resize(chunk_count)
	chunk_needs_heat.resize(chunk_count)
	chunk_needs_redraw.resize(chunk_count)
	chunk_has_pressure.resize(chunk_count)
	sim_bounds.resize(chunk_count * BOUNDS_STRIDE)
	sim_bounds_next.resize(chunk_count * BOUNDS_STRIDE)
	heat_bounds.resize(chunk_count * BOUNDS_STRIDE)
	redraw_bounds.resize(chunk_count * BOUNDS_STRIDE)

	clear()


## Setzt die ganze Welt auf Luft zurueck.
func clear() -> void:
	material_id.fill(MaterialLibrary.EMPTY_ID)
	move_state.fill(MoveState.REST)
	cell_flags.fill(0)
	move_generation.fill(0)
	settle_state.fill(0)
	conversion_progress.fill(0)
	celsius.fill(ambient_celsius)
	gravity.fill(base_gravity)

	chunk_awake.fill(1)
	chunk_awake_next.fill(1)
	chunk_needs_heat.fill(0)
	chunk_needs_redraw.fill(1)
	chunk_has_pressure.fill(0)
	has_gravity_zones = false
	for chunk in chunk_count:
		_fill_bounds(sim_bounds, chunk)
		_fill_bounds(sim_bounds_next, chunk)
		_fill_bounds(heat_bounds, chunk)
		_fill_bounds(redraw_bounds, chunk)

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


## Setzt eine Zelle mitsamt aller Nebenbuchhaltung: Chunks wecken, Nachbarn
## aufruetteln. Das ist der einzige legitime Schreibpfad von aussen.
##
## [param temperature] auf [constant USE_MATERIAL_TEMPERATURE] lassen, um die
## Materialvorgabe zu nehmen. So bringt Lava ihre 1200 Grad und Eis seine
## -60 Grad selbst mit, ohne dass der Aufrufer davon wissen muss.
func set_cell(x: int, y: int, new_material: int, make_static: bool,
		temperature: float = USE_MATERIAL_TEMPERATURE) -> void:
	if not in_bounds(x, y):
		return
	var cell := y * width + x
	material_id[cell] = new_material
	cell_flags[cell] = FLAG_STATIC if make_static else 0
	settle_state[cell] = 0
	# Frisch gesetzt heisst unversehrt: eine halb verbrannte Holzzelle, die
	# uebermalt wird, faengt von vorne an.
	conversion_progress[cell] = 0
	if _lookups.pressure_rate[new_material] > 0:
		mark_pressure_at(x, y)
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


## Setzt die Schwerkraft in einem Rechteck - der Weg, auf dem ein Level sein
## Gravitationsfeld aufbaut. Gedacht fuer den Aufbau, nicht fuer jeden Frame.
##
## Weckt den Bereich mit auf: wo "unten" jetzt woanders liegt, muessen ruhende
## Zellen ihre Lage neu bewerten, sonst bleiben sie in einer Haltung liegen,
## die unter dem neuen Feld gar nicht stabil ist.
func set_gravity_area(area: Rect2i, vector: Vector2) -> void:
	var left := maxi(area.position.x, 0)
	var top := maxi(area.position.y, 0)
	var right := mini(area.end.x - 1, width - 1)
	var bottom := mini(area.end.y - 1, height - 1)
	if left > right or top > bottom:
		return
	if vector != base_gravity:
		has_gravity_zones = true
	for y in range(top, bottom + 1):
		var row := y * width
		for x in range(left, right + 1):
			gravity[row + x] = vector

	wake_region(left, top, right, bottom)
	for chunk_y in range(top / chunk_size, bottom / chunk_size + 1):
		for chunk_x in range(left / chunk_size, right / chunk_size + 1):
			wake_chunk(chunk_x, chunk_y)


## Die Schwerkraft an einer Stelle. Bequem, aber langsam - der Schleifenkern
## indiziert [member gravity] direkt.
func gravity_at(x: int, y: int) -> Vector2:
	if not in_bounds(x, y):
		return base_gravity
	return gravity[y * width + x]


## Merkt den Chunk dieser Zelle fuer den [PressurePass] vor.
func mark_pressure_at(x: int, y: int) -> void:
	if not in_bounds(x, y):
		return
	chunk_has_pressure[(y / chunk_size) * chunks_x + (x / chunk_size)] = 1


## Die Last auf einer Zelle: die Summe der Dichten entlang der Schwerkraft
## darueber, geteilt durch 1000 - also in "Metern Wassersaeule".
##
## Laeuft die Spalte von oben neu durch und ist deshalb nur fuer einzelne
## Abfragen gedacht (HUD, Selbsttests). Der [PressurePass] rechnet dieselbe
## Summe nebenbei, waehrend er ohnehin ueber die Spalte laeuft, und braucht
## diese Funktion nicht.
func pressure_at(x: int, y: int) -> float:
	if not in_bounds(x, y):
		return 0.0
	var load := 0.0
	var cell := x
	for row in y:
		var material := material_id[cell]
		if material == MaterialLibrary.EMPTY_ID:
			load = 0.0
		else:
			if has_gravity_zones and gravity[cell] != base_gravity:
				load = 0.0
			load += _lookups.density[material] * PressurePass.LOAD_SCALE
		cell += width
	return load

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


## Merkt einen ganzen Chunk fuer den Waermepass vor, auf voller Flaeche.
func mark_heat_chunk(chunk_x: int, chunk_y: int) -> void:
	if chunk_x < 0 or chunk_y < 0 or chunk_x >= chunks_x or chunk_y >= chunks_y:
		return
	var chunk := chunk_y * chunks_x + chunk_x
	chunk_needs_heat[chunk] = 1
	_fill_bounds(heat_bounds, chunk)


## Merkt EINE Zelle fuer den Waermepass vor und zieht das Rechteck ihres Chunks
## darum auf.
func mark_heat_cell(x: int, y: int) -> void:
	if not in_bounds(x, y):
		return
	var chunk := (y / chunk_size) * chunks_x + (x / chunk_size)
	chunk_needs_heat[chunk] = 1
	_grow_bounds(heat_bounds, chunk, x, y)


## Wie [method wake_at], nur fuer den Waermepass: die Zelle selbst und, wenn sie
## am Chunkrand liegt, die Nachbarzelle jenseits der Grenze.
func mark_heat_at(x: int, y: int) -> void:
	mark_heat_cell(x, y)
	var local_x := x % chunk_size
	var local_y := y % chunk_size
	if local_x == 0:
		mark_heat_cell(x - 1, y)
	elif local_x == chunk_size - 1:
		mark_heat_cell(x + 1, y)
	if local_y == 0:
		mark_heat_cell(x, y - 1)
	elif local_y == chunk_size - 1:
		mark_heat_cell(x, y + 1)


## Vom Waermepass aufgerufen: das Rechteck der noch warmen Zellen uebernehmen.
func set_heat_bounds(chunk: int, left: int, top: int, right: int, bottom: int) -> void:
	var base := chunk * BOUNDS_STRIDE
	heat_bounds[base] = left
	heat_bounds[base + 1] = top
	heat_bounds[base + 2] = right
	heat_bounds[base + 3] = bottom


## Der Chunk ist ausgekuehlt.
func clear_heat(chunk: int) -> void:
	chunk_needs_heat[chunk] = 0
	_clear_bounds(heat_bounds, chunk)


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


## Ganzen Chunk zum Neuzeichnen vormerken, etwa beim Zuruecksetzen der Welt.
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
## die Spielregeln aendern statt des Inhalts - etwa nachdem das Level die
## Schwerkraft in einem Bereich gesetzt hat.
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
