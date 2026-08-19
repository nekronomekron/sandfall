class_name SandSimulation
extends Node

## Der Simulationsschritt als Knoten in der Szene. Reihenfolge pro Frame:
## [br]1. Gravitationsfeld neu backen, falls sich eine Quelle geaendert hat
## [br]2. Waermeleitung samt Aggregatzustands-FSM (nur thermisch aktive Chunks)
## [br]3. Bewegungs-FSM (nur wache Chunks)
##
## RICHTUNGSUNABHAENGIGKEIT: Klassische Falling-Sand-Simulationen verlassen
## sich darauf, dass die Scanreihenfolge der Gravitationsrichtung entspricht.
## Das faellt aus, sobald die Gravitation regional umgekehrt oder blockiert ist.
## Stattdessen traegt jede Zelle einen Generationsstempel: sie wird pro Frame
## hoechstens einmal bewegt, egal in welcher Reihenfolge sie besucht wird.
##
## PERFORMANCE: Materialeigenschaften kommen aus [MaterialLookups], nicht aus
## Property-Zugriffen auf die [SandMaterial]-Resource - die liegen hier im
## innersten Schleifenkern und kosten ein Vielfaches.

## Die acht Nachbarrichtungen im Kreis. Der Index ist der auf 45 Grad
## gerundete Winkel, Index 2 ist also "unten" bei normaler Gravitation.
const DIRECTION_COUNT := 8

## Schrittweiten auf diesem Richtungskreis.
const TURN_DIAGONAL_CW := 1
const TURN_DIAGONAL_CCW := DIRECTION_COUNT - 1
const TURN_SIDEWAYS_CW := 2
const TURN_SIDEWAYS_CCW := DIRECTION_COUNT - 2

## Aufbau des settle-Bytes einer Zelle ([member CellGrid.settle_state]):
## [br]Bit 0-5  Anzahl der Richtungswechsel beim seitlichen Ausweichen
## [br]Bit 6    es liegt eine gemerkte Fliessrichtung vor
## [br]Bit 7    welche der beiden Querrichtungen gemerkt ist
##
## Gezaehlt werden bewusst nur die WECHSEL, nicht die zurueckgelegten Schritte.
## Eine Fluessigkeit, die stetig nach aussen laeuft, kehrt nie um und darf
## deshalb beliebig weit fliessen, bis sie den tiefsten Punkt erreicht hat. Nur
## wer immer wieder umkehrt - also zwischen zwei gleichwertigen Lagen hin und
## her pendelt - kommt nach dem Umkehr-Budget des Materials zur Ruhe. Eine
## Begrenzung der Strecke statt der Wechsel liesse Fluessigkeiten mitten im
## Fliessen als Haufen stehen.
const SETTLE_CHANGE_MASK := 0x3F
const SETTLE_HAS_DIRECTION := 0x40
const SETTLE_PREFERS_CCW := 0x80
const SETTLE_MAX := 0xFF

## Der Generationsstempel ist ein Byte und muss den Wert 0 meiden, weil ein
## frisch angelegtes Gitter ueberall 0 stehen hat.
const GENERATION_WRAP := 250

@export_group("Verdrahtung")

## Woher Materialien und Lookups kommen. Im Editor zuweisen.
@export var registry: MaterialRegistry

## Backt das Gravitationsfeld. Im Editor zuweisen (ueblicherweise ein Kindknoten).
@export var gravity_field: GravityField

@export_group("Welt")

## Groesse der Welt in Zellen. Der sichtbare Ausschnitt ist deutlich kleiner -
## man sieht immer nur einen Teil und scrollt.
@export var world_size := Vector2i(1024, 576)

## Kantenlaenge eines Chunks. Chunks sind die Einheit fuer Schlafen und Wecken.
@export_range(16, 256, 16) var chunk_size := 64

## Umgebungstemperatur, gegen die alles langsam ausgleicht.
@export var ambient_celsius := 20.0

@export_group("Feinabstimmung")

## Wie viele Zellen eine Zelle bei verstaerkter Gravitation hoechstens pro
## Frame zuruecklegt.
@export_range(1, 8) var max_steps_per_frame := 4

## Der Waermepass laeuft nur jeden n-ten Frame - Waerme wandert langsam genug,
## dass das nicht auffaellt, und der Pass ist teuer.
@export_range(1, 16) var heat_interval := 3

## Darunter gilt die Zelle als schwerelos und schwebt, statt zu fallen.
@export_range(0.0, 1.0, 0.01) var weightless_below := 0.06

## Ab dieser Abweichung von der Umgebungstemperatur bleibt ein Chunk thermisch
## aktiv. Darunter schlaeft er ein.
@export_range(0.0, 5.0, 0.05) var heat_settled_below := 0.35

