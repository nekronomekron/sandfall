class_name Simulation
extends RefCounted

## Der Simulationsschritt. Reihenfolge pro Frame:
##   1. Gravitationsfeld neu backen, falls sich eine Quelle geaendert hat
##   2. Waermeleitung (nur thermisch aktive Chunks, alle N Frames)
##   3. Aggregatzustands-FSM (Temperaturschwellen)
##   4. Bewegungs-FSM (nur wache Chunks)
##
## RICHTUNGSUNABHAENGIGKEIT: Klassische Falling-Sand-Sims verlassen sich darauf,
## dass die Scanreihenfolge der Gravitationsrichtung entspricht. Das faellt aus,
## sobald Gravitation regional umgekehrt oder blockiert ist. Stattdessen traegt
## jede Zelle einen Generationszaehler: sie wird pro Frame hoechstens einmal
## bewegt, unabhaengig davon in welcher Reihenfolge sie besucht wird.
##
## PERFORMANCE: Materialeigenschaften liegen in flachen Lookup-Arrays (Index =
## Material-id), nicht als Property-Zugriff auf die MaterialDef-Resource.
## Property-Zugriffe auf Resources sind in GDScript um ein Vielfaches teurer und
## liegen hier im innersten Schleifenkern. Die MaterialDef bleibt die einzige
## Quelle der Wahrheit - die Arrays werden in _init() daraus abgeleitet.

const MAX_STEPS := 4          ## max. Zellen pro Frame bei verstaerkter Gravitation
const THERMAL_INTERVAL := 3   ## Waermepass nur jeden n-ten Frame
const MIN_GRAVITY := 0.06     ## darunter gilt: schwerelos, Material schwebt

## Aufbau des settle-Bytes einer Zelle (SimWorld.settle):
##   Bit 0-5  Anzahl der Richtungswechsel beim seitlichen Ausweichen
##   Bit 6    es liegt eine gemerkte Fliessrichtung vor
##   Bit 7    welche der beiden Querrichtungen gemerkt ist
##
## Gezaehlt werden bewusst nur die WECHSEL, nicht die zurueckgelegten Schritte.
## Eine Fluessigkeit, die stetig nach aussen laeuft, kehrt nie um und darf
## deshalb beliebig weit fliessen, bis sie den tiefsten Punkt erreicht hat. Nur
## wer immer wieder umkehrt - also zwischen zwei gleichwertigen Lagen hin und
## her pendelt - kommt nach SETTLE_LIMIT Wechseln zur Ruhe. Eine Begrenzung der
## Strecke statt der Wechsel liesse Fluessigkeiten mitten im Fliessen als Haufen
## stehen bleiben.
const SETTLE_COUNT_MASK := 0x3F
const SETTLE_HAS_DIR := 0x40
const SETTLE_DIR_B := 0x80

## 8 Nachbarrichtungen, im Kreis. Index = round(Winkel / 45 Grad).
## Bewusst zwei PackedInt32Arrays statt Array[Vector2i]: das Indizieren eines
## typisierten Arrays liefert eine Variant und kostet im Schleifenkern spuerbar
## mehr als ein Packed-Array-Zugriff.
## (kein const: PackedInt32Array-Literale sind in GDScript kein Konstantenausdruck)
var _dirx := PackedInt32Array([1, 1, 0, -1, -1, -1, 0, 1])
var _diry := PackedInt32Array([0, 1, 1, 1, 0, -1, -1, -1])

var world: SimWorld
var gravity := GravityField.new()

var _defs: Array[MaterialDef]
var _rng := RandomNumberGenerator.new()
var _gen: int = 1
var _flip: bool = false
var _frame: int = 0

