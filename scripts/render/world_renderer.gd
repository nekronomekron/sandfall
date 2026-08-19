class_name WorldRenderer
extends Sprite2D

## Zeichnet das Gitter - ein Weltpixel ist ein Texturpixel.
##
## Zwei Stufen, weil beide Seiten unterschiedlich teuer sind:
##
## 1. Der CPU-Puffer haelt die Farben der GANZEN Welt. Aktualisiert wird darin
##    nur, was sich geaendert hat. Ein voller Redraw ueber eine halbe Million
##    Zellen waere in GDScript pro Frame unbezahlbar, ein einzelner Chunk nicht.
##
## 2. Zur GPU geht nur der sichtbare Ausschnitt. Die ganze Weltentextur
##    hochzuladen kostete gemessen 17 ms pro Frame, der Ausschnitt ein
##    Vierzehntel davon. Der Ausschnitt wird zeilenweise aus dem Puffer
##    geschnitten - [method PackedByteArray.slice] und
##    [method PackedByteArray.append_array] sind nativ, eine GDScript-Schleife
##    ueber die Pixel waere hier wieder der Flaschenhals.

const BYTES_PER_PIXEL := 4

@export_group("Verdrahtung")

## Welche Simulation gezeichnet wird. Im Editor zuweisen.
@export var simulation: SandSimulation

@export_group("Koernung")

## Fester Startwert, damit das Farbrauschen ueber Neustarts hinweg gleich
## aussieht - sonst flimmert ein Screenshot-Vergleich.
@export var grain_seed := 20260818

## Zeitmessung fuers HUD.
var last_draw_usec: int = 0

var _grid: CellGrid
var _lookups: MaterialLookups
var _view_size := Vector2i.ZERO
var _row_bytes := 0

var _image: Image
var _image_texture: ImageTexture
## Farben der ganzen Welt, RGBA8.
var _pixels: PackedByteArray
## Fester Rauschwert pro Zelle, damit Sand koernig statt flimmernd wirkt.
var _grain: PackedByteArray


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


## Bindet den Renderer an eine Simulation. Die Groesse des sichtbaren
## Ausschnitts kommt vom eigenen Viewport - also aus den Projekteinstellungen,
## siehe [WorldView].
##
## Wird bewusst von [Main] aufgerufen und nicht im eigenen [method Node._ready]:
## der SubViewport bekommt seine Groesse erst von [WorldView], und [Main] ist
## der einzige Knoten, dessen [method Node._ready] garantiert nach allen
## anderen laeuft.
## [param view_override] setzt die Groesse des sichtbaren Ausschnitts, statt
## sie vom eigenen Viewport zu nehmen. Der Benchmark braucht das: er laeuft
## ohne SubViewport und wuerde sonst die volle Fenstergroesse hochladen statt
## der Spielansicht.
func attach(target: SandSimulation, view_override := Vector2i.ZERO) -> void:
	simulation = target
	_grid = target.grid
	_lookups = target.registry.lookups

	var source := view_override
	if source == Vector2i.ZERO:
		source = Vector2i(get_viewport().get_visible_rect().size)
	_view_size = Vector2i(
		mini(source.x, _grid.width),
		mini(source.y, _grid.height))
	_row_bytes = _view_size.x * BYTES_PER_PIXEL

	_pixels.resize(_grid.cell_count * BYTES_PER_PIXEL)
	_build_grain()

	var blank := PackedByteArray()
	blank.resize(_view_size.x * _view_size.y * BYTES_PER_PIXEL)
	_image = Image.create_from_data(_view_size.x, _view_size.y, false,
		Image.FORMAT_RGBA8, blank)
	_image_texture = ImageTexture.create_from_image(_image)
	texture = _image_texture
	redraw_all()


func view_size() -> Vector2i:
	return _view_size


## Alles neu zeichnen. Muss die Rechtecke mitsetzen und nicht nur die Flags,
## sonst waeren die Chunks als schmutzig markiert, aber mit leerem Bereich.
func redraw_all() -> void:
	if _grid == null:
		return
	for chunk in _grid.chunk_count:
		_grid.mark_redraw_full(chunk)


## [param view_origin] ist die linke obere Ecke des sichtbaren Ausschnitts in
## Weltkoordinaten.
func redraw(view_origin: Vector2i) -> void:
	if _grid == null:
		return
	var started := Time.get_ticks_usec()
	_refresh_dirty_chunks()
	_upload_visible_window(view_origin)
	last_draw_usec = Time.get_ticks_usec() - started


## Geaenderte Bereiche in den CPU-Puffer zeichnen. Nicht den ganzen Chunk: das
## Redraw-Rechteck grenzt es auf das ein, was sich wirklich geaendert hat.
func _refresh_dirty_chunks() -> void:
	for chunk in _grid.chunk_count:
		if _grid.chunk_needs_redraw[chunk] == 0:
			continue
		var base := chunk * CellGrid.BOUNDS_STRIDE
		var left := _grid.redraw_bounds[base]
		var top := _grid.redraw_bounds[base + 1]
		var right := _grid.redraw_bounds[base + 2]
		var bottom := _grid.redraw_bounds[base + 3]
		_grid.clear_redraw_bounds(chunk)
		if left > right or top > bottom:
			continue
		_draw_area(left, top, right, bottom)


func _upload_visible_window(view_origin: Vector2i) -> void:
	var origin_x := clampi(view_origin.x, 0, _grid.width - _view_size.x)
	var origin_y := clampi(view_origin.y, 0, _grid.height - _view_size.y)
	position = Vector2(origin_x, origin_y)

	var window := PackedByteArray()
	for row in _view_size.y:
		var offset := ((origin_y + row) * _grid.width + origin_x) * BYTES_PER_PIXEL
		window.append_array(_pixels.slice(offset, offset + _row_bytes))
	_image.set_data(_view_size.x, _view_size.y, false, Image.FORMAT_RGBA8, window)
	_image_texture.update(_image)


## Zeichnet den Bereich einschliesslich beider Ecken in den CPU-Puffer.
func _draw_area(left: int, top: int, right: int, bottom: int) -> void:
	# Lokale Aliase auf alles, was hier im Schleifenkern liegt. Der groesste
	# Einzelposten des Renderns war gemessen nicht der Texturupload, sondern
	# genau diese Zugriffe.
	var materials := _grid.material_id
	var grain := _grain
	var pixels := _pixels
	var width := _grid.width
	var color_red := _lookups.color_red
	var color_green := _lookups.color_green
	var color_blue := _lookups.color_blue
	var grain_amount := _lookups.grain_amount

	for y in range(top, bottom + 1):
		var row := y * width
		for x in range(left, right + 1):
			var cell := row + x
			var material := materials[cell]
			var noise := (float(grain[cell]) / 255.0 - 0.5) * grain_amount[material]
			var red := color_red[material] + noise
			var green := color_green[material] + noise
			var blue := color_blue[material] + noise

			var offset := cell * BYTES_PER_PIXEL
			pixels[offset] = int(clampf(red, 0.0, 1.0) * 255.0)
			pixels[offset + 1] = int(clampf(green, 0.0, 1.0) * 255.0)
			pixels[offset + 2] = int(clampf(blue, 0.0, 1.0) * 255.0)
			pixels[offset + 3] = 255


func _build_grain() -> void:
	_grain.resize(_grid.cell_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = grain_seed
	for cell in _grid.cell_count:
		_grain[cell] = rng.randi() & 0xFF