var grid: CellGrid

# --- Statistik fuer das HUD --------------------------------------------------
var last_step_usec: int = 0
var stat_awake_chunks: int = 0
var stat_moved: int = 0
var stat_gravity_usec: int = 0
var stat_heat_usec: int = 0
var stat_move_usec: int = 0

var _lookups: MaterialLookups

## Die Arrays aus [MaterialLookups] noch einmal als eigene Member.
##
## Das ist keine Doppelung der Daten - es sind dieselben Arrays, nur unter einem
## kuerzeren Namen. `_lookups.movable[m]` kostet in GDScript zwei Zugriffe
## (erst die Eigenschaft, dann das Array), `_movable[m]` nur einen. Im
## Schleifenkern der Bewegung und der Waermeleitung macht das gemessen rund
## 40 Prozent aus, deshalb steht es hier ausgeschrieben.
var _movable: PackedByteArray
var _is_gas: PackedByteArray
var _is_fluid: PackedByteArray
var _density: PackedFloat32Array
var _dispersion: PackedByteArray
var _friction_u8: PackedByteArray
var _change_budget: PackedByteArray
var _starts_static: PackedByteArray
var _is_gravity_source: PackedByteArray
var _heat_transfer: PackedFloat32Array
var _ambient_pull: PackedFloat32Array
var _emits_heat: PackedByteArray
var _emit_celsius: PackedFloat32Array
var _emit_power: PackedFloat32Array
var _transition_start: PackedInt32Array
var _transition_count: PackedInt32Array
var _transition_above: PackedByteArray
var _transition_threshold: PackedFloat32Array
var _transition_target: PackedInt32Array
var _transition_resets: PackedByteArray
var _transition_result: PackedFloat32Array

## Weltgroesse, ebenfalls lokal statt ueber `grid.` - gleiche Begruendung.
var _width: int
var _height: int

var _rng := RandomNumberGenerator.new()
var _generation: int = 1
var _frame: int = 0
## Scanrichtung jeden Frame spiegeln, damit sich keine Drift nach einer Seite
## einschleicht.
var _scan_reversed: bool = false

# Bewusst PackedInt32Array statt Array[Vector2i]: das Indizieren eines
# typisierten Arrays liefert eine Variant und kostet im Schleifenkern spuerbar
# mehr als ein Packed-Array-Zugriff.
var _direction_x := PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
var _direction_y := PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])
## Index-Offsets der acht Nachbarn, passend zu den Richtungsarrays. Erspart im
## Inneren des Gitters die Multiplikation pro Nachbar.
var _neighbour_offset: PackedInt32Array


func _ready() -> void:
	ensure_world()


## Legt das Gitter an, falls es noch keins gibt. Alle Knoten, die das Gitter
## brauchen, rufen das in ihrem eigenen [method Node._ready] auf - damit ist die
## Reihenfolge im Szenenbaum egal.
func ensure_world() -> void:
	if grid == null:
		create_world()


## Legt ein frisches Gitter an und verwirft das alte.
func create_world() -> void:
	assert(registry != null, "SandSimulation braucht eine MaterialRegistry.")
	registry.build()
	_lookups = registry.lookups
	_rng.randomize()

	grid = CellGrid.new(world_size, chunk_size, _lookups, ambient_celsius)
	_width = grid.width
	_height = grid.height
	_cache_lookups()

	_neighbour_offset.resize(DIRECTION_COUNT)
	for direction in DIRECTION_COUNT:
		_neighbour_offset[direction] = _direction_y[direction] * _width + _direction_x[direction]


## Holt die Lookup-Arrays unter kurze Namen, siehe deren Deklaration.
func _cache_lookups() -> void:
	_movable = _lookups.movable
	_is_gas = _lookups.is_gas
	_is_fluid = _lookups.is_fluid
	_density = _lookups.density
	_dispersion = _lookups.dispersion
	_friction_u8 = _lookups.friction_u8
	_change_budget = _lookups.direction_change_budget
	_starts_static = _lookups.starts_static
	_is_gravity_source = _lookups.is_gravity_source
	_heat_transfer = _lookups.heat_transfer
	_ambient_pull = _lookups.ambient_pull
	_emits_heat = _lookups.emits_heat
	_emit_celsius = _lookups.emit_celsius
	_emit_power = _lookups.emit_power
	_transition_start = _lookups.transition_start
	_transition_count = _lookups.transition_count
	_transition_above = _lookups.transition_above
	_transition_threshold = _lookups.transition_threshold
	_transition_target = _lookups.transition_target
	_transition_resets = _lookups.transition_resets_temperature
	_transition_result = _lookups.transition_result


