# v0.1.0

Initial release.

- `{.tikz}` code blocks render as inline SVG in the DOM (no `<img>`):
  compiled with `latex` → `dvisvgm`, cached by content hash.
- Diagrams are sized in `em`, so they scale with the surrounding font size.
- Ink follows the page text color via `currentColor`; palette colors
  (`accent`, `accent2`–`accent5`, `muted`, `canvas`) are themable through
  `--teacup-*` CSS custom properties — dark mode needs no re-rendering.
- Per-diagram scoping of dvisvgm's embedded font subsets and style rules.
- Block attributes: `width`, extra classes, `id`. Document metadata:
  `preamble`, `font-size` (10/11/12), `cache`, `engine` (`latex` or
  `dvilualatex`).
- Raw-LaTeX passthrough for PDF builds, with the TikZ setup (package,
  libraries, palette colors, ink default) injected into the document
  preamble so passed-through diagrams compile unchanged.
