# Sand Simulation

Falling-Sand-Simulation in Godot 4.7, GDScript. Eine Zelle ist ein Pixel. Drei
zusammenspielende Systeme: eine Bewegungs-FSM pro Zelle, eine
temperaturgetriebene Aggregatzustands-FSM und ein ortsabhaengiges
Gravitationsfeld.

![Screenshot](docs/screenshot.png)

## Aufbau: alles ist ein Knoten in der Szene

Es gibt keine versteckten Singletons und keine statische Registry. Jeder
zentrale Baustein ist ein Knoten in `scenes/main.tscn` und wird dort im Editor
mit den anderen verdrahtet:

```
Main                        main.gd - Schleife und Tastenkuerzel
├── MaterialRegistry        haelt die MaterialLibrary, baut die Lookups
├── SandSimulation          Bewegung, Waerme, Zustandswechsel
│   └── GravityField        backt das Gravitationsfeld
├── DemoWorld               Startinhalt (Steinboden)
├── WorldLayer
│   └── WorldView           skaliert die Spielansicht ganzzahlig ins Fenster
├── WorldViewport           SubViewport in Weltaufloesung
│   ├── WorldRenderer       Gitter -> Textur
│   └── WorldCamera         schwenken und zoomen
├── PaintTool               zeichnen und radieren
└── UiLayer
    ├── Toolbar             Materialauswahl (scenes/ui/toolbar.tscn)
    └── Hud                 zwei Zeilen unten links (scenes/ui/hud.tscn)
```

Alle Verweise zwischen diesen Knoten sind `@export`-Eigenschaften. Wer wissen
will, woher die `SandSimulation` ihre Materialien bekommt, klickt sie im Editor
an und sieht es im Inspektor - nicht in einem Konstruktor.

Ebenso liegen alle Stellschrauben im Inspektor statt als Konstante im Code:
Weltgroesse und Chunkgroesse, Waermeintervall und Schwerelosigkeitsschwelle an
der `SandSimulation`, die Waermetoenung am `WorldRenderer`, Zoomstufen und
Schwenkgeschwindigkeit an der `WorldCamera`, der Pinselradius am `PaintTool`.

| Datei | Verantwortung |
| --- | --- |
| `scripts/materials/sand_material.gd` | Eigenschaften eines Materialtyps (Resource) |
| `scripts/materials/material_transition.gd` | Ein Aggregatzustandswechsel (Resource) |
| `scripts/materials/material_library.gd` | Die Liste aller Materialtypen (Resource) |
| `scripts/materials/material_registry.gd` | Knoten, der die Bibliothek haelt und aufloest |
| `scripts/materials/material_lookups.gd` | Materialeigenschaften als flache Arrays |
| `scripts/sim/cell_grid.gd` | Zell- und Chunk-Arrays, Zugriff, Aufwachlogik |
| `scripts/sim/sand_simulation.gd` | Simulationsschritt: Bewegung, Waerme, Zustandswechsel |
| `scripts/sim/gravity_field.gd` | Backt das Gravitationsfeld aus abstrahlenden Zellen |
| `scripts/render/world_renderer.gd` | Gitter -> Textur, nur geaenderte Bereiche |
| `scripts/view/world_view.gd` | Ganzzahlige Skalierung, Maus -> Weltzelle |
| `scripts/view/world_camera.gd` | Schwenken und Zoomen |
| `scripts/world/demo_world.gd` | Startinhalt der Welt |
| `scripts/world/paint_tool.gd` | Zeichnen und Radieren |
| `scripts/ui/toolbar.gd` | Materialauswahl, Static-Flag |
| `scripts/ui/hud.gd` | Leistungsdaten und Zelle unter der Maus |
| `scripts/main.gd` | Schleife, Tastenkuerzel |
| `scripts/tests/` | Die Selbsttests, einer je Startparameter |

Ein Materialtyp existiert genau einmal als Objekt, nie einmal pro Pixel. Das
Gitter speichert nur die numerische id in einem `PackedByteArray`.

## Neues Material hinzufuegen

Eine Datei anlegen, eine Zeile eintragen - kein Code.

1. `res://resources/materials/oel.tres` anlegen, als Resource-Typ
   `SandMaterial` waehlen und im Inspektor ausfuellen.
2. Die Datei in `res://resources/material_library.tres` hinten an die Liste
   `materials` anhaengen.