## Leert die Welt und das Gravitationsfeld.
func reset() -> void:
	grid.clear()
	if gravity_field != null:
		gravity_field.reset()


## Ein Simulationsschritt.
func step() -> void:
	var started := Time.get_ticks_usec()
	_frame += 1
	_generation = (_generation % GENERATION_WRAP) + 1
	stat_moved = 0
	stat_gravity_usec = 0
	stat_heat_usec = 0

	if grid.gravity_dirty and gravity_field != null:
		var gravity_started := Time.get_ticks_usec()
		gravity_field.rebuild(grid, registry.library)
		grid.gravity_dirty = false
		stat_gravity_usec = Time.get_ticks_usec() - gravity_started

	if _frame % heat_interval == 0:
		var heat_started := Time.get_ticks_usec()
		_step_heat()
		stat_heat_usec = Time.get_ticks_usec() - heat_started

	grid.begin_frame()
	stat_awake_chunks = grid.awake_chunk_count()
	var move_started := Time.get_ticks_usec()
	_step_movement()
	stat_move_usec = Time.get_ticks_usec() - move_started

	_scan_reversed = not _scan_reversed
	last_step_usec = Time.get_ticks_usec() - started

# --- Bewegung ----------------------------------------------------------------

func _step_movement() -> void:
	# Chunkreihen von unten nach oben: tiefer liegende Zellen raeumen zuerst
	# Platz, das ergibt dichtere Haufen. Die Korrektheit haengt nicht daran.
	for chunk_y in range(grid.chunks_y - 1, -1, -1):
		for column in grid.chunks_x:
			var chunk_x := grid.chunks_x - 1 - column if _scan_reversed else column
			var chunk := chunk_y * grid.chunks_x + chunk_x
			if grid.chunk_awake[chunk] == 0:
				continue
			_step_chunk(chunk_x, chunk_y, chunk)


## Die Vorfilterung steht bewusst inline in der Schleife statt in
## [method _update_cell]: der weit ueberwiegende Teil eines wachen Chunks ist
## Luft oder ruhender Feststoff, und ein GDScript-Funktionsaufruf pro Zelle
## waere dafuer der teuerste Einzelposten des ganzen Frames.
func _step_chunk(chunk_x: int, chunk_y: int, chunk: int) -> void:
	var base := chunk * CellGrid.BOUNDS_STRIDE
	var dirty_left := grid.sim_bounds[base]
	var dirty_top := grid.sim_bounds[base + 1]
	var dirty_right := grid.sim_bounds[base + 2]
	var dirty_bottom := grid.sim_bounds[base + 3]
	if dirty_left > dirty_right or dirty_top > dirty_bottom:
		return

	# Eine Zelle Sicherheitsmarge um das Dirty-Rect: Material direkt neben einer
	# Aenderung muss neu bewertet werden, etwa Sand ueber einer geraeumten Zelle.
	var chunk_left := chunk_x * grid.chunk_size
	var chunk_top := chunk_y * grid.chunk_size
	var left := maxi(dirty_left - 1, chunk_left)
	var top := maxi(dirty_top - 1, chunk_top)
	var right := mini(dirty_right + 1, mini(chunk_left + grid.chunk_size, grid.width) - 1)
	var bottom := mini(dirty_bottom + 1, mini(chunk_top + grid.chunk_size, grid.height) - 1)

	# Lokale Aliase auf die Zell-Arrays. Packed-Arrays teilen sich in GDScript
	# den Puffer: ein lokaler Alias forkt beim Schreiben nicht, Schreibzugriffe
	# ueber grid bleiben also sichtbar. Ein Member-Zugriff kostet hier gemessen
	# das 2,75-fache, und das ist der meistausgefuehrte Code im ganzen Projekt.
	var materials := grid.material_id
	var generations := grid.move_generation
	var flags := grid.cell_flags
	var states := grid.move_state
	var movable := _movable
	var width := grid.width
	var generation := _generation

	var scan_step := -1 if _scan_reversed else 1
	var scan_from := right if _scan_reversed else left
	var scan_to := left - 1 if _scan_reversed else right + 1

	for y in range(bottom, top - 1, -1):
		var row := y * width
		for x in range(scan_from, scan_to, scan_step):
			var cell := row + x
			var material := materials[cell]
			if material == MaterialLibrary.EMPTY_ID:
				continue
			if movable[material] == 0:
				continue
			if generations[cell] == generation:
				continue
			# Ruhende Zellen kosten ab hier nichts mehr. Sie werden erst wieder
			# betrachtet, wenn jemand sie weckt - weil daneben ein Loch entsteht
			# oder weil sie mitgerissen werden.
			if states[cell] == CellGrid.MoveState.REST:
				continue
			if (flags[cell] & CellGrid.FLAG_STATIC) != 0:
				continue
			_update_cell(x, y, cell, material)