# --- Flache Material-Lookups (Index = Material-id) ---------------------------
var _movable: PackedByteArray
var _is_gas: PackedByteArray
## Fluessigkeit oder Gas. Entscheidet, WEN ein Material verdraengen darf.
var _is_fluid: PackedByteArray
var _density: PackedFloat32Array
var _dispersion: PackedByteArray
var _conduct: PackedFloat32Array
var _ambient_k: PackedFloat32Array
var _emits: PackedByteArray
var _emit_t: PackedFloat32Array
var _emit_p: PackedFloat32Array
var _grav_src: PackedByteArray
var _has_trans: PackedByteArray
## Reibung als 0..255, damit im Schleifenkern kein Float-Vergleich noetig ist.
var _friction_u8: PackedByteArray
## Index-Offsets der 8 Nachbarn, passend zu _dirx/_diry. Erspart im Inneren des
## Gitters die Multiplikation und die Grenzpruefung pro Nachbar.
var _noff: PackedInt32Array
## Wie viele rein seitliche Ausweichschritte eine Zelle macht, bevor sie liegen
## bleibt. Aus der Reibung abgeleitet.
var _settle_limit: PackedByteArray

# Statistik fuer das HUD
var stat_awake_chunks: int = 0
var stat_moved: int = 0
var stat_grav_usec: int = 0
var stat_thermal_usec: int = 0
var stat_trans_usec: int = 0
var stat_move_usec: int = 0

func _init(w: SimWorld) -> void:
	world = w
	_defs = MaterialDB.defs()
	_rng.randomize()
	_build_lookups()
	_noff.resize(8)
	for k in range(8):
		_noff[k] = _diry[k] * w.width + _dirx[k]

func _build_lookups() -> void:
	var n := _defs.size()
	_movable.resize(n)
	_is_gas.resize(n)
	_is_fluid.resize(n)
	_density.resize(n)
	_dispersion.resize(n)
	_conduct.resize(n)
	_ambient_k.resize(n)
	_emits.resize(n)
	_emit_t.resize(n)
	_emit_p.resize(n)
	_grav_src.resize(n)
	_has_trans.resize(n)
	_friction_u8.resize(n)
	_settle_limit.resize(n)
	for i in range(n):
		var d := _defs[i]
		_movable[i] = 1 if d.is_movable() else 0
		_is_gas[i] = 1 if d.kind == MaterialDef.Kind.GAS else 0
		_is_fluid[i] = 1 if (d.kind == MaterialDef.Kind.LIQUID or d.kind == MaterialDef.Kind.GAS) else 0
		_density[i] = d.density
		_dispersion[i] = clampi(d.dispersion, 0, 255)
		# Waermekapazitaet daempft die Aenderungsrate; 0.24 ist die
		# Stabilitaetsgrenze der expliziten Waermeleitung.
		var cap := maxf(d.heat_capacity, 0.1)
		_conduct[i] = clampf(d.conductivity / cap, 0.0, 0.24)
		# Angleichung an die Umgebungstemperatur: Luft schnell, Feststoff traege.
		var base_amb := 0.02 if d.kind == MaterialDef.Kind.EMPTY else 0.002
		_ambient_k[i] = base_amb / cap
		_emits[i] = 1 if d.emits_heat else 0
		_emit_t[i] = d.emit_temp
		_emit_p[i] = d.emit_power
		_grav_src[i] = 1 if d.is_grav_source() else 0
		_has_trans[i] = 1 if not d.transitions.is_empty() else 0
		var fr := clampf(d.friction, 0.0, 1.0)
		_friction_u8[i] = int(fr * 255.0)
		# In Richtungswechseln, nicht in Schritten.
		_settle_limit[i] = clampi(roundi(lerpf(30.0, 1.0, fr)), 1, SETTLE_COUNT_MASK)

func step() -> void:
	_frame += 1
	_gen = (_gen % 250) + 1
	stat_moved = 0
	stat_grav_usec = 0
	stat_thermal_usec = 0
	stat_trans_usec = 0

	if world.gravity_dirty:
		var tg := Time.get_ticks_usec()
		gravity.rebuild(world, _defs)
		world.gravity_dirty = false
		stat_grav_usec = Time.get_ticks_usec() - tg

	if _frame % THERMAL_INTERVAL == 0:
		var tt := Time.get_ticks_usec()
		_step_thermal()
		stat_thermal_usec = Time.get_ticks_usec() - tt

	world.begin_frame()
	stat_awake_chunks = world.awake_chunk_count()
	var tm := Time.get_ticks_usec()
	_step_movement()
	stat_move_usec = Time.get_ticks_usec() - tm
	_flip = not _flip

