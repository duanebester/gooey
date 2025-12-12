Engineering Notes

1. Always prefer performance as number 1 priority!
2. We are using Zig 0.15.2. make sure to use latest API's
   e.g. Check how we do ArrayList inits.

Each glyph carries its own clip bounds, and the fragment shader discards pixels outside. No extra draw calls, no scissor rect state changes, just a simple `discard_fragment()` in the shader.

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
