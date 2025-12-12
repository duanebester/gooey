Engineering Notes

1. Always prefer performance as number 1 priority!
2. We are using Zig 0.15.2. make sure to use latest API's
   e.g. Check how we do ArrayList inits.

Each glyph carries its own clip bounds, and the fragment shader discards pixels outside. No extra draw calls, no scissor rect state changes, just a simple `discard_fragment()` in-shader.

## Text Rendering (GPUI-style)

Our text rendering follows GPUI's approach for sharp, pixel-perfect text:

### Glyph Rasterization

1. **Get raster bounds from font metrics** - `CTFontGetBoundingRectsForGlyphs` gives exact pixel bounds _before_ rendering. No bitmap scanning needed.

2. **Translate context by raster origin** - Position the glyph correctly within the bitmap buffer by translating by `-raster_bounds.origin`.

3. **Subpixel variants** - Cache 4 horizontal variants (0, 0.25, 0.5, 0.75 pixel offsets) for sharper text at fractional positions. The subpixel shift is applied during rasterization.

### Screen Positioning

The key to sharp text on retina displays:

```
device_pos = logical_pos * scale_factor
subpixel_variant = floor(fract(device_pos.x) * 4)
final_pos = (floor(device_pos) + raster_offset) / scale_factor
```

**Critical**: Floor the device pixel position _before_ adding the offset. This ensures glyphs land on pixel boundaries. The subpixel variant handles fractional positioning within the pre-rendered bitmap.

### References

- GPUI: `crates/gpui/src/platform/mac/text_system.rs` (raster_bounds + rasterize_glyph)
- GPUI: `crates/gpui/src/window.rs` (paint_glyph - floor + offset pattern)
- Our implementation: `src/text/backends/coretext/face.zig`, `src/text/render.zig`

When creating apps/examples:
You can't nest `cx.box()` calls directly inside tuples\** because they return `void`. Use component structs (like `Card{}`, `CounterRow{}`) for nesting. The component's `render` method receives a `*Builder`and can call`b.box()` etc.

So we have a foundation for:

1. **Scroll containers** - push clip to viewport, render children, pop
2. **`overflow: hidden`** on any element - same pattern
3. **Nested clips** - the stack automatically intersects them
4. **Tooltips/dropdowns** that can overflow their parent - just don't push a clip

Design Philosophy

1. **Plain structs by default** - no wrappers needed for simple state
2. **Context when you need it** - opt-in to reactivity
3. **Components are just structs with `render`** - like GPUI Views
4. **Progressive complexity** - start simple, add power as needed