# --- Bewegung ----------------------------------------------------------------

func _step_movement() -> void:
	var w := world
	# Chunkreihen von unten nach oben: tiefer liegende Zellen raeumen zuerst
	# Platz, das ergibt dichtere Haufen. Die Korrektheit haengt nicht daran.
	for cy in range(w.cy_count - 1, -1, -1):
		for k in range(w.cx_count):
			var cx := k
			if _flip:
				cx = w.cx_count - 1 - k
			var ci := cy * w.cx_count + cx
			if w.chunk_awake[ci] == 0:
				continue
			_step_chunk(cx, cy, ci)

## Die Vorfilterung steht bewusst inline in der Schleife statt in _update_cell:
## der weit ueberwiegende Teil eines wachen Chunks ist Luft oder ruhender
## Feststoff, und ein GDScript-Funktionsaufruf pro Zelle waere dafuer der
## teuerste Einzelposten des ganzen Frames.
func _step_chunk(cx: int, cy: int, ci: int) -> void:
	var w := world
	var b := ci * 4
	var rx0 := w.chunk_rect[b]
	var ry0 := w.chunk_rect[b + 1]
	var rx1 := w.chunk_rect[b + 2]
	var ry1 := w.chunk_rect[b + 3]
	if rx0 > rx1 or ry0 > ry1:
		return

	# Eine Zelle Sicherheitsmarge um das Dirty-Rect: Material direkt neben einer
	# Aenderung muss neu bewertet werden, etwa Sand ueber einer geraeumten Zelle.
	var cxl := cx * SimWorld.CHUNK
	var cyt := cy * SimWorld.CHUNK
	var x0 := maxi(rx0 - 1, cxl)
	var y0 := maxi(ry0 - 1, cyt)
	var x1 := mini(rx1 + 1, mini(cxl + SimWorld.CHUNK, w.width) - 1)
	var y1 := mini(ry1 + 1, mini(cyt + SimWorld.CHUNK, w.height) - 1)

	# Lokale Aliase auf die Zell-Arrays. Packed-Arrays teilen sich in GDScript
	# den Puffer, ein lokaler Alias forkt beim Schreiben nicht - Schreibzugriffe
	# ueber world bleiben also sichtbar. Member-Zugriff kostet hier gemessen das
	# 2,75-fache, und das ist der meistausgefuehrte Code im ganzen Projekt.
	var mats := w.mat
	var gens := w.gen
	var flgs := w.flags
	var stts := w.state
	var movable := _movable
	var width := w.width
	var gen_now := _gen

	for y in range(y1, y0 - 1, -1):
		var row := y * width
		if _flip:
			for x in range(x1, x0 - 1, -1):
				var i := row + x
				var m := mats[i]
				if m == 0:
					continue
				if movable[m] == 0:
					continue
				if gens[i] == gen_now:
					continue
				# Ruhende Zellen kosten ab hier nichts mehr. Sie werden erst
				# wieder betrachtet, wenn sie jemand aufweckt - weil daneben ein
				# Loch entsteht oder weil sie mitgerissen werden.
				if stts[i] == SimWorld.MoveState.REST:
					continue
				if (flgs[i] & SimWorld.F_STATIC) != 0:
					continue
				_update_cell(x, y, i, m)
		else:
			for x in range(x0, x1 + 1):
				var i := row + x
				var m := mats[i]
				if m == 0:
					continue
				if movable[m] == 0:
					continue
				if gens[i] == gen_now:
					continue
				# Ruhende Zellen kosten ab hier nichts mehr. Sie werden erst
				# wieder betrachtet, wenn sie jemand aufweckt - weil daneben ein
				# Loch entsteht oder weil sie mitgerissen werden.
				if stts[i] == SimWorld.MoveState.REST:
					continue
				if (flgs[i] & SimWorld.F_STATIC) != 0:
					continue
				_update_cell(x, y, i, m)

