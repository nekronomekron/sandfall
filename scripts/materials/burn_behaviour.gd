class_name BurnBehaviour
extends Resource

## Macht ein Material brennbar. Haengt als optionale Resource an
## [member SandMaterial.burning] - fehlt sie, kann das Material nicht brennen.
##
## NUR AN DER OBERFLAECHE: eine Zelle faengt erst Feuer, wenn sie heiss genug
## ist UND eine freie Seite hat (Luft oder Gas als direkter Nachbar). Zellen im
## Inneren eines Blocks haben keine freie Seite und bleiben deshalb kalt liegen,
## bis die Schicht ueber ihnen weggebrannt ist. Daraus ergibt sich die nach
## innen wandernde Brandfront von selbst - es gibt keinen Code, der sie
## ausdruecklich herstellt.
##
## Die Pruefung laeuft im Waermepass mit, der die heissen Zellen ohnehin schon
## besucht und ihre Temperatur zur Hand hat. Feuer braucht deshalb keinen
## eigenen Durchlauf ueber das Gitter.
##
## Ziele werden ueber den NAMEN angesprochen, nicht ueber eine
## Resource-Referenz - siehe [MaterialTransition] fuer den Grund.

## Ab dieser Temperatur faengt eine freiliegende Zelle an zu brennen.
@export var ignition_celsius: float = 300.0

## Fortschritt pro Waermeschritt, von 0 bis 255. Das ist die Stellschraube
## dafuer, wie schnell ein Material abbrennt: 255 heisst in einem Schritt
## durch, 8 heisst 32 Schritte.
@export_range(1, 255) var burn_rate: int = 16

## Auf diese Temperatur zieht sich eine brennende Zelle selbst hoch. Dadurch
## wird sie zur Waermequelle und entzuendet ihre Nachbarn - das ist der ganze
## Mechanismus der Ausbreitung.
@export var burn_celsius: float = 800.0

## Was uebrig bleibt, wenn die Zelle durchgebrannt ist. Leer = nichts, die
## Zelle wird zu Luft.
@export var residue: StringName = &""

## Wie oft [member residue] tatsaechlich zurueckbleibt. Der Rest wird restlos
## verzehrt.
##
## Das ist die Stellschraube zwischen zwei Verhalten: bei 1.0 wird jede Zelle
## zu Kohle, die Kruste blockt das Feuer, und ein Block kohlt nur aussen an.
## Darunter frisst sich das Feuer nach innen und laesst verstreute Kohle
## zurueck.
@export_range(0.0, 1.0, 0.01) var residue_chance: float = 0.35

## Was eine brennende Zelle in einen freien Nachbarn setzt - die sichtbare
## Flamme. Leer = keine.
@export var emits: StringName = &"fire"

## Wie oft je Waermeschritt eine Flamme gesetzt wird. Niedrig halten: jede
## Flamme ist eine Gaszelle, die danach faellt, steigt und gezeichnet wird.
@export_range(0.0, 1.0, 0.01) var emit_chance: float = 0.20

## Von [method MaterialLibrary.resolve] gefuellt.
var residue_id: int = MaterialLibrary.EMPTY_ID
var emits_id: int = -1