## Eine bewegliche, wache Zelle: Fallrichtung bestimmen und der Reihe nach
## Hauptrichtung, Diagonalen und Querrichtung probieren.
func _update_cell(x: int, y: int, cell: int, material: int) -> void:
	var local_gravity := grid.gravity[cell]
	var gravity_x := local_gravity.x
	var gravity_y := local_gravity.y

	# Auftrieb: Gas steigt entgegen der oertlichen Gravitation - und darf dabei
	# schwerere Fluide verdraengen statt leichtere, siehe [method can_displace].
	var rising := _is_gas[material] == 1
	if rising:
		gravity_x = -gravity_x
		gravity_y = -gravity_y

	# Richtungsindex und Betrag der oertlichen Gravitation. Der Schnellpfad fuer
	# rein senkrechte Gravitation steht ausgeschrieben statt in zwei
	# Hilfsfunktionen: er gilt fuer die grosse Mehrheit aller Zellen, laeuft
	# einmal pro wacher Zelle und spart so zwei Aufrufe, atan2 und die Wurzel.
	var direction: int
	var strength: float
	if gravity_x == 0.0:
		direction = 2 if gravity_y > 0.0 else 6
		strength = absf(gravity_y)
	else:
		direction = posmod(roundi(atan2(gravity_y, gravity_x) / (PI / 4.0)), DIRECTION_COUNT)
		strength = sqrt(gravity_x * gravity_x + gravity_y * gravity_y)

	if strength < weightless_below:
		# Schwerelos, etwa im Radius eines Grav-Blockers.
		grid.move_state[cell] = CellGrid.MoveState.REST
		return

	var steps := clampi(roundi(strength), 1, max_steps_per_frame)
	var density := _density[material]

	if _try_fall(x, y, cell, direction, steps, density, rising):
		return
	if _try_slide_diagonally(x, y, cell, direction, density, rising):
		return
	if _try_spread_sideways(x, y, cell, material, direction, density, rising):
		return

	grid.move_state[cell] = CellGrid.MoveState.REST


## Schritt in der Hauptrichtung der oertlichen Gravitation.
func _try_fall(x: int, y: int, cell: int, direction: int, steps: int,
		density: float, rising: bool) -> bool:
	var target_x := x + _direction_x[direction]
	var target_y := y + _direction_y[direction]
	if target_x < 0 or target_y < 0 or target_x >= _width or target_y >= _height:
		return false
	if not _is_passable(target_y * _width + target_x, density, rising):
		return false

	if steps > 1:
		# Verstaerkte Gravitation: den Pfad Zelle fuer Zelle pruefen, sonst
		# tunnelt Material durch duenne Waende.
		var reached := _walk(x, y, _direction_x[direction], _direction_y[direction],
			steps, density, rising)
		_commit(cell, x, y, reached.x, reached.y, CellGrid.MoveState.FALLING, 0, direction)
	else:
		_commit(cell, x, y, target_x, target_y, CellGrid.MoveState.FALLING, 0, direction)
	return true


## Diagonal abrutschen - das ist es, was einen Schuettkegel entstehen laesst.
## Welche Seite zuerst probiert wird, entscheidet der Zufall, sonst driftet ein
## Haufen systematisch zu einer Seite.
func _try_slide_diagonally(x: int, y: int, cell: int, direction: int,
		density: float, rising: bool) -> bool:
	var first := (direction + TURN_DIAGONAL_CW) % DIRECTION_COUNT
	var second := (direction + TURN_DIAGONAL_CCW) % DIRECTION_COUNT
	if _rng.randi() % 2 == 1:
		var swap := first
		first = second
		second = swap

	# `for ... in 2` statt `for ... in [first, second]`: ein Array-Literal wird
	# bei jedem Aufruf neu angelegt, und das hier laeuft einmal pro bewegter Zelle.
	for attempt in 2:
		var diagonal := first if attempt == 0 else second
		var target_x := x + _direction_x[diagonal]
		var target_y := y + _direction_y[diagonal]
		if target_x < 0 or target_y < 0 or target_x >= _width or target_y >= _height:
			continue
		if not _is_passable(target_y * _width + target_x, density, rising):
			continue
		# Abrutschen hat eine Komponente entlang der Gravitation, zaehlt also
		# als Fallen: der Umkehrzaehler faellt auf 0 zurueck.
		_commit(cell, x, y, target_x, target_y, CellGrid.MoveState.SLIDING, 0, diagonal)
		return true
	return false


