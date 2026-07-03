# teacup development commands

export PATH := env_var('HOME') / ".local/bin:" + env_var('PATH')

# list available recipes
default:
    @just --list

# run unit + e2e tests
test: test-unit test-e2e

# static analysis: type/nil checker + linter (runs from the pre-commit hook)
check:
    lua-language-server --check . --checklevel=Warning
    luacheck _extensions/teacup/teacup.lua --globals pandoc PANDOC_STATE

# point git at the checked-in hooks (run once after cloning)
install-hooks:
    git config core.hooksPath .githooks

# unit tests for the Lua post-processing functions (no TeX needed)
test-unit:
    TEACUP_TEST=1 quarto pandoc lua test/unit.lua

# end-to-end tests: render fixtures and assert on the HTML
test-e2e:
    bash test/e2e.sh

# render the demo document
example:
    quarto render example.qmd

# render the demo and open it in a browser
preview: example
    xdg-open example.html

# remove rendered outputs and caches (test artifacts survive `just test`
# for inspection; this is what removes them)
clean:
    rm -rf example.html example_files _teacup-cache \
        test/fixtures/basic.html test/fixtures/broken.html \
        test/fixtures/preamble.html test/fixtures/preamble_files \
        test/fixtures/viewbox.html test/fixtures/viewbox_files \
        test/fixtures/idcollision.html test/fixtures/idcollision_files \
        test/fixtures/basic.pdf test/fixtures/basic.tex \
        test/fixtures/basic_files test/fixtures/broken_files \
        test/fixtures/_fixture-cache
