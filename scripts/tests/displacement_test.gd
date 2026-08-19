class_name DisplacementTest
extends RefCounted

## `-- --displacetest`: wer darf durch wen hindurch?
##
## Verdraengt wird ausschliesslich in Fluiden. Feste Materialien - Pulver wie
## Sand und Stein ebenso wie echte Feststoffe - werden NIE verdraengt: Lava
## laeuft ueber einen Sandhaufen statt hindurch, und ein Steinbrocken sinkt
## nicht darin ein.
##
## Gemessen wird mit Saeulenprofilen statt mit Summen. Summen ueber Rechtecke
## haben hier dreimal Fehlalarm ausgeloest, weil sie Material mitzaehlten, das
## seitlich am Messfenster vorbeigelaufen war.

const FLOOR_Y := 400
const FRAMES := 800


static func run(host: Node) -> void:
	print("=== Verdraengungstest ===")
	var world := TestSupport.new(host)
	_lava_on_sand_bed(world)
	_sand_in_water(world)
	_lava_falling_on_sand(world)
	_steam_bubble(world)
	print("=== fertig ===")


## Lava auf einem Sandbett muss oben aufliegen - weder fluessig noch als
## erstarrter Stein darf sie unter die Sandoberflaeche geraten.
static func _lava_on_sand_bed(world: TestSupport) -> void:
	const SAND_TOP := 380
	const BED := Rect2i(240, SAND_TOP, 140, FLOOR_Y - SAND_TOP)
	const LAVA := Rect2i(290, SAND_TOP - 14, 40, 14)
	# Dicker Boden, damit ein etwaiges Anschmelzen den Kasten nicht sofort
	# leerlaufen laesst und die Messung im Sandbett sauber bleibt.
	const FLOOR_THICKNESS := 24

	world.reset()
	world.build_box(Rect2i(240, 320, 140, FLOOR_Y - 320), world.stone, 4)
	var floor_before := world.fill(Rect2i(240, FLOOR_Y, 140, FLOOR_THICKNESS),
		world.stone, true)
	var sand_before := world.fill(BED, world.sand)
	var lava_before := world.fill(LAVA, world.lava)
	world.step(FRAMES)

	# Pro Spalte die oberste Sandzelle suchen und zaehlen, ob DARUNTER Lava oder
	# daraus erstarrter Stein liegt. Lava, die seitlich am Bett vorbei nach
	# unten gelaufen ist, zaehlt damit nicht mit.
	var deepest := 0
	var molten_intruders := 0
	var sunk_stone := 0
	for x in range(240, 380):
		var top_sand := -1
		for y in range(SAND_TOP - 20, FLOOR_Y):
			if world.material_at(x, y) == world.sand:
				top_sand = y
				break
		if top_sand < 0:
			continue
		for y in range(top_sand + 1, FLOOR_Y):
			var material := world.material_at(x, y)
			if material == world.lava:
				molten_intruders += 1
				deepest = maxi(deepest, y - top_sand)
			elif material == world.stone:
				sunk_stone += 1

	TestSupport.heading("Lava auf Sandbett - Lava soll oben aufliegen")
	print("  Saeulenprofile (Lauflaengen von oben nach unten, ab y=%d):" % (SAND_TOP - 30))
	for probe_x in [250, 300, 320, 370]:
		print("    x=%d: %s" % [probe_x,
			world.column_profile(probe_x, SAND_TOP - 30, FLOOR_Y + FLOOR_THICKNESS)])

	var floor_now := world.count_in(Rect2i(240, FLOOR_Y, 140, FLOOR_THICKNESS), world.stone)
	print("  Boden: %d von %d Steinzellen noch da (geschmolzen: %d)" % [
		floor_now, floor_before, floor_before - floor_now])
	print("  Sand weltweit: %d von %d (Erhaltung)" % [world.count(world.sand), sand_before])
	print("  Fluessige Lava unter der Sandoberflaeche: %d (tiefste %d Zellen)" % [
		molten_intruders, deepest])
	print("  Erstarrte Steinkoerner im Sand: %d (muss 0 sein)" % sunk_stone)
	print("  Bilanz: Lava %d + erstarrter Stein daraus, von %d platzierten" % [
		world.count(world.lava), lava_before])

	if molten_intruders == 0 and sunk_stone == 0:
		print("  OK: nichts sinkt in den Sand ein")
	elif molten_intruders > 0:
		print("  FEHLGESCHLAGEN: Lava %d Zellen tief im Sandbett" % deepest)
	else:
		print("  FEHLGESCHLAGEN: %d Steinkoerner in den Sand eingesunken" % sunk_stone)


