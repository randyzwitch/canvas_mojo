---
title: Retained Drawing
weight: 60
---

`DisplayList` owns a drawing that you can replay into any `DrawTarget`.
Record once when content changes, then replay during repaint or at another
display scale. Direct drawing keeps its existing behavior and pays no
recording cost.

```mojo
from canvas import Canvas, Color, DisplayList, FontCache, write_png


def main() raises:
    var scene = DisplayList()
    scene.fill_circle_aa(12.0, 12.0, 10.0, Color(35, 95, 175))
    var target = Canvas(80, 80, Color(255, 255, 255))
    var cache = FontCache()
    target.translate(15.0, 15.0)
    target.scale(2.0, 2.0)
    scene.replay(target, cache=cache)
    write_png(target, "retained.png")
```

The list implements the same drawing, text, transforms, clips, groups and
batches as `DrawTarget`. It deep-owns image pixels, paths, gradients, text,
styled runs, and list arguments. Repeated equal resources share a snapshot.
Finish an image's batch before recording it. A movable list can be a field
of a retained widget; the original drawing inputs can be changed or destroyed.

Balance saves, clips, batches and annotated groups before replay. Pop mixed
rectangle/path clips in reverse push order with the matching pop method;
`restore` removes clips opened inside its save scope. Invalid scopes raise
before any destination drawing. End a destination annotated group before
replay because these groups do not nest.

Replay treats the destination's incoming transform as its baseline.
Recorded `set_transform(m)` means that baseline composed with `m`, and
`reset_transform()` returns to the baseline. Incoming clips keep restricting
the scene. Graphics state, including existing raster batch depth, is restored
after successful or raising playback. Drawing emitted before an error is
retained; replay does not roll back pixels or document elements.

Text is retained as strings and styled runs. The cache passed while recording
is not retained. At replay, raster and bounds resolve through the supplied
`FontCache`, PDF uses its document cache, and SVG emits font descriptions for
its viewer. Fonts must still be available at playback. SVG text remains text;
PDF text remains selectable and searchable. Different font environments can
change glyphs and layout, so recordings do not promise portable font embedding.

`scene.bounds(cache=cache)` measures conservative logical ink without a page
boundary, including negative coordinates, stroke styles, text blocks, image
boxes and lines used for math rules. Check `known` before using its coordinates
for damage rejection: unknown bounds require repainting the widget. If
`has_ink` is false on a known result, the recording is empty. Clips use
conservative bounding boxes, and a half-pixel fringe includes raster coverage.
Recompute bounds if font configuration changes; a viewer's substituted SVG
font may have different extents.

Scaling a recording scales its existing geometry and text. It does not choose
new ticks, wrap labels, move legends or respond to a different available width.
Those changes require the chart layer to lay out and record again.

`command_count()`, `resource_count()`, `list_buffer_count()` and
`storage_bytes()` describe retained storage. The byte estimate includes list
capacities but excludes allocator metadata and string spare capacity; the
buffer count excludes String internals and counts live List buffers, not
allocation calls. Content-based resource interning compares retained resources
linearly. Measure recording cost for scenes with many distinct large resources.
Run `pixi run -e release display-list-bench` for icon and chart measurements.
