//! The headless renderer the core draws with in tests.
//!
//! `NullRenderer` satisfies the core's `Renderer` contract (`core/backend.zig`)
//! without a GPU, so a headless app (`App.initHeadless`, "TestBackend" in the
//! core's docs) runs its pack and draw stages end to end and goldens compare
//! the dump of what it was asked to draw.
//!
//! ## Target neutrality
//!
//! `src/testing/mod.zig` is reachable from the root module on every target, so
//! this file imports only target-neutral modules. Importing a concrete backend
//! here would break the wasm build.

const std = @import("std");

const geometry = @import("../geometry/geometry.zig");
const core_backend = @import("../core/backend.zig");
const packed_frame = @import("../core/packed_frame.zig");
const record_dump = @import("record_dump.zig");

const assert = std.debug.assert;

/// Whether a renderer may still be called: `initInPlace` enters `running`
/// and `deinit` leaves it.
const Lifecycle = enum(u8) {
    running,
    deinitialized,
};

// =============================================================================
// NullRenderer
// =============================================================================

/// Bytes of packed-frame dump the null renderer keeps: the most recent frame
/// only. A todo frame dumps to about 8 KiB, so 64 KiB leaves headroom for the
/// kept examples without making the renderer large on the stack.
pub const null_renderer_dump_bytes_max: u32 = 64 * 1024;

