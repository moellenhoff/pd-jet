# jet – Roadmap

jet ist ein GPU-natives Nachfolgekonzept zu Gem für Pure Data: dieselbe
Autorenidee (Objekte per Patch-Kabel zu Renderketten verbinden,
`jet_win` / `jet_head`, Gem-artige Objekte wie `rotateXYZ` mit heißen
Inlets), aber auf Metal statt OpenGL und mit Features aus TouchDesigner
und Max/Jitter. Aktuell **nur macOS / Apple Silicon / Metal**.

Aufwände sind Arbeitstage Entwicklung, Unsicherheit etwa ±50 %. Für
Render-Änderungen kommen Test-Runden dazu (grob +30 %), weil Ergebnisse
nur im laufenden Pd sichtbar sind.

## Entscheidungen

| # | Entscheidung | Beschluss | Aufwand | Status |
|---|---|---|---|---|
| 1 | Name/Präfix `jet_`, eigener Ordner, Git-Repo | ja | 1 | erledigt (Repo ohne Commit angelegt) |
| 2 | **Befehlsliste statt offenem Encoder**: Objekte zeichnen Befehle pro Render-Pass auf, das Fenster führt sie am Frame-Ende aus | ja – Herzstück des Umbaus | 5–8 | erledigt für den Bildschirm-Pass (Formen zeichnen Befehle auf, `jet_win` führt sie in einem Pass aus, sortiert Transparenz); Offscreen-Erzeuger (perlin, feedback, slitscan) kodieren ihre eigenen Pässe weiterhin sofort – wird erst für `jet_render`/Teilszenen in Texturen relevant |
| 3 | **Zustand pro Kette** (Transform, Textur, Tiefentest, Blending) beim Kettenstart sauber zurücksetzen | ja | 1–2 | erledigt (`jet_win_beginChain`; Blending folgt, sobald es Blending gibt) |
| 4 | **Benannte Textur-Handles** zusätzlich zum „current texture“ (bleibt der normale Gem-artige Fluss) | ja, Hybrid | 3–5 | erledigt (`jet_share name` / `jet_use name`, fensterweit, Fenster hält die Textur per retain) |
| 5 | **Zeichenreihenfolge**: Layer/Priorität pro Form, Sortierung für Transparenz (braucht 2) | ja | 3–5 | offen |
| 6 | **Fenster/Event-Schicht** sauber (Display-Link, ESC, `destroy`, Live-Resize, Retina) | ja | 3–5 | offen |
| 7 | **Taktung**: A) Pd-Clock wie bisher · B) Pd-Clock + besseres Frame-Pacing · C) eigener Render-Thread mit Display-Link | B jetzt, C erst nach Kurztest | B: 1–2 · C-Spike: 2–3 · C voll: 8–15 | offen |
| 8 | **Caching/Dirty-Flags** für teure statische Quellen | später | 2–4 | Backlog |
| 9 | **Massendaten/Instancing** aus Pd-Arrays | später | 5–8 | Backlog |
| 10 | **Kern/Backend-Trennung**: nur organisatorisch, keine abstrakte GPU-Schnittstelle. Die Befehlsliste aus 2 ist die neutrale Zwischenschicht | ja, schlank | 2–3 | Ordnerstruktur erledigt |

**Reihenfolge:** 1 → 10 → 3 → 2 → 4 → 5 → 6 → 7B, danach Spike 7C.
Kern gesamt: ca. 18–30 Tage. Größte Unsicherheiten: Punkt 2 und 7C.
Zeigt der Spike, dass der Render-Thread nötig ist, kommt 7C voll als
eigener Block dazu.

## Backlog / Zukunftsmusik

- `jet_obj`: OBJ + MTL laden, texturiertes Blender-Modell mit Licht
  (die bestehende 3D-Basis: Kamera, Tiefentest, ein Richtungslicht)
- Szene-in-Textur (`jet_render` o. ä.), mehrere Kameras, Schatten
- Eigene Shader: `jet_shader` ist da (Fragment-Effekte aus Dateien mit
  `// @param` / `// @input` / `// @feedback` / `// @size`, Parameter werden
  zu Inlets, Autoreload, Beispiele in `shaders/`). `// @history N`
  (Ringpuffer der letzten N Frames des ersten Eingangs,
  `jet_history(t, p, uv, framesAgo)`) trägt `shaders/slitscan.metal` und
  `slitscan_line.metal`; die früheren Objekte `jet_slitscan` und
  `jet_slitscan_line` sind entfernt.
  Offen: Verschmelzen von Punktoperationen, mehrere Durchläufe pro Objekt
  (z. B. getrennter Blur), weitere Bausteine (edge, displace, mirror, tile), `jet_compute`
  (Compute-Shader), Slider/Min-Max-Bereiche für Parameter