## Fluide und Gase breiten sich senkrecht zur Gravitation aus. Die Reibung
## begrenzt, wie oft eine Zelle das rein seitlich tut - ohne diese Grenze
## schiebt sich eine glatte Wasseroberflaeche endlos zwischen zwei
## gleichwertigen Zustaenden hin und her und kommt nie zur Ruhe.
func _try_spread_sideways(x: int, y: int, cell: int, material: int, direction: int,
		density: float, rising: bool) -> bool:
	var reach := _dispersion[material]
	if reach == 0:
		return false

	var settle := grid.settle_state[cell]
	var changes := settle & SETTLE_CHANGE_MASK
	if changes >= _change_budget[material]:
		return false

	# Die gemerkte Richtung zuerst probieren. Ohne Erinnerung entscheidet der
	# Zufall, damit ein frisch gelandeter Tropfen nicht systematisch driftet.
	var prefers_ccw := (settle & SETTLE_PREFERS_CCW) != 0
	if (settle & SETTLE_HAS_DIRECTION) == 0:
		prefers_ccw = _rng.randi() % 2 == 1

	var clockwise := (direction + TURN_SIDEWAYS_CW) % DIRECTION_COUNT
	var counter_clockwise := (direction + TURN_SIDEWAYS_CCW) % DIRECTION_COUNT
	var remembered := counter_clockwise if prefers_ccw else clockwise
	var opposite := clockwise if prefers_ccw else counter_clockwise

	# Gleiche Richtung wie zuletzt: kein Wechsel, der Zaehler bleibt stehen.
	# Bewusst immer SLIDING und nie direkt REST - ein seitlicher Schritt kann
	# ueber einem Loch enden, und eine sofort auf REST gesetzte Zelle bliebe
	# dort in der Luft stehen.
	if _try_step_sideways(x, y, cell, remembered, reach, density, rising,
			changes, prefers_ccw):
		return true

	# Umkehr - nur das zaehlt als Schritt Richtung Ruhezustand.
	var increased := mini(changes + 1, SETTLE_CHANGE_MASK)
	return _try_step_sideways(x, y, cell, opposite, reach, density, rising,
		increased, not prefers_ccw)


func _try_step_sideways(x: int, y: int, cell: int, direction: int, reach: int,
		density: float, rising: bool, changes: int, prefers_ccw: bool) -> bool:
	var reached := _walk(x, y, _direction_x[direction], _direction_y[direction],
		reach, density, rising)
	if reached.x == x and reached.y == y:
		return false
	var settle := changes | SETTLE_HAS_DIRECTION
	if prefers_ccw:
		settle |= SETTLE_PREFERS_CCW
	_commit(cell, x, y, reached.x, reached.y, CellGrid.MoveState.SLIDING, settle, direction)
	return true


## Ist diese Nachbarzelle frei oder verdraengbar?
func _is_passable(neighbour: int, density: float, rising: bool) -> bool:
	var occupant := grid.material_id[neighbour]
	if occupant == MaterialLibrary.EMPTY_ID:
		return true
	if (grid.cell_flags[neighbour] & CellGrid.FLAG_STATIC) != 0:
		return false
	# Eine Zelle, die in diesem Frame schon bewegt wurde, darf nicht noch einmal
	# verdraengt werden. Ohne diese Bedingung ratscht jede nachfallende
	# Wasserzelle dieselbe Dampfblase eine weitere Stufe hoch, und die Blase
	# legt eine ganze Wassersaeule in einem einzigen Frame zurueck.
	if grid.move_generation[neighbour] == _generation:
		return false
	return can_displace(occupant, density, rising)


## Darf ein Material der Dichte [param density] die Zelle mit Material
## [param occupant] verdraengen?
##
## Verdraengt wird ausschliesslich in Fluiden: ein schwereres Teilchen schiebt
## sich durch eine leichtere Fluessigkeit oder ein Gas. Sand sinkt deshalb
## durch Wasser, und Wasser schiebt Dampf weg.
##
## Feste Materialien - Pulver wie Sand und Stein ebenso wie echte Feststoffe -
## werden dagegen NIE verdraengt. Sie bleiben aufeinander liegen, egal wie
## schwer das Material darueber ist. Ein Kornhaufen ist ein Gefuege, kein Bad:
## ein Steinbrocken sinkt nicht in einen Sandhaufen ein, und Lava laeuft ueber
## den Sand statt hindurch.
##
## Massgeblich ist die Bewegungsrichtung relativ zur oertlichen Gravitation:
## [br]- Wer MIT der Gravitation faellt, schiebt sich durch LEICHTERE Fluide.
## [br]- Wer GEGEN sie steigt - also Gase, deren Auftrieb die Richtung umdreht -
##   schiebt sich durch SCHWERERE Fluide. Das ist der Auftrieb: eine Dampfblase
##   unter Wasser tauscht mit dem Wasser darueber und steigt auf.
##
## Auf die Art des Verursachers kommt es sonst nicht an, nur auf das, was
## verdraengt werden soll.
func can_displace(occupant: int, density: float, rising: bool) -> bool:
	if _movable[occupant] == 0:
		return false
	if _is_fluid[occupant] == 0:
		return false
	if rising:
		return _density[occupant] > density
	return _density[occupant] < density


