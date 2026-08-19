class_name WorldView
extends TextureRect

## Zeigt das Bild des Spiel-SubViewports im Fenster an - GANZZAHLIG
## hochskaliert und zentriert.
##
## ZWEI GETRENNTE AUFLOESUNGEN:
## [br]- Die Spielwelt rendert in einen SubViewport mit der Aufloesung aus den
##   Projekteinstellungen (Anzeige > Fenster > Groesse) und wird davon nur
##   ganzzahlig vergroessert. Nur ganzzahlig: jeder andere Faktor verteilt
##   Weltpixel ungleich auf Bildschirmpixel und macht das Bild unruhig.
## [br]- Die UI liegt darueber in der nativen Fensteraufloesung und wird gar
##   nicht skaliert. Deshalb ist der Text scharf statt hochgerechnet.
##
## Ausserdem die Umrechnung Fensterkoordinate -> Weltzelle, die alle
## Werkzeuge brauchen.

## Ergebnis von [method screen_to_cell], wenn der Punkt gar nicht auf der
## Spielflaeche liegt.
const OUTSIDE := Vector2i(-99999, -99999)

const SETTING_VIEW_WIDTH := "display/window/size/viewport_width"
const SETTING_VIEW_HEIGHT := "display/window/size/viewport_height"

@export_group("Verdrahtung")

## Der SubViewport, in den die Spielwelt rendert. Im Editor zuweisen.
@export var world_viewport: SubViewport

@export_group("Aufloesung")

## Die Aufloesung der Spielwelt aus den Projekteinstellungen uebernehmen. So
## steht die Fenster- und Ansichtsgroesse an genau einer Stelle.
@export var use_project_settings := true

## Wird nur benutzt, wenn [member use_project_settings] aus ist.
@export var view_size_override := Vector2i(576, 324)

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
	if not use_project_settings:
		return view_size_override
	return Vector2i(
		ProjectSettings.get_setting(SETTING_VIEW_WIDTH, view_size_override.x),
		ProjectSettings.get_setting(SETTING_VIEW_HEIGHT, view_size_override.y))


## Groesster ganzzahliger Faktor, mit dem die Ansicht noch ins Fenster passt.
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
