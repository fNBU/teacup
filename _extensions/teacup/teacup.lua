-- teacup: compile TikZ code blocks to SVG and inline the SVG into the DOM.
--
-- Pipeline per block:  tikz source -> standalone .tex -> dvilualatex -> .dvi
--                      -> dvisvgm (woff2 text, currentColor) -> post-process -> RawBlock html
--
-- Post-processing makes the SVG a first-class page citizen:
--   * width/height attributes stripped; size set in em so diagrams scale with
--     the surrounding font size (labels included, proportionally)
--   * black is emitted as currentColor, so labels/strokes inherit the page's
--     text color (dark mode works with zero extra rules)
--   * palette colors (teacup's named colors) are left as sentinel hexes that
--     teacup.css remaps to CSS custom properties via attribute selectors
--
-- Block usage:
--   ```{.tikz}
--   \begin{tikzpicture} ... \end{tikzpicture}
--   ```
-- Attributes: width="14em" (override computed width), class=..., id=...
--
-- Document metadata (all optional), under `teacup:`:
--   preamble:     extra LaTeX preamble (string or list of strings)
--   font-size:    base font size in pt used for the em conversion (default 10)
--   cache:        cache directory (default "_teacup-cache")

-- Part of the cache key: bump whenever compilation or SVG correction changes
-- in a way the tex source alone doesn't capture, so stale entries can't be
-- served.
local FILTER_VERSION = "3"

local FONT_SIZE_PT = 10.0
local CACHE_DIR = "_teacup-cache"
local EXTRA_PREAMBLE = ""

-- Sentinel palette: the single source of truth. The LaTeX preamble defines
-- these as named colors, and the sentinel-remapping CSS (attribute selectors
-- -> CSS custom properties) is generated from this table at render time, so
-- the hex values cannot drift between files.
-- Accent hexes are the Okabe-Ito colorblind-safe palette, so the raw SVG is
-- still legible anywhere the page CSS doesn't reach.
-- `css` overrides the value the sentinel maps to (default:
-- var(--teacup-<name>, #<sentinel>)).
local PALETTE = {
  -- "ink" is the default draw/text color; mapping it to currentColor makes
  -- diagrams inherit the page text color. (A sentinel + attribute selector
  -- because dvisvgm 3.0 lacks --currentcolor, and default-black elements
  -- carry no fill/stroke attribute to select on.)
  { name = "ink",     hex = "010101", css = "currentColor" },
  { name = "accent",  hex = "E69F00" },
  { name = "accent2", hex = "0072B2" },
  { name = "accent3", hex = "009E73" },
  { name = "accent4", hex = "D55E00" },
  { name = "accent5", hex = "CC79A7" },
  { name = "muted",   hex = "8A8A8A" },
  -- fills that should follow the page background; invisible unless themed
  { name = "canvas",  hex = "FDFDFC", css = "var(--teacup-canvas, transparent)" },
}

-- CSS remapping each sentinel to its themable value, generated from PALETTE.
-- dvisvgm writes hex colors lowercased; attribute selectors are exact-match.
local function palette_css()
  local rules = {}
  for _, c in ipairs(PALETTE) do
    local hex = "#" .. c.hex:lower()
    local value = c.css or string.format("var(--teacup-%s, %s)", c.name, hex)
    rules[#rules + 1] = string.format(
      '.teacup [fill=%q]{fill:%s}.teacup [stroke=%q]{stroke:%s}',
      hex, value, hex, value)
  end
  return table.concat(rules, "\n")
end

local function palette_preamble()
  local lines = {}
  for _, c in ipairs(PALETTE) do
    lines[#lines + 1] = string.format("\\definecolor{%s}{HTML}{%s}", c.name, c.hex)
  end
  return table.concat(lines, "\n")
end

-- TikZ setup shared by both output paths: the standalone compile for HTML
-- and the in-header injection for LaTeX/PDF builds. EXTRA_PREAMBLE is read
-- at call time (after Meta has run).
local function tikz_preamble()
  return table.concat({
    "\\usetikzlibrary{arrows.meta,calc,positioning,decorations.pathreplacing,decorations.markings}",
    palette_preamble(),
    "\\tikzset{every picture/.style={color=ink}}",
    EXTRA_PREAMBLE,
  }, "\n")
end

-- article instead of standalone: standalone.cls is the only file that pulls
-- Debian's texlive-latex-extra (~80 MB). dvisvgm computes a tight bounding
-- box from the ink itself, so page-cropping is unnecessary; \pagestyle{empty}
-- keeps page numbers from contributing ink.
-- The picture goes through a savebox so its exact TeX dimensions can be read
-- back from the log (TEACUP-DIM): dvisvgm 3.0.x miscomputes the bounding box
-- of pgf's mirror-transform text specials, inflating the viewBox rightward
-- and clipping descenders, so its reported size cannot be trusted.
-- lrbox, not \savebox{...}: TikZ matrices break inside the argument form.
-- overlay is neutralized (standalone compile only, not the PDF passthrough):
-- it excludes ink from pgf's bounding box, which in a standalone picture can
-- only clip that ink out of the viewBox — here all ink must count.
local TEX_TEMPLATE = [[
\documentclass[%spt,dvisvgm]{article}
\usepackage{amsmath,amssymb}
\def\pgfsysdriver{pgfsys-dvisvgm.def}
\usepackage{tikz}
\tikzset{overlay/.code={}}
%s
\pagestyle{empty}
\newsavebox\teacupbox
\begin{document}
\begin{lrbox}{\teacupbox}%%
%s%%
\end{lrbox}%%
\typeout{TEACUP-DIM: \the\wd\teacupbox\space\the\ht\teacupbox\space\the\dp\teacupbox}
\usebox\teacupbox
\end{document}
]]

-- Engines that produce DVI for dvisvgm. `latex` (pdfTeX in DVI mode) is the
-- lightest; `dvilualatex` adds full unicode at the cost of texlive-luatex.
-- Whitelist because the value is interpolated into a shell command.
local ENGINES = { latex = true, dvilualatex = true }
local ENGINE = "latex"

local palette_css_injected = false
local latex_preamble_injected = false

-- pandoc.utils.stringify drops RawInline/RawBlock content, and pandoc parses
-- LaTeX commands in metadata strings (e.g. \usetikzlibrary{arrows}) as raw
-- TeX — so a stringify-only conversion silently discards most preambles.
-- Convert manually, preserving raw elements verbatim.
local function inlines_to_string(inlines)
  local parts = {}
  for _, el in ipairs(inlines) do
    if el.t == "RawInline" then parts[#parts + 1] = el.text
    elseif el.t == "SoftBreak" or el.t == "LineBreak" then parts[#parts + 1] = "\n"
    else parts[#parts + 1] = pandoc.utils.stringify(el) end
  end
  return table.concat(parts)
end

local function meta_to_string(v)
  if v == nil then return nil end
  local ty = pandoc.utils.type(v)
  if ty == "List" then -- YAML list: one entry per line
    local parts = {}
    for _, item in ipairs(v) do parts[#parts + 1] = meta_to_string(item) end
    return table.concat(parts, "\n")
  elseif ty == "Inlines" then
    return inlines_to_string(v)
  elseif ty == "Blocks" then -- YAML block scalar (|): one Para/RawBlock per chunk
    local parts = {}
    for _, b in ipairs(v) do
      if b.t == "RawBlock" then parts[#parts + 1] = b.text
      elseif b.content then parts[#parts + 1] = inlines_to_string(b.content)
      else parts[#parts + 1] = pandoc.utils.stringify(b) end
    end
    return table.concat(parts, "\n")
  end
  return pandoc.utils.stringify(v)
end

local function get_meta(meta)
  local opts = meta["teacup"]
  if opts then
    local pre = meta_to_string(opts["preamble"])
    if pre then EXTRA_PREAMBLE = pre end
    local fs = meta_to_string(opts["font-size"])
    if fs then
      local n = tonumber(fs)
      -- article only honors 10/11/12pt; anything else would silently compile
      -- at 10pt and desynchronize the em conversion
      if n == 10 or n == 11 or n == 12 then FONT_SIZE_PT = n
      else io.stderr:write("[teacup] warning: font-size must be 10, 11 or 12; ignoring '" .. fs .. "'\n") end
    end
    local cd = meta_to_string(opts["cache"])
    if cd then CACHE_DIR = cd end
    local eng = meta_to_string(opts["engine"])
    if eng then
      if ENGINES[eng] then ENGINE = eng
      else io.stderr:write("[teacup] warning: unknown engine '" .. eng .. "'; using " .. ENGINE .. "\n") end
    end
  end
end

local function ensure_dir(path)
  pandoc.system.make_directory(path, true)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("a")
  f:close()
  return content
end

local function write_file(path, content)
  local f, err = io.open(path, "wb")
  if not f then error("[teacup] cannot write " .. path .. ": " .. tostring(err)) end
  f:write(content)
  f:close()
end

-- Run a command; return success, combined output. Never silently swallows.
local function run(cmd)
  local pipe, perr = io.popen(cmd .. " 2>&1")
  if not pipe then
    error("[teacup] cannot spawn command '" .. cmd .. "': " .. tostring(perr))
  end
  local output = pipe:read("a") or ""
  local ok = pipe:close()
  return ok, output
end

local function tail(s, n)
  local lines = {}
  for line in s:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local start = math.max(1, #lines - n)
  return table.concat(lines, "\n", start)
end

-- Overwrite the SVG root's viewBox/width/height with the TeX box metrics.
-- dvisvgm's left and top edges are trustworthy (all observed inflation is
-- rightward, all clipping at the bottom), so min-x/min-y are kept and only
-- the extents are replaced: width = \wd, height = \ht + \dp.
local function fix_viewbox(svg, wd, ht, dp)
  local minx, miny = svg:match("viewBox=['\"]([%-%d%.]+) ([%-%d%.]+) [%-%d%.]+ [%-%d%.]+['\"]")
  if not minx then
    io.stderr:write("[teacup] warning: no viewBox in dvisvgm output; keeping its dimensions\n")
    return svg
  end
  local h = ht + dp
  svg = svg:gsub("viewBox=['\"][^'\"]*['\"]",
    string.format("viewBox='%s %s %.4f %.4f'", minx, miny, wd, h), 1)
  svg = svg:gsub("width=['\"][^'\"]*['\"]", string.format("width='%.4fpt'", wd), 1)
  svg = svg:gsub("height=['\"][^'\"]*['\"]", string.format("height='%.4fpt'", h), 1)
  return svg
end

-- Compile tex source to raw SVG text, using the cache when possible.
local function compile_tikz(tex_source)
  local hash = pandoc.utils.sha1(FILTER_VERSION .. "\n" .. ENGINE .. "\n" .. tex_source)
  ensure_dir(CACHE_DIR)
  local cached = CACHE_DIR .. "/" .. hash .. ".svg"
  local svg = read_file(cached)
  -- an empty/truncated cache entry (e.g. from an interrupted run) is a miss
  if svg and svg:find("<svg") then return svg, hash end

  local result
  pandoc.system.with_temporary_directory("teacup", function(tmp)
    local texfile = tmp .. "/fig.tex"
    write_file(texfile, tex_source)

    local ok, log = run(string.format(
      "cd %q && " .. ENGINE .. " --interaction=nonstopmode --halt-on-error fig.tex", tmp))
    if not ok or not read_file(tmp .. "/fig.dvi") then
      write_file(CACHE_DIR .. "/last-failure.log", log .. "\n=== SOURCE ===\n" .. tex_source)
      error("[teacup] LaTeX compilation failed. Log tail:\n" .. tail(log, 30) ..
            "\n[teacup] Source:\n" .. tex_source)
    end

    local ok2, out2 = run(string.format(
      "cd %q && dvisvgm --font-format=woff2 --exact-bbox --optimize -o fig.svg fig.dvi", tmp))
    result = read_file(tmp .. "/fig.svg")
    if not ok2 or not result then
      error("[teacup] dvisvgm failed:\n" .. out2)
    end

    local wd, ht, dp = log:match("TEACUP%-DIM: ([%d%.]+)pt ([%d%.]+)pt ([%d%.]+)pt")
    if wd then
      result = fix_viewbox(result, tonumber(wd), tonumber(ht), tonumber(dp))
    else
      io.stderr:write("[teacup] warning: TEACUP-DIM not found in the LaTeX log; " ..
        "keeping dvisvgm's (possibly inflated) dimensions\n")
    end
  end)

  if not result:find("<svg") then
    error("[teacup] dvisvgm produced no <svg> element; refusing to cache")
  end
  write_file(cached, result)
  return result, hash
end

-- Turn raw dvisvgm output into an inline-ready fragment sized in em.
local function postprocess(svg, hash, attr_width, extra_classes, user_id)
  -- drop the XML prolog and comments; inline HTML must not carry them
  svg = svg:gsub("<%?xml.-%?>%s*", "")
  svg = svg:gsub("<!%-%-.-%-%->%s*", "")

  -- Inline <style> blocks are document-global in HTML, and dvisvgm names its
  -- (subsetted!) embedded fonts and text classes identically in every SVG
  -- (cmr10, text.f0, ...). Without scoping, one diagram's font subset would
  -- shadow another's and glyphs would silently disappear. Scope both to a
  -- per-diagram id derived from the content hash.
  local id = user_id ~= "" and user_id or ("teacup-" .. hash:sub(1, 8))
  svg = svg:gsub("(<style.-</style>)", function(style)
    style = style:gsub("font%-family:%s*([%w%.%-]+)", "font-family:" .. "%1-" .. hash:sub(1, 8))
    style = style:gsub("text%.f", "#" .. id .. " text.f")
    return style
  end)

  local open_tag = svg:match("<svg[^>]*>")
  if not open_tag then
    error("[teacup] unexpected dvisvgm output: no <svg> root element found")
  end

  local width_pt = tonumber(open_tag:match("width=['\"]([%d%.]+)pt['\"]"))
  local new_tag = open_tag
    :gsub("%s+width=['\"][^'\"]*['\"]", "")
    :gsub("%s+height=['\"][^'\"]*['\"]", "")

  local css_width
  if attr_width then
    css_width = attr_width
  elseif width_pt then
    css_width = string.format("%.4fem", width_pt / FONT_SIZE_PT)
  else
    io.stderr:write("[teacup] warning: could not read SVG width; falling back to auto\n")
    css_width = "auto"
  end

  local class = "teacup" .. (extra_classes ~= "" and (" " .. extra_classes) or "")
  -- overflow:visible: ink outside the viewBox (use as bounding box,
  -- \pgfinterruptboundingbox) still renders, overhanging the layout box as
  -- it would on a printed page, instead of being silently clipped.
  local svg_attrs = string.format(
    '<svg id=%q class=%q style="width:%s;max-width:100%%;height:auto;overflow:visible;" role="img"',
    id, class, css_width)
  -- function replacements: attribute values may contain '%', which is special
  -- in gsub replacement strings
  new_tag = new_tag:gsub("<svg", function() return svg_attrs end, 1)
  return svg:gsub("<svg[^>]*>", function() return new_tag end, 1)
end

local function CodeBlock(el)
  if not el.classes:includes("tikz") then return nil end

  local body = el.text
  if not body:match("\\begin{tikzpicture}") then
    body = "\\begin{tikzpicture}\n" .. body .. "\n\\end{tikzpicture}"
  end

  -- Non-HTML formats: pass TikZ through as raw LaTeX (PDF builds of the
  -- book). The blocks reference teacup's named colors and rely on the
  -- every-picture ink default, so the preamble that the HTML path bakes into
  -- each standalone compile must be injected into the document here.
  if quarto.doc.is_format("latex") then
    if not latex_preamble_injected then
      quarto.doc.include_text("in-header",
        "\\usepackage{tikz}\n" .. tikz_preamble())
      latex_preamble_injected = true
    end
    return pandoc.RawBlock("latex", body)
  end
  if not quarto.doc.is_format("html") then
    return nil
  end

  quarto.doc.add_html_dependency({
    name = "teacup",
    version = "0.1.0",
    stylesheets = { "teacup.css" },
  })
  -- sentinel-remapping rules, generated from PALETTE; inject once per document
  if not palette_css_injected then
    quarto.doc.include_text("in-header", "<style>\n" .. palette_css() .. "\n</style>")
    palette_css_injected = true
  end

  local tex = string.format(TEX_TEMPLATE,
    string.format("%g", FONT_SIZE_PT), tikz_preamble(), body)

  local svg, hash = compile_tikz(tex)

  local extra_classes = {}
  for _, c in ipairs(el.classes) do
    if c ~= "tikz" then extra_classes[#extra_classes + 1] = c end
  end
  svg = postprocess(svg, hash, el.attributes["width"],
    table.concat(extra_classes, " "), el.identifier)

  return pandoc.RawBlock("html", '<div class="teacup-wrap">' .. svg .. "</div>")
end

-- Expose internals to the unit tests (test/unit.lua) without changing the
-- filter's shape for pandoc. Only active when the test harness asks for it.
if os.getenv("TEACUP_TEST") then
  _G.teacup_internals = {
    postprocess = postprocess,
    palette_css = palette_css,
    palette_preamble = palette_preamble,
    tikz_preamble = tikz_preamble,
    meta_to_string = meta_to_string,
    fix_viewbox = fix_viewbox,
    tail = tail,
    PALETTE = PALETTE,
    TEX_TEMPLATE = TEX_TEMPLATE,
  }
end

return {
  { Meta = get_meta },
  { CodeBlock = CodeBlock },
}
