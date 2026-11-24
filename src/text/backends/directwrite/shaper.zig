const std = @import("std");
const assert = std.debug.assert;
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const DirectWriteFace = @import("face.zig").DirectWriteFace;
const limits = @import("../../../core/limits.zig");

const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;

const log = std.log.scoped(.directwrite);

pub const text_utf16_count_max: u32 = 2048;
pub const glyph_count_max: u32 = text_utf16_count_max * 3 / 2 + 16;
pub const script_run_count_max: u32 = 256;

comptime {
    std.debug.assert(text_utf16_count_max >= 2 * limits.run_codepoint_count_max);
}

const locale_name_empty = [_:0]u16{};

const ScriptRun = struct {
    position: u32,
    length: u32,
    analysis: dw.DWRITE_SCRIPT_ANALYSIS,
};

pub const DirectWriteShaper = struct {
    text_utf16: [text_utf16_count_max]u16,
    byte_offsets: [text_utf16_count_max]u32,
    text_utf16_count: u32,
    cluster_map: [text_utf16_count_max]u16,
    text_properties: [text_utf16_count_max]dw.DWRITE_SHAPING_TEXT_PROPERTIES,

    glyph_indices: [glyph_count_max]u16,
    glyph_properties: [glyph_count_max]dw.DWRITE_SHAPING_GLYPH_PROPERTIES,
    glyph_advances: [glyph_count_max]f32,
    glyph_offsets: [glyph_count_max]dw.DWRITE_GLYPH_OFFSET,
    glyph_clusters: [glyph_count_max]u32,

    script_runs: [script_run_count_max]ScriptRun,
    script_run_count: u32,
    script_run_overflow: bool,

    source: dw.IDWriteTextAnalysisSource,
    sink: dw.IDWriteTextAnalysisSink,
    reference_count: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return .{
            .text_utf16 = undefined,
            .byte_offsets = undefined,
            .text_utf16_count = 0,
            .cluster_map = undefined,
            .text_properties = undefined,
            .glyph_indices = undefined,
            .glyph_properties = undefined,
            .glyph_advances = undefined,
            .glyph_offsets = undefined,
            .glyph_clusters = undefined,
            .script_runs = undefined,
            .script_run_count = 0,
            .script_run_overflow = false,
            .source = .{ .vtable = &source_vtable },
            .sink = .{ .vtable = &sink_vtable },
            .reference_count = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        assert(self.reference_count == 1);
        self.* = undefined;
    }

    pub fn shape(
        self: *Self,
        face: *const DirectWriteFace,
        text: []const u8,
        allocator: std.mem.Allocator,
    ) !ShapedRun {
        assert(self.reference_count == 1);
        if (text.len == 0) {
            return .{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        try self.convertText(text);
        try self.analyzeScripts(face.text_analyzer);

        var glyph_count: u32 = 0;
        for (self.script_runs[0..self.script_run_count]) |*run| {
            glyph_count += try self.shapeScriptRun(face, run, glyph_count);
        }
        assert(glyph_count <= glyph_count_max);
        if (glyph_count == 0) {
            return .{ .glyphs = &[_]ShapedGlyph{}, .width = 0 };
        }

        const glyphs = try allocator.alloc(ShapedGlyph, glyph_count);
        const width = writeShapedGlyphs(
            face,
            text,
            self.glyph_indices[0..glyph_count],
            self.glyph_advances[0..glyph_count],
            self.glyph_offsets[0..glyph_count],
            self.glyph_clusters[0..glyph_count],
            glyphs,
        );
        assert(width >= 0);
        return .{ .glyphs = glyphs, .width = width };
    }

    fn convertText(self: *Self, text: []const u8) !void {
        assert(text.len > 0);
        const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var iterator = view.iterator();

        var count: u32 = 0;
        var byte_offset: u32 = 0;
        while (iterator.nextCodepoint()) |codepoint| {
            assert(iterator.i <= text.len);
            assert(count < text.len);
            const unit_count: u32 = if (codepoint < 0x1_0000) 1 else 2;
            if (count + unit_count > text_utf16_count_max) {
                log.warn("text of {d} bytes exceeds text_utf16_count_max ({d})", .{
                    text.len,
                    text_utf16_count_max,
                });
                return error.TextTooLong;
            }
            if (unit_count == 1) {
                self.text_utf16[count] = @intCast(codepoint);
            } else {
                const offset = codepoint - 0x1_0000;
                self.text_utf16[count] = @intCast(0xD800 + (offset >> 10));
                self.text_utf16[count + 1] = @intCast(0xDC00 + (offset & 0x3FF));
            }
            self.byte_offsets[count] = byte_offset;
            self.byte_offsets[count + unit_count - 1] = byte_offset;
            count += unit_count;
            byte_offset = @intCast(iterator.i);
        }
        assert(byte_offset == text.len);
        assert(count > 0);
        assert(count <= text.len);
        self.text_utf16_count = count;
    }

    fn analyzeScripts(self: *Self, analyzer: *dw.IDWriteTextAnalyzer) !void {
        assert(self.text_utf16_count > 0);
        self.script_run_count = 0;
        self.script_run_overflow = false;

        const result = analyzer.vtable.AnalyzeScript(
            analyzer,
            &self.source,
            0,
            self.text_utf16_count,
            &self.sink,
        );
        assert(self.reference_count == 1);
        if (self.script_run_overflow) {
            log.warn("text of {d} UTF-16 units exceeds script_run_count_max ({d})", .{
                self.text_utf16_count,
                script_run_count_max,
            });
            return error.TooManyScriptRuns;
        }
        if (!dw.succeeded(result)) {
            logFailure("AnalyzeScript", result);
            return error.ShapingFailed;
        }

        var covered: u32 = 0;
        for (self.script_runs[0..self.script_run_count]) |run| {
            assert(run.position == covered);
            assert(run.length > 0);
            covered += run.length;
        }
        assert(covered == self.text_utf16_count);
    }

    fn shapeScriptRun(
        self: *Self,
        face: *const DirectWriteFace,
        run: *const ScriptRun,
        glyph_base: u32,
    ) !u32 {
        assert(run.length > 0);
        assert(run.position + run.length <= self.text_utf16_count);
        assert(glyph_base <= glyph_count_max);

        const glyph_count = try self.selectGlyphs(face, run, glyph_base);
        assert(glyph_count > 0);
        assert(glyph_count <= glyph_count_max - glyph_base);
        try self.placeGlyphs(face, run, glyph_base, glyph_count);

        const text_end = run.position + run.length;
        computeGlyphClusters(
            self.cluster_map[run.position..text_end],
            self.byte_offsets[run.position..text_end],
            self.glyph_clusters[glyph_base..][0..glyph_count],
        );
        return glyph_count;
    }

    fn selectGlyphs(
        self: *Self,
        face: *const DirectWriteFace,
        run: *const ScriptRun,
        glyph_base: u32,
    ) !u32 {
        const text_end = run.position + run.length;
        const glyph_capacity = glyph_count_max - glyph_base;
        const analyzer = face.text_analyzer;

        var glyph_count: u32 = 0;
        const glyphs_result = analyzer.vtable.GetGlyphs(
            analyzer,
            self.text_utf16[run.position..text_end].ptr,
            run.length,
            face.font_face,
            dw.FALSE,
            dw.FALSE,
            &run.analysis,
            &locale_name_empty,
            null,
            null,
            null,
            0,
            glyph_capacity,
            self.cluster_map[run.position..text_end].ptr,
            self.text_properties[run.position..text_end].ptr,
            self.glyph_indices[glyph_base..].ptr,
            self.glyph_properties[glyph_base..].ptr,
            &glyph_count,
        );
        if (glyphs_result == dw.E_NOT_SUFFICIENT_BUFFER) {
            log.warn("text of {d} UTF-16 units exceeds glyph_count_max ({d})", .{
                self.text_utf16_count,
                glyph_count_max,
            });
            return error.TextTooLong;
        }
        if (!dw.succeeded(glyphs_result)) {
            logFailure("GetGlyphs", glyphs_result);
            return error.ShapingFailed;
        }
        assert(glyph_count > 0);
        assert(glyph_count <= glyph_capacity);
        return glyph_count;
    }

    fn placeGlyphs(
        self: *Self,
        face: *const DirectWriteFace,
        run: *const ScriptRun,
        glyph_base: u32,
        glyph_count: u32,
    ) !void {
        assert(glyph_count > 0);
        assert(glyph_base + glyph_count <= glyph_count_max);
        const text_end = run.position + run.length;
        const glyph_end = glyph_base + glyph_count;
        const analyzer = face.text_analyzer;

        const placements_result = analyzer.vtable.GetGlyphPlacements(
            analyzer,
            self.text_utf16[run.position..text_end].ptr,
            self.cluster_map[run.position..text_end].ptr,
            self.text_properties[run.position..text_end].ptr,
            run.length,
            self.glyph_indices[glyph_base..glyph_end].ptr,
            self.glyph_properties[glyph_base..glyph_end].ptr,
            glyph_count,
            face.font_face,
            face.metrics.point_size,
            dw.FALSE,
            dw.FALSE,
            &run.analysis,
            &locale_name_empty,
            null,
            null,
            0,
            self.glyph_advances[glyph_base..glyph_end].ptr,
            self.glyph_offsets[glyph_base..glyph_end].ptr,
        );
        if (!dw.succeeded(placements_result)) {
            logFailure("GetGlyphPlacements", placements_result);
            return error.ShapingFailed;
        }
    }
};

fn computeGlyphClusters(
    cluster_map: []const u16,
    byte_offsets: []const u32,
    glyph_clusters: []u32,
) void {
    assert(cluster_map.len == byte_offsets.len);
    assert(cluster_map.len > 0);
    assert(glyph_clusters.len > 0);
    assert(cluster_map[0] == 0);

    var glyph_cursor: u32 = 0;
    var cluster_byte_offset: u32 = byte_offsets[0];
    for (cluster_map[1..], byte_offsets[1..], 0..) |glyph_first, byte_offset, previous| {
        if (glyph_first != cluster_map[previous]) {
            assert(glyph_first > glyph_cursor);
            assert(glyph_first < glyph_clusters.len);
            @memset(glyph_clusters[glyph_cursor..glyph_first], cluster_byte_offset);
            glyph_cursor = glyph_first;
            cluster_byte_offset = byte_offset;
        }
    }
    @memset(glyph_clusters[glyph_cursor..], cluster_byte_offset);
}

fn writeShapedGlyphs(
    face: *const DirectWriteFace,
    text: []const u8,
    glyph_indices: []const u16,
    glyph_advances: []const f32,
    glyph_offsets: []const dw.DWRITE_GLYPH_OFFSET,
    glyph_clusters: []const u32,
    glyphs: []ShapedGlyph,
) f32 {
    assert(glyph_indices.len == glyphs.len);
    assert(glyph_advances.len == glyphs.len);
    assert(glyph_offsets.len == glyphs.len);
    assert(glyph_clusters.len == glyphs.len);

    var width: f32 = 0;
    for (glyphs, glyph_indices, glyph_advances, glyph_offsets, glyph_clusters) |
        *glyph,
        glyph_id,
        advance,
        offset,
        cluster,
    | {
        assert(cluster < text.len);
        glyph.* = .{
            .glyph_id = if (text[cluster] == '\t') face.glyphIndex(' ') else glyph_id,
            .x_offset = offset.advanceOffset,
            .y_offset = -offset.ascenderOffset,
            .x_advance = advance,
            .y_advance = 0,
            .cluster = cluster,
            .font_ref = null,
            .is_color = false,
        };
        width += advance;
    }
    return width;
}

fn logFailure(operation: []const u8, result: dw.HRESULT) void {
    assert(!dw.succeeded(result));
    log.err("DirectWrite {s} failed: HRESULT 0x{X:0>8}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
}

const source_vtable: dw.IDWriteTextAnalysisSource.VTable = .{
    .QueryInterface = sourceQueryInterface,
    .AddRef = sourceAddRef,
    .Release = sourceRelease,
    .GetTextAtPosition = sourceGetTextAtPosition,
    .GetTextBeforePosition = sourceGetTextBeforePosition,
    .GetParagraphReadingDirection = sourceGetParagraphReadingDirection,
    .GetLocaleName = sourceGetLocaleName,
    .GetNumberSubstitution = sourceGetNumberSubstitution,
};

const sink_vtable: dw.IDWriteTextAnalysisSink.VTable = .{
    .QueryInterface = sinkQueryInterface,
    .AddRef = sinkAddRef,
    .Release = sinkRelease,
    .SetScriptAnalysis = sinkSetScriptAnalysis,
    .SetLineBreakpoints = sinkSetLineBreakpoints,
    .SetBidiLevel = sinkSetBidiLevel,
    .SetNumberSubstitution = sinkSetNumberSubstitution,
};

fn shaperFromSource(source: *dw.IDWriteTextAnalysisSource) *DirectWriteShaper {
    const shaper: *DirectWriteShaper = @alignCast(@fieldParentPtr("source", source));
    assert(shaper.reference_count >= 1);
    return shaper;
}

fn shaperFromSink(sink: *dw.IDWriteTextAnalysisSink) *DirectWriteShaper {
    const shaper: *DirectWriteShaper = @alignCast(@fieldParentPtr("sink", sink));
    assert(shaper.reference_count >= 1);
    return shaper;
}

const reference_count_max: u32 = 64;

fn addReference(shaper: *DirectWriteShaper) u32 {
    assert(shaper.reference_count >= 1);
    assert(shaper.reference_count < reference_count_max);
    shaper.reference_count += 1;
    return shaper.reference_count;
}

fn releaseReference(shaper: *DirectWriteShaper) u32 {
    assert(shaper.reference_count > 1);
    shaper.reference_count -= 1;
    assert(shaper.reference_count >= 1);
    return shaper.reference_count;
}

fn remainingLength(shaper: *const DirectWriteShaper, position: u32) u32 {
    assert(shaper.text_utf16_count <= text_utf16_count_max);
    assert(position <= shaper.text_utf16_count);
    return shaper.text_utf16_count - position;
}

fn sourceQueryInterface(
    source: *dw.IDWriteTextAnalysisSource,
    iid: *const dw.GUID,
    object: *?*anyopaque,
) callconv(.winapi) dw.HRESULT {
    if (iid.eql(&dw.IID_IUnknown) or iid.eql(&dw.IID_IDWriteTextAnalysisSource)) {
        _ = addReference(shaperFromSource(source));
        object.* = source;
        return dw.S_OK;
    }
    object.* = null;
    return dw.E_NOINTERFACE;
}

fn sourceAddRef(source: *dw.IDWriteTextAnalysisSource) callconv(.winapi) u32 {
    return addReference(shaperFromSource(source));
}

fn sourceRelease(source: *dw.IDWriteTextAnalysisSource) callconv(.winapi) u32 {
    return releaseReference(shaperFromSource(source));
}

fn sourceGetTextAtPosition(
    source: *dw.IDWriteTextAnalysisSource,
    position: u32,
    text: *?[*]const u16,
    text_length: *u32,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSource(source);
    assert(shaper.text_utf16_count > 0);
    text_length.* = remainingLength(shaper, position);
    text.* = if (text_length.* > 0) shaper.text_utf16[position..].ptr else null;
    assert(position + text_length.* == shaper.text_utf16_count);
    return dw.S_OK;
}

fn sourceGetTextBeforePosition(
    source: *dw.IDWriteTextAnalysisSource,
    position: u32,
    text: *?[*]const u16,
    text_length: *u32,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSource(source);
    assert(shaper.text_utf16_count > 0);
    assert(position <= shaper.text_utf16_count);
    if (position > 0) {
        text.* = &shaper.text_utf16;
        text_length.* = position;
    } else {
        text.* = null;
        text_length.* = 0;
    }
    return dw.S_OK;
}

fn sourceGetParagraphReadingDirection(
    source: *dw.IDWriteTextAnalysisSource,
) callconv(.winapi) u32 {
    assert(shaperFromSource(source).text_utf16_count > 0);
    return dw.DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
}

fn sourceGetLocaleName(
    source: *dw.IDWriteTextAnalysisSource,
    position: u32,
    text_length: *u32,
    locale_name: *?[*:0]const u16,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSource(source);
    assert(shaper.text_utf16_count > 0);
    text_length.* = remainingLength(shaper, position);
    locale_name.* = &locale_name_empty;
    assert(position + text_length.* == shaper.text_utf16_count);
    return dw.S_OK;
}

fn sourceGetNumberSubstitution(
    source: *dw.IDWriteTextAnalysisSource,
    position: u32,
    text_length: *u32,
    substitution: *?*anyopaque,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSource(source);
    assert(shaper.text_utf16_count > 0);
    text_length.* = remainingLength(shaper, position);
    substitution.* = null;
    assert(position + text_length.* == shaper.text_utf16_count);
    return dw.S_OK;
}

fn sinkQueryInterface(
    sink: *dw.IDWriteTextAnalysisSink,
    iid: *const dw.GUID,
    object: *?*anyopaque,
) callconv(.winapi) dw.HRESULT {
    if (iid.eql(&dw.IID_IUnknown) or iid.eql(&dw.IID_IDWriteTextAnalysisSink)) {
        _ = addReference(shaperFromSink(sink));
        object.* = sink;
        return dw.S_OK;
    }
    object.* = null;
    return dw.E_NOINTERFACE;
}

fn sinkAddRef(sink: *dw.IDWriteTextAnalysisSink) callconv(.winapi) u32 {
    return addReference(shaperFromSink(sink));
}

fn sinkRelease(sink: *dw.IDWriteTextAnalysisSink) callconv(.winapi) u32 {
    return releaseReference(shaperFromSink(sink));
}

fn sinkSetScriptAnalysis(
    sink: *dw.IDWriteTextAnalysisSink,
    position: u32,
    length: u32,
    analysis: *const dw.DWRITE_SCRIPT_ANALYSIS,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSink(sink);
    assert(length > 0);
    assert(position < shaper.text_utf16_count);
    assert(length <= shaper.text_utf16_count - position);
    assert(shaper.script_run_count <= script_run_count_max);
    if (shaper.script_run_count < script_run_count_max) {
        shaper.script_runs[shaper.script_run_count] = .{
            .position = position,
            .length = length,
            .analysis = analysis.*,
        };
        shaper.script_run_count += 1;
        return dw.S_OK;
    } else {
        shaper.script_run_overflow = true;
        return dw.E_NOT_SUFFICIENT_BUFFER;
    }
}

fn sinkSetLineBreakpoints(
    sink: *dw.IDWriteTextAnalysisSink,
    position: u32,
    length: u32,
    breakpoints: *const anyopaque,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSink(sink);
    assert(position <= shaper.text_utf16_count);
    assert(length <= shaper.text_utf16_count - position);
    _ = breakpoints;
    return dw.S_OK;
}

fn sinkSetBidiLevel(
    sink: *dw.IDWriteTextAnalysisSink,
    position: u32,
    length: u32,
    explicit_level: u8,
    resolved_level: u8,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSink(sink);
    assert(position <= shaper.text_utf16_count);
    assert(length <= shaper.text_utf16_count - position);
    _ = .{ explicit_level, resolved_level };
    return dw.S_OK;
}

fn sinkSetNumberSubstitution(
    sink: *dw.IDWriteTextAnalysisSink,
    position: u32,
    length: u32,
    substitution: ?*anyopaque,
) callconv(.winapi) dw.HRESULT {
    const shaper = shaperFromSink(sink);
    assert(position <= shaper.text_utf16_count);
    assert(length <= shaper.text_utf16_count - position);
    _ = substitution;
    return dw.S_OK;
}

test "computeGlyphClusters maps ligatures, multi-glyph clusters, and surrogates" {
    const testing = std.testing;

    var ligature: [2]u32 = undefined;
    computeGlyphClusters(&.{ 0, 0, 0, 1 }, &.{ 0, 1, 2, 3 }, &ligature);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &ligature);

    var decomposed: [3]u32 = undefined;
    computeGlyphClusters(&.{ 0, 2 }, &.{ 0, 2 }, &decomposed);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 2 }, &decomposed);

    var surrogate: [3]u32 = undefined;
    computeGlyphClusters(&.{ 0, 1, 1, 2 }, &.{ 0, 1, 1, 5 }, &surrogate);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 5 }, &surrogate);
}
