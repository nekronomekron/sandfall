class_name SandMaterial
extends Resource

## Ein Materialtyp. Es existiert genau eine Instanz pro Typ, niemals eine pro
## Pixel: das Gitter speichert nur die numerische [member id].
##
## NEUES MATERIAL: eine neue .tres-Datei unter res://resources/materials/
## anlegen, dieses Skript als Resource-Typ waehlen, ausfuellen und in die Liste
## von res://resources/material_library.tres eintragen. Sonst ist nichts zu
## tun - Toolbar, Renderer und Simulation lesen alles aus diesen
## Eigenschaften.
##
## NEUE EIGENSCHAFT: hier ein @export ergaenzen und dort auswerten, wo sie
## wirkt. Liegt sie im Schleifenkern von Bewegung, Waerme oder Renderer, gehoert
## sie zusaetzlich in [MaterialLookups] - Property-Zugriffe auf eine Resource
## kosten in GDScript ein Vielfaches eines Packed-Array-Zugriffs.

enum Phase {
	EMPTY,   ## Luft. Bewegt sich nicht, wird von allem verdraengt.
	SOLID,   ## Faellt entlang der Gravitation, rutscht aber NICHT ab. Ein Block
	         ## behaelt so seine Form und stapelt sich in Saeulen, statt zu
	         ## einem Kegel zu zerlaufen (Eis).
	POWDER,  ## Faellt entlang der Gravitation und rutscht diagonal ab (Sand, Stein).
	LIQUID,  ## Wie POWDER, breitet sich zusaetzlich senkrecht zur Gravitation aus.
	GAS,     ## Wie LIQUID, aber ENTGEGEN der Gravitation (Auftrieb).
}

@export_group("Identitaet")

## Eindeutiger Schluessel, ueber den andere Resourcen dieses Material
## ansprechen - etwa [member MaterialTransition.becomes]. Klein und ohne
## Leerzeichen, z.B. &"water".
@export var material_name: StringName = &""

## Beschriftung in Toolbar und HUD.
@export var display_name: String = ""

## Taucht das Material als Knopf in der Toolbar auf?
@export var selectable: bool = true

## Abweichende Beschriftung des Toolbar-Knopfes. Leer = [member display_name].
## Das leere Material heisst im HUD "Leer", auf dem Knopf aber "Radierer".
@export var toolbar_label: String = ""

@export_group("Aussehen")

@export var color: Color = Color.MAGENTA

## Farbrauschen pro Zelle, rein optisch. Laesst Sand koernig wirken.
@export_range(0.0, 1.0, 0.01) var grain: float = 0.05

@export_group("Physik")

@export var phase: Phase = Phase.SOLID

## Dichteres Material verdraengt leichteres - aber nur innerhalb von Fluiden,
## siehe [method SandSimulation.can_displace].
@export var density: float = 1.0

## Wie viele Zellen weit sich das Material pro Schritt senkrecht zur
## Gravitation ausbreitet. 0 = gar nicht, dann bildet es einen Schuettkegel
## statt eines Spiegels.
@export_range(0, 16) var dispersion: int = 0

## Reibung, 0 bis 1. Zwei Wirkungen:
## [br]- Wie lange sich das Material seitlich ausbreitet, bevor es zur Ruhe
##   kommt. Wasser (niedrig) laeuft weit, Lava (hoeher) bleibt eher liegen.
##   Ohne das schiebt sich eine stehende Fluessigkeitsoberflaeche endlos hin
##   und her.
## [br]- Wie wahrscheinlich eine bereits ruhende Zelle von einer vorbeifallenden
##   Nachbarzelle mitgerissen wird. Hohe Reibung = bleibt liegen.
@export_range(0.0, 1.0, 0.01) var friction: float = 0.35

## Vorgabe fuer das Static-Flag beim Platzieren. Das Flag sitzt bewusst PRO
## ZELLE und nicht pro Material - derselbe Stein kann unverrueckbarer Boden
## oder fallendes Geroell sein.
@export var starts_static: bool = false

@export_group("Waerme")

## Anteil des Temperaturausgleichs mit den Nachbarn pro Waermeschritt.
@export_range(0.0, 1.0, 0.01) var conductivity: float = 0.08

