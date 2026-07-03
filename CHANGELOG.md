# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- SVG dimensions no longer trust dvisvgm's bounding box, which dvisvgm 3.0.x
  inflates rightward (up to ~50% on TikZ-matrix diagrams, leaving them
  left-pinned with phantom space) and clips at the bottom (descenders).
  The picture is compiled inside a savebox and its exact TeX box metrics
  (`\wd`, `\ht`+`\dp`) replace the viewBox extents and drive the em width.
  The cache key now includes a filter version, so stale wide-viewBox entries
  are invalidated automatically — but rendered documents should be
  re-rendered once to pick up the corrected sizes.

- Raw TeX in the `preamble` metadata (e.g. `\usetikzlibrary{arrows}`)
  was silently dropped. pandoc parses LaTeX commands in metadata as raw
  inlines/blocks, and `pandoc.utils.stringify` discards raw content; the
  conversion now preserves raw elements verbatim (strings, YAML lists, and
  `|` block scalars).

## [0.1.0] - 2026-07-02

Initial release.

### Added

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