func _update_cell(x: int, y: int, i: int, m: int) -> void:
	var w := world
	var g := w.grav[i]
	var gx := g.x
	var gy := g.y
	# Auftrieb: Gas steigt entgegen der lokalen Gravitation - und darf dabei
	# schwerere Fluide verdraengen statt leichtere (siehe _can_displace).
	var rising := _is_gas[m] == 1
	if rising:
		gx = -gx
		gy = -gy

	# Schnellpfad fuer den Normalfall (rein vertikale Gravitation) - spart
	# atan2 und sqrt fuer die grosse Mehrheit aller Zellen.
	var di: int
	var mag: float
	if gx == 0.0:
		if gy > 0.0:
			di = 2
			mag = gy
		else:
			di = 6
			mag = -gy
	else:
		mag = sqrt(gx * gx + gy * gy)
		di = posmod(int(round(atan2(gy, gx) / (PI / 4.0))), 8)

	if mag < MIN_GRAVITY:
		# Schwerelos (z.B. im Radius eines Grav-Blockers): FSM -> REST
		w.state[i] = SimWorld.MoveState.REST
		return

	var steps := clampi(int(round(mag)), 1, MAX_STEPS)
	var dens := _density[m]

	# Lokale Aliase - siehe Begruendung in _step_chunk.
	var mats := w.mat
	var flgs := w.flags
	var gens := w.gen
	var movable := _movable
	var density := _density
	var width := w.width
	var height := w.height
	var gen_now := _gen

	# 1) Hauptrichtung. Der Einzelschritt ist ausgeschrieben statt ueber _slide
	# zu laufen: er ist der mit Abstand haeufigste Fall, und ein GDScript-
	# Funktionsaufruf kostet hier mehr als die Pruefung selbst.
	var dirx := _dirx
	var diry := _diry
	var dx := dirx[di]
	var dy := diry[di]
	var tx := x + dx
	var ty := y + dy
	if tx >= 0 and ty >= 0 and tx < width and ty < height:
		var ni := ty * width + tx
		var om := mats[ni]
		# gens[ni] != gen_now: eine Zelle, die in diesem Frame schon bewegt
		# wurde, darf nicht noch einmal verdraengt werden. Der
		# Generationszaehler hat bisher nur den Verursacher geschuetzt, nicht
		# das Verdraengte - dadurch konnte eine Dampfblase von jeder
		# nachfallenden Wasserzelle im selben Frame eine weitere Stufe
		# hochgeratscht werden und legte so eine ganze Wassersaeule in einem
		# einzigen Frame zurueck.
		if om == 0 or ((flgs[ni] & SimWorld.F_STATIC) == 0 and gens[ni] != gen_now and _can_displace(om, dens, rising)):
			if steps > 1:
				# Verstaerkte Gravitation: Pfad Zelle fuer Zelle pruefen.
				var p := _slide(x, y, dx, dy, steps, dens, rising)
				_commit(i, x, y, p.x, p.y, SimWorld.MoveState.FALLING, 0, di)
			else:
				_commit(i, x, y, tx, ty, SimWorld.MoveState.FALLING, 0, di)
			return

	# 2) Diagonal abrutschen (Schuettkegel), Seite zufaellig zuerst.
	var a := (di + 1) % 8
	var b := (di + 7) % 8
	if (_rng.randi() & 1) == 1:
		var t := a
		a = b
		b = t
	for pass_idx in 2:
		var dd := a if pass_idx == 0 else b
		var ax := x + dirx[dd]
		var ay := y + diry[dd]
		if ax < 0 or ay < 0 or ax >= width or ay >= height:
			continue
		var ni2 := ay * width + ax
		var om2 := mats[ni2]
		if om2 == 0 or ((flgs[ni2] & SimWorld.F_STATIC) == 0 and gens[ni2] != gen_now and _can_displace(om2, dens, rising)):
			# Diagonal abrutschen hat eine Komponente entlang der Gravitation,
			# zaehlt also als Fallen: der Ruhezaehler faellt zurueck auf 0.
			_commit(i, x, y, ax, ay, SimWorld.MoveState.SLIDING, 0, dd)
			return

	# 3) Fluide/Gase: senkrecht zur lokalen Gravitation ausbreiten.
	# Reibung begrenzt, wie oft eine Zelle das rein seitlich tut. Ohne diese
	# Grenze schiebt sich eine glatte Wasseroberflaeche endlos zwischen zwei
	# gleichwertigen Zustaenden hin und her und kommt nie zur Ruhe.
	var disp := _dispersion[m]
	var packed := w.settle[i]
	var turns := packed & SETTLE_COUNT_MASK
	if disp > 0 and turns < _settle_limit[m]:
		var pa := (di + 2) % 8
		var pb := (di + 6) % 8
		# Gemerkte Richtung zuerst probieren. Ohne Erinnerung entscheidet der
		# Zufall, damit ein frisch gelandeter Tropfen nicht systematisch nach
		# einer Seite driftet.
		var prefer_b := false
		if (packed & SETTLE_HAS_DIR) != 0:
			prefer_b = (packed & SETTLE_DIR_B) != 0
		else:
			prefer_b = (_rng.randi() & 1) == 1
		var first := pb if prefer_b else pa
		var second := pa if prefer_b else pb

		var q := _slide(x, y, dirx[first], diry[first], disp, dens, rising)
		if q.x != x or q.y != y:
			# Gleiche Richtung wie zuletzt: kein Wechsel, Zaehler bleibt stehen.
			var keep := turns | SETTLE_HAS_DIR
			if prefer_b:
				keep |= SETTLE_DIR_B
			# Bewusst immer SLIDING, nie direkt REST: ein seitlicher Schritt
			# kann ueber einem Loch enden, und eine sofort auf REST gesetzte
			# Zelle wuerde dort in der Luft stehen bleiben.
			_commit(i, x, y, q.x, q.y, SimWorld.MoveState.SLIDING, keep, first)
			return

		q = _slide(x, y, dirx[second], diry[second], disp, dens, rising)
		if q.x != x or q.y != y:
			# Umkehr - nur das zaehlt als Schritt Richtung Ruhezustand.
			var nt := mini(turns + 1, SETTLE_COUNT_MASK)
			var flipped := nt | SETTLE_HAS_DIR
			if not prefer_b:
				flipped |= SETTLE_DIR_B
			_commit(i, x, y, q.x, q.y, SimWorld.MoveState.SLIDING, flipped, second)
			return

	w.state[i] = SimWorld.MoveState.REST

