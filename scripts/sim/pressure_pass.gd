class_name PressurePass
extends RefCounted

## Druck: die Last des Materials, das entlang der Schwerkraft ueber einer Zelle
## liegt. Wo sie die Schwelle eines Materials ueberschreitet, waechst dessen
## Umwandlungsfortschritt - Holz wird zu Kohle, Kohle zu Diamant.
##
## WARUM DIESER AUFBAU: die Last einer Zelle haengt von allem ueber ihr ab, ein
## Chunk allein reicht dafuer nicht. Ein Sweep ueber die ganze Welt kostet aber
## gemessen 25,8 ms - pro Frame unbezahlbar und selbst als Stoss alle paar
## Frames ein sichtbarer Ruckler. Drei Dinge machen ihn bezahlbar:
##
## 1. KEIN DRUCK-ARRAY. Der Sweep laeuft ohnehin ueber jede Zelle der Spalte und
##    loest die Umwandlung gleich dort aus. Das spart ein Float je Zelle
##    (2,4 MB) und einen Schreibzugriff pro Zelle. Wer den Wert einzeln braucht -
##    HUD, Selbsttests - fragt [method CellGrid.pressure_at].
##
## 2. NUR BETROFFENE SPALTEN. Gesehen werden nur Chunk-Spalten, in denen
##    mindestens ein Chunk [member CellGrid.chunk_has_pressure] gesetzt hat, und
##    nur bis zur Unterkante des tiefsten davon. Ohne Holz oder Kohle in der
##    Welt kostet der Pass gar nichts.
##
## 3. UEBER FRAMES VERTEILT. Statt eines Stosses arbeitet jeder Frame nur
##    [member columns_per_frame] Weltspalten ab. Die Kosten sind damit konstant
##    statt stossweise; ein voller Zyklus dauert entsprechend viele Frames. Fuer
##    einen Vorgang, der ohnehin "eine gewisse Zeit" braucht, ist das kein
##    Nachteil, sondern die natuerliche Taktung.

## Dichte in "Meter Wassersaeule" umrechnen, damit im Inspektor lesbare Zahlen
## stehen statt Zehntausendern: 100 Zellen Wasser ergeben 100.
const LOAD_SCALE := 0.001

## Wie viele Weltspalten ein Frame abarbeitet.
var columns_per_frame: int = 16

# --- Statistik ---------------------------------------------------------------
var stat_columns: int = 0
var stat_usec: int = 0

## Die Weltspalten des laufenden Zyklus und, je Spalte, bis zu welcher Zeile
## gerechnet werden muss.
var _columns := PackedInt32Array()
var _bottoms := PackedInt32Array()
var _cursor: int = 0

## Chunks, in denen dieser Zyklus tatsaechlich druckempfindliches Material
## gefunden hat, und die Erwartung vom Zyklusbeginn. Aus der Differenz werden
## am Zyklusende die Flags geraeumt - aber nur die, die schon zu Beginn standen.
## Ein Flag, das mitten im Zyklus dazukommt (frisch gemaltes Holz), bleibt
## unangetastet, sonst faellt es durch und wuerde nie wieder betrachtet.
var _seen := PackedByteArray()
var _expected := PackedByteArray()

## Zellen, die umgewandelt werden sollen, als Paare (Zelle, Zielmaterial).
## Gesammelt statt sofort ausgefuehrt, damit der Sweep eine reine Leseschleife
## bleibt und [SandSimulation] die Umwandlung mit derselben Buchhaltung
## erledigt wie einen Temperaturwechsel.
var pending := PackedInt32Array()


