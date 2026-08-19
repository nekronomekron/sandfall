class_name LevelTest
extends RefCounted

## `-- --leveltest`: sucht Material den tiefsten Punkt?
##
## Kippt eine Saeule Material an EIN Ende einer breiten Wanne und misst danach
## das Hoehenprofil. Fluessigkeiten muessen einen flachen Spiegel bilden;
## Pulver darf und soll einen Schuettkegel bilden - deshalb laeuft Sand als
## Gegenprobe mit. Nur Materialien mit Dispersion groesser 0 durchlaufen
## ueberhaupt den seitlichen Ausweichschritt.

enum Expectation {
	MIRROR,  ## Flacher Spiegel ueber die ganze Wanne.
	SPREAD,  ## Laeuft weg, ohne dass ein Spiegel entstehen muss.
	HEAP,    ## Schuettkegel, ausdruecklich KEIN Spiegel.
}

const BASIN_LEFT := 200
const BASIN_RIGHT := 500
const FLOOR_Y := 400
const BASIN_HEIGHT := 120
const COLUMN := Rect2i(200, 300, 40, 100)
const PROFILE_DEPTH := 130

## Hoechstens so viele Zellen darf eine Spalte vom Mittel abweichen, sonst gilt
## sie als Ausreisser. Min/Max waere zu empfindlich - eine einzelne Spalte
## kippte sonst das Urteil.
const OUTLIER_TOLERANCE := 3.0

## Anteil erlaubter Ausreisser fuer einen flachen Spiegel.
const MAX_OUTLIER_SHARE := 0.05

## Ein Kegel muss mindestens so viel Hoehenunterschied haben.
const MIN_HEAP_SPREAD := 10

## Ein wegfliessendes Material muss mindestens so viel breiter werden.
const MIN_SPREAD_FACTOR := 3

# --- Gasfall -----------------------------------------------------------------
const GAS_CEILING_Y := 300
const GAS_ROOM_HEIGHT := 126
const GAS_COLUMN := Rect2i(200, 360, 30, 60)
const GAS_START_CELSIUS := 600.0
const GAS_FRAMES := 200
const GAS_MIN_COLUMNS := 60


static func run(host: Node) -> void:
	print("=== Spiegeltest: sucht Material den tiefsten Punkt? ===")
	var world := TestSupport.new(host)
	# Laufzeit je Fall unterschiedlich: Lava erstarrt unterwegs zu Stein, sie
	# muss also gemessen werden, solange sie noch fluessig ist.
	_case(world, "Wasser (Fluessigkeit) - flacher Spiegel erwartet",
		world.water, Expectation.MIRROR, 3000)
	_case(world, "Lava (erstarrt unterwegs) - Wegfliessen erwartet",
		world.lava, Expectation.SPREAD, 1200)
	_case(world, "Sand (Pulver) - Schuettkegel erwartet, KEIN Spiegel",
		world.sand, Expectation.HEAP, 3000)
	_gas_case(world)
	print("=== fertig ===")


static func _case(world: TestSupport, title: String, material: int,
		expectation: int, frames: int) -> void:
	world.reset()
	world.build_box(Rect2i(BASIN_LEFT, FLOOR_Y - BASIN_HEIGHT,
		BASIN_RIGHT - BASIN_LEFT, BASIN_HEIGHT), world.stone, 4)
	var placed := world.fill(COLUMN, material)
	world.step(frames)

	var heights := _column_heights(world, material)
	var filled_left := BASIN_RIGHT
	var filled_right := BASIN_LEFT
	var total := 0
	for index in heights.size():
		total += heights[index]
		if heights[index] > 0:
			filled_left = mini(filled_left, BASIN_LEFT + index)
			filled_right = maxi(filled_right, BASIN_LEFT + index)

	var lowest := 9999
	var highest := 0
	var columns := 0
	var sum := 0
	for index in heights.size():
		var x := BASIN_LEFT + index
		if x < filled_left or x > filled_right:
			continue
		lowest = mini(lowest, heights[index])
		highest = maxi(highest, heights[index])
		sum += heights[index]
		columns += 1
	var mean := float(sum) / float(maxi(columns, 1))

	var outliers := 0
	for index in heights.size():
		var x := BASIN_LEFT + index
		if x < filled_left or x > filled_right:
			continue
		if absf(float(heights[index]) - mean) > OUTLIER_TOLERANCE:
			outliers += 1

	TestSupport.heading(title)
	print("  nach %d Frames: %d von %d Zellen erhalten" % [frames, total, placed])
	print("  belegt x %d..%d (%d Spalten von %d), Hoehe %d..%d, Mittel %.1f" % [
		filled_left, filled_right, filled_right - filled_left + 1,
		BASIN_RIGHT - BASIN_LEFT, lowest, highest, mean])
	print("  Spalten mit mehr als %d Zellen Abweichung: %d von %d" % [
		int(OUTLIER_TOLERANCE), outliers, columns])
	print("  wache Chunks: %d" % world.simulation.stat_awake_chunks)

	_judge(world, expectation, outliers, columns, highest - lowest)