## Laeuft bis zu [param steps] Zellen in eine Richtung und liefert die weiteste
## erreichbare Position.
func _walk(x: int, y: int, step_x: int, step_y: int, steps: int,
		density: float, rising: bool) -> Vector2i:
	var reached_x := x
	var reached_y := y
	for step in steps:
		var next_x := reached_x + step_x
		var next_y := reached_y + step_y
		if next_x < 0 or next_y < 0 or next_x >= _width or next_y >= _height:
			break
		var next := next_y * _width + next_x
		if grid.material_id[next] == MaterialLibrary.EMPTY_ID:
			reached_x = next_x
			reached_y = next_y
			continue
		# Verdraengt wird nur im ERSTEN Schritt. Sonst tauscht eine Zelle, die
		# schon mehrere leere Felder weit geflogen ist, mit dem Material am Ende
		# ihrer Bahn - und das landet dann an ihrer Startposition, also mitten
		# in der Luft. Genau so entstanden beim Lavafall Sandkoerner im Nichts.
		if step == 0 and _is_passable(next, density, rising):
			reached_x = next_x
			reached_y = next_y
		break
	return Vector2i(reached_x, reached_y)


## Fuehrt eine Bewegung aus: Zelle und Ziel tauschen ihren Inhalt.
func _commit(cell: int, x: int, y: int, target_x: int, target_y: int,
		state: int, settle: int, direction: int) -> void:
	var target := target_y * _width + target_x

	# Lokale Aliase - dieser Block laeuft einmal pro bewegter Zelle und ist nach
	# dem Scan der zweitheisseste Pfad der Simulation.
	var materials := grid.material_id
	var flags := grid.cell_flags
	var temperatures := grid.celsius
	var states := grid.move_state
	var generations := grid.move_generation
	var settles := grid.settle_state
	var generation := _generation

	var material := materials[cell]
	var occupant := materials[target]

	var moved_flags := flags[cell]
	var moved_celsius := temperatures[cell]
	var swapped_flags := flags[target]
	var swapped_celsius := temperatures[target]
	var swapped_settle := settles[target]

	materials[target] = material
	flags[target] = moved_flags
	temperatures[target] = moved_celsius
	states[target] = state
	settles[target] = mini(settle, SETTLE_MAX)
	generations[target] = generation

	materials[cell] = occupant
	flags[cell] = swapped_flags
	temperatures[cell] = swapped_celsius
	settles[cell] = swapped_settle
	var left_empty := occupant == MaterialLibrary.EMPTY_ID
	states[cell] = CellGrid.MoveState.REST if left_empty else CellGrid.MoveState.FALLING
	generations[cell] = generation

	# Bewegliche Gravitationsquellen: Registrierung mitfuehren, Feld neu backen.
	if _is_gravity_source[material] == 1:
		grid.move_gravity_source(cell, target)
	if not left_empty and _is_gravity_source[occupant] == 1:
		grid.move_gravity_source(target, cell)

	# BEIDE Endpunkte wecken, auch innerhalb desselben Chunks. Das Dirty-Rect
	# ist eine Bounding-Box: nur die Quelle einzutragen laesst das Ziel
	# ausserhalb liegen, sobald der Schritt weiter als die Ein-Zellen-Marge
	# geht - und Wasser streut bis zu seiner Dispersion weit. Betroffenes
	# Material bliebe dann stehen, bis es zufaellig von woanders geweckt wird.
	grid.wake_at(x, y)
	grid.wake_at(target_x, target_y)

	# Nur wenn wirklich ein Loch entstanden ist - bei einer Verdraengung hat
	# sich an der Unterlage der Nachbarn nichts geaendert.
	if left_empty:
		_wake_all_neighbours(x, y, target)
	# Am Ziel zieht die vorbeigekommene Zelle an den ruhenden Zellen NEBEN ihrer
	# Bahn. Ob die mitgehen, entscheidet ihre Reibung.
	_entrain(target_x, target_y, direction)
	stat_moved += 1