## Laeuft bis zu `steps` Zellen in Richtung `dir` und liefert die weiteste
## erreichbare Position. Jede Zwischenzelle wird geprueft - ohne das wuerde
## verstaerkte Gravitation Material durch duenne Waende tunneln lassen.
## Darf ein Material der Dichte `dens` die Zelle mit Material `om` verdraengen?
##
## Verdraengt wird ausschliesslich in Fluiden: ein schwereres Teilchen schiebt
## sich durch eine leichtere Fluessigkeit oder ein Gas. Sand sinkt deshalb durch
## Wasser, und Wasser schiebt Dampf weg.
##
## Feste Materialien - Pulver wie Sand und Stein ebenso wie echte Feststoffe -
## werden dagegen NIE verdraengt. Sie bleiben aufeinander liegen, egal wie
## schwer das Material darueber ist. Ein Kornhaufen ist ein Gefuege, kein Bad:
## ein Steinbrocken sinkt nicht in einen Sandhaufen ein, und Lava laeuft ueber
## den Sand statt hindurch.
##
## Massgeblich ist die Bewegungsrichtung relativ zur oertlichen Gravitation:
##  - Wer MIT der Gravitation faellt, schiebt sich durch LEICHTERE Fluide.
##  - Wer GEGEN sie steigt - also Gase, deren Auftrieb die Richtung umdreht -
##    schiebt sich durch SCHWERERE Fluide. Das ist der Auftrieb: eine Dampfblase
##    unter Wasser tauscht mit dem Wasser darueber und steigt auf.
##
## Auf die Art des Verursachers kommt es sonst nicht an, nur auf das, was
## verdraengt werden soll.
func _can_displace(om: int, dens: float, rising: bool) -> bool:
	if _movable[om] == 0:
		return false
	if _is_fluid[om] == 0:
		return false
	if rising:
		return _density[om] > dens
	return _density[om] < dens

