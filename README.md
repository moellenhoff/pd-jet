# pd-jet

**jet** is a set of GPU-native render-chain objects for [Pure Data](https://puredata.info/) on macOS.
It keeps the authoring model Gem users know — a window, chains that start at a head object,
Gem-style `translateXYZ` / `rotateXYZ` / `scaleXYZ`, `color`, `separator` — but draws with
**Metal** instead of OpenGL, and adds things that are hard to do on a CPU/OpenGL pipeline:
zero-copy live camera video, user-written fragment shaders with parameters that become inlets,
and a small library of effect blocks you can patch together.

> **Status: early and experimental.** It works and is used, but the API still changes.
> macOS on **Apple Silicon** only (see [Requirements](#requirements)).

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [A first patch](#a-first-patch)
- [How it works](#how-it-works)
- [Objects](#objects)
- [Writing your own effects: `jet_shader`](#writing-your-own-effects-jet_shader)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Differences to Gem](#differences-to-gem)
- [Roadmap and known issues](#roadmap-and-known-issues)
- [License](#license)

## Requirements

- A Mac with **Apple Silicon** (M1 or newer). The binaries are arm64 only; Intel Macs are not supported.
- macOS 11 or newer (built with that deployment target; developed on a current macOS).
- Pure Data (vanilla); developed and tested with Pd 0.56.
- To build from source: Xcode command line tools (`xcode-select --install`) and a Pd.app that contains
  the `m_pd.h` header (the standard Pd.app does).

Linux, Windows and other graphics APIs are not planned for now — the project is deliberately Metal-only.

## Install

**Recommended: the install script** (no compiling, no macOS warnings). Files that the Terminal downloads never get
the quarantine flag that makes macOS refuse to load a browser-downloaded plug-in, so this just works:

```bash
tools/install-release.sh              # from a clone of this repo; newest release, or add a tag like v0.2.0
# without a clone (public repo):
curl -fsSL https://raw.githubusercontent.com/moellenhoff/pd-jet/main/tools/install-release.sh | bash
```

It needs either the GitHub CLI (`gh`, logged in — required while the repo is private) or `curl`, puts the folder
`jet` into `~/Documents/Pd/externals/` (the previous one is kept as `jet.previous`) and reminds you of the
Pd path. Then restart Pd.

**From a release zip by hand** (nothing to compile): download `jet-macos-arm64.zip` from the Releases page,
unzip it and put the folder `jet` into `~/Documents/Pd/externals/`. Everything — objects (`*.pd_darwin`),
help patches, effect files (`*.metal`) and sample media — lives flat in that one folder, which is how
Pd finds it. Because the zip came through a browser, macOS marks it as quarantined and may refuse to load the objects;
remove the flag:

```bash
xattr -dr com.apple.quarantine ~/Documents/Pd/externals/jet
```

(If that is not allowed, the Terminal probably lacks access to your Documents folder — System Settings →
Privacy & Security → Files and Folders / Full Disk Access — or use the install script above.)

In Pd, add `~/Documents/Pd/externals/jet` under *Preferences → Path*, and restart Pd completely
(Pd loads a library only once per session, so a restart is also needed after every update).
`INSTALL.txt` in the zip repeats this in German. Open `jet_transform-help.pd` to try it.

**From source:** see [Building from source](#building-from-source).

## A first patch

```
[jet_win]          <- [create(          (a window; "destroy" closes it)
[jet_head 0]                            (the start of a chain; runs once per frame)
|
[jet_color 1 0.5 0.2]
|
[jet_rotateXYZ 0 30 0]
|
[jet_cube 2]
```

`jet_win` opens the window and renders every frame. Each `jet_head` is the start of a chain that is
triggered once per frame; the objects below it draw in order. Parameters are in **Gem units**: the window
is always 8 units tall (y = −4 … +4) and `8 × aspect` wide, so `[jet_rectangle 5.33 4]` fills a 4:3
window exactly as `[rectangle 5.33 4]` does in Gem.

A video-effect chain looks like this:

```
[jet_head 0]
|
[jet_video]            camera, zero-copy on the GPU (send it "start" once)
|
[jet_hsv 40 1.2]
|
[jet_blur 3]
|
[jet_rectangle 4.2 3.2]
```

## How it works

- **Chains.** A `jet_head` hands a bang down its chain every frame. Shapes don't draw immediately;
  they *record* draw commands and the window executes all of them in one Metal render pass at the end
  of the frame, sorted (translucent shapes last, back to front).
- **Chain state.** Transform, colour, depth test and the current texture belong to the chain: every
  chain starts clean, and `[jet_separator]` saves and restores the state around a branch (just like
  `[separator]` in Gem). Branch with `[t b b]`, never with a plain fan-out — Pd doesn't define the order
  of a fan-out.
- **Inlets like Gem.** The left inlet takes the chain (bang) and messages; every parameter has its own
  inlet to the right. Parameter inlets only *store* — the next bang from the chain uses them (the chain
  is banged every frame).
- **Textures.** Effects work on the chain's *current texture*. `[jet_share name]` publishes it under a
  name, `[jet_use name]` picks it up in any chain, in the same or the next frame. Names belong to a window.
- **Everything on the GPU.** Effects render into pooled GPU textures; nothing is copied back to the CPU.

## Objects

| Group | Objects |
|---|---|
| Window / chain | `jet_win` (window, borderless fullscreen on any display, camera, light, render on/off), `jet_head` (chain start; optional priority and window name) |
| State | `jet_color r g b a`, `jet_depth`, `jet_separator`, `jet_translateXYZ`, `jet_rotateXYZ`, `jet_scaleXYZ` |
| Shapes | `jet_rectangle`, `jet_triangle`, `jet_cube` (real 3D geometry; textured if a texture is current) |
| Scenes | `jet_render` (renders a sub-scene with its own camera into a texture) |
| Sources | `jet_video` (live camera), `jet_movie` and `jet_movie~` (video file with audio-synced playback), `jet_image` + `jet_texture` (image file), `jet_perlin` (noise), `jet_feedback` |
| Named textures | `jet_share`, `jet_use` |
| Effect blocks | `jet_level`, `jet_hsv`, `jet_blur`, `jet_mix`, `jet_uvtransform`, `jet_threshold` |
| Your own effects | `jet_shader` |

Every object has a help patch in `help/` (installed next to the objects). Send `info` to a
`jet_shader` or an effect block to list its inlets in the Pd window.

## Writing your own effects: `jet_shader`

`[jet_shader file.metal]` runs a Metal fragment shader on the current texture and passes the result on.
The file is plain Metal Shading Language plus comment directives; the declared parameters become inlets:

```metal
// @input src                      first input = the chain's current texture
// @param float amount = 0.5       becomes a float inlet
// @param color tint = 1 0.6 0.3 1 float2/float3/float4/color become list inlets

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 c = t.src.sample(t.smp, uv);
  return mix(c, p.tint, p.amount);
}
```

Further directives: more `@input` lines (named textures published with `jet_share`), `@feedback`
(`t.prev` = this effect's previous output), `@size w h`, and `@history N` (a ring buffer of the last N
input frames, read with `jet_history(t, p, uv, framesAgo)` — enough to write a slit-scan, see
`shaders/slitscan.metal`). `p.time`, `p.frame` and `p.resolution` are always available.

Saving the file while the patch runs updates the picture within a fraction of a second; compile errors
show up in the Pd window with the line number of *your* file. Examples are in `shaders/`.

The built-in effect blocks are made the same way — their shaders are in `fx/` and are embedded at build
time, so a new block is a short `.metal` file plus a four-line `.mm` file.

## Building from source

```bash
git clone https://github.com/moellenhoff/pd-jet.git
cd pd-jet
make PD_APP=/Applications/Pd-0.56-2.app       # builds build/*.pd_darwin
make shadertest                               # compiles every embedded shader and checks the parameter layout on the GPU
make install                                  # builds, tests, copies everything to ~/Documents/Pd/externals/jet
```

Other targets: `make install-only` (copy what is already built, no compiling) and
`make package` (a ready-to-copy folder and `dist/jet-macos-arm64.zip` for other Macs).
`PD_EXTERNALS_DIR` overrides the install location.

## Project layout

```
src/      one .mm file per Pd object, jet_shared.h (the interface between objects),
          jet_fx_object.h / jet_shader_core.h (jet_shader and the effect blocks)
fx/       shaders of the built-in effect blocks (embedded at build time)
shaders/  example effects for jet_shader (installed next to the objects)
help/     help patches
assets/   small media files the help patches use
tools/    shader test tooling, packaging helpers
ROADMAP.md  decisions, conventions, open points
```

Each object is its own bundle; they find each other's exported functions (`jet_shared.h`) when Pd
loads them, so a `jet_win` has to be loaded before the other objects (put it first in the patch) and all
bundles must come from the same build.

## Differences to Gem

- Metal instead of OpenGL, so macOS only; no GEM-style `gemlist` — chains are plain bangs with state kept
  by the window.
- Parameter inlets are cold and the chain is banged every frame; there is no render-on-change.
- Shapes carry no position or colour arguments — use `jet_translateXYZ` and `jet_color` (as in Gem's
  own idiom, but enforced).
- Textures are GPU objects (current texture, named textures), not CPU pixel buffers; effects are shaders,
  not CPU loops.
- jet does **not** load Gem objects and is not compatible with Gem's objects or binaries.

## Roadmap and known issues

See [ROADMAP.md](ROADMAP.md). Planned: more effect blocks
(edge, displace, mirror, tile), fusing neighbouring per-pixel effects into one GPU pass, compute shaders,
OBJ model loading with lighting. Known issue: reverse video playback is choppy.

## License

pd-jet is free software, released under the **GNU General Public License, version 3** (see [LICENSE](LICENSE)).
Copyright © 2026 Moellenhoff.

jet is inspired by [Gem](https://github.com/umlaeute/Gem), the Graphics Environment for Multimedia,
and by TouchDesigner's texture operators.