## Weckt alle acht ruhenden Nachbarn, ohne Reibungswurf: eine fehlende Unterlage
## ist keine Frage der Reibung. Die bewegte Zelle selbst wird ausgenommen, sonst
## weckt sie sich sofort wieder und pendelt in ihr eigenes Loch zurueck.
##
## Der Rumpf steht bewusst ausgeschrieben in der Schleife statt in einer
## Hilfsfunktion: das laeuft acht Mal pro bewegter Zelle, und der
## Aufruf-Overhead von GDScript kostete gemessen mehr als die Pruefungen selbst.
func _wake_all_neighbours(x: int, y: int, skip_cell: int) -> void:
	var width := _width
	var states := grid.move_state
	var materials := grid.material_id
	var flags := grid.cell_flags
	var movable := _movable
	var interior := x > 0 and y > 0 and x < width - 1 and y < _height - 1
	var cell := y * width + x

	for direction in DIRECTION_COUNT:
		var neighbour: int
		if interior:
			neighbour = cell + _neighbour_offset[direction]
		else:
			var neighbour_x := x + _direction_x[direction]
			var neighbour_y := y + _direction_y[direction]
			if neighbour_x < 0 or neighbour_y < 0 or neighbour_x >= _width or neighbour_y >= _height:
				continue
			neighbour = neighbour_y * width + neighbour_x
		if neighbour == skip_cell:
			continue
		if states[neighbour] != CellGrid.MoveState.REST:
			continue
		var material := materials[neighbour]
		if material == MaterialLibrary.EMPTY_ID or movable[material] == 0:
			continue
		if (flags[neighbour] & CellGrid.FLAG_STATIC) != 0:
			continue
		states[neighbour] = CellGrid.MoveState.FALLING
		grid.wake_at(neighbour % width, neighbour / width)


## Mitreissen: nur die beiden Zellen quer zur Bewegungsrichtung, und nur wenn
## der Wurf gegen ihre Reibung ausfaellt. Sand (hohe Reibung) wird selten
## mitgerissen und behaelt dadurch stabile Boeschungen, Wasser fast immer.
func _entrain(x: int, y: int, direction: int) -> void:
	# Kein Array-Literal, siehe [method _try_slide_diagonally].
	var clockwise := (direction + TURN_SIDEWAYS_CW) % DIRECTION_COUNT
	var counter_clockwise := (direction + TURN_SIDEWAYS_CCW) % DIRECTION_COUNT
	for attempt in 2:
		var side := clockwise if attempt == 0 else counter_clockwise
		var neighbour_x := x + _direction_x[side]
		var neighbour_y := y + _direction_y[side]
		if neighbour_x < 0 or neighbour_y < 0 or neighbour_x >= _width or neighbour_y >= _height:
			continue
		var neighbour := neighbour_y * _width + neighbour_x
		if grid.move_state[neighbour] != CellGrid.MoveState.REST:
			continue
		var material := grid.material_id[neighbour]
		if material == MaterialLibrary.EMPTY_ID or _movable[material] == 0:
			continue
		if (grid.cell_flags[neighbour] & CellGrid.FLAG_STATIC) != 0:
			continue
		if (_rng.randi() & 0xFF) < _friction_u8[material]:
			continue
		grid.move_state[neighbour] = CellGrid.MoveState.FALLING
		grid.wake_at(neighbour_x, neighbour_y)

# --- Waermeleitung und Aggregatzustands-FSM ----------------------------------

