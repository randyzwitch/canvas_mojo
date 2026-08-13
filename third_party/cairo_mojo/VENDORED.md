# Vendored: cairo-mojo

This directory is a vendored snapshot of a third-party project, not code
written for `graphics`. It's the one exception to this repo's stdlib-only
rule (see the root `README.md`) -- `canvas_mojo/text.mojo` uses it, via the
system's `libcairo`, to get real system-font text rendering (hinting,
fontconfig font matching) rather than reimplementing that from scratch.
An earlier from-scratch TrueType parser/rasterizer (a standalone `fonts/`
package) was explored first and then deleted once this existed -- see
`canvas_mojo/ROADMAP.md`'s `text.mojo` entry for that history.

- **Source**: https://github.com/MoSafi2/cairo-mojo
- **Commit**: `c651c18f8c0033f22b118cfcb4e281103da976d5` (2026-05-18)
- **License**: MIT (see `LICENSE` in this directory) -- copyright cairo-mojo
  contributors, not us.
- **What's included**: only the `cairo_mojo/` library source and its
  `LICENSE`. Not vendored: their `examples/`, `test/`, `third_party/cairo/`
  C headers (only needed offline by their binding generator, not at
  runtime), or their `pixi.toml`/build recipe.

## Why a vendored copy instead of a pixi dependency

Originally: cairo-mojo's own `pixi.toml` pinned `mojo == 1.0.0b1` (build,
host, and run dependencies alike), conflicting with this workspace's own
`mojo` pin at the time. That's since been superseded -- this workspace
upgraded to Mojo `1.0.0` stable, and cairo-mojo's own current constraint
(`mojo >=1.0.0b1,<2`) comfortably includes it, so that original conflict
is gone.

A *real* pixi/git dependency was directly attempted after that upgrade
(`pixi add --git https://github.com/MoSafi2/cairo-mojo cairo-mojo`,
cairo-mojo's own `pixi-build-mojo` backend, with the `pixi-build` preview
feature enabled) and is currently blocked by a different, external
problem instead: that backend still invokes Mojo's now-removed `mojo
package` command, which Mojo `1.0.0` hard-errors on rather than just
warning about. This is a bug in third-party build tooling, not a
version-pin conflict -- see `canvas_mojo/ROADMAP.md`'s own "Deferred on
purpose, not forgotten" entry for the full attempt and the retry
condition. Until that's fixed upstream, this stays a plain vendored
source snapshot, imported the same way this workspace already imports its
own packages -- via `-I` search paths (see the root `pixi.toml`'s
`tasks`).

This was verified to actually work, not assumed: cairo-mojo's own text
example was compiled and run unmodified against *this* workspace's pinned
Mojo (1.0.0b2, one patch ahead of cairo-mojo's own 1.0.0b1 pin) and
produced correct, properly-hinted anti-aliased text. It compiled with a
handful of deprecation warnings (an origin-type rename between the two
Mojo patch versions -- `MutExternalOrigin`/`ImmutExternalOrigin` renamed to
`MutUntrackedOrigin`/`ImmutUntrackedOrigin`) and zero errors.

## Updating this vendored copy

Deliberate only -- re-copy `cairo_mojo/` and `LICENSE` from a chosen
upstream commit, update the commit hash above, and re-run `pixi run test`
before committing. Don't silently drift onto upstream's `main`.

## Runtime dependency

Needs a system-installed `libcairo` (>= 1.18, the version this snapshot
was built against) discoverable by `cairo_mojo/cairo_runtime.mojo`'s
`OwnedDLHandle` probing (canonical soname first, then `ldconfig`/
`pkg-config`/`CAIRO_LIB` env var as fallbacks) -- not bundled, not a pixi
dependency of this workspace. On Debian/Ubuntu: `libcairo2`. On this
machine it was already present as a transitive dependency of something
else.
