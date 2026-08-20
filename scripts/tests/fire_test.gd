class_name FireTest
extends RefCounted

## `-- --firetest`: brennt Holz von aussen nach innen ab?
##
## Der Kern der Behauptung ist nicht "Holz verschwindet", sondern die
## RICHTUNG: eine Zelle faengt nur Feuer, wenn sie eine freie Seite hat.
## Gemessen wird deshalb der Rand gegen den Kern desselben Blocks - beide aus
## demselben Material, beide gleich heiss angefangen. Bleibt der Kern laenger
## stehen als der Rand, wandert die Front nach innen.

const FLOOR := Rect2i(240, 400, 200, 8)

## Ein Block, gross genug fuer einen messbaren Kern.
const BLOCK := Rect2i(300, 360, 24, 24)

## Wie tief der "Rand" reicht. Alles weiter innen zaehlt als Kern.
const BORDER := 3

const BURN_FRAMES := 900

## So viele Prozentpunkte muss der Kern dem Rand unterwegs mindestens
## vorausliegen, damit die Front als "nach innen wandernd" gilt.
const MIN_CORE_LEAD := 0.30


static func run(host: Node) -> void:
	print("=== Feuertest: brennt es von aussen nach innen? ===")
	var world := TestSupport.new(host)
	_wood_burns_inward(world)
	_fire_ignites_wood(world)
	_coal_and_diamond_do_not_burn(world)
	_submerged_wood_does_not_burn(world)
	_smoke_fades_without_residue(world)
	print("=== fertig ===")


## Ein Holzblock, rundum angezuendet. Der Rand muss vor dem Kern verschwinden.
static func _wood_burns_inward(world: TestSupport) -> void:
	world.reset()
	world.fill(FLOOR, world.stone, true)
	# Statisch, damit der Block nicht zusammenfaellt, waehrend er abbrennt -
	# gemessen werden soll die Brandfront, nicht das Nachrutschen.
	world.fill(BLOCK, world.wood, true, 900.0)

	var border_before := _count_ring(world, world.wood)
	var core_before := _count_core(world, world.wood)

	TestSupport.heading("Holzblock rundum angezuendet - Rand brennt vor dem Kern")
	print("  Start: Rand %d, Kern %d Zellen Holz" % [border_before, core_before])

	var coal_seen := 0
	var smoke_seen := 0
	# Der Vorsprung des Kerns waehrend des Brands ist das Mass, nicht der
	# Endstand: am Ende ist der ganze Block weg, und zwar zu Recht. Gemessen
	# wird, ob der Kern unterwegs deutlich laenger steht als der Rand.
	var widest_lead := 0.0
	var steps := BURN_FRAMES / 4
	for checkpoint in 4:
		world.step(steps)
		coal_seen = maxi(coal_seen, world.count(world.coal))
		smoke_seen = maxi(smoke_seen, world.count(world.smoke))
		var border_share := float(_count_ring(world, world.wood)) / float(maxi(border_before, 1))
		var core_share := float(_count_core(world, world.wood)) / float(maxi(core_before, 1))
		widest_lead = maxf(widest_lead, core_share - border_share)
		print("  nach %4d Frames: Rand %3d (%3.0f%%), Kern %3d (%3.0f%%), Kohle %3d, Rauch %3d" % [
			(checkpoint + 1) * steps,
			_count_ring(world, world.wood), border_share * 100.0,
			_count_core(world, world.wood), core_share * 100.0,
			world.count(world.coal), world.count(world.smoke)])

	print("  groesster Vorsprung des Kerns: %.0f Prozentpunkte" % (widest_lead * 100.0))
	if _count_ring(world, world.wood) >= border_before:
		print("  FEHLGESCHLAGEN: der Rand hat gar nicht gebrannt")
	elif widest_lead < MIN_CORE_LEAD:
		print("  FEHLGESCHLAGEN: der Kern stand nie nennenswert laenger als der Rand")
	elif coal_seen == 0:
		print("  FEHLGESCHLAGEN: keine Kohle entstanden")
	elif smoke_seen == 0:
		print("  FEHLGESCHLAGEN: kein Rauch entstanden")
	else:
		print("  OK: Front wandert nach innen, Kohle und Rauch entstehen")


