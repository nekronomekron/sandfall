class_name GravityField
extends Node

## Backt das gecachte Gravitationsfeld ([member CellGrid.gravity]) aus den
## abstrahlenden Materialzellen.
##
## WANN: nur wenn sich eine Quelle geaendert hat - gesetzt, geloescht oder
## bewegt. Statische Quellen kosten nach dem Platzieren nichts, bewegliche nur
## solange sie tatsaechlich fallen.
##
## WIE: nicht pro Quellzelle einen Radius-Kreis stempeln - das waere
## O(Quellen x Flaeche) und damit quadratisch in der Pinselgroesse (gemessen
## rund 98 ms fuer einen 10x10-Block mit Radius 44). Stattdessen pro Materialtyp
## eine Chamfer-Distanztransformation ueber das Einflussrechteck: zwei
## Durchlaeufe, O(Flaeche), unabhaengig von der Zahl der Quellzellen.
##
## UEBERLAGERUNG: multiplikative Faktoren mehrerer Materialtypen werden
## distanzgewichtet eingeblendet, additive Anteile aufsummiert. Ein Blocker
## (Faktor 0) zieht den Betrag in seinem Radius gegen 0, ein Umkehrer (-1)
## dreht die Richtung, ein Verstaerker (3) erhoeht den Betrag.

## Chamfer-Gewichte 3-4: ein orthogonaler Schritt zaehlt 3, ein diagonaler 4.
## Die echte Distanz ist der Wert geteilt durch 3, mit rund 8 Prozent Fehler
## gegenueber Euklid - fuer eine Feldabschwaechung mehr als genau genug und
## ohne Wurzel pro Zelle.
const CHAMFER_ORTHOGONAL := 3.0
const CHAMFER_DIAGONAL := 4.0

## Startwert der Distanztransformation, praktisch unendlich.
const DISTANCE_UNREACHED := 1.0e9

## Untergrenze fuer die Rampenbreite, damit ein Plateau von 1.0 nicht durch
## Null teilt.
const MIN_RAMP := 0.05

## Die Grundgravitation, die ueberall gilt, wo kein Feld wirkt.
@export var base_gravity := Vector2.DOWN

## Das zuletzt bearbeitete Rechteck. Es muss beim naechsten Mal mit
## aufgeraeumt werden, sonst bleiben alte Feldwerte stehen, wenn eine Quelle
## verschwindet.
var _previous_rect := Rect2i()


func reset() -> void:
	_previous_rect = Rect2i()


func rebuild(grid: CellGrid, library: MaterialLibrary) -> void:
	var current_rect := _influence_rect(grid, library)
	var work := _union(_previous_rect, current_rect)
	_previous_rect = current_rect
	if work.size.x <= 0 or work.size.y <= 0:
		return

	var sources_by_material := _group_sources(grid, library)
	if sources_by_material.is_empty():
		_fill_with_base_gravity(grid, work)
		_wake(grid, work)
		return

	var cells := work.size.x * work.size.y
	var scale := PackedFloat32Array()
	scale.resize(cells)
	scale.fill(1.0)
	var offset := PackedVector2Array()
	offset.resize(cells)
	var distance := PackedFloat32Array()
	distance.resize(cells)

	for key in sources_by_material:
		var material_id: int = key
		var material := library.get_material(material_id)
		if material.gravity_radius <= 0:
			continue
		var sources: PackedInt32Array = sources_by_material[material_id]
		_distance_transform(distance, sources, work, grid.width)
		_blend_material(scale, offset, distance, material, cells)

	_write_field(grid, work, scale, offset)
	_wake(grid, work)


## Quellen nach Materialtyp gruppieren - je Typ eine Distanztransformation.
func _group_sources(grid: CellGrid, library: MaterialLibrary) -> Dictionary:
	var by_material := {}
	for key in grid.gravity_sources:
		var cell: int = key
		var material_id: int = grid.material_id[cell]
		if material_id >= library.size():
			continue
		if not library.get_material(material_id).is_gravity_source():
			continue
		if not by_material.has(material_id):
			by_material[material_id] = PackedInt32Array()
		by_material[material_id].append(cell)
	return by_material


## Blendet einen Materialtyp distanzgewichtet in Skalierung und Versatz ein.
func _blend_material(scale: PackedFloat32Array, offset: PackedVector2Array,
		distance: PackedFloat32Array, material: SandMaterial, cells: int) -> void:
	var max_distance := float(material.gravity_radius) * CHAMFER_ORTHOGONAL
	# Plateau: volle Wirkung bis Plateau * Radius, danach eine Rampe zurueck
	# auf die Grundgravitation.
	var ramp := maxf(1.0 - clampf(material.gravity_plateau, 0.0, 0.95), MIN_RAMP)
	var has_offset := material.gravity_offset != Vector2.ZERO

	for index in cells:
		var to_source := distance[index]
		if to_source >= max_distance:
			continue
		var weight := clampf((1.0 - to_source / max_distance) / ramp, 0.0, 1.0)
		scale[index] = lerpf(scale[index], scale[index] * material.gravity_factor, weight)
		if has_offset:
			offset[index] += material.gravity_offset * weight