## Gegenprobe: die Regel darf nicht zu scharf werden - Sand muss weiterhin
## durch Wasser auf den Grund sinken.
static func _sand_in_water(world: TestSupport) -> void:
	const POOL := Rect2i(244, 340, 132, FLOOR_Y - 340)
	const SAND := Rect2i(295, 300, 30, 20)

	world.reset()
	world.build_box(POOL, world.stone, 4)
	world.fill(POOL, world.water)
	world.fill(SAND, world.sand)
	world.step(FRAMES)

	var sand_top := 9999
	var sand_bottom := 0
	var water_top := 9999
	for y in range(280, FLOOR_Y):
		for x in range(POOL.position.x, POOL.end.x):
			var material := world.material_at(x, y)
			if material == world.sand:
				sand_top = mini(sand_top, y)
				sand_bottom = maxi(sand_bottom, y)
			elif material == world.water:
				water_top = mini(water_top, y)

	TestSupport.heading("Sand in Wasser - Sand soll absinken (Gegenprobe)")
	print("  Sand liegt bei y %d..%d, Wasseroberflaeche bei y %d" % [
		sand_top, sand_bottom, water_top])
	TestSupport.verdict(sand_bottom >= FLOOR_Y - 4 and sand_top > water_top,
		"Sand ist bis auf den Grund gesunken",
		"Sand sinkt nicht mehr durch Wasser")


## Verdraengt wird nur im ersten Schritt einer Bewegung. Sonst tauscht eine
## Zelle, die schon mehrere leere Felder weit gefallen ist, mit dem Material am
## Ende ihrer Bahn - und das landet dann mitten in der Luft.
static func _lava_falling_on_sand(world: TestSupport) -> void:
	const PILE_TOP := 370
	const PILE := Rect2i(280, PILE_TOP, 60, FLOOR_Y - PILE_TOP)
	const LAVA := Rect2i(300, 300, 20, 16)

	world.reset()
	world.fill(Rect2i(240, FLOOR_Y, 140, 6), world.stone, true)
	var sand_before := world.fill(PILE, world.sand)
	world.fill(LAVA, world.lava)

	# Waehrend des Falls pruefen, nicht nur danach: nur Koerner, unter denen
	# wirklich Luft ist. Ein Korn, das von einem absinkenden Brocken um eine
	# Zelle nach oben geschoben wurde, liegt weiter auf etwas auf.
	var floating := 0
	for frame in FRAMES:
		world.simulation.step()
		for y in range(280, PILE_TOP - 2):
			for x in range(240, 380):
				if world.material_at(x, y) == world.sand \
						and world.material_at(x, y + 1) == world.air:
					floating += 1

	var sand_after := world.count_in(Rect2i(240, 280, 140, FLOOR_Y - 280), world.sand)
	TestSupport.heading("Lava faellt auf Sandhaufen - keine Koerner in der Luft erwartet")
	print("  Sand oberhalb des Haufens (ueber alle %d Frames summiert): %d" % [FRAMES, floating])
	print("  Sand: %d von %d erhalten" % [sand_after, sand_before])
	if floating == 0 and sand_after == sand_before:
		print("  OK: keine Koerner in der Luft, Sandmenge unveraendert")
	elif floating == 0:
		print("  FEHLGESCHLAGEN: Sandmenge veraendert (%d statt %d)" % [sand_after, sand_before])
	else:
		print("  FEHLGESCHLAGEN: %d Sandvorkommen ueber dem Haufen" % floating)