## Waermeleitung ueber die vier direkten Nachbarn, gewichtet mit
## Leitfaehigkeit und Waermekapazitaet. Die Aggregatzustands-FSM wird gleich
## hier ausgewertet statt in einem zweiten Durchlauf ueber dieselben Zellen:
## Material und neue Temperatur liegen an dieser Stelle ohnehin vor, ein
## zweiter Durchlauf kostete gemessen 3,4 ms pro Frame.
func _step_heat() -> void:
	if not _any_chunk_needs_heat():
		return

	# Doppelpuffer: die Leitung muss vom Zustand des letzten Schritts lesen.
	var source := grid.celsius
	var destination := source.duplicate()
	var materials := grid.material_id
	var width := _width
	var height := _height
	var ambient := grid.ambient_celsius
	var heat_transfer := _heat_transfer
	var ambient_pull := _ambient_pull
	var emits_heat := _emits_heat
	var emit_celsius := _emit_celsius
	var emit_power := _emit_power
	var transition_start := _transition_start
	var transition_count := _transition_count
	var transition_above := _transition_above
	var transition_threshold := _transition_threshold
	var transition_target := _transition_target
	var transition_resets := _transition_resets
	var transition_result := _transition_result
	var settled_below := heat_settled_below

	for chunk_y in grid.chunks_y:
		for chunk_x in grid.chunks_x:
			var chunk := chunk_y * grid.chunks_x + chunk_x
			if grid.chunk_needs_heat[chunk] == 0:
				continue
			var left := chunk_x * grid.chunk_size
			var top := chunk_y * grid.chunk_size
			var right := mini(left + grid.chunk_size, width)
			var bottom := mini(top + grid.chunk_size, height)
			var still_hot := false

			for y in range(top, bottom):
				var row := y * width
				for x in range(left, right):
					var cell := row + x
					var material := materials[cell]
					var celsius := source[cell]

					var neighbour_sum := 0.0
					var neighbours := 0
					if x > 0:
						neighbour_sum += source[cell - 1]
						neighbours += 1
					if x < width - 1:
						neighbour_sum += source[cell + 1]
						neighbours += 1
					if y > 0:
						neighbour_sum += source[cell - width]
						neighbours += 1
					if y < height - 1:
						neighbour_sum += source[cell + width]
						neighbours += 1

					var updated := celsius + heat_transfer[material] \
						* (neighbour_sum / float(neighbours) - celsius)
					if emits_heat[material] == 1:
						updated = lerpf(updated, emit_celsius[material],
							emit_power[material])
					else:
						updated = lerpf(updated, ambient, ambient_pull[material])
					destination[cell] = updated

					# Aggregatzustands-FSM. Der Rumpf steht bewusst ausgeschrieben
					# statt in einer Hilfsfunktion: die Pruefung laeuft fuer JEDE
					# Zelle eines Materials mit Uebergaengen - also fuer jede
					# Wasserzelle - und ein GDScript-Aufruf pro Zelle kostet hier
					# mehr als die Pruefung selbst.
					var transition := transition_start[material]
					var transitions_end := transition + transition_count[material]
					while transition < transitions_end:
						var threshold := transition_threshold[transition]
						var fires := updated >= threshold \
							if transition_above[transition] == 1 else updated <= threshold
						if fires:
							_transition_cell(cell, x, y, transition_target[transition])
							# Eine optionale Zieltemperatur muss in den Doppelpuffer
							# geschrieben werden, weil das Gitter erst am Ende des
							# Passes ersetzt wird.
							if transition_resets[transition] == 1:
								destination[cell] = transition_result[transition]
							break
						transition += 1

					if absf(updated - ambient) > settled_below:
						still_hot = true
						# Waerme wandert ueber Chunkgrenzen.
						if x == left:
							grid.mark_heat_chunk(chunk_x - 1, chunk_y)
						elif x == right - 1:
							grid.mark_heat_chunk(chunk_x + 1, chunk_y)
						if y == top:
							grid.mark_heat_chunk(chunk_x, chunk_y - 1)
						elif y == bottom - 1:
							grid.mark_heat_chunk(chunk_x, chunk_y + 1)

			if still_hot:
				# Die Temperatur faerbt den ganzen Chunk, nicht nur einzelne Zellen.
				grid.mark_redraw_full(chunk)
			else:
				grid.chunk_needs_heat[chunk] = 0

	grid.celsius = destination


func _any_chunk_needs_heat() -> bool:
	for chunk in grid.chunk_count:
		if grid.chunk_needs_heat[chunk] != 0:
			return true
	return false


func _transition_cell(cell: int, x: int, y: int, target_material: int) -> void:
	var previous := grid.material_id[cell]
	grid.material_id[cell] = target_material

	# Statisch bleibt nur, was vorher statisch war UND dessen neues Material
	# statisch vorgesehen ist. Sonst wuerde erstarrende Lava mitten in der Luft
	# zu unverrueckbarem Stein und tauendes Eis zu unverrueckbarem Wasser.
	var was_static := (grid.cell_flags[cell] & CellGrid.FLAG_STATIC) != 0
	var stays_static := was_static and _starts_static[target_material] == 1
	grid.cell_flags[cell] = CellGrid.FLAG_STATIC if stays_static else 0

	grid.move_state[cell] = CellGrid.MoveState.FALLING
	grid.settle_state[cell] = 0

	# Aus einem Feststoff kann eine Fluessigkeit geworden sein oder umgekehrt.
	# Ruhende Nachbarn muessen ihre Lage neu bewerten.
	_wake_all_neighbours(x, y, -1)

	if _is_gravity_source[previous] != _is_gravity_source[target_material]:
		if _is_gravity_source[target_material] == 1:
			grid.gravity_sources[cell] = true
		else:
			grid.gravity_sources.erase(cell)
		grid.gravity_dirty = true

	grid.wake_at(x, y)