## `rising` = die Zelle bewegt sich entgegen der oertlichen Gravitation.
func _slide(x: int, y: int, dx: int, dy: int, steps: int, dens: float, rising: bool) -> Vector2i:
	var w := world
	var width := w.width
	var height := w.height
	var lx := x
	var ly := y
	for s in range(steps):
		var nx := lx + dx
		var ny := ly + dy
		if nx < 0 or ny < 0 or nx >= width or ny >= height:
			break
		var ni := ny * width + nx
		var om := w.mat[ni]
		if om == 0:
			lx = nx
			ly = ny
			continue
		if (w.flags[ni] & SimWorld.F_STATIC) != 0:
			break
		# Verdraengen nur im ERSTEN Schritt. Sonst tauscht eine Zelle, die schon
		# mehrere leere Felder weit geflogen ist, mit dem Material am Ende der
		# Bahn - und das landet dann an ihrer Startposition, also mitten in der
		# Luft. Genau so entstanden beim Lavafall einzelne Sandkoerner im
		# Nichts. Verdraengung ist nur zwischen direkten Nachbarn sinnvoll.
		if s == 0 and w.gen[ni] != _gen and _can_displace(om, dens, rising):
			lx = nx
			ly = ny
			break
		break
	return Vector2i(lx, ly)

func _commit(i: int, x: int, y: int, nx: int, ny: int, st: int, new_settle: int, di: int) -> void:
	var w := world
	var ni := ny * w.width + nx

	# Lokale Aliase - dieser Block laeuft einmal pro bewegter Zelle und ist nach
	# dem Scan der zweitheisseste Pfad der Simulation.
	var mats := w.mat
	var flgs := w.flags
	var tmps := w.temp
	var stts := w.state
	var gens := w.gen
	var setl := w.settle
	var gen_now := _gen

	var m := mats[i]
	var fl := flgs[i]
	var tp := tmps[i]
	var om := mats[ni]
	var ofl := flgs[ni]
	var otp := tmps[ni]
	var ose := setl[ni]

	mats[ni] = m
	flgs[ni] = fl
	tmps[ni] = tp
	stts[ni] = st
	setl[ni] = mini(new_settle, 255)
	gens[ni] = gen_now

	mats[i] = om
	flgs[i] = ofl
	tmps[i] = otp
	setl[i] = ose
	if om == 0:
		stts[i] = SimWorld.MoveState.REST
	else:
		stts[i] = SimWorld.MoveState.FALLING
	gens[i] = gen_now

	# Bewegliche Gravitationsquelle: Registrierung mitfuehren, Feld neu backen.
	if _grav_src[m] == 1:
		w.move_grav_source(i, ni)
	if om != 0 and _grav_src[om] == 1:
		w.move_grav_source(ni, i)

	# BEIDE Endpunkte wecken, auch innerhalb desselben Chunks. Das Dirty-Rect
	# ist eine Bounding-Box: nur die Quelle einzutragen laesst das Ziel
	# ausserhalb liegen, sobald der Schritt weiter als die 1-Zellen-Marge geht -
	# und Wasser streut bis zu `dispersion` Zellen weit. Betroffenes Material
	# bliebe dann stehen, bis es zufaellig von woanders geweckt wird.
	# Da beide Punkte in die Box eingehen, ist der gesamte Pfad abgedeckt.
	w.wake_at(x, y)
	w.wake_at(nx, ny)

	# Nur wenn wirklich ein Loch entstanden ist - bei einer Verdraengung hat sich
	# an der Unterlage der Nachbarn nichts geaendert.
	if om == 0:
		# Alle ruhenden Nachbarn muessen neu bewerten, ob sie nachrutschen. Ohne
		# Reibungswurf: fehlende Unterlage ist keine Frage der Reibung. Die
		# bewegte Zelle selbst wird ausgenommen, sonst weckt sie sich sofort
		# wieder und pendelt in ihr eigenes Loch zurueck.
		_disturb_all(x, y, ni)
	# Am Ziel zieht die vorbeigekommene Zelle an den ruhenden Zellen NEBEN ihrer
	# Bahn - dort passiert das Mitreissen. Ob sie mitgehen, entscheidet ihre
	# Reibung.
	_entrain(nx, ny, (di + 2) % 8, (di + 6) % 8)
	stat_moved += 1