## Auftrieb: eine Dampfblase am Boden einer Wassersaeule muss aufsteigen und
## darf dabei schwereres Wasser verdraengen - die Gegenrichtung zur normalen
## Regel, deshalb ein eigener Fall.
static func _steam_bubble(world: TestSupport) -> void:
	const TOP := 300
	const SHAFT := Rect2i(280, TOP, 64, FLOOR_Y - TOP)
	const BUBBLE := Rect2i(300, FLOOR_Y - 12, 24, 12)
	const BUBBLE_CELSIUS := 900.0
	const CHECKPOINTS := [20, 40, 60]
	## Der Aufstieg ist eine Zelle pro Frame, siehe Kommentar beim Urteil.
	## Etwas Luft nach unten, weil die oberste Zelle auskondensieren kann.
	const MIN_RISE := 40

	world.reset()
	world.build_box(SHAFT, world.stone, 4)
	world.fill(SHAFT, world.water)
	# Heiss genug, um waehrend des Aufstiegs Dampf zu bleiben.
	var placed := world.fill(BUBBLE, world.steam, false, BUBBLE_CELSIUS)
	var start_mean := float(FLOOR_Y - 6)

	TestSupport.heading("Dampfblase unter Wasser - Aufstieg erwartet")
	# Zwischenstaende: der Aufstieg muss gemessen werden, BEVOR die Blase im
	# kalten Wasser auskondensiert - genau das passiert nach gut hundert
	# Frames, und es ist richtig so.
	var frames_done := 0
	for checkpoint in CHECKPOINTS:
		world.step(checkpoint - frames_done)
		frames_done = checkpoint
		var measured := _measure_steam(world, SHAFT, TOP)
		print("  nach %3d Frames: %3d Dampfzellen, Mittel y %.1f, oberste y %d" % [
			checkpoint, measured.x, measured.y, measured.z])

	var final := _measure_steam(world, SHAFT, TOP)
	var count := int(final.x)
	var topmost := int(final.z)
	var risen := BUBBLE.position.y - topmost
	print("  %d von %d Dampfzellen uebrig, mittlere Hoehe y %.1f (Start %.1f)" % [
		count, placed, final.y, start_mean])

	# Gemessen wird die OBERSTE Zelle, nicht das Mittel. Die heisse Blase
	# verdampft unterwegs laufend neues Wasser an ihrer Unterseite; dieser
	# Nachschub zieht das Mittel nach unten, obwohl die Blase selbst steigt.
	# Das Mittel misst also die Waermeleitung mit, die oberste Zelle misst den
	# Auftrieb - und nur um den geht es hier.
	if count == 0:
		print("  FEHLGESCHLAGEN: Dampf komplett kondensiert, Aufstieg nicht messbar")
	elif risen >= MIN_RISE:
		print("  OK: oberste Zelle um %d Zellen gestiegen (%d Frames, y %d -> %d)" % [
			risen, CHECKPOINTS[-1], BUBBLE.position.y, topmost])
	else:
		print("  FEHLGESCHLAGEN: oberste Zelle nur um %d Zellen gestiegen" % risen)


## Liefert Anzahl, mittlere Hoehe und oberste Zeile des Dampfes.
static func _measure_steam(world: TestSupport, shaft: Rect2i, top: int) -> Vector3:
	var count := 0
	var sum_y := 0
	var topmost := 9999
	for y in range(top - 40, shaft.end.y):
		for x in range(shaft.position.x, shaft.end.x):
			if world.material_at(x, y) != world.steam:
				continue
			count += 1
			sum_y += y
			topmost = mini(topmost, y)
	return Vector3(count, float(sum_y) / float(maxi(count, 1)), topmost)