Die Position in dieser Liste ist die id, mit der das Gitter arbeitet. Niemand
vergibt ids von Hand, und es gibt keine `COUNT`-Konstante zu pflegen. Toolbar,
Renderer, Simulation und Gravitationsfeld lesen alles aus den Eigenschaften der
Resource: das neue Material taucht von selbst als Knopf in der Toolbar auf.

Fuer Oel etwa `phase = LIQUID`, `density = 850`, `dispersion = 4`,
`conductivity = 0.10`, `heat_capacity = 2.0`. Dichte 850 unter Wasser 1000
heisst automatisch: Oel schwimmt oben.

Der einzige Eintrag, den man nicht vergessen darf, ist `material_name` - der
Schluessel, ueber den Zustandswechsel und Demo-Aufbau das Material ansprechen.
`MaterialLibrary.resolve()` meldet fehlende und doppelte Namen beim Start.

**Aggregatzustaende.** Ein `MaterialTransition` ist eine eigene Resource und
liegt in der Liste `transitions` des Materials. Er nennt sein Ziel beim Namen
(`becomes = &"ice"`) statt per Verweis: Wasser zeigt auf Eis und Eis zurueck
auf Wasser, und solche Ringe kann Godot zwischen zwei `.tres`-Dateien nicht
laden. Die Bibliothek loest die Namen einmal beim Start in ids auf.

**Neue Eigenschaft.** Ein `@export` in `sand_material.gd`, ein Default, und die
Auswertung dort wo sie wirkt. Liegt sie im Schleifenkern von Bewegung, Waerme
oder Renderer, gehoert sie zusaetzlich in `material_lookups.gd` - ein
Property-Zugriff auf eine Resource kostet dort ein Vielfaches eines
Packed-Array-Zugriffs.

## Zwei getrennte Aufloesungen

| | Aufloesung | Skalierung |
| --- | --- | --- |
| Spielwelt | 576 x 324 (SubViewport) | ganzzahlig hochskaliert, nearest |
| UI | native Fenstergroesse (1728 x 972) | gar nicht - 1:1 gerastert |

Beide Zahlen stehen in den **Projekteinstellungen** unter Anzeige > Fenster,
nicht im Code: `window/size/viewport_width` und `viewport_height` sind die
Aufloesung der Spielwelt, `window_width_override` und `window_height_override`
die Fenstergroesse. `WorldView` liest die Ansichtsgroesse beim Start von dort
und setzt damit den SubViewport.

Die Spielwelt rendert in diesen SubViewport und wird davon **ganzzahlig**
vergroessert. Nur ganzzahlig: jeder andere Faktor verteilt Weltpixel ungleich
auf Bildschirmpixel und macht das Bild unruhig. Die UI liegt darueber in der
nativen Aufloesung und wird nicht mitskaliert - deshalb ist der Text scharf
statt hochgerechnet.

Die Welt selbst ist mit **1024 x 576** Zellen (589 824) groesser als der
sichtbare Ausschnitt. Man sieht also immer nur einen Teil und scrollt.

## Starten

```bash
"C:/Projects/Godot/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe" --path "C:/Projects/Godot/sandfall"
```

## Selbsttests

Benchmark, FSM-, Fliess-, Spiegel- und Verdraengungstest laufen headless. Der
Eingabetest braucht ein Fenster. Jeder Test liegt in einer eigenen Datei unter
`scripts/tests/`; `SelfTests.take_over()` verteilt die Startparameter.

```bash
"C:/Projects/Godot/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:/Projects/Godot/sandfall" -- --bench
```

Ebenso `--fsmtest`, `--flowtest`, `--leveltest`, `--displacetest`. Ohne
`--headless` laufen `--inputtest` und `--shot [--frames=N]`; letzterer rendert N
Frames und schreibt einen Screenshot.

Die Simulation wuerfelt (`RandomNumberGenerator.randomize()`), die Tests sind
also nicht Bit-fuer-Bit reproduzierbar. Die Urteile sind entsprechend
grosszuegig gewaehlt.

## Steuerung

| Eingabe | Aktion | Wirkung |
| --- | --- | --- |
| Linke Maustaste | `paint` | Material zeichnen (genau eine Zelle) |
| Rechte Maustaste | `erase` | Radieren |
| Mittlere Maustaste ziehen | `pan_drag` | Ansicht verschieben |
| Pfeiltasten / WASD | `pan_*` | Ansicht verschieben |
| Mausrad | `zoom_in` / `zoom_out` | Zoomen (1x, 2x, 3x, 4x, 6x, 8x) |
| Leertaste | `pause` | Pause |
| N | `step` | Einzelschritt (bei Pause) |
| R | `reset` | Zuruecksetzen |
| H | `toggle_heat` | Waermetoenung an/aus |

