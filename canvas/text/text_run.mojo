"""TextRun, in its own module for the reason `text_align.mojo` gives:
`canvas.vector.draw_target` and `canvas.buffer` name it in a signature
and cannot import render.mojo, which imports `canvas.buffer` itself.
`from canvas.text.render import TextRun` also works: render.mojo
re-exports this type beside the function that lays a list of them out.
"""

from canvas.text.font_discovery import FontSlant


struct TextRun(Copyable, ImplicitlyCopyable, Movable):
    """One piece of a label `draw_text_runs` draws: its text at its own
    size and slant, placed against the runs around it. A label that
    mixes sizes or slants -- a variable in italic, a superscript at
    70% -- is a list of these and stays one label: one `<text>`
    element on SVG, one string to select, copy or announce.

    `dx` moves the pen before the run, from where the previous run's
    advance ended: a kern, negative to back up, which is how a
    fraction's denominator gets under its numerator. `dy` is the run's
    baseline relative to the label's baseline, positive downward, so a
    superscript is negative and the run after it is back at 0. Both
    are in the label's own frame, before `rotation`. They are
    `<tspan>`'s `dx` and `dy`, except that `dy` here names the run's
    own baseline rather than a shift that carries on to the runs after
    it.
    """

    var text: String
    var size: Float64
    var slant: FontSlant
    var dx: Float64
    var dy: Float64

    def __init__(
        out self,
        text: String,
        size: Float64,
        slant: FontSlant = FontSlant.NORMAL,
        dx: Float64 = 0.0,
        dy: Float64 = 0.0,
    ):
        """One run of a label made of several.

        Args:
            text: The run's text, one line.
            size: Font size in pixels.
            slant: Upright, italic or oblique.
            dx: Pen shift before the run, from the previous run's end.
            dy: The run's baseline, relative to the label's; positive
                is downward, so a superscript is negative.
        """
        self.text = text
        self.size = size
        self.slant = slant
        self.dx = dx
        self.dy = dy
