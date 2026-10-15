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
| 2 | **Befehlsliste statt offenem Encoder**: Objekte zeichnen Befehle pro Render-Pass auf, das Fenster führt sie am Frame-Ende aus | ja – Herzstück des Umbaus | 5–8 | offen |
| 3 | **Zustand pro Kette** (Transform, Textur, Tiefentest, Blending) beim Kettenstart sauber zurücksetzen | ja | 1–2 | erledigt (`jet_win_beginChain`; Blending folgt, sobald es Blending gibt) |
| 4 | **Benannte Textur-Handles** zusätzlich zum „current texture“ (bleibt der normale Gem-artige Fluss) | ja, Hybrid | 3–5 | offen |
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
- Eigene Shader: `jet_shader` (Fragment, Datei, Live-Reload, benannte
  Parameter), danach `jet_compute` (Compute-Shader)
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
  (y = -4..+4) und 8·Aspekt breit. 2D-Formen (`jet_rectangle`,
  `jet_triangle`) und die 2D-Transforms arbeiten darin; die 3D-Standard-
  kamera (z = 4, fov 90) macht die z=0-Ebene ebenfalls 8 Einheiten hoch,
  sodass 2D und 3D denselben Maßstab haben. `[jet_rectangle 0 0 5.33 4]`
  füllt ein 800x600-Fenster wie `[rectangle 5.33 4]` in Gem. Parameter
  von Rechteck/Dreieck sind Halbmaße.
- **Zustandsbereiche** (Kette / Frame / Objekt) und die Regel, dass jedes
  zeichnende Objekt seinen Encoder-Zustand selbst setzt, stehen im Kopf
  von `src/jet_shared.h`.
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
  Offline-Metal-Toolchain.

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
- **Encoder-Zustand:** Depth-Stencil-Zustand bleibt am geteilten Encoder
  bestehen; 2D-Formen setzen daher explizit „kein Tiefentest“.