Die Belegung liegt als Input-Map in den Projekteinstellungen und ist dort
aenderbar, ohne eine Zeile Code anzufassen.

Der Pinsel ist voreingestellt eine Zelle gross (`PaintTool.brush_radius`). Beim
Ziehen wird zwischen den Mauspositionen interpoliert, damit schnelle Bewegungen
keine Luecken lassen.

Der Haken **statisch** setzt das Static-Flag pro Zelle: darauf wirkt keine
Schwerkraft, egal was das lokale Gravitationsfeld sagt. Der Steinboden der Demo
ist genau so gebaut. Das Flag ist bewusst *pro Zelle* und nicht pro Material -
derselbe Stein kann unverrueckbarer Boden oder fallendes Geroell sein.

## Materialien

| Material | Art | Reibung | Besonderheit |
| --- | --- | --- | --- |
| Sand | Pulver | 0,55 | Bildet Schuettkegel |
| Wasser | Fluessigkeit | 0,05 | Gefriert bei 0 C, siedet bei 100 C, laeuft weit |
| Stein | Pulver, statisch | 0,90 | Schmilzt ueber 950 C zu Lava |
| Eis | Feststoff, statisch | 0,90 | Wird mit -60 C platziert, taut ueber 2 C |
| Dampf | Gas | 0,02 | Steigt auf, kondensiert unter 95 C |
| Lava | Fluessigkeit | 0,50 | 1200 C beim Platzieren, erstarrt unter 700 C zu Stein |
| Grav-Blocker | Pulver, statisch | 0,80 | Hebt die Schwerkraft im Umkreis auf |
| Grav-Verstaerker | Pulver, statisch | 0,80 | Verdreifacht die Schwerkraft im Umkreis |
| Grav-Umkehrer | Pulver, statisch | 0,80 | Dreht die Schwerkraft im Umkreis um |

Waerme und Kaelte kommen aus echten Materialien statt aus abstrakten Quellen:
Lava bringt ihre 1200 Grad mit, Eis seine -60 Grad, und die Waermeleitung macht
daraus von selbst Waerme- und Kaeltequellen. Beide verbrauchen sich dabei -
Lava erstarrt zu Stein, Eis taut zu Wasser.

## Die drei Systeme

**Bewegungs-FSM (pro Zelle).** Zustaende `REST`, `FALLING`, `SLIDING`. Ein
Partikel probiert der Reihe nach: Hauptrichtung der lokalen Gravitation
(`_try_fall`), dann die beiden Diagonalen (`_try_slide_diagonally`), dann - bei
Fluiden und Gasen - senkrecht dazu (`_try_spread_sideways`). Gelingt nichts,
geht es nach `REST`. Der Zustand ist nicht nur Deko: ruhende Regionen lassen
ihren Chunk einschlafen, und schlafende Chunks kosten null.

Klassische Falling-Sand-Simulationen verlassen sich darauf, dass die
Scanreihenfolge der Gravitationsrichtung entspricht. Das faellt aus, sobald die
Gravitation regional umgekehrt oder blockiert ist. Stattdessen traegt jede
Zelle einen Generationsstempel und wird pro Frame hoechstens einmal bewegt,
egal in welcher Reihenfolge sie besucht wird.

**Aggregatzustands-FSM (pro Materialtyp).** Ein zweites Gitter haelt die
Temperatur. Waerme leitet zwischen Nachbarn, gewichtet mit Leitfaehigkeit und
Waermekapazitaet. Uebergaenge stehen als `MaterialTransition`-Resourcen am
Material und werden direkt im Waermepass ausgewertet - Material und neue
Temperatur liegen dort ohnehin vor, ein zweiter Durchlauf ueber dieselben
Zellen kostete gemessen 3,4 ms pro Frame. Hysterese verhindert Flackern: Wasser
gefriert bei 0 Grad, Eis taut erst bei +2; Wasser siedet bei 100, Dampf
kondensiert erst bei 95; Lava erstarrt bei 700, Stein schmilzt erst bei 950.

