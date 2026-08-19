class_name RegressionTest
extends RefCounted

## `-- --regressiontest`: zwei gemeldete Fehler nachstellen.
##
## 1. LAVA HEIZT NICHT MEHR. Das Symptom ist nicht "wenig Dampf", sondern
##    STILLSTAND: Lava und Dampf bleiben auf einem festen Stand stehen, statt
##    zu erstarren und zu kondensieren. Ursache war das Dirty-Rect des
##    Waermepasses - eine fallende Zelle legt mehr Strecke zurueck, als das
##    Rechteck pro Durchlauf waechst, und wird thermisch unsichtbar. Geprueft
##    wird deshalb, dass sich die Mengen ueber die Zeit noch AENDERN.
##
## 2. WASSERBERGE NACH EINER VERDRAENGUNG. Sinkt Sand durch das Wasser, darf
##    die Oberflaeche danach nicht als Berg stehen bleiben. Gemessen wird die
##    Oberkante je Spalte, nicht die Wassermenge - ein Berg ist genau das:
##    unterschiedlich hohe Oberkanten.
##
##    Bewusst getrennt in zwei Sorten Faelle, weil sie verschiedene Dinge
##    pruefen:
##    [br]- VERDRAENGUNG: Sand wird mitten im ruhenden Wasser gesetzt. Danach
##      muss der Spiegel exakt flach sein - das ist der gemeldete Fehler.
##    [br]- SPRITZER: Sand faellt aus der Hoehe hinein. Dabei landet Wasser
##      oberhalb des Spiegels, und Wasser kann Wasser nicht verdraengen: es
##      kommt nur seitlich weiter, und das begrenzt das Umkehr-Budget. Was
##      bleibt, ist eine Restwelligkeit von wenigen Zellen. Die ist eine
##      bekannte Grenze und wird hier gemessen, nicht auf null gefordert.

const FLOOR_Y := 400

## Die Wanne hat Freibord: laeuft sie ueber, verfaelscht das jede Messung.
const BASIN := Rect2i(200, 300, 200, FLOOR_Y - 300)
const WATER := Rect2i(200, 340, 200, FLOOR_Y - 340)
const LAVA_BRUSH := Rect2i(280, 380, 40, 16)
const SAND_DROP := Rect2i(285, 305, 30, 20)

## Hoechstens so viele Zellen darf eine Oberkante vom Mittel abweichen.
const SURFACE_TOLERANCE := 3.0
const MAX_OUTLIERS := 8

## Ueber so viele Wuerfe wird jeder Fall gemessen. Ein einzelner Lauf schwankt
## zwischen 0 und ueber 30 Ausreissern, je nachdem wie die Zufallsentscheidungen
## fallen - daraus laesst sich nichts ableiten.
const SEEDS: Array[int] = [20260819, 7, 12345, 999, 424242]

## Restwelligkeit nach einem Spritzer, in Zellen Spanne. Gemessen wurden 9 bis
## 13; darueber waere es keine Welligkeit mehr, sondern wieder ein Berg. Die
## Stellschraube ist MAX_DIRECTION_CHANGES in MaterialLookups - ein groesseres
## Budget glaettet mehr, laesst Fluessigkeiten aber laenger schwappen.
const MAX_SPLASH_SPREAD := 20


static func run(host: Node) -> void:
	print("=== Regressionstest: gemeldete Fehler ===")
	var world := TestSupport.new(host)
	_lava_keeps_working(world)
	_water_levels_after_displacement(world)
	_solids_obey_the_static_flag(world)
	print("=== fertig ===")


