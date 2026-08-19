class_name GravityZone
extends Resource

## Ein rechteckiger Bereich der Karte mit abweichender Schwerkraft.
##
## Zonen sind STATISCH: [DemoWorld] traegt sie beim Aufbau einmal in das Feld
## von [CellGrid] ein, danach ruehrt sie niemand mehr an. Es gibt bewusst keine
## Materialien mehr, die zur Laufzeit ein eigenes Feld abstrahlen - ein Level
## legt sein Gravitationsfeld fest, und die Simulation liest es nur noch.
##
## Spaeter eingetragene Zonen ueberschreiben frueher eingetragene dort, wo sie
## sich ueberlappen.

## Der Bereich in Weltzellen.
@export var area := Rect2i()

## Die Schwerkraft in diesem Bereich. Laenge 1 entspricht der normalen Staerke.
## [br](0, 1) faellt nach unten, (0, -1) nach oben, (1, 0) zur Seite.
## [br](0, 3) zieht dreifach stark, (0, 0) macht den Bereich schwerelos.
@export var gravity := Vector2.DOWN

## Nur zur Orientierung im Editor.
@export var label := ""
