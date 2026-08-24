"""TextAlign -- kept in its own module, separate from render.mojo, so
it can be referenced (by `canvas_mojo.vector.draw_target`, and
transitively by `canvas_mojo.buffer`'s `Canvas` -- see that trait for
why) without pulling in render.mojo's heavier
FFI-touching imports (font_discovery.mojo/ttf.mojo/glyph_outline.mojo/
bidi.mojo). `from canvas_mojo.text.render import TextAlign` also works
-- render.mojo re-exports this same type.
"""


struct TextAlign(Copyable, ImplicitlyCopyable, Movable):
    """Horizontal alignment of each line relative to draw_text's
    (x, y) anchor.

    Measured against a line's *advance* width (TextMetrics.advance --
    the logical cursor-advance distance), not its tight ink bounds --
    matching HTML5 Canvas's textAlign and every mainstream text API,
    so trailing whitespace still shifts centering the way it visually
    should, not the way a tight ink-bounds measurement would ignore.
    """

    var _value: Int

    comptime LEFT = Self(0)
    comptime CENTER = Self(1)
    comptime RIGHT = Self(2)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value