## Lava wird zellweise gesetzt, so wie das Malwerkzeug es tut.
static func _lava_keeps_working(world: TestSupport) -> void:
	world.reset()
	world.build_box(BASIN, world.stone, 6)
	world.fill(WATER, world.water)

	TestSupport.heading("Lava einzeln ins Wasser gemalt - muss weiter arbeiten")
	for y in range(LAVA_BRUSH.position.y, LAVA_BRUSH.end.y):
		for x in range(LAVA_BRUSH.position.x, LAVA_BRUSH.end.x):
			world.grid.set_cell(x, y, world.lava, false)
		world.simulation.step()

	var peak_steam := 0
	var readings := []
	for sample in range(1, 8):
		world.step(150)
		var steam := world.count(world.steam)
		var lava := world.count(world.lava)
		peak_steam = maxi(peak_steam, steam)
		readings.append(Vector2i(steam, lava))
		print("  nach %4d Frames: Dampf %4d  Lava %4d  Wasser %5d" % [
			sample * 150, steam, lava, world.count(world.water)])

	# Der eigentliche Test: bewegt sich ueberhaupt noch etwas? Ein System, das
	# thermisch blind geworden ist, liefert dreimal denselben Wert.
	var last: Vector2i = readings[-1]
	var third_last: Vector2i = readings[-3]
	var frozen := last == third_last and last.x > 0
	var boiled := peak_steam > 20

	if not boiled:
		print("  FEHLGESCHLAGEN: nur %d Dampfzellen - Lava heizt das Wasser nicht auf" % peak_steam)
	elif frozen:
		print("  FEHLGESCHLAGEN: Dampf %d und Lava %d aendern sich nicht mehr - thermisch eingefroren" % [
			last.x, last.y])
	else:
		print("  OK: bis zu %d Dampfzellen, und die Mengen aendern sich weiter (Lava %d)" % [
			peak_steam, last.y])


static func _water_levels_after_displacement(world: TestSupport) -> void:
	# Der gemeldete Fehler: Sand mitten IN den ruhenden Wasserkoerper gesetzt.
	# Das Wasser wird verdraengt, ohne dass vorher etwas faellt.
	_displacement_case(world, "Sand mitten im Wasser gesetzt",
		Rect2i(270, 360, 60, 30), 0, true)
	# Derselbe Fall, nachdem Lava das Becken lange umgewaelzt hat.
	_displacement_case(world, "Sand im Wasser, nach Lava im Becken",
		Rect2i(270, 360, 60, 30), 1, true)
	# Spritzer: Sand faellt aus der Hoehe hinein, siehe Kopf der Datei.
	_displacement_case(world, "Spritzer, kleiner Sandwurf von oben", SAND_DROP, 0, false)
	_displacement_case(world, "Spritzer, grosser Sandwurf von oben",
		Rect2i(250, 302, 100, 30), 0, false)


static func _displacement_case(world: TestSupport, title: String, drop: Rect2i,
		lava_first: int, expect_flat: bool) -> void:
	TestSupport.heading("Wasserspiegel nach Verdraengung: %s" % title)
	var worst := 0
	var worst_spread := 0
	var last_profile := ""
	for seed_value in SEEDS:
		world.reseed(seed_value)
		world.build_box(BASIN, world.stone, 6)
		world.fill(WATER, world.water)
		if lava_first == 1:
			world.fill(Rect2i(280, 380, 40, 12), world.lava)
			world.step(900)
		# Erst ohne Stoerung ausgleichen lassen.
		world.step(600)

		world.fill(drop, world.sand)
		world.step(2000)
		var after := _surface_report(world)
		worst = maxi(worst, int(after.w))
		worst_spread = maxi(worst_spread, int(after.y) - int(after.x))
		# Profil der HOECHSTEN Spalte - dort sitzt der Berg, den es zu erklaeren gilt.
		var peak_x := WATER.position.x
		var peak_y := FLOOR_Y
		for x in range(WATER.position.x, WATER.end.x):
			for y in range(BASIN.position.y, FLOOR_Y):
				if world.material_at(x, y) != world.air:
					if y < peak_y:
						peak_y = y
						peak_x = x
					break
		last_profile = "x=%d (hoechste): %s" % [peak_x,
			world.column_profile(peak_x, BASIN.position.y, FLOOR_Y)]
		print("  Wurf %8d: Oberkante y %d..%d, Mittel %.1f, Ausreisser %d von %d" % [
			seed_value, after.x, after.y, after.z, after.w, WATER.size.x])
	print("    Profil %s" % last_profile)
	if expect_flat:
		TestSupport.verdict(worst <= MAX_OUTLIERS,
			"Spiegel exakt flach, schlimmstenfalls %d Ausreisser" % worst,
			"schlimmstenfalls %d Ausreisser bei %d Zellen Spanne - das Wasser bleibt als Berg stehen" % [
				worst, worst_spread])
	else:
		TestSupport.verdict(worst_spread <= MAX_SPLASH_SPREAD,
			"Restwelligkeit %d Zellen Spanne, im Rahmen des Umkehr-Budgets" % worst_spread,
			"%d Zellen Spanne - mehr als Restwelligkeit" % worst_spread)


