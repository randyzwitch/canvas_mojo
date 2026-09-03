"""TextAlign, in its own module so it can be referenced by
`canvas.vector.draw_target` -- and transitively by `canvas.buffer`'s
`Canvas` -- without pulling in render.mojo's font-touching imports
(font_discovery.mojo/ttf.mojo/glyph_outline.mojo/bidi.mojo).
`from canvas.text.render import TextAlign` also works: render.mojo
re-exports this same type.
"""


struct TextAlign(Copyable, ImplicitlyCopyable, Movable):
    """Horizontal alignment of each line relative to draw_text's
    (x, y) anchor.

    Measured against a line's *advance* width (TextMetrics.advance, the
    logical cursor-advance distance) rather than its tight ink bounds,
    matching HTML5 Canvas's textAlign, so trailing whitespace shifts
    centering instead of being ignored.
    """

    var _value: Int

    comptime LEFT = Self(0)
    comptime CENTER = Self(1)
    comptime RIGHT = Self(2)

    def __init__(out self, value: Int):
        """Prefer the `LEFT`/`CENTER`/`RIGHT` comptime constants over
        constructing one directly.

        Args:
            value: 0 for LEFT, 1 for CENTER, 2 for RIGHT.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value
