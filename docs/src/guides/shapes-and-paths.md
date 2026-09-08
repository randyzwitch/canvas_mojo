---
title: Shapes and Paths
weight: 20
---

Use a shape primitive when its geometry matches the mark you need. Use a
`Path` for Bezier curves, mixed segments, holes, or several subpaths.

## Shape primitives

The main primitive families are:

- `draw_line_aa`, `draw_polyline_aa`, and `draw_polygon_aa`
- `draw_rect` and `fill_rect`
- `draw_circle_aa` and `fill_circle_aa`
- `draw_ellipse_aa` and `fill_ellipse_aa`
- `draw_arc_aa`, `fill_arc_aa`, and `fill_ring_sector_aa`
- `fill_polygon_aa`

Stroke functions accept a width. Lines and paths can also take dash
lengths, a dash offset, `LineCap`, `LineJoin`, and a miter limit.

For a large set of equal-radius markers, use `fill_circles_aa` with a
`List[FPoint]`. An overload accepts one `Color` per center.

## Construct a path

Each subpath begins with `move_to`. Add segments, then optionally close
the subpath:

```mojo
from canvas import Color, Path, fill_path_aa, stroke_path_aa

var path = Path()
path.move_to(40.0, 160.0)
path.line_to(100.0, 60.0)
path.quad_curve_to(180.0, 20.0, 240.0, 100.0)
path.line_to(280.0, 160.0)
path.close()

fill_path_aa(canvas, path, Color(40, 100, 200, 100))
stroke_path_aa(canvas, path, Color(40, 100, 200), 3.0)
```

`quad_curve_to` takes one control point and an endpoint.
`cubic_curve_to` takes two control points and an endpoint. `arc_to`
takes a center, radius, start angle, and end angle; it still requires a
current point established by `move_to` or a previous segment.

## Fill rules and holes

`FillRule.EVEN_ODD`, the default, alternates inside and outside whenever
a ray crosses a boundary. It is convenient for holes because subpath
direction does not matter.

`FillRule.NONZERO` uses winding direction. Oppositely wound subpaths can
cancel; subpaths wound in the same direction remain filled where they
overlap.

```mojo
from canvas import FillRule

fill_path_aa(canvas, path, color, FillRule.NONZERO)
```

## Gradients and patterns

Gradients and patterns are paint sources. Construct the source, add its
stops or tile, then pass it to a matching rectangle or path fill
function. Gradient coordinates are interpreted in the same user space
as the shape and follow the active canvas transform.

See the [examples](../../examples/) for linear, radial, conic, and
pattern-filled paths.