Ein Uebergang kann zusaetzlich eine Zieltemperatur setzen
(`resets_temperature`). Lava nutzt das: erstarrter Stein springt auf
Normaltemperatur. Sonst bliebe er bei 700 Grad stehen und wuerde daneben weiter
Wasser verdampfen, ohne dass im Bild noch etwas Heisses zu sehen waere - der
Spieler saehe Dampf ohne erkennbare Ursache. Im `--fsmtest` schrumpft die Lava
sichtbar ueber die sechs Messpunkte von rund 160 auf eine Handvoll Zellen,
waehrend der neue Stein auf rund 150 Zellen waechst und die Dampfmenge am Ende
mit der Lava zurueckgeht.

**Gravitationsfeld.** Materialien mit `gravity_radius > 0` strahlen ein Feld
ab. Ein Blocker (Faktor 0) hebt die Schwerkraft auf, ein Verstaerker (3) erhoeht
sie, ein Umkehrer (-1) dreht sie um. Das Feld wirkt voll bis
`gravity_plateau * radius` und rampt erst danach zurueck - ohne dieses Plateau
haette ein Blocker mit Radius 44 nur rund drei Zellen echte Wirkung, weil ein
rein linearer Abfall den Betrag wie `d/r` wachsen laesst.

## Verdraengung: wer darf durch wen hindurch?

Verdraengt wird **ausschliesslich in Fluiden**, und die Richtung entscheidet:

- Wer **mit** der Gravitation faellt, schiebt sich durch **leichtere** Fluide.
  Sand sinkt durch Wasser, Stein sinkt durch Wasser, Wasser schiebt Dampf weg.
- Wer **gegen** sie steigt - also Gase, deren Auftrieb die Richtung umdreht -
  schiebt sich durch **schwerere** Fluide. Eine Dampfblase unter Wasser tauscht
  mit dem Wasser darueber und steigt auf, statt bis zum Kondensieren
  festzustecken.

**Feste Materialien werden nie verdraengt.** Pulver wie Sand und Stein ebenso
wie echte Feststoffe bleiben aufeinander liegen, egal wie schwer das Material
darueber ist. Ein Kornhaufen ist ein Gefuege, kein Bad: Lava laeuft ueber einen
Sandhaufen statt hindurch, und ein Steinbrocken sinkt nicht darin ein. Auf den
Verursacher kommt es nicht an, nur auf das, was verdraengt werden soll -
`SandSimulation.can_displace()` ist entsprechend kurz.

Zweite Regel: **verdraengt wird nur im ersten Schritt einer Bewegung.** Eine
Zelle, die mehrere leere Felder weit gefallen ist, tauscht nicht mit dem
Material am Ende ihrer Bahn - sonst landet dieses Material an ihrer
Startposition, also mitten in der Luft. Genau dadurch entstanden beim Lavafall
einzelne Sandkoerner im Nichts. Verdraengung ist nur zwischen direkten Nachbarn
sinnvoll.

`--displacetest` prueft das mit Saeulenprofilen statt mit Summen - Summen ueber
Rechtecke haben hier dreimal Fehlalarm ausgeloest, weil sie Material mitzaehlten,
das seitlich am Messfenster vorbeigelaufen war:

| Fall | Erwartung | Ergebnis |
| --- | --- | --- |
| Lava auf Sandbett | liegt oben auf | 0 fluessige Lava und 0 Steinkoerner unter der Sandoberflaeche |
| Sand in Wasser | sinkt auf den Grund | Sand bei y 381-399, Wasser darueber ab y 339 |
| Lava faellt auf Sandhaufen | keine Koerner in der Luft | 0 schwebende Koerner, Sandmenge exakt erhalten |
| Dampfblase unter Wasser | steigt auf | oberste Zelle steigt genau 1 Zelle pro Frame, 388 -> 328 in 60 Frames |

Beim Aufstieg zaehlt die **oberste** Dampfzelle, nicht das Mittel. Die heisse
Blase verdampft unterwegs laufend neues Wasser an ihrer Unterseite; dieser
Nachschub zieht das Mittel nach unten, obwohl die Blase selbst steigt. Das
Mittel misst also die Waermeleitung mit - der Auftrieb steht in der obersten
Zelle.

Typisches Saeulenprofil nach dem Test: `Lava:3 Stein:2 Sand:20 Stein:24` - Lava
und ihre Erstarrungskruste liegen auf dem Sand, nichts steckt darin.

