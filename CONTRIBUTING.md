# Contributing to teacup

## Setup

```sh
apt install texlive-pictures dvisvgm   # TeX toolchain (see README)
# quarto: https://quarto.org/docs/get-started/ (>= 1.4)
# just:   https://github.com/casey/just
```

Static analysis needs two more tools on `PATH`:

- [lua-language-server](https://github.com/LuaLS/lua-language-server) — type/nil checker
- [luacheck](https://github.com/lunarmodules/luacheck) — linter

Then run `just install-hooks` once to enable the checked-in pre-commit hook
(`.githooks/pre-commit`), which runs `just check`.

Verify the setup with `just check` and `just test`.

## Development workflow

- `just check` — static analysis: `lua-language-server --check` and
  `luacheck`. **PRs are blocked until `just check` passes.**
- `just test` — full suite: `test-unit` (pure Lua, ~1 s) and `test-e2e`
  (renders `test/fixtures/`, ~15 s)
- `just example` / `just preview` — render the demo document
- `just clean` — remove rendered outputs and caches

Every behavioral change needs a test: post-processing logic belongs in
`test/unit.lua` (it exercises the internals exposed under `TEACUP_TEST=1`),
anything involving the TeX toolchain or Quarto integration belongs in
`test/e2e.sh`. Fixed bugs get a regression check (see "width override with %
survives gsub" for the pattern).

## Changelog and versioning

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Both are normative for this project: every user-visible change lands with an
entry under the `Unreleased` heading in the same commit, and releases bump
the version according to SemVer rules.

## Architecture in one paragraph

`_extensions/teacup/teacup.lua` turns `{.tikz}` code blocks into inline SVG:
LaTeX source is generated from `TEX_TEMPLATE`, compiled (`latex` →
`dvisvgm`), cached in `_teacup-cache/` by SHA-1 of engine + source, then
post-processed — `width`/`height` stripped in favor of an em-based CSS width,
per-diagram scoping of dvisvgm's `<style>`/font names, sentinel colors left
for CSS to remap. `teacup.css` carries layout and theme variable defaults.

## Invariants to preserve

- **PALETTE is the single source of truth.** Sentinel hexes, LaTeX color
  definitions, and the remapping CSS all derive from the `PALETTE` table in
  `teacup.lua`. Never hard-code a sentinel hex anywhere else; the unit tests
  enforce this.
- **Everything the page needs must be in the DOM.** No `<img>`, no external
  fetches, no JavaScript requirements for correct display. Diagram ink uses
  `currentColor`; themable colors go through `--teacup-*` custom properties.
- **Scoping is load-bearing.** Inline `<style>` is document-global and
  dvisvgm reuses names (`cmr10`, `text.f0`) across SVGs with *different* font
  subsets. Any new inlined output must stay scoped to the per-diagram id.
- **Sizes stay relative.** Diagram width is expressed in `em` (TeX pt ÷ base
  font size) so diagrams track the surrounding font size. Don't introduce
  absolute px/pt sizing.
- **Fail loudly and usefully.** LaTeX/dvisvgm failures must surface the log
  tail and the offending source. Don't swallow errors or cache partial
  output.
- **Keep the dependency floor low.** The default pipeline must work with
  `texlive-pictures` + `dvisvgm` alone (no `standalone`, no `texlive-luatex`,
  dvisvgm ≥ 3.0 — avoid options newer than that).

## Style

- Lua: match the existing code — `local` functions, early `error()` with a
  `[teacup]`-prefixed message, comments only for non-obvious constraints.
- Validate external input at the boundary (metadata values are checked
  against whitelists/ranges before use; keep it that way — engine names are
  interpolated into a shell command).

## License

By contributing you agree that your contributions are licensed under the MIT
license (see `LICENSE`).
