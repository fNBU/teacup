#!/usr/bin/env bash
# End-to-end regression tests: render fixtures with quarto and assert
# invariants on the produced HTML. Run from the repo root: test/e2e.sh
set -u

cd "$(dirname "$0")/.."
FIX=test/fixtures
OUT=$FIX/basic.html
failures=0

check() { # check <description> — reads exit status of the previous command
  if [ $? -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures+1)); fi
}

# Start from a clean slate so stale artifacts can't mask failures, but keep
# everything after the run for inspection (`just clean` removes it).
rm -rf "$FIX"/basic.html "$FIX"/broken.html "$FIX"/preamble.html \
       "$FIX"/basic_files "$FIX"/broken_files "$FIX"/preamble_files \
       "$FIX"/basic.pdf "$FIX"/basic.tex "$FIX"/_fixture-cache

# --- successful render ---------------------------------------------------
quarto render "$FIX/basic.qmd" >/dev/null 2>&1 && [ -f "$OUT" ]
check "basic.qmd renders"

[ "$(grep -c '<svg' "$OUT")" -eq 3 ]
check "three inline <svg> elements"

! grep -q '<img' "$OUT"
check "no <img> elements"

! grep -qE "width='[0-9.]+pt'" "$OUT"
check "no fixed pt width attributes on svg roots"

grep -q 'style="width:[0-9.]*em;max-width:100%;height:auto;"' "$OUT"
check "em-based width styles present"

grep -q 'style="width:25%;max-width:100%' "$OUT"
check "width override honored"

grep -q 'id="fig-circ"' "$OUT"
check "user-supplied id on svg root"

# scoping: no font-family may appear without a hash/id suffix
! grep -oE 'font-family:cm[a-z0-9]+[;}]' "$OUT" | grep -q .
check "all font families are hash-suffixed"

[ "$(grep -o 'id="teacup-[0-9a-f]*"' "$OUT" | sort | uniq -d | wc -l)" -eq 0 ]
check "hash-derived ids are unique"

[ "$(grep -c 'fill="#010101"\]{fill:currentColor}' "$OUT")" -eq 1 ]
check "generated palette CSS injected exactly once"

grep -q 'currentColor' "$OUT" && grep -q 'var(--teacup-accent' "$OUT"
check "ink and accent remapping rules present"

# caching: a second render must reuse the cache (same svg files, no recompile)
before=$(ls "$FIX/_fixture-cache" | sort)
quarto render "$FIX/basic.qmd" >/dev/null 2>&1
after=$(ls "$FIX/_fixture-cache" | sort)
[ -n "$before" ] && [ "$before" = "$after" ]
check "second render reuses the cache"

# --- PDF output ----------------------------------------------------------
# LaTeX passthrough: diagrams must arrive as raw tikzpicture environments,
# with teacup's colors/libraries injected into the preamble exactly once.
pdf_log=$(quarto render "$FIX/basic.qmd" --to pdf -M keep-tex:true 2>&1)
pdf_status=$?
if [ $pdf_status -ne 0 ] || [ ! -f "$FIX/basic.pdf" ]; then
  echo "--- PDF render output (tail) ---"
  printf '%s\n' "$pdf_log" | tail -40
  echo "--------------------------------"
  false
fi
check "basic.qmd renders to PDF"

TEX=$FIX/basic.tex
[ "$(grep -c '\\begin{tikzpicture}' "$TEX")" -eq 3 ]
check "three raw tikzpicture environments in the TeX"

! grep -q '<svg' "$TEX"
check "no HTML leaked into the TeX"

[ "$(grep -c '\\usepackage{tikz}' "$TEX")" -eq 1 ]
check "tikz package injected exactly once"

for color in ink accent accent2 muted; do
  grep -q "\\\\definecolor{$color}" "$TEX"
  check "palette color '$color' defined in preamble"
done

grep -q 'every picture/.style={color=ink}' "$TEX"
check "every-picture ink default injected"

# --- metadata preamble ---------------------------------------------------
# preamble.qmd needs \usetikzlibrary{arrows} from its metadata preamble to
# compile at all; a dropped preamble fails the render. (Regression: raw TeX
# in metadata was silently discarded by stringify.)
quarto render "$FIX/preamble.qmd" >/dev/null 2>&1 && [ -f "$FIX/preamble.html" ]
check "preamble.qmd renders (metadata \\usetikzlibrary reaches LaTeX)"

grep -q '<svg' "$FIX/preamble.html"
check "preamble fixture produced an inline <svg>"

# --- failing render ------------------------------------------------------
err=$(quarto render "$FIX/broken.qmd" 2>&1)
status=$?
[ $status -ne 0 ]
check "broken.qmd fails the render"

echo "$err" | grep -q 'LaTeX compilation failed'
check "error message identifies LaTeX failure"

echo "$err" | grep -q 'thiscommanddoesnotexist'
check "error message includes the offending source"

echo
echo "$failures failure(s)"
exit $((failures > 0))