## Traegheit gegen Temperaturaenderung. Hoch = das Material haelt seine
## Temperatur lange. Lava braucht das, sonst faellt sie nach wenigen Frames
## unter ihre Erstarrungsschwelle und ist sofort wieder Stein.
@export_range(0.1, 20.0, 0.1) var heat_capacity: float = 1.0

## Temperatur, mit der eine Zelle dieses Materials platziert wird. Damit sind
## Lava (heiss) und Eis (kalt) echte Waerme- bzw. Kaeltequellen, ohne dass es
## kuenstliche Emitter-Materialien braucht - die Waermeleitung erledigt den Rest.
@export var default_celsius: float = 20.0

## Aggregatzustands-FSM: Uebergaenge, die im Waermepass geprueft werden.
@export var transitions: Array[MaterialTransition] = []

@export_group("Feuer")

## Macht das Material brennbar. Leer = es brennt nicht.
@export var burning: BurnBehaviour

## Fuer Flammen: bleibt liegen, solange brennbares Material danebenliegt.
##
## Ohne das laesst sich nichts anzuenden. Ein Gas steigt eine Zelle pro Frame
## auf, der Waermepass laeuft aber nur jeden dritten Frame - eine Flamme, die
## auf einen Holzstapel gelegt wird, ist schon zwei Zellen weit weg, bevor sie
## das erste Mal Waerme abgeben durfte. Seitlich an einer Wand ginge es gut,
## oben auf einer Flaeche nie.
##
## Eine Flamme haengt an ihrem Brennstoff, bis er weg ist - dann steigt sie
## weiter auf wie jedes andere Gas.
@export var clings_to_fuel: bool = false

@export_group("Druck")

## Macht das Material durch Druck verformbar. Leer = Druck laesst es kalt.
@export var pressure: PressureChange

@export_group("Waerme")
@export_subgroup("Dauerquelle")

## Optionale Dauerquelle, die die Zelle aktiv auf [member emit_celsius] zieht.
## Von keinem mitgelieferten Material benutzt, aber fuer eigene Erweiterungen da.
@export var emits_heat: bool = false
@export var emit_celsius: float = 20.0
@export_range(0.0, 1.0, 0.01) var emit_power: float = 0.0

## Laufzeit-id: die Position in [member MaterialLibrary.materials]. Wird von
## [method MaterialLibrary.resolve] gesetzt und ist bewusst nicht exportiert -
## niemand soll ids von Hand vergeben muessen.
var id: int = 0


## Faellt, rutscht oder steigt dieses Material ueberhaupt?
##
## Ob es sich TATSAECHLICH bewegt, entscheidet zusaetzlich das Static-Flag der
## einzelnen Zelle. Nur die Luft ist grundsaetzlich unbeweglich.
func is_movable() -> bool:
	return phase != Phase.EMPTY


## Rutscht dieses Material diagonal ab? Das ist der Unterschied zwischen einem
## Schuettkegel und einem Stapel: Pulver und Fluide tun es, ein Feststoff nicht.
func slides_diagonally() -> bool:
	return phase == Phase.POWDER or phase == Phase.LIQUID or phase == Phase.GAS


## Kann durch dieses Material hindurch verdraengt werden? Feststoffe und Pulver
## nicht: ein Kornhaufen ist ein Gefuege, kein Bad.
func is_fluid() -> bool:
	return phase == Phase.LIQUID or phase == Phase.GAS


## Steigt entgegen der oertlichen Gravitation auf.
func is_gas() -> bool:
	return phase == Phase.GAS


## Kann Feuer fangen? Siehe [BurnBehaviour].
func is_flammable() -> bool:
	return burning != null


## Laesst dieses Material Feuer an eine Nachbarzelle heran? Luft und Gase tun
## das, alles andere schirmt ab - unter Wasser brennt nichts.
func exposes_neighbours() -> bool:
	return phase == Phase.EMPTY or phase == Phase.GAS


## Laesst sich durch Druck umwandeln? Siehe [PressureChange].
func is_pressure_sensitive() -> bool:
	return pressure != null

