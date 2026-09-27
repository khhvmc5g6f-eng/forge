# Forge · Neural Lab — web export

This is the **web export of the Neural Lab panel inside the Forge app**
(`lib/ui/panels/neural_lab/` in this repository). One app, two delivery forms:

- **Native** — the full Forge workstation (macOS today, iOS phone/tablet ready):
  run from source with `flutter run -d macos`, or download the build from
  [Releases](https://github.com/khhvmc5g6f-eng/forge/releases).
- **Web** — this folder, served live from the Forge repo's GitHub Pages:
  **https://khhvmc5g6f-eng.github.io/forge/**

Both share the same verified MLP engine: the native panel uses the pure-Dart port in
`lib/core/neural/mlp_engine.dart`; this export carries the original JavaScript twin of
that engine. Both are gradient-check verified against numerical differentiation to
~1e-10 — see `test/engine.test.mjs` here and `test/core/neural/mlp_engine_test.dart`
in the app.

It doubles as the companion lab for the
[MLclass](https://github.com/erachelson/MLclass) course, Section 6 — Artificial Neural
Networks.

## What you see

- **Cyan pulse waves** — the forward pass: a real training sample flowing in → out.
- **Orange pulse waves** — the backward pass: **real per-edge gradients ∂L/∂w** flowing
  out → in; edges re-colour by gradient magnitude while the wave flows, pulses scale
  with each connection's share of the blame, and layer flashes carry the per-layer
  gradient norm (the vanishing-gradient story, made visible).
- Neurons glow with live activations; connections encode weight sign/magnitude; a
  decision-surface plane evolves live below the network.
- Full analytics dock: train/test loss curves (+ log-scale toggle), decision-boundary
  map, per-layer gradient bars, confusion matrix with precision/recall, and a text
  training-phase chip (idle / learning / converged / plateaued / overfit / diverging).
- Controls: dataset (spiral, moons, circles, XOR, gaussians) + noise, architecture,
  raw vs engineered input features, Adam/SGD, learning rate, batch size, train/wave
  speed. Keyboard: Space train/pause · S step · R regenerate · 1–5 dataset ·
  F fullscreen · ? help. Settings persist in localStorage; `prefers-reduced-motion`
  is respected; every chart carries a live screen-reader summary.

## Verify the engine

```bash
node web_lab/test/engine.test.mjs
```

Runs the numerical gradient check, dataset integrity checks, and convergence
thresholds against the exact engine embedded in `index.html`.

## Deploy

The live site is served from the `gh-pages` branch of this repository (just the
`index.html` from this folder). Update it with:

```bash
cp web_lab/index.html /tmp/index.html
d=$(mktemp -d)
git clone -q --branch gh-pages https://github.com/khhvmc5g6f-eng/forge.git "$d"
cp /tmp/index.html "$d/index.html"
git -C "$d" commit -am "web lab update" && git -C "$d" push
```
