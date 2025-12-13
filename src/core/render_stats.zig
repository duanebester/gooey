//! Render Statistics - Performance monitoring for GPU rendering
//!
//! Tracks draw calls, pipeline switches, and primitive counts per frame.
//! Use for profiling and understanding actual rendering bottlenecks.

const std = @import("std");

pub const RenderStats = struct {
    // Draw call counts
    draw_calls: u32 = 0,
    pipeline_switches: u32 = 0,

    // Primitive counts
    quads_rendered: u32 = 0,
    shadows_rendered: u32 = 0,
    glyphs_rendered: u32 = 0,

    // Culling stats
    quads_culled: u32 = 0,
    shadows_culled: u32 = 0,
    glyphs_culled: u32 = 0,

    // Batch stats
    quad_batches: u32 = 0,
    shadow_batches: u32 = 0,

    const Self = @This();

    /// Reset all counters to zero (call at start of frame)
    pub fn reset(self: *Self) void {
        self.* = .{};
    }

    /// Record a draw call
    pub inline fn recordDrawCall(self: *Self) void {
        self.draw_calls += 1;
    }

    /// Record a pipeline switch
    pub inline fn recordPipelineSwitch(self: *Self) void {
        self.pipeline_switches += 1;
    }

    /// Record rendered quads
    pub inline fn recordQuads(self: *Self, count: u32) void {
        self.quads_rendered += count;
        self.quad_batches += 1;
    }

    /// Record rendered shadows
    pub inline fn recordShadows(self: *Self, count: u32) void {
        self.shadows_rendered += count;
        self.shadow_batches += 1;
    }

    /// Record rendered glyphs
    pub inline fn recordGlyphs(self: *Self, count: u32) void {
        self.glyphs_rendered += count;
    }

    /// Record culled quads (skipped due to being off-screen)
    pub inline fn recordQuadsCulled(self: *Self, count: u32) void {
        self.quads_culled += count;
    }

    /// Record culled shadows
    pub inline fn recordShadowsCulled(self: *Self, count: u32) void {
        self.shadows_culled += count;
    }

    /// Record culled glyphs
    pub inline fn recordGlyphsCulled(self: *Self, count: u32) void {
        self.glyphs_culled += count;
    }

    /// Calculate culling efficiency (0.0 = no culling, 1.0 = 100% culled)
    pub fn cullingEfficiency(self: *const Self) f32 {
        const total_quads = self.quads_rendered + self.quads_culled;
        if (total_quads == 0) return 0.0;
        return @as(f32, @floatFromInt(self.quads_culled)) / @as(f32, @floatFromInt(total_quads));
    }

    /// Average batch size for quads
    pub fn avgQuadBatchSize(self: *const Self) f32 {
        if (self.quad_batches == 0) return 0.0;
        return @as(f32, @floatFromInt(self.quads_rendered)) / @as(f32, @floatFromInt(self.quad_batches));
    }

    /// Average batch size for shadows
    pub fn avgShadowBatchSize(self: *const Self) f32 {
        if (self.shadow_batches == 0) return 0.0;
        return @as(f32, @floatFromInt(self.shadows_rendered)) / @as(f32, @floatFromInt(self.shadow_batches));
    }

    /// Print statistics to debug output
    pub fn print(self: *const Self) void {
        std.debug.print(
            \\
            \\═══════════════════════════════════════
            \\  Render Stats
            \\═══════════════════════════════════════
            \\  Draw calls:        {d}
            \\  Pipeline switches: {d}
            \\───────────────────────────────────────
            \\  Quads:    {d} rendered, {d} culled
            \\  Shadows:  {d} rendered, {d} culled
            \\  Glyphs:   {d} rendered, {d} culled
            \\───────────────────────────────────────
            \\  Quad batches:   {d} (avg {d:.1} per batch)
            \\  Shadow batches: {d} (avg {d:.1} per batch)
            \\  Culling efficiency: {d:.1}%
            \\═══════════════════════════════════════
            \\
        , .{
            self.draw_calls,
            self.pipeline_switches,
            self.quads_rendered,
            self.quads_culled,
            self.shadows_rendered,
            self.shadows_culled,
            self.glyphs_rendered,
            self.glyphs_culled,
            self.quad_batches,
            self.avgQuadBatchSize(),
            self.shadow_batches,
            self.avgShadowBatchSize(),
            self.cullingEfficiency() * 100.0,
        });
    }

    /// Format stats as a single-line summary (for HUD overlay)
    pub fn summary(self: *const Self, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, "DC:{d} PS:{d} Q:{d}/{d} S:{d} G:{d}", .{
            self.draw_calls,
            self.pipeline_switches,
            self.quads_rendered,
            self.quads_culled,
            self.shadows_rendered,
            self.glyphs_rendered,
        }) catch return "stats error";
        return result;
    }
};

// Thread-local stats for easy access (optional - can also pass explicitly)
pub var frame_stats: RenderStats = .{};

/// Start a new frame (resets stats)
pub fn beginFrame() void {
    frame_stats.reset();
}

/// Get current frame stats
pub fn getStats() *RenderStats {
    return &frame_stats;
}

test "RenderStats basic operations" {
    var stats = RenderStats{};

    stats.recordDrawCall();
    stats.recordDrawCall();
    stats.recordQuads(10);
    stats.recordQuads(5);
    stats.recordQuadsCulled(3);

    try std.testing.expectEqual(@as(u32, 2), stats.draw_calls);
    try std.testing.expectEqual(@as(u32, 15), stats.quads_rendered);
    try std.testing.expectEqual(@as(u32, 2), stats.quad_batches);
    try std.testing.expectEqual(@as(u32, 3), stats.quads_culled);
    try std.testing.expectEqual(@as(f32, 7.5), stats.avgQuadBatchSize());
}
