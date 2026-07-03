# teacup

A Quarto filter that renders TikZ diagrams as **inline SVG in the DOM** — real
`<path>`/`<text>` elements the page's CSS sees and styles directly — instead of
opaque `<img>` files. Built to solve the two classic pain points of TikZ in
Quarto: size coordination with surrounding text, and light/dark theming.

## How it works

Each `{.tikz}` code block is compiled `dvilualatex → dvisvgm` (text kept as SVG
`<text>` with embedded WOFF2 subsets of the TeX fonts), then post-processed:

- **Size:** `width`/`height` attributes are stripped (only `viewBox` remains)
  and the SVG is sized in `em` (TeX pt width ÷ base font size). Diagrams —
  geometry and labels together — scale with the surrounding font size.
- **Color:** the default ink is a sentinel (`#010101`) that `teacup.css` maps
  to `currentColor`, so labels and strokes inherit the page text color. Named
  palette colors (`accent`, `accent2`–`accent5`, `muted`, `canvas`) are
  sentinels remapped to CSS custom properties (`--teacup-accent`, …) via
  attribute selectors. Dark mode is therefore pure CSS; no re-rendering.
- **Scoping:** dvisvgm names embedded font subsets and text classes identically
  in every SVG (`cmr10`, `text.f0`). Inline `<style>` is document-global, so
  fonts and selectors are renamed/scoped per diagram (hash-derived id) to
  prevent one diagram's font subset from shadowing another's.
- **Caching:** compiled SVGs are cached in `_teacup-cache/` keyed by SHA-1 of the
  generated TeX source.
- **PDF builds:** for `latex` output the TikZ passes through as raw LaTeX.

## Install

```sh
quarto add fNBU/teacup
```

This installs the extension under the `_extensions` subdirectory of your
project. If you're using version control, check that directory in. Requires
Quarto ≥ 1.4 and the TeX toolchain listed under Requirements below.

## Usage

````markdown
---
filters: [teacup]
---

```{.tikz}
\draw[->, thick, accent] (0,0) -- (3,1) node[right] {$u$};
```
````

Bare drawing commands are wrapped in `tikzpicture` automatically; a full
`\begin{tikzpicture}…\end{tikzpicture}` is also accepted.

Block attributes: `width="30%"` (or any CSS width) overrides the computed em
width; extra classes and an `#id` are carried onto the `<svg>` element.

Document metadata under `teacup:`:

- `preamble:` extra LaTeX preamble (string or list)
- `font-size:` base font size in pt: 10, 11 or 12 (default 10; article class
  ignores other values, which would desynchronize the em conversion)
- `cache:` cache directory (default `_teacup-cache`)
- `engine:` `latex` (default, lightest) or `dvilualatex` (full unicode input;
  needs `texlive-luatex`)

## Theming

Override the custom properties in your theme SCSS/CSS:

```css
body.quarto-dark { --teacup-accent: #ffc04d; }
```

Defaults for `body.quarto-light` / `body.quarto-dark` ship in `teacup.css`.
The sentinel-remapping rules themselves are generated from `PALETTE` in
`teacup.lua` at render time and injected into the document head — `PALETTE`
is the single source of truth for sentinel hexes and palette names.

## Requirements

Minimal Debian/Ubuntu install:

```sh
apt install texlive-pictures dvisvgm
```

(`texlive-pictures` provides pgf/TikZ and pulls `texlive-latex-base`,
`texlive-latex-recommended` (for `xcolor`), `texlive-base` and
`texlive-binaries` — about 210 MB total. Neither `texlive-latex-extra` nor
`texlive-luatex` is needed: the template uses `article`, not `standalone`,
and the default engine is plain `latex`.)

- `dvisvgm` ≥ 3.0 (3.1+ not required; `--currentcolor` is not used)
- Quarto ≥ 1.4

## Development

Common commands via [just](https://github.com/casey/just):

- `just test` — unit tests (`test/unit.lua`, pure Lua post-processing, no TeX
  needed) plus end-to-end tests (`test/e2e.sh`, renders `test/fixtures/` and
  asserts on the HTML: inline SVGs, em sizing, width override, font/style
  scoping, single CSS injection, cache reuse, and useful LaTeX error output)
- `just example` — render the demo; `just preview` — render and open it
- `just clean` — remove rendered outputs and caches

The unit tests load the filter with `TEACUP_TEST=1`, which makes it expose
its internals as `teacup_internals`.

## Demo

`quarto render example.qmd` — three diagrams exercising em-sizing, palette
colors, math labels, and a width override. Toggle the page's dark mode to see
diagrams follow the theme.

## Contributing & license

See `CONTRIBUTING.md`. MIT-licensed (`LICENSE`).