- Weitere Primitive, Material-/Lichtmodell erweitern
- Linux/Windows (Vulkan-Backend oder WebGPU), erst wenn der Mac-Kern
  steht
- libpd nur, falls später Standalone-Apps/iOS gewünscht sind (dann
  braucht es eine vom Host gestellte Zeichenfläche, siehe Punkt 6)

## Bekannte offene Punkte

- Rückwärts-Videowiedergabe ruckelt (AVAssetReader kann nur vorwärts
  decodieren, jeder Schritt ist ein Neuaufbau; derzeit auf ~12 Seeks/s
  gedrosselt)
- ESC beendet den Vollbildmodus nicht zuverlässig (Folge der manuellen
  Event-Pumpe, siehe Punkt 6)
- Video+Audio auf dem Pd-Scheduler-Thread: Dekodierung läuft bereits in
  eigenen Threads, das Rendering selbst noch nicht (siehe Punkt 7)

## Konventionen

- **Einheiten = Gem-Einheiten.** Das fertige Bild ist 8 Einheiten hoch
  (y = -4..+4) und 8·Aspekt breit. Formen (`jet_rectangle`,
  `jet_triangle`) arbeiten darin; die Standardkamera (z = 4, fov 90)
  macht die z=0-Ebene 8 Einheiten hoch. `[jet_rectangle 5.33 4]`
  füllt ein 800x600-Fenster wie `[rectangle 5.33 4]` in Gem. Parameter
  von Rechteck/Dreieck sind Halbmaße.
- **Formen und Inlets nach Gem-Vorbild:** der linke Inlet nimmt die Kette
  (Bang) und Messages, jeder Parameter hat einen eigenen Inlet danach
  (`jet_rectangle w h`: Bang | Breite | Höhe; `jet_translateXYZ`:
  Kette | x | y | z; `jet_color`: Kette | r | g | b; `jet_triangle` und
  `jet_cube`: Kette | Größe). Parameter-Inlets speichern nur, gezeichnet
  bzw. angewendet wird beim Bang der Kette (jet_win bangt jeden Frame).
  Position kommt aus `jet_translateXYZ`, Farbe aus `jet_color`
  (Kettenzustand, Standard weiß; bei Textur wirkt sie als Tönung),
  Tiefentest aus `jet_depth` (Standard an), der Zustand eines Zweigs wird
  mit `jet_separator` gekapselt. Verzweigen immer mit `[t b b]`.
- **Alle Formen sind echte 3D-Geometrie** (Rechteck/Dreieck ungelit, Würfel
  gelit) und laufen durch Kamera und ein einziges 4x4-Modelltransform.
  Der frühere 2D-Transform ist entfernt.
- **Zeichnen = Befehle aufzeichnen.** Formen rufen `jet_win_submit_draw`
  auf (Vertexdaten, Pipeline-Art, Textur, Uniforms); das Fenster führt am
  Frame-Ende alle in einem Render-Pass aus. Reihenfolge: alles außer
  „tiefengetestet und alpha < 1“ in Aufzeichnungsreihenfolge (damit
  `jet_depth 0` Malerreihenfolge behält), danach die transparenten von
  hinten nach vorn, ohne Tiefe zu schreiben.
- **Benannte Texturen:** `jet_share <name>` veröffentlicht die aktuelle
  Textur, `jet_use <name>` bindet sie in beliebiger Kette. Namen gelten
  pro Fenster und bleiben bis zur nächsten Veröffentlichung; läuft der
  Erzeuger später als der Verbraucher, kommt das Bild des Vorframes
  (Priorität der `jet_head` steuert das).
- **Effekt-Bausteine** (`jet_level`, `jet_hsv`, `jet_blur`, `jet_mix`,
  `jet_uvtransform`, `jet_threshold`): dünne Hüllen um dasselbe System wie
  `jet_shader` (`src/jet_fx_object.h`); der Shader jedes Bausteins liegt in
  `fx/<name>.metal` und wird beim Bauen eingebettet (`tools/embed_fx.py`).
  Creation-Argumente: Zahlen füllen die Parameter der Reihe nach, Symbole
  benennen die zusätzlichen Textur-Eingänge. Nach der Kette darunter
  stellen sie die aktuelle Textur wieder her (wie ein Separator).
