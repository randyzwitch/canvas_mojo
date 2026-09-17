"""Image and stream codecs: `png`, `bmp`, `jpeg` and `deflate`.

`MAX_DECODED_PIXELS` is the one thing they share. A file's header
claims its dimensions before a byte of pixel data is read, and a
decoder sizes its buffers from that claim; a header naming 65535 by
65535 pixels asks for gigabytes and minutes of work from a file of a
few hundred bytes. Each decoder raises when the claimed area exceeds
this, before anything is allocated (#430). The limit admits any image
a chart or a photograph plausibly is, a 16384-square included, and
refuses what only a crafted file asks for.
"""

comptime MAX_DECODED_PIXELS = 1 << 28