## Ein Schritt. Liefert die Zahl der bearbeiteten Spalten.
func step(grid: CellGrid, lookups: MaterialLookups) -> void:
	var started := Time.get_ticks_usec()
	stat_columns = 0
	pending.clear()

	if _cursor >= _columns.size():
		_begin_cycle(grid)
	if _columns.is_empty():
		stat_usec = Time.get_ticks_usec() - started
		return

	var last := mini(_cursor + columns_per_frame, _columns.size())
	while _cursor < last:
		_sweep_column(grid, lookups, _columns[_cursor], _bottoms[_cursor])
		_cursor += 1
		stat_columns += 1

	if _cursor >= _columns.size():
		_end_cycle(grid)
	stat_usec = Time.get_ticks_usec() - started


## Verwirft den laufenden Zyklus. Nach einem Zuruecksetzen der Welt stimmen die
## gemerkten Spalten nicht mehr.
func reset() -> void:
	_columns.clear()
	_bottoms.clear()
	_cursor = 0
	pending.clear()


## Stellt die Arbeitsliste des Zyklus zusammen: alle Weltspalten der
## Chunk-Spalten, in denen druckempfindliches Material liegt.
func _begin_cycle(grid: CellGrid) -> void:
	_columns.clear()
	_bottoms.clear()
	_cursor = 0
	_seen.resize(grid.chunk_count)
	_seen.fill(0)
	_expected = grid.chunk_has_pressure.duplicate()

	for chunk_x in grid.chunks_x:
		var deepest := -1
		for chunk_y in grid.chunks_y:
			if grid.chunk_has_pressure[chunk_y * grid.chunks_x + chunk_x] != 0:
				deepest = chunk_y
		if deepest < 0:
			continue
		# Bis zur Unterkante des tiefsten betroffenen Chunks - was darunter
		# liegt, kann keine Umwandlung mehr ausloesen.
		var bottom := mini((deepest + 1) * grid.chunk_size, grid.height)
		var left := chunk_x * grid.chunk_size
		var right := mini(left + grid.chunk_size, grid.width)
		for x in range(left, right):
			_columns.append(x)
			_bottoms.append(bottom)


## Raeumt die Flags der Chunks, in denen dieser Zyklus nichts gefunden hat.
func _end_cycle(grid: CellGrid) -> void:
	for chunk in grid.chunk_count:
		if _expected[chunk] != 0 and _seen[chunk] == 0:
			grid.chunk_has_pressure[chunk] = 0


## Eine Weltspalte von oben nach unten: Dichten aufsummieren und unterwegs
## pruefen, ob eine Zelle unter ihrer Schwelle steht.
func _sweep_column(grid: CellGrid, lookups: MaterialLookups, x: int, bottom: int) -> void:
	# Lokale Aliase - siehe die Begruendung in [SandSimulation].
	var materials := grid.material_id
	var progress := grid.conversion_progress
	var gravity := grid.gravity
	var density := lookups.density
	var pressure_rate := lookups.pressure_rate
	var pressure_threshold := lookups.pressure_threshold
	var pressure_target := lookups.pressure_target
	var width := grid.width
	var chunks_x := grid.chunks_x
	var chunk_size := grid.chunk_size
	var chunk_column := x / chunk_size
	var check_zones := grid.has_gravity_zones
	var base_gravity := grid.base_gravity

	var load := 0.0
	var cell := x
	for y in bottom:
		var material := materials[cell]
		if material == MaterialLibrary.EMPTY_ID:
			# Eine Luecke traegt: was ueber einer Hoehle liegt, drueckt auf
			# deren Decke, nicht auf den Boden darunter.
			load = 0.0
			cell += width
			continue

		if check_zones and gravity[cell] != base_gravity:
			# Andere Schwerkraft, andere Saeule - die Last von oben gilt hier nicht.
			load = 0.0

		var rate := pressure_rate[material]
		if rate > 0:
			_seen[(y / chunk_size) * chunks_x + chunk_column] = 1
			if load >= pressure_threshold[material]:
				var advanced := progress[cell] + rate
				if advanced < 255:
					progress[cell] = advanced
				else:
					progress[cell] = 0
					pending.append(cell)
					pending.append(pressure_target[material])

		load += density[material] * LOAD_SCALE
		cell += width