## Weckt alle acht ruhenden Nachbarn. Der Rumpf steht bewusst ausgeschrieben in
## der Schleife statt in einer Hilfsfunktion: das hier laeuft acht Mal pro
## bewegter Zelle, und der Aufruf-Overhead von GDScript kostete gemessen mehr
## als die Pruefungen selbst.
func _disturb_all(x: int, y: int, skip_i: int) -> void:
	var w := world
	var width := w.width
	var stts := w.state
	var mats := w.mat
	var flgs := w.flags
	var movable := _movable
	var interior := x > 0 and y > 0 and x < width - 1 and y < w.height - 1
	var i := y * width + x
	for k in range(8):
		var ai: int
		if interior:
			ai = i + _noff[k]
		else:
			var ax := x + _dirx[k]
			var ay := y + _diry[k]
			if ax < 0 or ay < 0 or ax >= width or ay >= w.height:
				continue
			ai = ay * width + ax
		if ai == skip_i:
			continue
		if stts[ai] != SimWorld.MoveState.REST:
			continue
		var am := mats[ai]
		if am == 0 or movable[am] == 0:
			continue
		if (flgs[ai] & SimWorld.F_STATIC) != 0:
			continue
		stts[ai] = SimWorld.MoveState.FALLING
		w.wake_at(ai % width, ai / width)

## Mitreissen: nur die beiden Zellen quer zur Bewegungsrichtung, und nur wenn
## der Wurf gegen ihre Reibung ausfaellt.
func _entrain(x: int, y: int, ka: int, kb: int) -> void:
	var w := world
	var stts := w.state
	var mats := w.mat
	for k in [ka, kb]:
		var ax := x + _dirx[k]
		var ay := y + _diry[k]
		if ax < 0 or ay < 0 or ax >= w.width or ay >= w.height:
			continue
		var ai := ay * w.width + ax
		if stts[ai] != SimWorld.MoveState.REST:
			continue
		var am := mats[ai]
		if am == 0 or _movable[am] == 0:
			continue
		if (w.flags[ai] & SimWorld.F_STATIC) != 0:
			continue
		if (_rng.randi() & 255) < _friction_u8[am]:
			continue
		stts[ai] = SimWorld.MoveState.FALLING
		w.wake_at(ax, ay)

# --- Waermeleitung -----------------------------------------------------------