## Reicht eine Flamme daneben, um Holz zu entzuenden? Das ist die Probe auf die
## Ausbreitung ueber die Waermeleitung - ohne sie waere Feuer nur Deko.
static func _fire_ignites_wood(world: TestSupport) -> void:
	world.reset()
	world.fill(FLOOR, world.stone, true)
	var wall := Rect2i(300, 360, 16, 30)
	var placed := world.fill(wall, world.wood, true)
	# Eine Reihe Flammen direkt darueber.
	world.fill(Rect2i(wall.position.x, wall.position.y - 1, wall.size.x, 1), world.fire)

	world.step(BURN_FRAMES)
	var left := world.count_in(wall, world.wood)

	TestSupport.heading("Flamme neben Holz - das Holz muss Feuer fangen")
	print("  Holz: %d von %d uebrig, Kohle %d, Rauch %d" % [
		left, placed, world.count(world.coal), world.count(world.smoke)])
	TestSupport.verdict(left < placed,
		"%d Zellen abgebrannt" % (placed - left),
		"nichts gebrannt - die Flamme bringt das Holz nicht ueber die Zuendtemperatur")


## Kohle und Diamant sind nicht brennbar. Beide werden hier so heiss
## angefangen, wie brennendes Holz waere.
static func _coal_and_diamond_do_not_burn(world: TestSupport) -> void:
	TestSupport.heading("Kohle und Diamant duerfen nicht brennen")
	for material_name in ["coal", "diamond"]:
		world.reset()
		world.fill(FLOOR, world.stone, true)
		var material := world.registry.require_id(StringName(material_name))
		var placed := world.fill(BLOCK, material, true, 900.0)
		world.step(BURN_FRAMES / 2)
		var left := world.count(material)
		print("  %-8s %d von %d Zellen uebrig" % [
			world.registry.get_material(material).display_name, left, placed])
		if left < placed:
			print("    FEHLGESCHLAGEN: %d Zellen sind verschwunden" % (placed - left))
		else:
			print("    OK: unveraendert")


## Wasser schuetzt: es hat keine freie Seite anzubieten und leitet ausserdem die
## Waerme weg. Ueber dem Becken brennt es, unten kommt nichts an.
##
## Das Holz wird bewusst NICHT gluehend platziert, sondern normal temperiert und
## von aussen beheizt - genau so, wie es im Spiel passiert. Gluehend heisses
## Holz im Wasser waere eine andere Frage: es kocht sein eigenes Wasser zu Dampf,
## und Dampf ist ein Gas, das Feuer sehr wohl heranlaesst.
static func _submerged_wood_does_not_burn(world: TestSupport) -> void:
	world.reset()
	# Flach genug, dass die Wassersaeule unter der Druckschwelle von Holz
	# bleibt - sonst presst sie das Holz zu Kohle, und der Test misst den
	# Druckpass statt das Feuer.
	var basin := Rect2i(280, 356, 80, 44)
	world.build_box(basin, world.stone, 4)
	world.fill(basin, world.water)
	# Unten im Becken, mit reichlich Wasser darueber.
	var placed := world.fill(Rect2i(300, 384, 16, 16), world.wood, true)
	# Ein Feuer auf der Wasseroberflaeche.
	world.fill(Rect2i(300, 355, 16, 1), world.fire)

	world.step(BURN_FRAMES / 2)
	var left := world.count(world.wood)

	TestSupport.heading("Holz unter Wasser, Feuer darueber - darf nicht brennen")
	print("  Holz: %d von %d uebrig" % [left, placed])
	TestSupport.verdict(left == placed,
		"unveraendert - Wasser schirmt ab und leitet die Waerme weg",
		"%d Zellen sind trotz Wasser abgebrannt" % (placed - left))


## Rauch verschwindet restlos: am Ende darf weder Rauch noch irgendein
## Rueckstand an seiner Stelle liegen.
static func _smoke_fades_without_residue(world: TestSupport) -> void:
	world.reset()
	var cloud := Rect2i(300, 300, 40, 20)
	var placed := world.fill(cloud, world.smoke)
	world.step(BURN_FRAMES)

	var smoke_left := world.count(world.smoke)
	var anything := 0
	for id in world.registry.count():
		if id != MaterialLibrary.EMPTY_ID:
			anything += world.count(id)

	TestSupport.heading("Rauch - muss restlos verschwinden")
	print("  Rauch: %d von %d uebrig, sonstiges Material in der Welt: %d" % [
		smoke_left, placed, anything])
	TestSupport.verdict(smoke_left == 0 and anything == 0,
		"vollstaendig aufgeloest, nichts bleibt zurueck",
		"es ist etwas uebrig geblieben")


## Zellen im Randstreifen des Blocks.
static func _count_ring(world: TestSupport, material: int) -> int:
	return world.count_in(BLOCK, material) - _count_core(world, material)


## Zellen im Kern, also alles weiter als BORDER von der Blockkante entfernt.
static func _count_core(world: TestSupport, material: int) -> int:
	return world.count_in(Rect2i(
		BLOCK.position.x + BORDER, BLOCK.position.y + BORDER,
		BLOCK.size.x - 2 * BORDER, BLOCK.size.y - 2 * BORDER), material)