static func _judge(world: TestSupport, expectation: int, outliers: int,
		columns: int, spread: int) -> void:
	match expectation:
		Expectation.MIRROR:
			var flat := float(outliers) <= float(columns) * MAX_OUTLIER_SHARE
			if flat and world.simulation.stat_awake_chunks == 0:
				print("  OK: flacher Spiegel, zur Ruhe gekommen")
			elif flat:
				print("  OK: flacher Spiegel, noch %d Chunks in Bewegung" %
					world.simulation.stat_awake_chunks)
			else:
				print("  FEHLGESCHLAGEN: %d Spalten weichen ab - Material bleibt aufgetuermt" % outliers)
		Expectation.SPREAD:
			# Bei Lava waere ein flacher Spiegel das falsche Ziel: sie erstarrt
			# von vorne weg zu Stein und friert ihre Form dabei ein. Geprueft
			# wird nur, dass sie ueberhaupt wegfliesst.
			var start_columns := COLUMN.size.x
			TestSupport.verdict(columns >= start_columns * MIN_SPREAD_FACTOR,
				"von %d auf %d Spalten gelaufen, bevor es erstarrt" % [start_columns, columns],
				"nur %d Spalten - bleibt an der Quelle liegen" % columns)
		_:
			if spread > MIN_HEAP_SPREAD:
				print("  OK: Kegel erhalten (Pulver soll sich nicht einebnen)")
			else:
				print("  UNERWARTET: Pulver hat sich eingeebnet wie eine Fluessigkeit")


static func _column_heights(world: TestSupport, material: int) -> PackedInt32Array:
	var heights := PackedInt32Array()
	for x in range(BASIN_LEFT, BASIN_RIGHT):
		var height := 0
		for y in range(FLOOR_Y - PROFILE_DEPTH, FLOOR_Y):
			if world.material_at(x, y) == material:
				height += 1
		heights.append(height)
	return heights


## Gase laufen durch denselben Ausweich-Code, nur entgegen der Gravitation.
## Statt eines Spiegels am Boden zaehlt hier die Breite unter der Decke: bleibt
## Dampf als Saeule stehen, belegt er nur wenige Spalten.
static func _gas_case(world: TestSupport) -> void:
	world.reset()
	var room := Rect2i(BASIN_LEFT, GAS_CEILING_Y, BASIN_RIGHT - BASIN_LEFT, GAS_ROOM_HEIGHT)
	world.build_box(room, world.stone, 4)
	# Decke, damit der Dampf sich darunter ausbreiten muss statt zu entweichen.
	world.fill(Rect2i(BASIN_LEFT - 4, GAS_CEILING_Y - 6,
		BASIN_RIGHT - BASIN_LEFT + 8, 6), world.stone, true)
	# Deutlich ueber der Kondensationsschwelle platzieren, sonst ist der Dampf
	# schon wieder Wasser, bevor er sich ausbreiten konnte.
	world.fill(GAS_COLUMN, world.steam, false, GAS_START_CELSIUS)
	world.step(GAS_FRAMES)

	var columns := 0
	for x in range(BASIN_LEFT, BASIN_RIGHT):
		for y in range(GAS_CEILING_Y, GAS_CEILING_Y + GAS_ROOM_HEIGHT):
			if world.material_at(x, y) == world.steam:
				columns += 1
				break

	TestSupport.heading("Dampf (Gas) - Ausbreitung unter der Decke erwartet")
	print("  nach %d Frames: %d von %d Spalten belegt (Start: %d)" % [
		GAS_FRAMES, columns, BASIN_RIGHT - BASIN_LEFT, GAS_COLUMN.size.x])
	TestSupport.verdict(columns > GAS_MIN_COLUMNS,
		"breitet sich aus statt als Saeule stehen zu bleiben",
		"Dampf bleibt auf %d Spalten stehen" % columns)