## Ein Feststoff muss dem Static-Flag gehorchen wie jedes andere Material auch:
## mit Haken liegen bleiben, ohne Haken fallen. Und er darf dabei nicht zum
## Schuettkegel zerlaufen - das ist der Unterschied zwischen Eis und Sand.
static func _solids_obey_the_static_flag(world: TestSupport) -> void:
	const GROUND := Rect2i(200, 400, 200, 8)
	const BLOCK := Rect2i(280, 300, 20, 20)
	const DROP_FRAMES := 800

	# 1. Mit Haken: liegen bleiben.
	world.reset()
	world.fill(GROUND, world.stone, true)
	world.fill(BLOCK, world.ice, true)
	world.step(DROP_FRAMES)
	var static_top := _top_of(world, world.ice, BLOCK.position.x + 10)

	# 2. Ohne Haken: fallen.
	world.reset()
	world.fill(GROUND, world.stone, true)
	world.fill(BLOCK, world.ice, false)
	world.step(DROP_FRAMES)
	var loose_top := _top_of(world, world.ice, BLOCK.position.x + 10)
	var ice_width := _width_of(world, world.ice)

	# 3. Gegenprobe mit Sand: der muss zerlaufen, das Eis nicht.
	world.reset()
	world.fill(GROUND, world.stone, true)
	world.fill(BLOCK, world.sand, false)
	world.step(DROP_FRAMES)
	var sand_width := _width_of(world, world.sand)

	TestSupport.heading("Feststoff und Static-Flag (Eis)")
	print("  mit Haken:  Oberkante y %d (gesetzt bei y %d)" % [static_top, BLOCK.position.y])
	print("  ohne Haken: Oberkante y %d, Breite %d (gesetzt %d breit)" % [
		loose_top, ice_width, BLOCK.size.x])
	print("  Sand zum Vergleich: Breite %d" % sand_width)

	if static_top != BLOCK.position.y:
		print("  FEHLGESCHLAGEN: statisches Eis ist von y %d nach y %d gerutscht" % [
			BLOCK.position.y, static_top])
	elif loose_top <= BLOCK.position.y + 4:
		print("  FEHLGESCHLAGEN: Eis ohne Haken bleibt bei y %d liegen" % loose_top)
	elif ice_width > BLOCK.size.x + 4:
		print("  FEHLGESCHLAGEN: Eis zerlaeuft auf %d Zellen Breite" % ice_width)
	else:
		print("  OK: mit Haken fest, ohne Haken gefallen (y %d -> %d), Form erhalten (%d breit gegen %d bei Sand)" % [
			BLOCK.position.y, loose_top, ice_width, sand_width])


## Oberste Zeile, in der dieses Material in der Spalte vorkommt.
static func _top_of(world: TestSupport, material: int, x: int) -> int:
	for y in range(200, 420):
		if world.material_at(x, y) == material:
			return y
	return -1


## Wie viele Spalten das Material insgesamt belegt.
static func _width_of(world: TestSupport, material: int) -> int:
	var columns := 0
	for x in range(200, 400):
		for y in range(200, 420):
			if world.material_at(x, y) == material:
				columns += 1
				break
	return columns


## Oberkante je Spalte: die hoechste Zelle, die nicht leer ist. Genau das sieht
## man als Berg. Liefert (hoechste, tiefste, mittlere Oberkante, Ausreisser).
static func _surface_report(world: TestSupport) -> Vector4:
	var tops := PackedInt32Array()
	for x in range(WATER.position.x, WATER.end.x):
		var top := FLOOR_Y
		for y in range(BASIN.position.y, FLOOR_Y):
			if world.material_at(x, y) != world.air:
				top = y
				break
		tops.append(top)

	var highest := FLOOR_Y
	var lowest := 0
	var sum := 0
	for top in tops:
		highest = mini(highest, top)
		lowest = maxi(lowest, top)
		sum += top
	var mean := float(sum) / float(maxi(tops.size(), 1))
	var outliers := 0
	for top in tops:
		if absf(float(top) - mean) > SURFACE_TOLERANCE:
			outliers += 1
	return Vector4(highest, lowest, mean, outliers)
