class_name GravityField
extends RefCounted

## Baut das gecachte Gravitationsfeld (SimWorld.grav) aus den abstrahlenden
## Materialzellen.
##
## WANN: nur wenn sich eine Quelle geaendert hat - gesetzt, geloescht oder
## bewegt. Statische Quellen kosten nach dem Platzieren null, bewegliche nur
## solange sie tatsaechlich fallen.
##
## WIE: nicht pro Quellzelle einen Radius-Kreis stempeln - das waere
## O(Quellen x Flaeche) und damit quadratisch in der Pinselgroesse (gemessen:
## ~98 ms fuer einen 10x10-Block mit Radius 44). Stattdessen pro Materialtyp
## eine Chamfer-Distanztransformation ueber das Einflussrechteck: zwei Durchlaeufe,
## O(Flaeche), unabhaengig davon wie viele Quellzellen es sind. Der Feldwert
## einer Zelle haengt danach nur noch von der Distanz zur naechsten Quelle ab.
##
## UEBERLAGERUNG: multiplikative Faktoren mehrerer Materialtypen werden
## distanzgewichtet eingeblendet, additive Anteile aufsummiert. Ein Blocker
## (Faktor 0) zieht den Betrag in seinem Radius gegen 0, ein Umkehrer (-1)
## dreht die Richtung, ein Verstaerker (3) erhoeht den Betrag.

const BASE := Vector2(0.0, 1.0)

# Chamfer-Gewichte 3-4: orthogonaler Schritt 3, diagonaler 4. Die echte Distanz
# ist der Wert geteilt durch 3, mit ca. 8 % Fehler gegenueber Euklid - fuer eine
# Feldabschwaechung mehr als genau genug und ohne sqrt pro Zelle.
const STEP_ORTHO := 3.0
const STEP_DIAG := 4.0
const FAR := 1.0e9

var _prev_rect := Rect2i()

func rebuild(w: SimWorld, defs: Array[MaterialDef]) -> void:
	var new_rect := _influence_rect(w, defs)
	var work := _union(_prev_rect, new_rect)
	_prev_rect = new_rect
	if work.size.x <= 0 or work.size.y <= 0:
		return

	var rx := work.position.x
	var ry := work.position.y
	var rw := work.size.x
	var rh := work.size.y
	var width := w.width
	var grav := w.grav

	# Quellen nach Materialtyp gruppieren - je Typ eine Distanztransformation.
	var by_mat := {}
	for key in w.grav_sources:
		var si: int = key
		var mid := w.mat[si]
		if mid >= defs.size() or not defs[mid].is_grav_source():
			continue
		if not by_mat.has(mid):
			by_mat[mid] = PackedInt32Array()
		by_mat[mid].append(si)

	if by_mat.is_empty():
		# Keine Quellen mehr: Arbeitsbereich auf Grundgravitation zuruecksetzen.
		for yy in range(rh):
			var row := (ry + yy) * width + rx
			for xx in range(rw):
				grav[row + xx] = BASE
		_wake(w, work)
		return

	var cells := rw * rh
	var scale := PackedFloat32Array()
	scale.resize(cells)
	scale.fill(1.0)
	var addv := PackedVector2Array()
	addv.resize(cells)
	var dist := PackedFloat32Array()
	dist.resize(cells)

	for key in by_mat:
		var mid: int = key
		var d := defs[mid]
		var radius := float(d.grav_radius)
		if radius <= 0.0:
			continue
		_distance_transform(dist, by_mat[mid], rx, ry, rw, rh, width)
		var factor := d.grav_factor
		var av := d.grav_add
		var has_add := av != Vector2.ZERO
		var max_d := radius * STEP_ORTHO
		# Plateau: volle Wirkung bis grav_plateau * radius, danach Rampe.
		var ramp := maxf(1.0 - clampf(d.grav_plateau, 0.0, 0.95), 0.05)
		for j in range(cells):
			var dv := dist[j]
			if dv >= max_d:
				continue
			var weight := clampf((1.0 - dv / max_d) / ramp, 0.0, 1.0)
			scale[j] = lerpf(scale[j], scale[j] * factor, weight)
			if has_add:
				addv[j] += av * weight

	for yy in range(rh):
		var row := (ry + yy) * width + rx
		var jrow := yy * rw
		for xx in range(rw):
			grav[row + xx] = (BASE + addv[jrow + xx]) * scale[jrow + xx]

	_wake(w, work)

