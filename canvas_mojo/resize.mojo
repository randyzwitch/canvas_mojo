"""Box-filter downsampling -- shrink a Canvas by an integer factor,
each output pixel the average of the corresponding factor x factor
block of input pixels. This is the actual mechanism behind
supersampled anti-aliasing: render something `factor` times larger
than its intended final size, then `downsample()` back down to that
final size -- every output pixel is averaged across `factor * factor`
real source samples instead of one, producing genuinely finer-grained
edges than a single-resolution render at the final size alone. The
improvement is baked into the file itself (same final pixel
dimensions as an unsupersampled render, objectively better per-pixel
quality), not a trick that relies on whatever later displays or
rescales it.
"""

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color


def downsample(source: Canvas, factor: Int) raises -> Canvas:
    """Shrink `source` by `factor`. `factor` must evenly divide both
    `source.width` and `source.height` -- raises rather than silently
    truncating or rounding away a partial edge block, the same
    "raise, don't misrepresent" stance the rest of this workspace
    takes on malformed input. `factor=1` is a valid, un-special-cased
    no-op copy -- a caller sweeping `factor` through several values
    (to compare supersampling levels, say) doesn't need to branch
    around 1 itself.

    Each output pixel is the *rounded* mean (not truncated -- see the
    `+ n // 2` below) of its `factor x factor` source block's own
    r/g/b channels independently; alpha isn't part of this (Canvas
    itself never stores per-pixel alpha -- see its own docstring).
    """
    if factor <= 0:
        raise Error("downsample(): factor must be positive (got " + String(factor) + ")")
    if source.width % factor != 0 or source.height % factor != 0:
        raise Error(
            "downsample(): factor ("
            + String(factor)
            + ") must evenly divide both width ("
            + String(source.width)
            + ") and height ("
            + String(source.height)
            + ")"
        )

    var out_width = source.width // factor
    var out_height = source.height // factor
    var result = Canvas(out_width, out_height)
    var n = factor * factor

    for oy in range(out_height):
        for ox in range(out_width):
            var r_sum = 0
            var g_sum = 0
            var b_sum = 0
            for dy in range(factor):
                for dx in range(factor):
                    var p = source.get_pixel(ox * factor + dx, oy * factor + dy)
                    r_sum += Int(p.r)
                    g_sum += Int(p.g)
                    b_sum += Int(p.b)
            result.set_pixel(
                ox,
                oy,
                Color(
                    UInt8((r_sum + n // 2) // n),
                    UInt8((g_sum + n // 2) // n),
                    UInt8((b_sum + n // 2) // n),
                ),
            )
    return result^