### Auch das Verdraengte zaehlt nur einmal

Der Generationszaehler hat urspruenglich nur den Verursacher einer Bewegung
geschuetzt, nicht die Zelle, die dabei verdraengt wurde. Dadurch konnte
dieselbe Zelle in einem einzigen Frame mehrfach weitergereicht werden: jede
nachfallende Wasserzelle ratschte eine Dampfblase eine weitere Stufe hoch, und
die Blase legte eine ganze Wassersaeule in einem Frame zurueck - gemessen 88
Zellen statt einer.

Seit die Bedingung auch fuer das Ziel gilt (`SandSimulation._is_passable()`),
bewegt sich jede Zelle hoechstens einmal pro Frame, egal ob aus eigenem Antrieb
oder weil sie geschoben wurde. Der Aufstieg ist danach exakt linear mit einer
Zelle pro Frame. Der Fehler betraf nicht nur Gase - auch Wasser unter fallendem
Sand wurde so mehrfach pro Frame verschoben.

## Reibung und Ruhezustand

`SandMaterial.friction` (0 bis 1) steuert, wann eine Zelle liegen bleibt und
wann sie wieder losgeht.

**Gezaehlt werden Richtungswechsel, nicht Schritte.** Jede Fluessigkeitszelle
merkt sich ihre letzte seitliche Fliessrichtung und probiert sie zuerst wieder.
Laeuft sie weiter in dieselbe Richtung, passiert nichts - sie darf beliebig weit
fliessen. Erst wenn sie *umkehrt*, zaehlt ein Zaehler hoch; nach der von der
Reibung bestimmten Zahl an Wechseln (Wasser rund 29, Lava rund 16) hoert sie
auf, seitlich auszuweichen. Faellt die Zelle - auch nur diagonal -, wird der
Zaehler samt Richtungsgedaechtnis geloescht.

Das ist der entscheidende Unterschied zu einer Begrenzung der *Strecke*: eine
Fluessigkeit, die stetig zum tiefsten Punkt laeuft, kehrt dabei nie um und wird
nie gebremst. Nur wer zwischen zwei gleichwertigen Lagen hin und her pendelt,
kommt zur Ruhe. Eine Streckenbegrenzung liess Wasser dagegen mitten im Fliessen
als Haufen stehen, obwohl weiter aussen noch Platz war.

Das settle-Byte pro Zelle traegt beides: Bit 0-5 die Zahl der Wechsel, Bit 6 ob
eine Richtung gemerkt ist, Bit 7 welche.

**Mitgerissen werden.** Ruhende Zellen werden gar nicht mehr simuliert - das ist
der groesste Einzelposten der Ersparnis. Aufgeweckt werden sie auf zwei Wegen:

- Entsteht daneben ein Loch, werden *alle* ruhenden Nachbarn geweckt. Ohne
  Reibungswurf: fehlende Unterlage ist keine Frage der Reibung.
- Kommt eine Zelle vorbei, zieht sie an den ruhenden Zellen *neben ihrer Bahn*.
  Ob die mitgehen, entscheidet ein Wurf gegen deren Reibung. Sand (0,55) wird
  nur manchmal mitgerissen und behaelt dadurch stabile Boeschungen, Wasser
  (0,05) fast immer.

Ein geweckter Nachbar behaelt seinen Wechselzaehler. Er darf also wieder fallen,
faengt aber nicht erneut an, endlos seitlich zu schaukeln.

### Wen betrifft das?

Nur Materialien mit `dispersion > 0` durchlaufen den seitlichen Ausweichschritt.
`--leveltest` prueft alle vier Faelle:

| Material | Art | Erwartung | Ergebnis |
| --- | --- | --- | --- |
| Wasser | Fluessigkeit | flacher Spiegel | 300 von 300 Spalten belegt, Hoehe 13-15, **0 Ausreisser**, zur Ruhe gekommen |
| Lava | Fluessigkeit | fliesst weg, erstarrt dabei | von 40 auf 261 Spalten gelaufen |
| Dampf | Gas | breitet sich unter der Decke aus | von 30 auf 152 Spalten |
| Sand | Pulver (`dispersion = 0`) | Schuettkegel, KEIN Spiegel | Kegel erhalten, Hoehe 1-88 |

Pulver - Sand, Stein und die Gravitationsmaterialien - haben `dispersion = 0`
und sind damit gar nicht betroffen. Das ist auch richtig so: ein Schuettkegel
soll stehen bleiben. Die Gegenprobe im Test stellt sicher, dass sich das nicht
versehentlich mitaendert.

