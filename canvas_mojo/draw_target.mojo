"""DrawTarget -- the minimal drawing-primitive interface `dataviz`
renders through, so its Plot/Scale/Theme grammar layer can target
either a raster `Canvas` or a vector `SvgCanvas` (or any future
backend) without knowing which one it's drawing into -- see
dataviz_mojo/ROADMAP.md's own entry for the concrete problem this solves
(a vector backend has no fixed pixel resolution to get wrong in the
first place, sidestepping the whole `Theme.scale`/`downsample()`
supersampling story for anything rendered through it).

Deliberately narrow: exactly the *shape* primitives `dataviz_mojo/plot.mojo`
actually calls today (`fill_rect`, `draw_line_aa`, `fill_circle_aa`,
`fill_arc_aa`, `fill_ring_sector_aa`, `stroke_path_aa`,
`fill_path_aa`), not `canvas_mojo.primitives`'s full surface -- no
`draw_ellipse`, no `fill_polygon`, no gradients here; add them if and
when something concrete needs them through this interface, matching
this whole project's stance on speculative API surface elsewhere
(`Plot`'s own channels, `Theme`'s own fields, all grew the same way).
Every method's own parameters mirror the `canvas_mojo.primitives`/`canvas.
path` function of the same name, trimmed to just the arguments
`dataviz` actually passes explicitly (no `supersample`, `dashes`,
`fill_rule` -- a raster `DrawTarget` implementation still gets to
choose its own supersample factor internally; a vector one has no
equivalent knob to expose at all).

Deliberately excludes text -- `canvas_mojo.text`'s real text rendering
depends on `cairo_mojo` (see that module's own docstring), and this
trait needs to be implementable by `Canvas` (`canvas_mojo/buffer.mojo`)
without buffer.mojo taking on that dependency for every caller, not
just the ones that draw text (see the wiki for additional information --
the two things that were tried and didn't work before this: a `Canvas`
method that called `canvas_mojo.text.draw_text` directly forced cairo onto
every `Canvas` user transitively, and a move-in/move-out wrapper
struct hit a real Mojo ownership-tracking limitation on extracting a
field back out after calling `mut self` methods on it). `dataviz/
plot.mojo`'s generic rendering core collects text as a `List` of
plain data (position, string, color, size, alignment) instead of
drawing it inline through this trait, then each backend (raster or
SVG) draws that list its own way, outside the generic path -- see that
module's own comments for exactly where.

Conformance is nominal, not structural (Mojo's own trait rule, not a
choice made here) -- `Canvas` (`canvas_mojo/buffer.mojo`) and `SvgCanvas`
(`canvas_mojo/svg.mojo`) each explicitly declare `DrawTarget` in their own
struct signature.
"""

from canvas_mojo.color import Color
from canvas_mojo.path import Path


trait DrawTarget:
    def fill_rect(mut self, x: Int, y: Int, width: Int, height: Int, color: Color): ...

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