## Zwei-Pass-Chamfer-Distanztransformation ueber das Arbeitsrechteck.
## Ergebnis in `dist`, Einheit: Chamfer-Schritte (echte Distanz = Wert / 3).
func _distance_transform(dist: PackedFloat32Array, sources: PackedInt32Array,
		rx: int, ry: int, rw: int, rh: int, width: int) -> void:
	dist.fill(FAR)
	for si in sources:
		var sx := si % width
		var sy := si / width
		var lx := sx - rx
		var ly := sy - ry
		if lx < 0 or ly < 0 or lx >= rw or ly >= rh:
			continue
		dist[ly * rw + lx] = 0.0

	# Vorwaerts: oben-links nach unten-rechts
	for yy in range(rh):
		var row := yy * rw
		var prow := row - rw
		for xx in range(rw):
			var j := row + xx
			var v := dist[j]
			if v == 0.0:
				continue
			if xx > 0:
				var c := dist[j - 1] + STEP_ORTHO
				if c < v:
					v = c
			if yy > 0:
				var c2 := dist[prow + xx] + STEP_ORTHO
				if c2 < v:
					v = c2
				if xx > 0:
					var c3 := dist[prow + xx - 1] + STEP_DIAG
					if c3 < v:
						v = c3
				if xx < rw - 1:
					var c4 := dist[prow + xx + 1] + STEP_DIAG
					if c4 < v:
						v = c4
			dist[j] = v

	# Rueckwaerts: unten-rechts nach oben-links
	for yy in range(rh - 1, -1, -1):
		var row := yy * rw
		var nrow := row + rw
		for xx in range(rw - 1, -1, -1):
			var j := row + xx
			var v := dist[j]
			if v == 0.0:
				continue
			if xx < rw - 1:
				var c := dist[j + 1] + STEP_ORTHO
				if c < v:
					v = c
			if yy < rh - 1:
				var c2 := dist[nrow + xx] + STEP_ORTHO
				if c2 < v:
					v = c2
				if xx < rw - 1:
					var c3 := dist[nrow + xx + 1] + STEP_DIAG
					if c3 < v:
						v = c3
				if xx > 0:
					var c4 := dist[nrow + xx - 1] + STEP_DIAG
					if c4 < v:
						v = c4
			dist[j] = v

func _wake(w: SimWorld, work: Rect2i) -> void:
	# In den betroffenen Chunks gelten jetzt andere Bewegungsregeln - hier ist
	# "unten" moeglicherweise woanders als vorher. Ruhende Zellen muessen daher
	# zurueck in den aktiven Zustand, sonst bleiben sie in einer Lage liegen,
	# die unter dem neuen Feld gar nicht mehr stabil ist.
	w.revive_region(work.position.x, work.position.y,
		work.position.x + work.size.x - 1, work.position.y + work.size.y - 1)
	var cx0 := work.position.x / SimWorld.CHUNK
	var cy0 := work.position.y / SimWorld.CHUNK
	var cx1 := (work.position.x + work.size.x - 1) / SimWorld.CHUNK
	var cy1 := (work.position.y + work.size.y - 1) / SimWorld.CHUNK
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			w.wake_chunk(cx, cy)

func _influence_rect(w: SimWorld, defs: Array[MaterialDef]) -> Rect2i:
	if w.grav_sources.is_empty():
		return Rect2i()
	var minx := w.width
	var miny := w.height
	var maxx := -1
	var maxy := -1
	for key in w.grav_sources:
		var si: int = key
		var mid := w.mat[si]
		if mid >= defs.size():
			continue
		var d := defs[mid]
		if not d.is_grav_source():
			continue
		var r := d.grav_radius
		var sx := si % w.width
		var sy := si / w.width
		minx = mini(minx, sx - r)
		miny = mini(miny, sy - r)
		maxx = maxi(maxx, sx + r + 1)
		maxy = maxi(maxy, sy + r + 1)
	if maxx < 0:
		return Rect2i()
	minx = maxi(minx, 0)
	miny = maxi(miny, 0)
	maxx = mini(maxx, w.width)
	maxy = mini(maxy, w.height)
	return Rect2i(minx, miny, maxi(maxx - minx, 0), maxi(maxy - miny, 0))

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

func reset() -> void:
	_prev_rect = Rect2i()
