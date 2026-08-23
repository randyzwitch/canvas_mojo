"""DrawTarget -- the minimal drawing-primitive interface a higher-level
charting/plotting layer can render through, so a chart-grammar (plot/
scale/theme-style) layer built on top of this package can target
either a raster `Canvas` or a vector `SvgCanvas` (or any future
backend) without knowing which one it's drawing into (a vector
backend has no fixed pixel resolution to get wrong in the first
place, sidestepping raster-only supersampling concerns for anything
rendered through it).

Deliberately narrow: exactly the *shape* primitives a chart-rendering
core actually needs (`fill_rect`, `draw_line_aa`, `fill_circle_aa`,
`fill_arc_aa`, `fill_ring_sector_aa`, `stroke_path_aa`,
`fill_path_aa`, `fill_rect_gradient`), not `canvas_mojo.shapes`'s
full surface -- no `draw_ellipse`, no `fill_polygon`, no dashes, no
clipping, no radial gradients, no path-shaped gradients here; add them
if and when something concrete needs them through this interface,
matching this whole project's stance on speculative API surface
elsewhere. `fill_rect_gradient` (linear only) is the one gradient
method that clears that bar today -- dataviz_mojo's own continuous
color legend needs a real smooth gradient bar, not the discrete
color-strip approximation it was reduced to without this (see that
project's own plot.mojo, `_draw_continuous_color_legend`); nothing
else in `canvas_mojo.gradient`'s own surface (`RadialGradient`,
`fill_path_gradient`, `fill_path_radial_gradient`) has a concrete
caller yet. Every method's own parameters mirror the
`canvas_mojo.shapes`/`canvas.path` function of the same name,
trimmed to just the arguments a generic chart-rendering caller would
pass explicitly (no `supersample`, `dashes`, `fill_rule` -- a raster
`DrawTarget` implementation still gets to choose its own supersample
factor internally; a vector one has no equivalent knob to expose at
all).

Deliberately excludes text -- raster and vector backends draw it
through fundamentally different mechanisms (`Canvas` rasterizes glyph
outlines to pixels via `fill_path_aa`; `SvgCanvas` emits `<text>`
markup for the viewer's own font engine to render, never touching a
glyph outline at all), so there's no single shared operation for this
trait's six shape primitives to generalize over the way there is for
`fill_rect`/`draw_line_aa`/etc. A generic chart-rendering core built on
top of this trait would instead collect text as a `List` of plain data
(position, string, color, size, alignment) rather than drawing it
inline through this trait, then have each backend draw that list its
own way, outside the generic path.

`canvas_mojo.text` used to depend on `cairo_mojo`, which was a second,
compile-time reason this exclusion mattered (importing it required an
extra `-I` search path, and forced that dependency onto every `Canvas`
user transitively, confirmed directly: a `Canvas` method that called
`canvas_mojo.text.draw_text` broke compilation for any file merely
importing `Canvas`, text or no text, since Mojo resolves a struct's
entire method surface eagerly, not lazily per call). `canvas_mojo.text`
is fully native now (a single fontconfig FFI call for font discovery,
no Cairo, no FreeType, no extra `-I` path -- see its own module
docstring) and no longer forces anything
onto callers who don't use it, so that second reason is gone; the
raster-vs-markup mechanism difference above is reason enough to keep
this exclusion on its own.

Conformance is nominal, not structural (Mojo's own trait rule, not a
choice made here) -- `Canvas` (`canvas_mojo/buffer.mojo`) and `SvgCanvas`
(`canvas_mojo/vector/svg.mojo`) each explicitly declare `DrawTarget` in their own
struct signature.
"""

from canvas_mojo.color import Color
from canvas_mojo.path import Path
from canvas_mojo.gradient import LinearGradient


trait DrawTarget:
    def fill_rect(mut self, x: Int, y: Int, width: Int, height: Int, color: Color): ...

    def fill_rect_gradient(
        mut self, x: Int, y: Int, width: Int, height: Int, gradient: LinearGradient
    ): ...

    def draw_line_aa(
        mut self, x0: Int, y0: Int, x1: Int, y1: Int, color: Color, width: Float64 = 1.0
    ): ...

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color): ...

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ): ...

    def fill_ring_sector_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        inner_radius: Float64,
        outer_radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ): ...

    def stroke_path_aa(mut self, path: Path, color: Color, width: Float64 = 1.0): ...

    def fill_path_aa(mut self, path: Path, color: Color): ...