- **Texturpool** (`jet_win_pool_acquire/release`): Ausgaben der Effekte
  kommen aus einem gemeinsamen Pool; eine freigegebene Textur wird erst
  wiederverwendet, wenn sie weder von einem aufgezeichneten Draw dieses
  Frames noch von einem `jet_share`-Namen gebraucht wird; ungenutzte werden
  nach ~300 Frames freigegeben. Innerhalb einer langen Kette hält jeder
  Knoten seine Textur, bis alles darunter durchgelaufen ist (Pd liefert
  keine Information über spätere Leser) - das spart erst die spätere
  Verschmelzung benachbarter Punktoperationen zu einem Durchlauf.
- **Alpha** kommt aus `jet_color r g b a`; Texturen-Alpha wird ignoriert.
- **Zustandsbereiche** (Kette / Frame / Objekt) stehen im Kopf von
  `src/jet_shared.h`.
- **Render an/aus:** ein Float an `jet_win` (1/0) wie bei `gemwin`.

## Werkzeuge

- `make` baut alle Bundles nach `build/`; `make install` kopiert Bundles,
  Help-Patches und Assets nach `~/Documents/Pd/externals/jet/`.
- `make shadertest` zieht alle eingebetteten Shader aus `src/*.mm`
  (`tools/extract_msl.py`) und kompiliert sie mit Metals Laufzeit-Compiler
  (`tools/msltest.mm`), also auf demselben Weg wie Pd beim Laden. Fängt
  kaputten MSL-Code und zerstörte Includes schon beim Bauen ab statt als
  leeres graues Fenster. `make install` läuft nur, wenn der Test besteht.
  Braucht eine Metal-fähige Maschine und `python3`, aber nicht die
  Offline-Metal-Toolchain. Derselbe Schritt prüft auch alle
  `shaders/*.metal` mit dem Code von `jet_shader` (`tools/effecttest.mm`,
  inkl. Selbsttest des Parameter-Layouts gegen die GPU).

## Stolperfallen (hart erkämpft)

- **Massen-Umbenennen mit `sed`:** `metal_` → `jet_` hat auch
  `#include <metal_stdlib>` im Shader-Text zerstört (alle Pipelines
  scheiterten, Fenster blieb grau). Nach solchen Umbauten immer
  `make shadertest` laufen lassen.
- **Speicherlayout CPU ↔ Shader:** Structs, die per `setVertexBytes`
  hochgeladen werden, müssen `packed_float2/3/4` verwenden. Normales
  `float3`/`float4` als Struct-Feld wird in MSL ausgerichtet (16 Byte)
  und liest ab dem zweiten Vertex falsch. Zeigt sich als wilde
  Spitzen-Geometrie.
- **Autorelease-Pool:** Alles, was aus einem Pd-Clock-Callback läuft,
  braucht ein eigenes `@autoreleasepool` (sonst Speicherwachstum und
  Abstürze nach einiger Zeit).
- **Querbündel-Symbole:** Optionale Abhängigkeiten zwischen Bundles per
  `dlsym` auflösen, nicht per `weak_import` (wird einmalig beim Laden
  gebunden, Ladereihenfolge-abhängig).
- **Gem-ABI:** (nur für Gem-Externals im Altbestand) Gem-Header müssen
  exakt zum installierten Gem-Commit passen.
- **Pd-Dateiformat:** Kommas/Semikolons in Message-Boxen und Kommentaren
  müssen als `\,` / `\;` geschrieben werden, sonst wird der Patch
  zerlegt.
- **Encoder-Zustand:** gibt es für Formen nicht mehr (Befehlsliste). Wer
  einen eigenen Offscreen-Pass kodiert, setzt dort alles selbst.
- **Shader-Test und Leerzeilen:** `tools/extract_msl.py` setzt Shader aus
  aufeinanderfolgenden String-Literalzeilen zusammen; eine Leerzeile oder
  ein Kommentar hinter dem Literal in derselben Zeile schneidet den
  Shader ab (der Test schlägt dann mit „missing }“ fehl).
- **Kein ARC:** alles wird ohne `-fobjc-arc` gebaut. `new…`-Objekte (z. B.
  `newTextureWithDescriptor`) sind +1 und müssen freigegeben werden;
  `jet_texture` hat pro Bang eine Textur verloren (behoben).
- **setVertexBytes** darf höchstens 4 KB: größere Netze (OBJ) brauchen
  einen `MTLBuffer` (`JetDrawDesc.vertexBuffer`).