func _step_thermal() -> void:
	var w := world
	var active := false
	for ci in range(w.chunk_count):
		if w.chunk_thermal[ci] != 0:
			active = true
			break
	if not active:
		return

	# Doppelpuffer: Leitung muss vom Zustand des letzten Schritts lesen.
	# w.mat und w.temp werden waehrend dieses Passes nicht geschrieben, deshalb
	# duerfen sie hier lokal gecacht werden (Copy-on-Write bleibt unberuehrt).
	var src := w.temp
	var dst := src.duplicate()
	var mats := w.mat
	var width := w.width
	var height := w.height
	var ambient := SimWorld.AMBIENT

	for cy in range(w.cy_count):
		for cx in range(w.cx_count):
			var ci := cy * w.cx_count + cx
			if w.chunk_thermal[ci] == 0:
				continue
			var x0 := cx * SimWorld.CHUNK
			var y0 := cy * SimWorld.CHUNK
			var x1 := mini(x0 + SimWorld.CHUNK, width)
			var y1 := mini(y0 + SimWorld.CHUNK, height)
			var still := false
			for y in range(y0, y1):
				var row := y * width
				for x in range(x0, x1):
					var i := row + x
					var t := src[i]
					var sum := 0.0
					var cnt := 0
					if x > 0:
						sum += src[i - 1]
						cnt += 1
					if x < width - 1:
						sum += src[i + 1]
						cnt += 1
					if y > 0:
						sum += src[i - width]
						cnt += 1
					if y < height - 1:
						sum += src[i + width]
						cnt += 1
					var mm := mats[i]
					var nt := t + _conduct[mm] * (sum / float(cnt) - t)
					if _emits[mm] == 1:
						nt = lerpf(nt, _emit_t[mm], _emit_p[mm])
					else:
						nt = lerpf(nt, ambient, _ambient_k[mm])
					dst[i] = nt
					# Aggregatzustands-FSM gleich hier auswerten statt in einem
					# zweiten Durchlauf ueber dieselben Zellen: Material und
					# neue Temperatur liegen an dieser Stelle ohnehin vor.
					if _has_trans[mm] == 1:
						for tr in _defs[mm].transitions:
							var fires := false
							if tr.has("above") and nt >= float(tr["above"]):
								fires = true
							elif tr.has("below") and nt <= float(tr["below"]):
								fires = true
							if fires:
								_transition(w, i, x, y, int(tr["to"]))
								# Optionale Zieltemperatur. Muss in den
								# Doppelpuffer geschrieben werden, weil w.temp
								# erst am Ende dieses Passes ersetzt wird.
								if tr.has("temp"):
									dst[i] = float(tr["temp"])
								break
					if absf(nt - ambient) > 0.35:
						still = true
						# Waerme wandert ueber Chunkgrenzen
						if x == x0:
							w.mark_thermal_chunk(cx - 1, cy)
						elif x == x1 - 1:
							w.mark_thermal_chunk(cx + 1, cy)
						if y == y0:
							w.mark_thermal_chunk(cx, cy - 1)
						elif y == y1 - 1:
							w.mark_thermal_chunk(cx, cy + 1)
			if still:
				# Die Temperatur aendert die Faerbung im ganzen Chunk.
				w.mark_render_full(ci)
			else:
				w.chunk_thermal[ci] = 0

	w.temp = dst

# --- Aggregatzustands-FSM ----------------------------------------------------

## Wird aus _step_thermal() heraus aufgerufen, siehe dort.
func _transition(w: SimWorld, i: int, x: int, y: int, to_id: int) -> void:
	var from_id := w.mat[i]
	var nd := _defs[to_id]
	w.mat[i] = to_id
	# Statisch bleibt nur, was vorher statisch war UND dessen neues Material
	# statisch vorgesehen ist. Sonst wuerde erstarrende Lava mitten in der Luft
	# zu unverrueckbarem Stein, und tauendes Eis zu unverrueckbarem Wasser.
	var was_static := (w.flags[i] & SimWorld.F_STATIC) != 0
	if was_static and nd.default_static:
		w.flags[i] = SimWorld.F_STATIC
	else:
		w.flags[i] = 0
	w.state[i] = SimWorld.MoveState.FALLING
	w.settle[i] = 0
	# Aus einem Feststoff kann eine Fluessigkeit geworden sein (oder umgekehrt).
	# Ruhende Nachbarn muessen ihre Lage neu bewerten.
	_disturb_all(x, y, -1)
	if _grav_src[from_id] != _grav_src[to_id]:
		if _grav_src[to_id] == 1:
			w.grav_sources[i] = true
		else:
			w.grav_sources.erase(i)
		w.gravity_dirty = true
	w.wake_at(x, y)