func _write_field(grid: CellGrid, work: Rect2i, scale: PackedFloat32Array,
		offset: PackedVector2Array) -> void:
	for local_y in work.size.y:
		var row := (work.position.y + local_y) * grid.width + work.position.x
		var local_row := local_y * work.size.x
		for local_x in work.size.x:
			grid.gravity[row + local_x] = (base_gravity + offset[local_row + local_x]) \
				* scale[local_row + local_x]


func _fill_with_base_gravity(grid: CellGrid, work: Rect2i) -> void:
	for local_y in work.size.y:
		var row := (work.position.y + local_y) * grid.width + work.position.x
		for local_x in work.size.x:
			grid.gravity[row + local_x] = base_gravity


## Zwei-Pass-Chamfer-Distanztransformation ueber das Arbeitsrechteck. Ergebnis
## in [param distance], Einheit: Chamfer-Schritte.
func _distance_transform(distance: PackedFloat32Array, sources: PackedInt32Array,
		work: Rect2i, world_width: int) -> void:
	var width := work.size.x
	var height := work.size.y
	distance.fill(DISTANCE_UNREACHED)
	for cell in sources:
		var local_x := cell % world_width - work.position.x
		var local_y := cell / world_width - work.position.y
		if local_x < 0 or local_y < 0 or local_x >= width or local_y >= height:
			continue
		distance[local_y * width + local_x] = 0.0

	# Vorwaerts: von oben links nach unten rechts.
	for y in height:
		var row := y * width
		var previous_row := row - width
		for x in width:
			var index := row + x
			var best := distance[index]
			if best == 0.0:
				continue
			if x > 0:
				best = minf(best, distance[index - 1] + CHAMFER_ORTHOGONAL)
			if y > 0:
				best = minf(best, distance[previous_row + x] + CHAMFER_ORTHOGONAL)
				if x > 0:
					best = minf(best, distance[previous_row + x - 1] + CHAMFER_DIAGONAL)
				if x < width - 1:
					best = minf(best, distance[previous_row + x + 1] + CHAMFER_DIAGONAL)
			distance[index] = best

	# Rueckwaerts: von unten rechts nach oben links.
	for y in range(height - 1, -1, -1):
		var row := y * width
		var next_row := row + width
		for x in range(width - 1, -1, -1):
			var index := row + x
			var best := distance[index]
			if best == 0.0:
				continue
			if x < width - 1:
				best = minf(best, distance[index + 1] + CHAMFER_ORTHOGONAL)
			if y < height - 1:
				best = minf(best, distance[next_row + x] + CHAMFER_ORTHOGONAL)
				if x < width - 1:
					best = minf(best, distance[next_row + x + 1] + CHAMFER_DIAGONAL)
				if x > 0:
					best = minf(best, distance[next_row + x - 1] + CHAMFER_DIAGONAL)
			distance[index] = best


## In den betroffenen Chunks gelten jetzt andere Bewegungsregeln - hier ist
## "unten" moeglicherweise woanders als vorher. Ruhende Zellen muessen deshalb
## zurueck in den aktiven Zustand, sonst bleiben sie in einer Lage liegen, die
## unter dem neuen Feld gar nicht mehr stabil ist.
func _wake(grid: CellGrid, work: Rect2i) -> void:
	var right := work.position.x + work.size.x - 1
	var bottom := work.position.y + work.size.y - 1
	grid.wake_region(work.position.x, work.position.y, right, bottom)
	for chunk_y in range(work.position.y / grid.chunk_size, bottom / grid.chunk_size + 1):
		for chunk_x in range(work.position.x / grid.chunk_size, right / grid.chunk_size + 1):
			grid.wake_chunk(chunk_x, chunk_y)


## Das Rechteck, in dem ueberhaupt Quellen wirken koennen.
func _influence_rect(grid: CellGrid, library: MaterialLibrary) -> Rect2i:
	if grid.gravity_sources.is_empty():
		return Rect2i()
	var left := grid.width
	var top := grid.height
	var right := -1
	var bottom := -1
	for key in grid.gravity_sources:
		var cell: int = key
		var material_id: int = grid.material_id[cell]
		if material_id >= library.size():
			continue
		var material := library.get_material(material_id)
		if not material.is_gravity_source():
			continue
		var radius := material.gravity_radius
		var x := cell % grid.width
		var y := cell / grid.width
		left = mini(left, x - radius)
		top = mini(top, y - radius)
		right = maxi(right, x + radius + 1)
		bottom = maxi(bottom, y + radius + 1)
	if right < 0:
		return Rect2i()
	left = maxi(left, 0)
	top = maxi(top, 0)
	right = mini(right, grid.width)
	bottom = mini(bottom, grid.height)
	return Rect2i(left, top, maxi(right - left, 0), maxi(bottom - top, 0))


func _union(a: Rect2i, b: Rect2i) -> Rect2i:
	var a_empty := a.size.x <= 0 or a.size.y <= 0
	var b_empty := b.size.x <= 0 or b.size.y <= 0
	if a_empty and b_empty:
		return Rect2i()
	if a_empty:
		return b
	if b_empty:
		return a
	return a.merge(b)
