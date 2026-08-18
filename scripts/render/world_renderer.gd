class_name WorldRenderer
extends Sprite2D

## Zeichnet das Grid - ein Weltpixel = ein Texturpixel.
##
## Zwei Stufen, weil beide Seiten unterschiedlich teuer sind:
##
## 1. CPU-Puffer `_px` haelt die Farben der GANZEN Welt. Aktualisiert wird darin
##    nur, was sich geaendert hat (SimWorld.chunk_render). Ein voller Redraw ueber
##    589 824 Zellen waere in GDScript pro Frame unbezahlbar, ein Chunk mit 4096
##    Zellen ist es nicht.
##
## 2. Zur GPU geht nur der sichtbare Ausschnitt. Die ganze Weltentextur
##    hochzuladen kostete gemessen 17 ms pro Frame (2,4 MB), der Ausschnitt von
##    320x130 kostet ein Vierzehntel davon. Der Ausschnitt wird zeilenweise aus
##    `_px` geschnitten - `slice` und `append_array` sind nativ, eine
##    GDScript-Schleife ueber die Pixel waere hier wieder der Flaschenhals.

var world: SimWorld
var show_heat: bool = true

var view_w: int = 320
var view_h: int = 130

var _defs: Array[MaterialDef]
var _img: Image
var _tex: ImageTexture
var _px: PackedByteArray
var _grain: PackedByteArray  ## fester Rauschwert pro Zelle, damit Sand koernig wirkt
var _row_bytes: int = 0

## Flache Material-Lookups (Index = Material-id). Gleiche Begruendung wie in
## Simulation: ein Property-Zugriff auf die MaterialDef-Resource kostet im
## Schleifenkern ein Vielfaches eines Packed-Array-Zugriffs, und dieser Kern
## laeuft ueber jede Zelle jedes geaenderten Chunks.
var _col_r: PackedFloat32Array
var _col_g: PackedFloat32Array
var _col_b: PackedFloat32Array
var _grain_amt: PackedFloat32Array

const HOT := Color(1.0, 0.35, 0.08)
const COLD := Color(0.40, 0.72, 1.0)

func setup(w: SimWorld, vw: int, vh: int) -> void:
	world = w
	view_w = mini(vw, w.width)
	view_h = mini(vh, w.height)
	_row_bytes = view_w * 4
	_defs = MaterialDB.defs()
	var n := _defs.size()
	_col_r.resize(n)
	_col_g.resize(n)
	_col_b.resize(n)
	_grain_amt.resize(n)
	for i in range(n):
		_col_r[i] = _defs[i].color.r
		_col_g[i] = _defs[i].color.g
		_col_b[i] = _defs[i].color.b
		_grain_amt[i] = _defs[i].grain * 2.0
	_px.resize(w.cell_count * 4)
	_grain.resize(w.cell_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260818
	for i in range(w.cell_count):
		_grain[i] = rng.randi() & 0xFF

	var blank := PackedByteArray()
	blank.resize(view_w * view_h * 4)
	_img = Image.create_from_data(view_w, view_h, false, Image.FORMAT_RGBA8, blank)
	_tex = ImageTexture.create_from_image(_img)
	texture = _tex
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	centered = false
	redraw_all()

## Alles neu zeichnen. Muss die Rechtecke mitsetzen, nicht nur die Flags -
## sonst waeren die Chunks als schmutzig markiert, aber mit leerem Bereich.
func redraw_all() -> void:
	for ci in range(world.chunk_count):
		world.mark_render_full(ci)

## `view_x` / `view_y` ist die linke obere Ecke des sichtbaren Ausschnitts in
## Weltkoordinaten. Der Aufrufer klemmt sie so, dass das Fenster in der Welt
## liegt.
func update_dirty(view_x: int, view_y: int) -> void:
	var w := world
	# 1) Geaenderte Bereiche in den CPU-Puffer zeichnen. Nicht den ganzen Chunk:
	# das Render-Dirty-Rect grenzt es auf das ein, was sich wirklich geaendert
	# hat - bei lokaler Aktivitaet ein paar hundert statt 4096 Zellen.
	for ci in range(w.chunk_count):
		if w.chunk_render[ci] == 0:
			continue
		var b := ci * 4
		var x0 := w.chunk_render_rect[b]
		var y0 := w.chunk_render_rect[b + 1]
		var x1 := w.chunk_render_rect[b + 2]
		var y1 := w.chunk_render_rect[b + 3]
		w.clear_render_rect(ci)
		if x0 > x1 or y0 > y1:
			continue
		_draw_rect(x0, y0, x1, y1)

	# 2) Sichtbaren Ausschnitt zur GPU
	var vx := clampi(view_x, 0, w.width - view_w)
	var vy := clampi(view_y, 0, w.height - view_h)
	position = Vector2(vx, vy)

	var out := PackedByteArray()
	for row in range(view_h):
		var off := ((vy + row) * w.width + vx) * 4
		out.append_array(_px.slice(off, off + _row_bytes))
	_img.set_data(view_w, view_h, false, Image.FORMAT_RGBA8, out)
	_tex.update(_img)

## Zeichnet den Bereich (x0,y0)-(x1,y1) einschliesslich in den CPU-Puffer.
func _draw_rect(x0: int, y0: int, x1: int, y1: int) -> void:
	var w := world
	var mats := w.mat
	var temps := w.temp
	var grain := _grain
	var px := _px
	var heat := show_heat
	var col_r := _col_r
	var col_g := _col_g
	var col_b := _col_b
	var grain_amt := _grain_amt
	for y in range(y0, y1 + 1):
		var row := y * w.width
		for x in range(x0, x1 + 1):
			var i := row + x
			var m := mats[i]
			var g := (float(grain[i]) / 255.0 - 0.5) * grain_amt[m]
			var r := col_r[m] + g
			var gr := col_g[m] + g
			var b := col_b[m] + g
			if heat:
				var t := temps[i]
				if t > 45.0:
					var f := clampf((t - 45.0) / 260.0, 0.0, 0.7)
					r = lerpf(r, HOT.r, f)
					gr = lerpf(gr, HOT.g, f)
					b = lerpf(b, HOT.b, f)
				elif t < 5.0:
					var f2 := clampf((5.0 - t) / 55.0, 0.0, 0.45)
					r = lerpf(r, COLD.r, f2)
					gr = lerpf(gr, COLD.g, f2)
					b = lerpf(b, COLD.b, f2)
			var o := i * 4
			px[o] = int(clampf(r, 0.0, 1.0) * 255.0)
			px[o + 1] = int(clampf(gr, 0.0, 1.0) * 255.0)
			px[o + 2] = int(clampf(b, 0.0, 1.0) * 255.0)
			px[o + 3] = 255