Bei Lava waere ein flacher Spiegel das falsche Ziel: sie erstarrt von vorne weg
zu Stein und friert ihre Form dabei ein. Geprueft wird deshalb nur, dass sie
ueberhaupt wegfliesst statt an der Quelle liegen zu bleiben.

## Performance

Gemessen auf diesem Rechner, 1024 x 576 Zellen, Godot 4.7.2 headless
(`-- --bench`), Werte pro Simulationsschritt:

| Szenario | Median | p95 |
| --- | --- | --- |
| Ruhe (alles gesetzt, nichts bewegt sich) | 0,07 ms | 0,10 ms |
| Typische Nutzung (Wasser + Lava + Gravitation) | 24,9 ms | 45,4 ms |
| Stresstest (Grossblock Sand + Wasser in freiem Fall) | 156,9 ms | 239,9 ms |

Die Zahlen streuen von Lauf zu Lauf spuerbar, weil die Simulation wuerfelt -
der Median der typischen Nutzung schwankt um mehrere Millisekunden.

### Was die Lesbarkeit kostet

Die Bewegung ist in `_try_fall`, `_try_slide_diagonally` und
`_try_spread_sideways` aufgeteilt, statt in einer langen Funktion zu stehen.
Das kostet: gegen die fruehere Fassung mit einem einzigen Block liegt der
Stresstest rund 6 Prozent hoeher, die Bewegung selbst rund 8 Prozent. Dafuer
laesst sich die Bewegungs-FSM lesen, ohne sie im Kopf zu zerlegen.

Was dagegen NICHT der Lesbarkeit geopfert wurde, weil es zu teuer war:

- Die Lookup-Arrays liegen als eigene Member der `SandSimulation` und nicht als
  `_lookups.movable[m]`. Zwei Zugriffe statt einem machten in Bewegung und
  Waerme zusammen rund 40 Prozent aus.
- Die Vorfilterung im Zellscan und die Aggregatzustands-FSM im Waermepass
  stehen ausgeschrieben in ihrer Schleife. Beide laufen einmal pro Zelle, und
  ein GDScript-Funktionsaufruf pro Zelle ist dort teurer als die Pruefung.
- Kein `for x in [a, b]` in Pfaden, die pro bewegter Zelle laufen - ein
  Array-Literal wird bei jedem Aufruf neu angelegt.

Der Waermepass ist dadurch inzwischen schneller als vorher (6,2 statt 6,8 ms
in der typischen Szene).

### Weitere Beobachtungen

Das grosszuegige Umkehr-Budget kostet: Fluessigkeiten schwappen laenger, bevor
sie liegen bleiben, und das schlaegt in den bewegten Szenarien mit rund zehn
Prozent zu Buche. Der Gegenwert ist ein wirklich flacher Wasserspiegel statt
eines Haufens - mit einem knapperen Budget bleibt Wasser mitten im Fliessen
stehen. Sobald sich eine Szene gesetzt hat, kostet sie ohnehin fast nichts.

Was den Unterschied macht, in der Reihenfolge der gemessenen Wirkung:

- **Schlafende Chunks und Dirty-Rects.** Ein wacher Chunk wird nur innerhalb des
  Rechtecks simuliert, in dem sich wirklich etwas geaendert hat, plus eine Zelle
  Rand. Ruhe: 175 ms -> 0,06 ms.
- **Nur den sichtbaren Ausschnitt und nur geaenderte Bereiche zeichnen.**
  Rendering: 17,2 ms -> 1,6 ms. Der groesste Einzelposten war dabei nicht der
  Texturupload, wie zuerst vermutet, sondern Property-Zugriffe auf die
  Material-Resource im Zeichenkern.
- **Distanztransformation statt Kreisstempel** im Gravitationsfeld. Vorher pro
  Quellzelle ein Radius-Kreis, O(Quellen x Flaeche): 98 ms fuer einen
  10x10-Block. Jetzt zwei Chamfer-Durchlaeufe ueber das Einflussrechteck,
  O(Flaeche), unabhaengig von der Quellenzahl.
- **Flache Lookup-Arrays statt Resource-Properties** in allen Schleifenkernen
  (`MaterialLookups`). Simulation und Renderer teilen sich dieselben Arrays -
  gebaut werden sie einmal von der `MaterialRegistry`.
