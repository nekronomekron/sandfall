class_name BenchmarkTest
extends RefCounted

## `-- --bench`: Leistungsmessung, laeuft headless.
##
## Die Szenarien sind so gebaut, dass sie sich PAARWEISE vergleichen lassen.
## Ein einzelner Stresstest sagt nur, dass es langsam ist; erst der Vergleich
## zeigt, WOVON. Deshalb gibt es dieselbe Szene je einmal mit und ohne Lava und
## einmal Lava ohne Wasser.
##
## Gemessen wird auch das Rendern, nicht nur die Simulation: der Renderer haengt
## an denselben Dirty-Rects wie die Bewegung, und lange war er der groessere
## Posten. Er bekommt dazu die Ausschnittsgroesse des Spiels, sonst wuerde er
## headless die volle Fenstergroesse hochladen.

const FLOOR := Rect2i(0, 480, 1024, 12)

## Ausschnitt wie im Spiel, siehe WorldView.level_resolution.
const VIEW := Vector2i(320, 180)

## Anteil der Messwerte, unter dem der p95-Wert liegt.
const P95 := 0.95

## Ungemessene Frames am Anfang. Der erste Frame zeichnet die ganze Welt neu
## und legt Puffer an - ohne Vorlauf steht in jedem Maximum nur dieser eine
## Ausreisser, und die Spalte sagt nichts mehr ueber den Dauerbetrieb.
const WARMUP_FRAMES := 5

## Ein Becken mit Steinwaenden, gross genug fuer ein paar tausend Zellen.
const BASIN := Rect2i(180, 400, 160, 78)
const POOL := Rect2i(180, 420, 160, 58)
const LAVA := Rect2i(230, 466, 60, 12)
const SAND_FALL := Rect2i(300, 240, 40, 40)


static func run(host: Node) -> void:
	var world := TestSupport.new(host)
	var renderer := _make_renderer(host, world)
	print("=== Sand Simulation Benchmark: %dx%d = %d Zellen, Ausschnitt %dx%d ===" % [
		world.grid.width, world.grid.height, world.grid.cell_count, VIEW.x, VIEW.y])

	_case(world, renderer, "Ruhe (nur Boden, alles gesetzt)", 200,
		func(_w: TestSupport) -> void: pass)

	_case(world, renderer, "Becken: Wasser + Sand, OHNE Lava", 400,
		func(w: TestSupport) -> void:
			w.build_box(BASIN, w.stone, 4)
			w.fill(POOL, w.water)
			w.fill(SAND_FALL, w.sand))

	_case(world, renderer, "Becken: dasselbe MIT Lava", 400,
		func(w: TestSupport) -> void:
			w.build_box(BASIN, w.stone, 4)
			w.fill(POOL, w.water)
			w.fill(SAND_FALL, w.sand)
			w.fill(LAVA, w.lava))

	_case(world, renderer, "Lava allein auf Stein, kein Wasser", 400,
		func(w: TestSupport) -> void:
			w.build_box(BASIN, w.stone, 4)
			w.fill(LAVA, w.lava))

	_case(world, renderer, "Gravitationszone (umgekehrt) mit Sand", 400,
		func(w: TestSupport) -> void:
			w.set_gravity(Rect2i(400, 300, 80, 120), Vector2.UP)
			w.fill(Rect2i(420, 400, 30, 20), w.sand))

	_case(world, renderer, "Stress: Grossblock Sand + Wasser in freiem Fall", 300,
		func(w: TestSupport) -> void:
			w.fill(Rect2i(280, 80, 150, 100), w.sand)
			w.fill(Rect2i(120, 340, 180, 80), w.water))

	print("=== fertig ===")


## Ein Renderer ohne SubViewport. Er zeichnet in seinen eigenen CPU-Puffer und
## laedt daraus einen Ausschnitt hoch - beides funktioniert auch headless.
static func _make_renderer(host: Node, world: TestSupport) -> WorldRenderer:
	var renderer := WorldRenderer.new()
	renderer.name = "BenchmarkRenderer"
	host.add_child(renderer)
	renderer.attach(world.simulation, VIEW)
	return renderer


static func _case(world: TestSupport, renderer: WorldRenderer, title: String,
		frames: int, setup: Callable) -> void:
	world.reset()
	renderer.redraw_all()
	world.fill(FLOOR, world.stone, true)
	setup.call(world)

	var samples := PackedInt32Array()
	var total_usec := 0
	var worst_usec := 0
	var heat_usec := 0
	var move_usec := 0
	var render_usec := 0
	var awake_chunks := 0
	var heat_chunks := 0
	var heat_cells := 0
	var moved := 0

	# Der Ausschnitt steht still, damit die Messung nicht von einer
	# Kamerafahrt abhaengt.
	var origin := Vector2i(160, 340)

	for warmup in WARMUP_FRAMES:
		world.simulation.step()
		renderer.redraw(origin)

	for frame in frames:
		var started := Time.get_ticks_usec()
		world.simulation.step()
		var simulated := Time.get_ticks_usec()
		renderer.redraw(origin)
		var elapsed := Time.get_ticks_usec() - started

		samples.append(elapsed)
		total_usec += elapsed
		worst_usec = maxi(worst_usec, elapsed)
		heat_usec += world.simulation.stat_heat_usec
		move_usec += world.simulation.stat_move_usec
		render_usec += Time.get_ticks_usec() - simulated
		awake_chunks += world.simulation.stat_awake_chunks
		heat_chunks += world.simulation.stat_heat_chunks
		heat_cells += world.simulation.stat_heat_cells
		moved += world.simulation.stat_moved

	var sorted_samples := Array(samples)
	sorted_samples.sort()
	var median: int = sorted_samples[sorted_samples.size() / 2]
	var p95: int = sorted_samples[int(sorted_samples.size() * P95)]
	var average := float(total_usec) / float(frames)

	TestSupport.heading("%s  (%d Frames)" % [title, frames])
	print("  gesamt   Median %6.2f ms   Mittel %6.2f ms   p95 %6.2f ms   Max %6.2f ms" % [
		median / 1000.0, average / 1000.0, p95 / 1000.0, worst_usec / 1000.0])
	print("  davon    Waerme %6.2f ms   Bewegung %6.2f ms   Rendern %6.2f ms" % [
		heat_usec / 1000.0 / frames, move_usec / 1000.0 / frames,
		render_usec / 1000.0 / frames])
	print("  je Frame wache Chunks %5.1f   Waerme-Zellen %8.0f   Bewegungen %6.1f" % [
		float(awake_chunks) / frames, float(heat_cells) / frames,
		float(moved) / frames])