/// A renderer that draws nothing and records what it was asked to draw.
///
/// It satisfies the contract §9 `Renderer` signatures, so the core's pack and
/// draw stages run end to end on `TestBackend`. `draw` writes the packed frame
/// as text (`record_dump.writePacked`), which is what goldens compare. Every
/// buffer is inline: `initInPlace` takes no allocator by contract, so the
/// renderer cannot allocate at all.
pub const NullRenderer = struct {
    lifecycle: Lifecycle,
    size_px: core_backend.SizePx,
    limits: core_backend.RenderLimits,
    draw_count: u64,
    upload_count: [4]u64,
    upload_bytes: u64,
    last_viewport: core_backend.Viewport,
    last_clear: geometry.Color,
    dump_bytes: [null_renderer_dump_bytes_max]u8,
    dump_len: u32,
    /// The glyph atlas the dump samples to identify glyphs. A GPU renderer
    /// receives atlas pixels through `uploadAtlas` into its own texture; the
    /// null renderer has no texture, so a test driver lends it the text
    /// system's CPU atlas instead (`observeGlyphAtlas`).
    glyph_atlas: ?record_dump.GlyphAtlasView,

    const Self = @This();

    comptime {
        core_backend.verifyRenderer(Self);
        assert(@sizeOf(Self) <= 80 * 1024);
    }

    pub noinline fn initInPlace(
        self: *Self,
        surface: *const core_backend.Surface,
        render_limits: *const core_backend.RenderLimits,
    ) error{WindowTooLarge}!void {
        assert(surface.scale_factor > 0);
        assert(render_limits.window.framebuffer_width_max > 0);
        if (surface.size_px.width > render_limits.window.framebuffer_width_max) {
            return error.WindowTooLarge;
        }
        if (surface.size_px.height > render_limits.window.framebuffer_height_max) {
            return error.WindowTooLarge;
        }
        self.lifecycle = .running;
        self.size_px = surface.size_px;
        self.limits = render_limits.*;
        self.draw_count = 0;
        self.upload_count = @splat(0);
        self.upload_bytes = 0;
        self.last_viewport = .{ .size_px = surface.size_px, .scale_factor = surface.scale_factor };
        self.last_clear = geometry.Color.transparent;
        self.dump_len = 0;
        self.glyph_atlas = null;
        assert(self.draw_count == 0);
    }

    /// Lend the dump a view of the glyph atlas; see `glyph_atlas`.
    pub fn observeGlyphAtlas(self: *Self, view: record_dump.GlyphAtlasView) void {
        assert(self.lifecycle == .running);
        assert(view.pixels.len >= @as(u64, view.size) * view.size);
        self.glyph_atlas = view;
    }

    pub fn uploadAtlas(
        self: *Self,
        atlas: core_backend.AtlasKind,
        dirty: core_backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.lifecycle == .running);
        assert(pixels.len >= @as(u64, dirty.width) * dirty.height);
        self.upload_count[@backingInt(atlas)] += 1;
        self.upload_bytes += pixels.len;
    }

    /// Record `frame` as text, replacing the previous frame's dump.
    pub fn draw(
        self: *Self,
        frame: *const core_backend.PackedFrame,
        viewport: core_backend.Viewport,
        clear: geometry.Color,
    ) void {
        assert(self.lifecycle == .running);
        assert(viewport.size_px.width <= self.limits.window.framebuffer_width_max);
        assert(viewport.size_px.height <= self.limits.window.framebuffer_height_max);
        self.draw_count += 1;
        self.last_viewport = viewport;
        self.last_clear = clear;

        var out = record_dump.TextBuffer.init(&self.dump_bytes, "NullRenderer frame dump");
        out.print("packed {d}x{d}@{d:.2} clear={f}\n", .{
            viewport.size_px.width,
            viewport.size_px.height,
            viewport.scale_factor,
            record_dump.Rgba{ .color = .{ clear.r, clear.g, clear.b, clear.a } },
        });
        record_dump.writePacked(&out, frame, if (self.glyph_atlas) |*view| view else null);
        self.dump_len = out.len;
        assert(self.dump_len <= self.dump_bytes.len);
    }

    /// The most recent frame's dump.
    pub fn frameDump(self: *const Self) []const u8 {
        assert(self.draw_count > 0);
        assert(self.dump_len <= self.dump_bytes.len);
        return self.dump_bytes[0..self.dump_len];
    }

    pub fn resize(self: *Self, size_px: core_backend.SizePx) void {
        assert(self.lifecycle == .running);
        assert(size_px.width <= self.limits.window.framebuffer_width_max);
        assert(size_px.height <= self.limits.window.framebuffer_height_max);
        self.size_px = size_px;
    }

    pub fn capabilities(self: *const Self) core_backend.Capabilities {
        assert(self.lifecycle == .running);
        return .{ .meshes = true };
    }

    pub fn deinit(self: *Self) void {
        assert(self.lifecycle == .running);
        self.lifecycle = .deinitialized;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "NullRenderer records the packed frame it is asked to draw" {
    // Goal: draw writes a dump of exactly the submitted frame, and resize past
    // the window budget is rejected at init. Methodology: draw a one-quad
    // scene and read the dump back.
    const render_limits = core_backend.RenderLimits.fromResourceLimits(&.nano);
    const renderer = try testing.allocator.create(NullRenderer);
    defer testing.allocator.destroy(renderer);
    const too_wide = core_backend.Surface{
        .native = null,
        .size_px = .{ .width = render_limits.window.framebuffer_width_max + 1, .height = 10 },
        .scale_factor = 1,
    };
    try testing.expectError(error.WindowTooLarge, renderer.initInPlace(&too_wide, &render_limits));

    const surface = core_backend.Surface{
        .native = null,
        .size_px = .{ .width = 200, .height = 100 },
        .scale_factor = 2,
    };
    try renderer.initInPlace(&surface, &render_limits);
    defer renderer.deinit();

    var frame: core_backend.PackedFrame = undefined;
    try frame.initInPlace(&.{ .scene = render_limits.scene, .paint_record_count_max = 4 });
    defer frame.deinit();
    frame.reset(1, &.{});
    frame.quads[0] = .{
        .bounds = .{ 1, 2, 30, 40 },
        .fill = .{ 1, 0, 0, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .corners = @splat(0),
        .border_widths = @splat(0),
        .blur = 0,
        .offset = .{ 0, 0 },
    };
    frame.quad_count = 1;
    frame.counts[@backingInt(packed_frame.Pool.quads)] = 1;
    frame.draws[0] = .{ .pipeline = .quad, .clip = 0, .first = 0, .count = 1 };
    frame.draw_count = 1;
    renderer.draw(&frame, .{ .size_px = surface.size_px, .scale_factor = 2 }, geometry.Color.white);

    try testing.expectEqualStrings(
        "packed 200x100@2.00 clear=#ffffffff\n  quad (1.00 2.00 30.00 40.00) fill=#ff0000ff\n",
        renderer.frameDump(),
    );
    try testing.expectEqual(@as(u64, 1), renderer.draw_count);
}
