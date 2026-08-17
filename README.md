# canvas_mojo

A Mojo raster/drawing engine — pixel buffer, colors, primitives (lines, shapes, curves, gradients), text, and image I/O.

## Why?

Scratching the itch of "What would it take to not use Cairo or other existing libraries as base for data visualization"! 

Please note that this is heavily Claude-influenced, so I do not guarantee consistency, logic, mapping to Cairo concepts or anything else. If you know what you're doing and what to contribute, let's chat! 

## Status

Mojo-only, plus one small direct FFI dependency on a system
library `canvas_mojo/text/render.mojo` links against for real
system-font text rendering: `libfontconfig` (font matching —
resolving a family/style name to an actual installed font file --
`canvas_mojo/text/font_discovery.mojo`), a typical,
near-universally-installed system library, not a new requirement
this package introduces. Font *parsing* (glyph outlines, metrics,
`canvas_mojo/text/ttf.mojo`) and rasterization (this package's own
`fill_path_aa`) are both native Mojo -- no FreeType, no Cairo, no
other third-party rendering/font engine anywhere in the pipeline.

## Development

```sh
pixi run test      # tests/*.mojo
pixi run example    # examples/*.mojo, writes examples/out_*.{bmp,png}
```

## License

MIT — see `LICENSE`.
