class_name WorldView
extends TextureRect

## Zeigt das Bild des Spiel-SubViewports an - GANZZAHLIG hochskaliert und
## zentriert.
##
## ZWEI GETRENNTE AUFLOESUNGEN, beide Pixelart:
## [br]- Die SPIELWELT rendert in einen SubViewport mit [member level_resolution]
##   (320x180) und wird hier ganzzahlig vergroessert. Das ist die groebere der
##   beiden Stufen.
## [br]- Die UI liegt darueber im Root-Viewport, dessen Aufloesung in den
##   Projekteinstellungen steht (640x360). Godot skaliert diesen ganzen Viewport
##   danach noch einmal aufs Fenster - Stretch-Modus "viewport". Die UI ist
##   damit ebenfalls Pixelart, aber doppelt so fein wie das Level, und die
##   Schrift bleibt scharf, weil sie bei 640x360 gerastert und nur noch
##   ganzzahlig vergroessert wird.
##
## Nur ganzzahlige Faktoren: jeder andere verteilt Weltpixel ungleich auf
## Bildpunkte und macht das Bild unruhig.
##
## Ausserdem die Umrechnung Fensterkoordinate -> Weltzelle, die alle
## Werkzeuge brauchen.

## Ergebnis von [method screen_to_cell], wenn der Punkt gar nicht auf der
## Spielflaeche liegt.
const OUTSIDE := Vector2i(-99999, -99999)

@export_group("Verdrahtung")

## Der SubViewport, in den die Spielwelt rendert. Im Editor zuweisen.
@export var world_viewport: SubViewport

@export_group("Aufloesung")

## Wie viele Weltzellen die Spielansicht zeigt. Bewusst NICHT aus den
## Projekteinstellungen: die beschreiben den Root-Viewport und damit die UI,
## und das Level soll ja ausdruecklich groeber sein.
##
## Sinnvoll ist ein ganzzahliger Teiler der UI-Aufloesung - bei 640x360 also
## 320x180 (Faktor 2) oder 160x90 (Faktor 4). Sonst bleibt am Rand ein
## schwarzer Streifen stehen.
@export var level_resolution := Vector2i(320, 180)

## Aktueller ganzzahliger Vergroesserungsfaktor.
var scale_factor: int = 1

## Bildschirmrechteck der hochskalierten Spielansicht.
var screen_rect := Rect2()


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stretch_mode = TextureRect.STRETCH_SCALE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Ohne IGNORE wuerde dieses Control ueber der Spielflaeche Maus-Hover und
	# _unhandled_input schlucken und damit Zeichnen und Kameraschwenk blockieren.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	world_viewport.size = view_resolution()
	texture = world_viewport.get_texture()
	get_viewport().size_changed.connect(relayout)
	relayout()


## Die interne Aufloesung der Spielwelt in Zellen.
func view_resolution() -> Vector2i:
	return level_resolution


## Groesster ganzzahliger Faktor, mit dem die Ansicht noch in den Root-Viewport
## passt. Bezugsgroesse ist der Root-Viewport, nicht das Fenster: Godot
## skaliert diesen danach noch einmal ganzzahlig aufs Fenster.
func relayout() -> void:
	var window_size := get_viewport().get_visible_rect().size
	var resolution := Vector2(world_viewport.size)
	scale_factor = maxi(mini(
		int(window_size.x / resolution.x),
		int(window_size.y / resolution.y)), 1)

	var scaled := resolution * float(scale_factor)
	var top_left := ((window_size - scaled) * 0.5).floor()
	position = top_left
	size = scaled
	screen_rect = Rect2(top_left, scaled)


## Fensterkoordinate -> Weltzelle, oder [constant OUTSIDE].
##
## Der Weg fuehrt ueber das Rechteck der hochskalierten Ansicht in
## SubViewport-Koordinaten und von dort ueber die Canvas-Transformation - also
## ueber die Kamera - in Weltkoordinaten.
func screen_to_cell(screen_position: Vector2) -> Vector2i:
	if not screen_rect.has_point(screen_position):
		return OUTSIDE
	var in_view := (screen_position - screen_rect.position) / float(scale_factor)
	var in_world := world_viewport.get_canvas_transform().affine_inverse() * in_view
	return Vector2i(floori(in_world.x), floori(in_world.y))


static func is_outside(cell: Vector2i) -> bool:
	return cell == OUTSIDE