- **Lokale Aliase auf die Packed-Arrays.** In GDScript teilen sich lokale Aliase
  und Member denselben Puffer - ein Alias forkt beim Schreiben *nicht*, beide
  Seiten sehen dieselben Daten (nachgemessen). Ein Member-Zugriff kostet dabei
  das 2,75-fache eines lokalen Zugriffs.

Wenn mehr noetig ist, liegt der naechste Schritt nicht in weiterer
GDScript-Optimierung, sondern im Wechsel der Sprache: `CellGrid` und
`SandSimulation` sind die einzigen Stellen, die Zellen anfassen, und lassen sich
geschlossen nach C# oder als GDExtension portieren, ohne dass Renderer, UI oder
Materialdefinitionen sich aendern.

## Behobener Fehler: haengenbleibendes Material

Bei einer Bewegung *innerhalb* eines Chunks wurde nur die Quellzelle in das
Dirty-Rect eingetragen, nicht das Ziel. Solange ganze Chunks gescannt wurden,
war das egal. Mit Dirty-Rects nicht mehr: das Dirty-Rect ist eine Bounding-Box
mit einer Zelle Rand, und Wasser springt bis zu `dispersion` (5) Zellen weit.
Material landete ausserhalb des simulierten Rechtecks und blieb dort stehen -
die Region schlief ein, obwohl noch etwas in der Luft hing.

`--flowtest` deckt das ab und meldet ausdruecklich den Fehlerfall: Material in
der Luft, waehrend niemand mehr simuliert wird. Ohne den Fix bleiben dauerhaft
14 Zellen haengen und die Welt schlaeft komplett ein.

Beim Einbau der Reibung ist derselbe Fehler in anderer Form zurueckgekommen: ein
seitlicher Ausweichschritt kann ueber einem Loch enden, und eine dabei sofort auf
`REST` gesetzte Zelle blieb dort in der Luft stehen. Seitliche Schritte enden
deshalb nie direkt im Ruhezustand - die Bremse ist allein der Ruhezaehler.

## Weg zur unendlichen Welt

Die Welt ist in Chunks von 64 x 64 organisiert (`SandSimulation.chunk_size`) und
alle Iteration laeuft chunkweise. Simulation, Renderer und UI greifen
ausschliesslich ueber `index_of()`, `in_bounds()`, `set_cell()` und `wake_at()`
zu; feste Weltgrenzen stehen nur in `cell_grid.gd`. Fuer Streaming muss das
Backing - die flachen Arrays - durch eine Chunk-Map ersetzt werden, plus Laden
und Entladen am Rand.

## Bekannte Grenzen

- Fluessigkeiten brauchen Zeit zum Einebnen: im Spiegeltest sind es rund 3000
  Frames, bis das Wasser ueber 300 Spalten flach liegt. Sie kommen an, aber
  nicht sofort.
- Ein Wasserspiegel, der von zwei Seiten gegen ein Hindernis pendelt, kann nach
  rund 29 Umkehrungen stehen bleiben, bevor er ganz ausgeglichen ist. Die
  Stellschraube ist `friction` von Wasser bzw. die Zuordnung Reibung zu
  Umkehr-Budget in `MaterialLookups`.
- Bewegung ist auf hoechstens eine Zelle pro Frame pro Zelle begrenzt
  (`max_steps_per_frame` erlaubt bei verstaerkter Gravitation bis zu vier).
- Die Waermeleitung laeuft nur jeden dritten Frame (`heat_interval`).
- Thermisch aktive Chunks werden ganzflaechig neu gezeichnet, weil die
  Waermetoenung sich ueber die ganze Flaeche aendern kann.
- Keine Latentwaerme: Schmelzen und Erstarren kosten keine Energie.
- Lava unter Wasser ist ein Dauerlaeufer: sie verdampft laufend Wasser, der
  Dampf steigt auf und kondensiert oben wieder. Das haelt viele Chunks wach und
  ist das teuerste, was die Demo-Szene zu bieten hat.
- Lava (1200 C beim Platzieren) liegt ueber der Schmelzschwelle von Stein
  (950 C). Sie frisst sich deshalb mit der Zeit durch duenne Steinboeden. Das
  ist eine bewusste Regel, faellt aber leicht als Fehler auf - wer es nicht will,
  setzt die Schwelle in `resources/materials/stone.tres` hoeher.
