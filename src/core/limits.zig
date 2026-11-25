const std = @import("std");
const assert = std.debug.assert;

const packed_frame = @import("packed_frame.zig");
const FontVariant = @import("../text/types.zig").FontVariant;
const ShapedGlyph = @import("../text/types.zig").ShapedGlyph;

pub const MAX_QUADS_PER_FRAME: u32 = 65536;

pub const MAX_GLYPHS_PER_FRAME: u32 = 65536;

pub const MAX_SHADOWS_PER_FRAME: u32 = 4096;

pub const MAX_SVGS_PER_FRAME: u32 = 8192;

pub const MAX_IMAGES_PER_FRAME: u32 = 4096;

pub const MAX_PATHS_PER_FRAME: u32 = 4096;

pub const MAX_POLYLINES_PER_FRAME: u32 = 4096;

pub const MAX_POINT_CLOUDS_PER_FRAME: u32 = 4096;

pub const MAX_CLIP_STACK_DEPTH: u32 = 32;

/// Shaders an app may declare. Each one costs a pipeline state at init: on Apple M2 Max,
/// about 4.5 ms cold (first launch or after a shader changes) and about 0.05 ms once the
/// Metal cache holds it.
pub const MAX_SHADERS: u32 = 64;

pub const MAX_CUSTOM_DRAWS_PER_FRAME: u32 = 16_384;

/// One custom draw's Params, and the stride of the per-frame params buffer.
pub const MAX_SHADER_PARAMS_BYTES: u32 = 64;

pub const shader_params_alignment: u32 = 16;

pub const MAX_FRAMEBUFFER_WIDTH: u32 = 7680;

pub const MAX_FRAMEBUFFER_HEIGHT: u32 = 4320;

pub const MAX_FRAMES_IN_FLIGHT: u32 = 3;

pub const MIN_FRAMES_IN_FLIGHT: u32 = 2;

pub const MAX_ATLAS_SIZE: u32 = 4096;

pub const MIN_ATLAS_SIZE: u32 = 64;

pub const MAX_SVG_ICON_SIZE: u32 = 256;

pub const MAX_SVG_PATH_BYTES: u32 = 64 * 1024;

pub const MAX_SVG_PATH_VERTEX_COUNT: u32 = 32 * 1024;

pub const MAX_GLYPH_SIZE: u32 = 256;

pub const MAX_ATLAS_UPLOAD_BYTES_PER_FRAME: u32 = 48 * 1024 * 1024;

pub const MAX_IMAGE_REQUESTS: u32 = 256;

pub const MAX_IMAGE_DECODE_BYTES: u32 = 96 * 1024 * 1024;

pub const MAX_SVG_ENTRIES: u32 = 16_384;

pub const MAX_SVG_RASTERIZATIONS_PER_FRAME: u32 = 64;

pub const MAX_IMAGE_ENTRIES: u32 = 4_096;

pub const MAX_IMAGE_PATH_BYTES: u32 = 4_096;

pub const atlas_open_frame_count_max: u32 = 1;

pub const window_count_max: u32 = 1;

pub const image_decode_outstanding_max: u32 = 1;

comptime {
    assert(window_count_max == 1);
    assert(image_decode_outstanding_max == 1);
    assert(MAX_IMAGE_DECODE_BYTES > MAX_ATLAS_SIZE * MAX_ATLAS_SIZE * 4);
    assert(MAX_SVG_RASTERIZATIONS_PER_FRAME <= MAX_SVG_ENTRIES);
    assert(MAX_IMAGE_REQUESTS <= MAX_IMAGE_ENTRIES);
    assert(atlas_open_frame_count_max >= 1);
    assert(atlas_open_frame_count_max * MAX_SVGS_PER_FRAME <= MAX_SVG_ENTRIES);
    assert(atlas_open_frame_count_max * MAX_IMAGES_PER_FRAME <= MAX_IMAGE_ENTRIES);
    assert(MAX_ATLAS_UPLOAD_BYTES_PER_FRAME * 3 == MAX_ATLAS_SIZE * MAX_ATLAS_SIZE * 9);
    assert(MAX_SHADER_PARAMS_BYTES % shader_params_alignment == 0);
    assert(MAX_SHADERS <= std.math.maxInt(u8));
}

pub const ResourceLimits = struct {
    paint: PaintLimits,
    window: WindowLimits,
    frame: FrameLimits,
    atlas: AtlasLimits,
    build: BuildLimits,
    records: RecordLimits,
    retained: RetainedLimits,
    events: EventLimits,
    text: TextLimits,
    entities: EntityLimits,
    a11y: A11yLimits,

    pub const profile_names = rung_names ++ [_][]const u8{"embedded"};

    pub const rung_names = [_][]const u8{ "nano", "small", "standard", "large", "ceiling" };

    pub const embedded: ResourceLimits = .{
        .paint = PaintLimits.embedded,
        .window = WindowLimits.embedded,
        .frame = FrameLimits.nano,
        .atlas = AtlasLimits.embedded,
        .build = BuildLimits.nano,
        .records = RecordLimits.nano,
        .retained = RetainedLimits.nano,
        .events = EventLimits.nano,
        .text = TextLimits.embedded,
        .entities = EntityLimits.nano,
        .a11y = A11yLimits.nano,
    };

    pub const nano: ResourceLimits = .{
        .paint = PaintLimits.nano,
        .window = WindowLimits.nano,
        .frame = FrameLimits.nano,
        .atlas = AtlasLimits.nano,
        .build = BuildLimits.nano,
        .records = RecordLimits.nano,
        .retained = RetainedLimits.nano,
        .events = EventLimits.nano,
        .text = TextLimits.nano,
        .entities = EntityLimits.nano,
        .a11y = A11yLimits.nano,
    };

    pub const small: ResourceLimits = .{
        .paint = PaintLimits.small,
        .window = WindowLimits.small,
        .frame = FrameLimits.small,
        .atlas = AtlasLimits.small,
        .build = BuildLimits.small,
        .records = RecordLimits.small,
        .retained = RetainedLimits.small,
        .events = EventLimits.small,
        .text = TextLimits.small,
        .entities = EntityLimits.small,
        .a11y = A11yLimits.small,
    };

    pub const standard: ResourceLimits = .{
        .paint = PaintLimits.standard,
        .window = WindowLimits.standard,
        .frame = FrameLimits.standard,
        .atlas = AtlasLimits.standard,
        .build = BuildLimits.standard,
        .records = RecordLimits.standard,
        .retained = RetainedLimits.standard,
        .events = EventLimits.standard,
        .text = TextLimits.standard,
        .entities = EntityLimits.standard,
        .a11y = A11yLimits.standard,
    };

    pub const large: ResourceLimits = .{
        .paint = PaintLimits.large,
        .window = WindowLimits.large,
        .frame = FrameLimits.large,
        .atlas = AtlasLimits.large,
        .build = BuildLimits.large,
        .records = RecordLimits.large,
        .retained = RetainedLimits.large,
        .events = EventLimits.large,
        .text = TextLimits.large,
        .entities = EntityLimits.large,
        .a11y = A11yLimits.large,
    };

    pub const ceiling: ResourceLimits = .{
        .paint = PaintLimits.ceiling,
        .window = WindowLimits.ceiling,
        .frame = FrameLimits.ceiling,
        .atlas = AtlasLimits.ceiling,
        .build = BuildLimits.ceiling,
        .records = RecordLimits.ceiling,
        .retained = RetainedLimits.ceiling,
        .events = EventLimits.ceiling,
        .text = TextLimits.ceiling,
        .entities = EntityLimits.ceiling,
        .a11y = A11yLimits.ceiling,
    };

    pub fn check(self: *const ResourceLimits) ?Violation {
        if (self.paint.check()) |violation| return violation;
        if (self.window.check()) |violation| return violation;
        if (self.frame.check()) |violation| return violation;
        if (self.atlas.check()) |violation| return violation;
        if (checkCeilings(BuildLimits, .build, &self.build)) |violation| return violation;
        if (checkCeilings(RecordLimits, .records, &self.records)) |violation| return violation;
        if (checkCeilings(RetainedLimits, .retained, &self.retained)) |violation| return violation;
        if (checkCeilings(EventLimits, .events, &self.events)) |violation| return violation;
        if (self.text.check()) |violation| return violation;
        if (checkCeilings(EntityLimits, .entities, &self.entities)) |violation| return violation;
        if (checkCeilings(A11yLimits, .a11y, &self.a11y)) |violation| return violation;
        return self.checkCoreRelationships();
    }

    fn checkCoreRelationships(self: *const ResourceLimits) ?Violation {
        const element_count = self.build.element_count_frame_max;
        if (self.records.hit_record_count_frame_max > element_count) {
            return relationship(
                .records,
                "hit_record_count_frame_max",
                self.records.hit_record_count_frame_max,
                element_count,
            );
        }
        if (self.records.handler_count_frame_max > element_count * handler_count_element_max) {
            return relationship(
                .records,
                "handler_count_frame_max",
                self.records.handler_count_frame_max,
                element_count * handler_count_element_max,
            );
        }
        if (self.records.handler_count_frame_max < self.textFieldHandlerCount()) {
            return .{
                .budget = .records,
                .field = "handler_count_frame_max",
                .rule = .below_text_field_handlers,
                .value = self.records.handler_count_frame_max,
                .bound = self.textFieldHandlerCount(),
            };
        }
        if (self.build.key_count_frame_max > element_count) {
            return relationship(
                .build,
                "key_count_frame_max",
                self.build.key_count_frame_max,
                element_count,
            );
        }
        if (self.build.layer_count_frame_max > element_count) {
            return relationship(
                .build,
                "layer_count_frame_max",
                self.build.layer_count_frame_max,
                element_count,
            );
        }
        if (self.build.box_depth_max > element_count) {
            return relationship(.build, "box_depth_max", self.build.box_depth_max, element_count);
        }
        if (self.build.grid_count_frame_max > element_count) {
            return relationship(
                .build,
                "grid_count_frame_max",
                self.build.grid_count_frame_max,
                element_count,
            );
        }
        if (self.checkA11yRelationships()) |violation| return violation;
        if (self.checkAtlasCacheRelationships()) |violation| return violation;
        if (self.text.preedit_bytes_max > self.events.text_bytes_max) {
            return relationship(
                .text,
                "preedit_bytes_max",
                self.text.preedit_bytes_max,
                self.events.text_bytes_max,
            );
        }
        if (self.checkEventRelationships()) |violation| return violation;
        return self.checkPaintRecordRelationships();
    }

    /// Every custom fill is one paint record, and every element may paint at least one.
    fn checkPaintRecordRelationships(self: *const ResourceLimits) ?Violation {
        const record_count = self.records.paint_record_count_frame_max;
        if (self.paint.custom_draw_count_frame_max > record_count) {
            return relationship(
                .paint,
                "custom_draw_count_frame_max",
                self.paint.custom_draw_count_frame_max,
                record_count,
            );
        }
        if (record_count < self.build.element_count_frame_max) {
            return .{
                .budget = .records,
                .field = "paint_record_count_frame_max",
                .rule = .below_relationship,
                .value = record_count,
                .bound = self.build.element_count_frame_max,
            };
        }
        return null;
    }

    pub const text_field_handlers = text_field_handler_count_max;

    pub fn textFieldHandlerCount(self: *const ResourceLimits) u32 {
        const field_count = self.text.input.count_max + self.text.area.count_max +
            self.text.editor.count_max;
        assert(field_count <= std.math.maxInt(u32) / text_field_handler_count_max);
        return field_count * text_field_handler_count_max;
    }

    fn checkAtlasCacheRelationships(self: *const ResourceLimits) ?Violation {
        const svg_bound = atlas_open_frame_count_max * self.paint.svg_count_frame_max;
        if (self.atlas.svg_entry_count_max < svg_bound) {
            return .{
                .budget = .atlas,
                .field = "svg_entry_count_max",
                .rule = .below_relationship,
                .value = self.atlas.svg_entry_count_max,
                .bound = svg_bound,
            };
        }
        const image_bound = atlas_open_frame_count_max * self.paint.image_count_frame_max;
        if (self.atlas.image_entry_count_max < image_bound) {
            return .{
                .budget = .atlas,
                .field = "image_entry_count_max",
                .rule = .below_relationship,
                .value = self.atlas.image_entry_count_max,
                .bound = image_bound,
            };
        }
        return null;
    }

    fn checkEventRelationships(self: *const ResourceLimits) ?Violation {
        const completion_bound = self.events.dialog_count_max + image_decode_outstanding_max +
            self.events.job_result_count_max + self.events.job_count_max;
        if (self.events.completion_count_max < completion_bound) {
            return .{
                .budget = .events,
                .field = "completion_count_max",
                .rule = .below_relationship,
                .value = self.events.completion_count_max,
                .bound = completion_bound,
            };
        }
        if (self.events.queue_count_max < input_burst_count_max) {
            return .{
                .budget = .events,
                .field = "queue_count_max",
                .rule = .below_relationship,
                .value = self.events.queue_count_max,
                .bound = input_burst_count_max,
            };
        }
        return null;
    }

    fn checkA11yRelationships(self: *const ResourceLimits) ?Violation {
        const element_count = self.build.element_count_frame_max;
        if (self.a11y.element_count_max > element_count) {
            return relationship(
                .a11y,
                "element_count_max",
                self.a11y.element_count_max,
                element_count,
            );
        }
        if (self.a11y.value_bytes_max > self.build.text_bytes_frame_max) {
            return relationship(
                .a11y,
                "value_bytes_max",
                self.a11y.value_bytes_max,
                self.build.text_bytes_frame_max,
            );
        }
        return null;
    }

    pub fn assertValid(self: *const ResourceLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.{t}.{s} = {d}: rule {t}, bound {d}", .{
                violation.budget,
                violation.field,
                violation.value,
                violation.rule,
                violation.bound,
            });
        }
    }

    pub fn validate(comptime self: ResourceLimits) void {
        comptime {
            if (self.check()) |violation| @compileError(violation.describe());
        }
    }
};

pub const PaintLimits = struct {
    quad_count_frame_max: u32,
    shadow_count_frame_max: u32,
    glyph_count_frame_max: u32,
    svg_count_frame_max: u32,
    image_count_frame_max: u32,
    path_count_frame_max: u32,
    polyline_count_frame_max: u32,
    point_cloud_count_frame_max: u32,
    path_vertex_count_frame_max: u32,
    polyline_point_count_frame_max: u32,
    point_count_frame_max: u32,
    clip_depth_max: u32,
    /// Shaders the app may declare in `App.shaders`. See MAX_SHADERS for the init cost.
    shader_count_max: u32,
    /// Custom-shader fill instances per frame; also the params slots per frame.
    custom_draw_count_frame_max: u32,
    /// Params bytes per custom draw, a multiple of 16. Per frame in flight the params
    /// buffer is custom_draw_count_frame_max * shader_params_bytes_max bytes.
    shader_params_bytes_max: u32,

    pub const nano: PaintLimits = .{
        .quad_count_frame_max = 256,
        .shadow_count_frame_max = 16,
        .glyph_count_frame_max = 1_024,
        .svg_count_frame_max = 16,
        .image_count_frame_max = 4,
        .path_count_frame_max = 16,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .path_vertex_count_frame_max = 1_024,
        .polyline_point_count_frame_max = 1_024,
        .point_count_frame_max = 1_024,
        .clip_depth_max = 8,
        .shader_count_max = 4,
        .custom_draw_count_frame_max = 64,
        .shader_params_bytes_max = 64,
    };

    pub const embedded: PaintLimits = .{
        .quad_count_frame_max = 128,
        .shadow_count_frame_max = 8,
        .glyph_count_frame_max = 1_024,
        .svg_count_frame_max = 16,
        .image_count_frame_max = 8,
        .path_count_frame_max = 16,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .path_vertex_count_frame_max = 1_024,
        .polyline_point_count_frame_max = 64,
        .point_count_frame_max = 64,
        .clip_depth_max = 8,
        .shader_count_max = 2,
        .custom_draw_count_frame_max = 16,
        .shader_params_bytes_max = 64,
    };

    pub const small: PaintLimits = .{
        .quad_count_frame_max = 1_024,
        .shadow_count_frame_max = 64,
        .glyph_count_frame_max = 4_096,
        .svg_count_frame_max = 128,
        .image_count_frame_max = 32,
        .path_count_frame_max = 128,
        .polyline_count_frame_max = 32,
        .point_cloud_count_frame_max = 32,
        .path_vertex_count_frame_max = 8_192,
        .polyline_point_count_frame_max = 8_192,
        .point_count_frame_max = 8_192,
        .clip_depth_max = 16,
        .shader_count_max = 8,
        .custom_draw_count_frame_max = 256,
        .shader_params_bytes_max = 64,
    };

    pub const standard: PaintLimits = .{
        .quad_count_frame_max = 4_096,
        .shadow_count_frame_max = 512,
        .glyph_count_frame_max = 8_192,
        .svg_count_frame_max = 1_024,
        .image_count_frame_max = 256,
        .path_count_frame_max = 1_024,
        .polyline_count_frame_max = 256,
        .point_cloud_count_frame_max = 256,
        .path_vertex_count_frame_max = 16_384,
        .polyline_point_count_frame_max = 32_768,
        .point_count_frame_max = 16_384,
        .clip_depth_max = 16,
        .shader_count_max = 16,
        .custom_draw_count_frame_max = 1_024,
        .shader_params_bytes_max = 64,
    };

    pub const large: PaintLimits = .{
        .quad_count_frame_max = 32_768,
        .shadow_count_frame_max = 2_048,
        .glyph_count_frame_max = 65_236,
        .svg_count_frame_max = 4_096,
        .image_count_frame_max = 1_024,
        .path_count_frame_max = 4_096,
        .polyline_count_frame_max = 1_024,
        .point_cloud_count_frame_max = 1_024,
        .path_vertex_count_frame_max = 262_144,
        .polyline_point_count_frame_max = 524_288,
        .point_count_frame_max = 262_144,
        .clip_depth_max = 32,
        .shader_count_max = 32,
        .custom_draw_count_frame_max = 4_096,
        .shader_params_bytes_max = 64,
    };

    pub const ceiling: PaintLimits = .{
        .quad_count_frame_max = MAX_QUADS_PER_FRAME,
        .shadow_count_frame_max = MAX_SHADOWS_PER_FRAME,
        .glyph_count_frame_max = MAX_GLYPHS_PER_FRAME,
        .svg_count_frame_max = MAX_SVGS_PER_FRAME,
        .image_count_frame_max = MAX_IMAGES_PER_FRAME,
        .path_count_frame_max = MAX_PATHS_PER_FRAME,
        .polyline_count_frame_max = MAX_POLYLINES_PER_FRAME,
        .point_cloud_count_frame_max = MAX_POINT_CLOUDS_PER_FRAME,
        .path_vertex_count_frame_max = MAX_PATHS_PER_FRAME * MAX_PATH_VERTICES,
        .polyline_point_count_frame_max = 32 * 1024 * 1024,
        .point_count_frame_max = 256 * 1024 * 1024,
        .clip_depth_max = MAX_CLIP_STACK_DEPTH,
        .shader_count_max = MAX_SHADERS,
        .custom_draw_count_frame_max = MAX_CUSTOM_DRAWS_PER_FRAME,
        .shader_params_bytes_max = MAX_SHADER_PARAMS_BYTES,
    };

    pub fn check(self: *const PaintLimits) ?Violation {
        inline for (@typeInfo(PaintLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .paint,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .paint,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        if (self.glyph_count_frame_max < MAX_GLYPHS_PER_RUN) {
            return .{
                .budget = .paint,
                .field = "glyph_count_frame_max",
                .rule = .below_relationship,
                .value = self.glyph_count_frame_max,
                .bound = MAX_GLYPHS_PER_RUN,
            };
        }
        if (self.shader_params_bytes_max % shader_params_alignment != 0) {
            return .{
                .budget = .paint,
                .field = "shader_params_bytes_max",
                .rule = .not_multiple,
                .value = self.shader_params_bytes_max,
                .bound = shader_params_alignment,
            };
        }
        return null;
    }

    pub fn paintBytes(self: *const PaintLimits) u64 {
        const packed_bytes = packed_frame.paintBytes(self);
        const point_bytes = @as(u64, packed_frame.meshPointCapacity(self)) *
            @sizeOf(packed_frame.MeshPoint);
        // Each of the two record frames holds its own mesh points and params slots.
        const params_bytes = @as(u64, self.custom_draw_count_frame_max) *
            self.shader_params_bytes_max;
        const bytes = packed_bytes + 2 * point_bytes + 2 * params_bytes;
        assert(bytes > packed_bytes);
        return bytes;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

pub const WindowLimits = struct {
    framebuffer_width_max: u32,
    framebuffer_height_max: u32,

    pub const nano: WindowLimits = .{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };

    pub const embedded: WindowLimits = .{
        .framebuffer_width_max = 1280,
        .framebuffer_height_max = 800,
    };

    pub const small: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2160,
    };

    pub const standard: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2400,
    };

    pub const large: WindowLimits = .{
        .framebuffer_width_max = 5120,
        .framebuffer_height_max = 2880,
    };

    pub const ceiling: WindowLimits = .{
        .framebuffer_width_max = MAX_FRAMEBUFFER_WIDTH,
        .framebuffer_height_max = MAX_FRAMEBUFFER_HEIGHT,
    };

    pub fn check(self: *const WindowLimits) ?Violation {
        inline for (@typeInfo(WindowLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        return null;
    }

    pub fn framebufferPixelCountMax(self: *const WindowLimits) u64 {
        assert(self.framebuffer_width_max <= MAX_FRAMEBUFFER_WIDTH);
        assert(self.framebuffer_height_max <= MAX_FRAMEBUFFER_HEIGHT);
        return @as(u64, self.framebuffer_width_max) * self.framebuffer_height_max;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

pub const FrameLimits = struct {
    in_flight_count: u32,

    pub const nano: FrameLimits = .{ .in_flight_count = 2 };
    pub const small: FrameLimits = .{ .in_flight_count = 2 };
    pub const standard: FrameLimits = .{ .in_flight_count = 3 };
    pub const large: FrameLimits = .{ .in_flight_count = 3 };
    pub const ceiling: FrameLimits = .{ .in_flight_count = MAX_FRAMES_IN_FLIGHT };

    pub fn check(self: *const FrameLimits) ?Violation {
        if (self.in_flight_count < MIN_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .below_relationship,
                .value = self.in_flight_count,
                .bound = MIN_FRAMES_IN_FLIGHT,
            };
        }
        if (self.in_flight_count > MAX_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .above_ceiling,
                .value = self.in_flight_count,
                .bound = MAX_FRAMES_IN_FLIGHT,
            };
        }
        return null;
    }

    comptime {
        assert(MIN_FRAMES_IN_FLIGHT <= MAX_FRAMES_IN_FLIGHT);
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

pub const AtlasLimits = struct {
    upload_bytes_frame_max: u32,
    text_size: u32,
    svg_size: u32,
    image_size: u32,
    svg_icon_size_max: u32,
    svg_path_bytes_max: u32,
    svg_path_vertex_count_max: u32,
    image_request_count_max: u32,
    image_decode_bytes_max: u32,
    svg_entry_count_max: u32,
    svg_rasterization_count_frame_max: u32,
    image_entry_count_max: u32,
    image_path_bytes_max: u32,

    pub const nano: AtlasLimits = .{
        .upload_bytes_frame_max = 256 * 1024,
        .text_size = 512,
        .svg_size = 256,
        .image_size = 256,
        .svg_icon_size_max = 64,
        .svg_path_bytes_max = 2 * 1024,
        .svg_path_vertex_count_max = 4 * 1024,
        .image_request_count_max = 4,
        .image_decode_bytes_max = 512 * 1024,
        .svg_entry_count_max = 64,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 8,
        .image_path_bytes_max = 1_024,
    };

    pub const embedded: AtlasLimits = .{
        .upload_bytes_frame_max = 384 * 384 * 4,
        .text_size = 512,
        .svg_size = 256,
        .image_size = 384,
        .svg_icon_size_max = 64,
        .svg_path_bytes_max = 2 * 1024,
        .svg_path_vertex_count_max = 4 * 1024,
        .image_request_count_max = 4,
        .image_decode_bytes_max = 384 * 384 * 4 * 3 / 2,
        .svg_entry_count_max = 64,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 16,
        .image_path_bytes_max = 1_024,
    };

    pub const small: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 1_024,
        .svg_size = 512,
        .image_size = 512,
        .svg_icon_size_max = 128,
        .svg_path_bytes_max = 4 * 1024,
        .svg_path_vertex_count_max = 8 * 1024,
        .image_request_count_max = 8,
        .image_decode_bytes_max = 2 * 1024 * 1024,
        .svg_entry_count_max = 256,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 32,
        .image_path_bytes_max = 1_024,
    };

    pub const standard: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 2_048,
        .svg_size = 1_024,
        .image_size = 1_024,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 8 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
        .image_request_count_max = 16,
        .image_decode_bytes_max = 8 * 1024 * 1024,
        .svg_entry_count_max = 1_024,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 256,
        .image_path_bytes_max = 1_024,
    };

    pub const large: AtlasLimits = .{
        .upload_bytes_frame_max = 16 * 1024 * 1024,
        .text_size = 4_096,
        .svg_size = 2_048,
        .image_size = 2_048,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 16 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
        .image_request_count_max = 64,
        .image_decode_bytes_max = 24 * 1024 * 1024,
        .svg_entry_count_max = 4_096,
        .svg_rasterization_count_frame_max = 16,
        .image_entry_count_max = 1_024,
        .image_path_bytes_max = 1_024,
    };

    pub const ceiling: AtlasLimits = .{
        .upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME,
        .text_size = MAX_ATLAS_SIZE,
        .svg_size = MAX_ATLAS_SIZE,
        .image_size = MAX_ATLAS_SIZE,
        .svg_icon_size_max = MAX_SVG_ICON_SIZE,
        .svg_path_bytes_max = MAX_SVG_PATH_BYTES,
        .svg_path_vertex_count_max = MAX_SVG_PATH_VERTEX_COUNT,
        .image_request_count_max = MAX_IMAGE_REQUESTS,
        .image_decode_bytes_max = MAX_IMAGE_DECODE_BYTES,
        .svg_entry_count_max = MAX_SVG_ENTRIES,
        .svg_rasterization_count_frame_max = MAX_SVG_RASTERIZATIONS_PER_FRAME,
        .image_entry_count_max = MAX_IMAGE_ENTRIES,
        .image_path_bytes_max = MAX_IMAGE_PATH_BYTES,
    };

    pub fn check(self: *const AtlasLimits) ?Violation {
        inline for (@typeInfo(AtlasLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .zero,
                    .value = 0,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        inline for (.{ "text_size", "svg_size", "image_size" }) |field_name| {
            const value: u32 = @field(self, field_name);
            if (value % MIN_ATLAS_SIZE != 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .not_multiple,
                    .value = value,
                    .bound = MIN_ATLAS_SIZE,
                };
            }
        }
        return self.checkRelationships();
    }

    pub fn assertValid(self: *const AtlasLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.atlas.{s} = {d}: rule {t}, bound {d}", .{
                violation.field,
                violation.value,
                violation.rule,
                violation.bound,
            });
        }
    }

    fn checkRelationships(self: *const AtlasLimits) ?Violation {
        if (self.svg_rasterization_count_frame_max > self.svg_entry_count_max) {
            return relationship(
                .atlas,
                "svg_rasterization_count_frame_max",
                self.svg_rasterization_count_frame_max,
                self.svg_entry_count_max,
            );
        }
        if (self.image_entry_count_max < self.image_request_count_max) {
            return .{
                .budget = .atlas,
                .field = "image_entry_count_max",
                .rule = .below_relationship,
                .value = self.image_entry_count_max,
                .bound = self.image_request_count_max,
            };
        }
        if (self.svg_size < self.svg_icon_size_max + 2) {
            return .{
                .budget = .atlas,
                .field = "svg_size",
                .rule = .below_relationship,
                .value = self.svg_size,
                .bound = self.svg_icon_size_max + 2,
            };
        }
        if (self.upload_bytes_frame_max < self.itemUploadBytesMax()) {
            return .{
                .budget = .atlas,
                .field = "upload_bytes_frame_max",
                .rule = .below_relationship,
                .value = self.upload_bytes_frame_max,
                .bound = self.itemUploadBytesMax(),
            };
        }
        return null;
    }

    pub fn itemUploadBytesMax(self: *const AtlasLimits) u32 {
        assert(self.svg_icon_size_max <= MAX_SVG_ICON_SIZE);
        const glyph_side: u32 = MAX_GLYPH_SIZE + 2;
        const icon_side: u32 = self.svg_icon_size_max + 2;
        return @max(glyph_side * glyph_side, icon_side * icon_side * 4);
    }

    pub fn textureBytes(self: *const AtlasLimits) u64 {
        assert(self.text_size <= MAX_ATLAS_SIZE);
        assert(self.image_size <= MAX_ATLAS_SIZE);
        var bytes: u64 = @as(u64, self.text_size) * self.text_size;
        bytes += @as(u64, self.svg_size) * self.svg_size * 4;
        bytes += @as(u64, self.image_size) * self.image_size * 4;
        return bytes;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

pub const element_count_frame_ceiling: u32 = 65_535;

pub const box_depth_ceiling: u32 = 128;

comptime {
    assert(box_depth_ceiling <= std.math.maxInt(u8));
    assert(element_count_frame_ceiling + 1 == 65_536);
}

pub const run_codepoint_count_max: u32 = 1024;

pub fn textScratchBytes(events: *const EventLimits) u32 {
    assert(events.dialog_path_bytes_max > 0);
    assert(events.dialog_path_count_max > 0);
    const run_bytes: u32 = run_codepoint_count_max * @sizeOf(ShapedGlyph);
    const dialog_bytes: u32 = 2 * events.dialog_path_bytes_max +
        @sizeOf([]const u8) * events.dialog_path_count_max;
    const scratch_bytes = 4 * run_bytes + dialog_bytes;
    assert(scratch_bytes > dialog_bytes);
    return scratch_bytes;
}

pub const handler_count_element_max: u32 = 3;

pub const text_field_handler_count_max: u32 = 9;

pub const MAX_COMPONENT_DEPTH: u32 = 128;

pub const layer_count_ceiling: u32 = std.math.maxInt(u8);
pub const grid_count_ceiling: u32 = 1_024;

pub const BuildLimits = struct {
    element_count_frame_max: u32,
    component_depth_max: u32,
    key_count_frame_max: u32,
    text_bytes_frame_max: u32,
    layer_count_frame_max: u32,
    box_depth_max: u32,
    grid_count_frame_max: u32,

    pub const nano: BuildLimits = .{
        .element_count_frame_max = 512,
        .component_depth_max = 64,
        .key_count_frame_max = 256,
        .text_bytes_frame_max = 16 * 1024,
        .layer_count_frame_max = 8,
        .box_depth_max = 64,
        .grid_count_frame_max = 8,
    };
    pub const small: BuildLimits = .{
        .element_count_frame_max = 2_048,
        .component_depth_max = 64,
        .key_count_frame_max = 1_024,
        .text_bytes_frame_max = 64 * 1024,
        .layer_count_frame_max = 16,
        .box_depth_max = 64,
        .grid_count_frame_max = 32,
    };
    pub const standard: BuildLimits = .{
        .element_count_frame_max = 4_096,
        .component_depth_max = 64,
        .key_count_frame_max = 4_096,
        .text_bytes_frame_max = 256 * 1024,
        .layer_count_frame_max = 32,
        .box_depth_max = 64,
        .grid_count_frame_max = 128,
    };
    pub const large: BuildLimits = .{
        .element_count_frame_max = 16_383,
        .component_depth_max = 64,
        .key_count_frame_max = 16_383,
        .text_bytes_frame_max = 1024 * 1024,
        .layer_count_frame_max = 64,
        .box_depth_max = 64,
        .grid_count_frame_max = 512,
    };
    pub const ceiling: BuildLimits = .{
        .element_count_frame_max = element_count_frame_ceiling,
        .component_depth_max = MAX_COMPONENT_DEPTH,
        .key_count_frame_max = element_count_frame_ceiling,
        .text_bytes_frame_max = 4 * 1024 * 1024,
        .layer_count_frame_max = layer_count_ceiling,
        .box_depth_max = box_depth_ceiling,
        .grid_count_frame_max = grid_count_ceiling,
    };
};

pub const RecordLimits = struct {
    paint_record_count_frame_max: u32,
    hit_record_count_frame_max: u32,
    handler_count_frame_max: u32,

    pub const nano: RecordLimits = .{
        .paint_record_count_frame_max = 4_096,
        .hit_record_count_frame_max = 512,
        .handler_count_frame_max = 512,
    };
    pub const small: RecordLimits = .{
        .paint_record_count_frame_max = 8_192,
        .hit_record_count_frame_max = 2_048,
        .handler_count_frame_max = 2_048,
    };
    pub const standard: RecordLimits = .{
        .paint_record_count_frame_max = 28_672,
        .hit_record_count_frame_max = 4_096,
        .handler_count_frame_max = 4_096,
    };
    pub const large: RecordLimits = .{
        .paint_record_count_frame_max = 65_536,
        .hit_record_count_frame_max = 16_383,
        .handler_count_frame_max = 16_384,
    };
    pub const ceiling: RecordLimits = .{
        .paint_record_count_frame_max = 262_144,
        .hit_record_count_frame_max = element_count_frame_ceiling,
        .handler_count_frame_max = element_count_frame_ceiling * handler_count_element_max,
    };
};

pub const RetainedLimits = struct {
    slot_count_64: u32,
    slot_count_256: u32,
    slot_count_1024: u32,
    slot_count_4096: u32,
    sweep_delay_frames: u32,

    pub const nano: RetainedLimits = .{
        .slot_count_64 = 128,
        .slot_count_256 = 64,
        .slot_count_1024 = 16,
        .slot_count_4096 = 4,
        .sweep_delay_frames = 8,
    };
    pub const small: RetainedLimits = .{
        .slot_count_64 = 512,
        .slot_count_256 = 256,
        .slot_count_1024 = 64,
        .slot_count_4096 = 16,
        .sweep_delay_frames = 8,
    };
    pub const standard: RetainedLimits = .{
        .slot_count_64 = 2_048,
        .slot_count_256 = 1_024,
        .slot_count_1024 = 256,
        .slot_count_4096 = 64,
        .sweep_delay_frames = 8,
    };
    pub const large: RetainedLimits = .{
        .slot_count_64 = 8_192,
        .slot_count_256 = 4_096,
        .slot_count_1024 = 1_024,
        .slot_count_4096 = 256,
        .sweep_delay_frames = 8,
    };
    pub const ceiling: RetainedLimits = .{
        .slot_count_64 = 65_536,
        .slot_count_256 = 16_384,
        .slot_count_1024 = 4_096,
        .slot_count_4096 = 1_024,
        .sweep_delay_frames = 600,
    };
};

pub const input_burst_count_max: u32 = 256;

pub const EventLimits = struct {
    queue_count_max: u32,
    completion_count_max: u32,
    text_bytes_max: u32,
    dialog_path_count_max: u32,
    dialog_path_bytes_max: u32,
    dialog_count_max: u32,
    job_count_max: u32,
    job_input_bytes_max: u32,
    job_result_count_max: u32,
    job_result_bytes_max: u32,

    pub const nano: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 16,
        .text_bytes_max = 4 * 1024,
        .dialog_path_count_max = 16,
        .dialog_path_bytes_max = 2 * 1024,
        .dialog_count_max = 2,
        .job_count_max = 2,
        .job_input_bytes_max = 256,
        .job_result_count_max = 8,
        .job_result_bytes_max = 1 * 1024,
    };
    pub const small: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 32,
        .text_bytes_max = 8 * 1024,
        .dialog_path_count_max = 32,
        .dialog_path_bytes_max = 4 * 1024,
        .dialog_count_max = 4,
        .job_count_max = 4,
        .job_input_bytes_max = 1 * 1024,
        .job_result_count_max = 16,
        .job_result_bytes_max = 2 * 1024,
    };
    pub const standard: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 64,
        .text_bytes_max = 16 * 1024,
        .dialog_path_count_max = 64,
        .dialog_path_bytes_max = 8 * 1024,
        .dialog_count_max = 8,
        .job_count_max = 8,
        .job_input_bytes_max = 4 * 1024,
        .job_result_count_max = 32,
        .job_result_bytes_max = 4 * 1024,
    };
    pub const large: EventLimits = .{
        .queue_count_max = 512,
        .completion_count_max = 128,
        .text_bytes_max = 64 * 1024,
        .dialog_path_count_max = 256,
        .dialog_path_bytes_max = 32 * 1024,
        .dialog_count_max = 8,
        .job_count_max = 16,
        .job_input_bytes_max = 16 * 1024,
        .job_result_count_max = 64,
        .job_result_bytes_max = 16 * 1024,
    };
    pub const ceiling: EventLimits = .{
        .queue_count_max = 4_096,
        .completion_count_max = 1_024,
        .text_bytes_max = 1024 * 1024,
        .dialog_path_count_max = 1_024,
        .dialog_path_bytes_max = 64 * 1024,
        .dialog_count_max = 64,
        .job_count_max = 64,
        .job_input_bytes_max = 256 * 1024,
        .job_result_count_max = 256,
        .job_result_bytes_max = 64 * 1024,
    };
};

pub const TextKindLimits = struct {
    count_max: u32,
    bytes_max: u32,
    undo_depth_max: u32,
};

pub const TextLimits = struct {
    fonts: FontLimits,
    glyph_cache_count_max: u32,
    shaped_run_count_max: u32,
    measure_slot_count_max: u32,
    text_size_slot_count_max: u32,
    preedit_bytes_max: u32,
    input: TextKindLimits,
    area: TextKindLimits,
    editor: TextKindLimits,

    const cache_field_names = .{
        "glyph_cache_count_max",
        "shaped_run_count_max",
        "measure_slot_count_max",
        "text_size_slot_count_max",
        "preedit_bytes_max",
    };

    pub const nano: TextLimits = .{
        .fonts = FontLimits.nano,
        .glyph_cache_count_max = 512,
        .shaped_run_count_max = 64,
        .measure_slot_count_max = 256,
        .text_size_slot_count_max = 256,
        .preedit_bytes_max = 256,
        .input = .{ .count_max = 4, .bytes_max = 1024, .undo_depth_max = 32 },
        .area = .{ .count_max = 0, .bytes_max = 16 * 1024, .undo_depth_max = 32 },
        .editor = .{ .count_max = 0, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
    };
    pub const embedded: TextLimits = blk: {
        var value = nano;
        value.fonts = FontLimits.embedded;
        break :blk value;
    };
    pub const small: TextLimits = .{
        .fonts = FontLimits.small,
        .glyph_cache_count_max = 1_024,
        .shaped_run_count_max = 128,
        .measure_slot_count_max = 1_024,
        .text_size_slot_count_max = 1_024,
        .preedit_bytes_max = 256,
        .input = .{ .count_max = 16, .bytes_max = 4 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 2, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
        .editor = .{ .count_max = 0, .bytes_max = 256 * 1024, .undo_depth_max = 128 },
    };
    pub const standard: TextLimits = .{
        .fonts = FontLimits.standard,
        .glyph_cache_count_max = 4_096,
        .shaped_run_count_max = 256,
        .measure_slot_count_max = 2_048,
        .text_size_slot_count_max = 4_096,
        .preedit_bytes_max = 1_024,
        .input = .{ .count_max = 64, .bytes_max = 8 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 4, .bytes_max = 128 * 1024, .undo_depth_max = 128 },
        .editor = .{ .count_max = 0, .bytes_max = 1024 * 1024, .undo_depth_max = 256 },
    };
    pub const large: TextLimits = .{
        .fonts = FontLimits.large,
        .glyph_cache_count_max = 8_192,
        .shaped_run_count_max = 512,
        .measure_slot_count_max = 4_096,
        .text_size_slot_count_max = 8_192,
        .preedit_bytes_max = 1_024,
        .input = .{ .count_max = 128, .bytes_max = 8 * 1024, .undo_depth_max = 128 },
        .area = .{ .count_max = 8, .bytes_max = 128 * 1024, .undo_depth_max = 256 },
        .editor = .{ .count_max = 0, .bytes_max = 4 * 1024 * 1024, .undo_depth_max = 512 },
    };
    pub const ceiling: TextLimits = .{
        .fonts = FontLimits.ceiling,
        .glyph_cache_count_max = 16_384,
        .shaped_run_count_max = 1_024,
        .measure_slot_count_max = 16_384,
        .text_size_slot_count_max = 65_536,
        .preedit_bytes_max = 4_000,
        .input = .{ .count_max = 1_024, .bytes_max = 64 * 1024, .undo_depth_max = 1_024 },
        .area = .{ .count_max = 256, .bytes_max = 1024 * 1024, .undo_depth_max = 1_024 },
        .editor = .{ .count_max = 64, .bytes_max = 16 * 1024 * 1024, .undo_depth_max = 4_096 },
    };

    pub fn check(self: *const TextLimits) ?Violation {
        if (self.fonts.check()) |violation| return violation;
        if (self.checkCaches()) |violation| return violation;
        inline for (.{ "input", "area", "editor" }) |kind| {
            const value: *const TextKindLimits = &@field(self, kind);
            const bound: *const TextKindLimits = &@field(ceiling, kind);
            inline for (@typeInfo(TextKindLimits).@"struct".field_names) |field_name| {
                const field_value: u32 = @field(value, field_name);
                const field_bound: u32 = @field(bound, field_name);
                const zero_allowed = comptime std.mem.eql(u8, field_name, "count_max");
                if (field_value == 0 and !zero_allowed) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .zero,
                        .value = 0,
                        .bound = 1,
                    };
                }
                if (field_value > field_bound) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .above_ceiling,
                        .value = field_value,
                        .bound = field_bound,
                    };
                }
            }
        }
        return null;
    }

    fn checkCaches(self: *const TextLimits) ?Violation {
        inline for (cache_field_names) |name| {
            const value: u32 = @field(self, name);
            const bound: u32 = @field(ceiling, name);
            if (value == 0) {
                return .{ .budget = .text, .field = name, .rule = .zero, .value = 0, .bound = 1 };
            }
            if (value > bound) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        inline for (.{ "measure_slot_count_max", "text_size_slot_count_max" }) |name| {
            const slots: u32 = @field(self, name);
            if (slots <= measure_probe_count) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .below_relationship,
                    .value = slots,
                    .bound = measure_probe_count + 1,
                };
            }
            if (!std.math.isPowerOfTwo(slots)) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .not_power_of_two,
                    .value = slots,
                    .bound = std.math.ceilPowerOfTwoAssert(u32, slots),
                };
            }
        }
        return null;
    }
};

pub const measure_probe_count: u32 = 8;

comptime {
    assert(std.math.isPowerOfTwo(TextLimits.ceiling.measure_slot_count_max));
    assert(std.math.isPowerOfTwo(TextLimits.ceiling.text_size_slot_count_max));
    assert(2 * TextLimits.ceiling.glyph_cache_count_max < std.math.maxInt(u16));
}

pub const EntityLimits = struct {
    count_per_type_max: u32,

    pub const nano: EntityLimits = .{ .count_per_type_max = 16 };
    pub const small: EntityLimits = .{ .count_per_type_max = 64 };
    pub const standard: EntityLimits = .{ .count_per_type_max = 256 };
    pub const large: EntityLimits = .{ .count_per_type_max = 1_024 };
    pub const ceiling: EntityLimits = .{ .count_per_type_max = 4_096 };
};

pub const A11yLimits = struct {
    element_count_max: u32,
    announcement_polite_pending_max: u32,
    announcement_message_bytes_max: u32,
    value_bytes_max: u32,

    pub const nano: A11yLimits = .{
        .element_count_max = 128,
        .announcement_polite_pending_max = 3,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 1024,
    };
    pub const small: A11yLimits = .{
        .element_count_max = 512,
        .announcement_polite_pending_max = 7,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 4 * 1024,
    };
    pub const standard: A11yLimits = .{
        .element_count_max = 2_048,
        .announcement_polite_pending_max = 15,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 8 * 1024,
    };
    pub const large: A11yLimits = .{
        .element_count_max = 8_192,
        .announcement_polite_pending_max = 15,
        .announcement_message_bytes_max = 256,
        .value_bytes_max = 16 * 1024,
    };
    pub const ceiling: A11yLimits = .{
        .element_count_max = a11y_element_count_ceiling,
        .announcement_polite_pending_max = 63,
        .announcement_message_bytes_max = 256,
        .value_bytes_max = a11y_value_bytes_ceiling,
    };
};

pub const a11y_value_bytes_ceiling: u32 = 32 * 1024;

pub const a11y_element_count_ceiling: u32 = 16_384;

comptime {
    assert(a11y_element_count_ceiling < std.math.maxInt(u16));
    assert(2 * a11y_element_count_ceiling <= std.math.maxInt(u16));
    assert(a11y_value_bytes_ceiling <= std.math.maxInt(u16));
    const pending_ceiling = A11yLimits.ceiling.announcement_polite_pending_max + 1;
    assert(pending_ceiling + a11y_element_count_ceiling < std.math.maxInt(u16));
    assert(@as(u64, pending_ceiling) * A11yLimits.ceiling.announcement_message_bytes_max <=
        std.math.maxInt(u32));
}

fn checkCeilings(comptime T: type, comptime budget: Violation.Budget, self: *const T) ?Violation {
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        const value: u32 = @field(self, field_name);
        const bound: u32 = @field(T.ceiling, field_name);
        if (value == 0) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .zero,
                .value = 0,
                .bound = 1,
            };
        }
        if (value > bound) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .above_ceiling,
                .value = value,
                .bound = bound,
            };
        }
    }
    return null;
}

fn relationship(
    comptime budget: Violation.Budget,
    comptime field: []const u8,
    value: u32,
    bound: u32,
) Violation {
    return .{
        .budget = budget,
        .field = field,
        .rule = .above_relationship,
        .value = value,
        .bound = bound,
    };
}

comptime {
    for (ResourceLimits.profile_names) |name| {
        assert(@field(ResourceLimits, name).check() == null);
    }
    assert(BuildLimits.standard.component_depth_max == 64);
    assert(BuildLimits.ceiling.component_depth_max == 128);
}

pub const Violation = struct {
    budget: Budget,
    field: []const u8,
    rule: Rule,
    value: u32,
    bound: u32,

    pub const Budget = enum {
        paint,
        window,
        frame,
        atlas,
        build,
        records,
        retained,
        events,
        text,
        entities,
        a11y,
    };
    pub const Rule = enum {
        zero,
        above_ceiling,
        below_relationship,
        above_relationship,
        below_text_field_handlers,
        not_multiple,
        not_power_of_two,
        duplicate,
        missing_regular,
    };

    pub fn describe(comptime self: Violation) []const u8 {
        return switch (self.rule) {
            .zero => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} must be at least 1, got 0",
                .{ self.budget, self.field },
            ),
            .above_ceiling => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds the framework ceiling {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .below_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is below the required minimum {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .above_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds {d}, set by a related budget",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .below_text_field_handlers => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is below {d}: every TextInput, TextArea, and " ++
                    "CodeEditor in ResourceLimits.text (input + area + editor count_max) " ++
                    "registers up to {d} handlers per frame; raise {s} or lower those counts",
                .{
                    self.budget,
                    self.field,
                    self.value,
                    self.bound,
                    text_field_handler_count_max,
                    self.field,
                },
            ),
            .not_multiple => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is not a multiple of {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .not_power_of_two => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is not a power of two; use {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .duplicate => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} lists a font variant twice",
                .{ self.budget, self.field },
            ),
            .missing_regular => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} lacks .regular, which supplies line metrics",
                .{ self.budget, self.field },
            ),
        };
    }
};

pub const MAX_GLYPHS_PER_RUN: u32 = 1024;

pub const FontLimits = struct {
    variants: []const FontVariant,
    mono_variants: []const FontVariant = &.{},

    pub const standard: FontLimits = .{
        .variants = &.{ .regular, .medium, .semibold, .bold, .italic, .bold_italic },
    };

    pub const nano: FontLimits = .{ .variants = &.{.regular} };

    pub const embedded: FontLimits = .{ .variants = &.{ .regular, .bold } };

    pub const small: FontLimits = .{ .variants = &.{ .regular, .medium, .semibold, .bold } };

    pub const large: FontLimits = standard;

    pub const ceiling: FontLimits = .{ .variants = &all_variants };

    const all_variants: [FontVariant.count]FontVariant = blk: {
        var result: [FontVariant.count]FontVariant = undefined;
        for (&result, 0..) |*variant, index| variant.* = @fromBackingInt(@intCast(index));
        break :blk result;
    };

    pub fn check(self: *const FontLimits) ?Violation {
        if (checkVariants("fonts.variants", self.variants, 1)) |violation| return violation;
        return checkVariants("fonts.mono_variants", self.mono_variants, 0);
    }

    fn checkVariants(
        comptime field: []const u8,
        variants: []const FontVariant,
        comptime count_min: u32,
    ) ?Violation {
        const count: u32 = @intCast(@min(variants.len, std.math.maxInt(u32)));
        if (count < count_min) return fontViolation(field, .zero, count, count_min);
        if (count > FontVariant.count) {
            return fontViolation(field, .above_ceiling, count, FontVariant.count);
        }
        if (count == 0) return null;
        if (hasDuplicate(variants)) return fontViolation(field, .duplicate, count, count - 1);
        for (variants) |variant| {
            if (variant == .regular) return null;
        }
        return fontViolation(field, .missing_regular, count, count);
    }

    fn fontViolation(
        comptime field: []const u8,
        rule: Violation.Rule,
        value: u32,
        bound: u32,
    ) Violation {
        assert(rule != .not_multiple);
        assert(rule != .not_power_of_two);
        return .{ .budget = .text, .field = field, .rule = rule, .value = value, .bound = bound };
    }

    fn hasDuplicate(variants: []const FontVariant) bool {
        assert(variants.len <= FontVariant.count);
        var seen: [FontVariant.count]bool = @splat(false);
        for (variants) |variant| {
            if (seen[@backingInt(variant)]) return true;
            seen[@backingInt(variant)] = true;
        }
        return false;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

pub const MAX_PATH_VERTICES: u32 = 512;

pub const MAX_PATH_TRIANGLES: u32 = MAX_PATH_VERTICES - 2;

pub const MAX_PATH_INDICES: u32 = MAX_PATH_TRIANGLES * 3;

pub const MAX_STROKE_INPUT: u32 = 512;

pub const MAX_STROKE_OUTPUT: u32 = 1024;

pub const ROUND_SEGMENTS: u32 = 8;

pub const MAX_STROKE_TRIANGLES: u32 = MAX_STROKE_OUTPUT;

pub const MAX_STROKE_INDICES: u32 = MAX_STROKE_TRIANGLES * 3;

pub const MAX_LINE_WIDTH: f32 = 1000.0;

pub const MAX_POINT_RADIUS: f32 = 1000.0;

comptime {
    std.debug.assert(MAX_GLYPHS_PER_FRAME >= MAX_GLYPHS_PER_RUN);
    std.debug.assert(MAX_CLIP_STACK_DEPTH <= 64);

    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);

    std.debug.assert(MAX_PATH_TRIANGLES == MAX_PATH_VERTICES - 2);
    std.debug.assert(MAX_PATH_INDICES == MAX_PATH_TRIANGLES * 3);

    std.debug.assert(MAX_STROKE_OUTPUT >= MAX_STROKE_INPUT);
    std.debug.assert(MAX_STROKE_TRIANGLES == MAX_STROKE_OUTPUT);
    std.debug.assert(MAX_STROKE_INDICES == MAX_STROKE_TRIANGLES * 3);
    std.debug.assert(ROUND_SEGMENTS >= 4);
}

test "limit relationships" {
    try std.testing.expectEqual(MAX_PATH_TRIANGLES, MAX_PATH_VERTICES - 2);
    try std.testing.expectEqual(MAX_PATH_INDICES, MAX_PATH_TRIANGLES * 3);
}

test "named profiles are valid and ordered" {
    inline for (ResourceLimits.profile_names) |name| {
        try std.testing.expect(@field(ResourceLimits, name).check() == null);
        try std.testing.expect(@field(FontLimits, name).check() == null);
    }
    const rungs = ResourceLimits.rung_names;
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower = @field(ResourceLimits, lower_name);
        const upper = @field(ResourceLimits, upper_name);
        inline for (.{ "paint", "window", "frame", "atlas" }) |budget| {
            const Budget = @TypeOf(@field(lower, budget));
            inline for (@typeInfo(Budget).@"struct".field_names) |field_name| {
                const lower_value = @field(@field(lower, budget), field_name);
                const upper_value = @field(@field(upper, budget), field_name);
                try std.testing.expect(lower_value <= upper_value);
            }
        }
        const lower_faces = @field(FontLimits, lower_name).variants.len;
        try std.testing.expect(lower_faces <= @field(FontLimits, upper_name).variants.len);
    }
    try std.testing.expectEqual(@as(u32, 2), ResourceLimits.small.frame.in_flight_count);
    try std.testing.expectEqual(@as(u32, 3), ResourceLimits.standard.frame.in_flight_count);
    try std.testing.expectEqual(@as(usize, 1), FontLimits.nano.variants.len);
    try std.testing.expectEqual(@as(usize, 4), FontLimits.small.variants.len);
}

test "the embedded profile fits board panels and stages its largest image in one frame" {
    const embedded = ResourceLimits.embedded;
    try std.testing.expect(embedded.check() == null);
    try std.testing.expect(embedded.window.framebuffer_width_max >= 1024);
    try std.testing.expect(embedded.window.framebuffer_height_max >= 600);
    try std.testing.expect(embedded.window.framebuffer_width_max < 1920);
    const side = embedded.atlas.image_size;
    try std.testing.expect(side * side * 4 <= embedded.atlas.upload_bytes_frame_max);
    try std.testing.expect((side + 1) * (side + 1) * 4 > embedded.atlas.upload_bytes_frame_max);
    try std.testing.expect(side * side * 4 <= embedded.atlas.image_decode_bytes_max);
    try std.testing.expectEqual(@as(usize, 2), embedded.text.fonts.variants.len);
    try std.testing.expectEqual(FontVariant.regular, embedded.text.fonts.variants[0]);
    try std.testing.expect(embedded.window.framebuffer_width_max <
        ResourceLimits.nano.window.framebuffer_width_max);
    try std.testing.expect(embedded.atlas.image_size > ResourceLimits.nano.atlas.image_size);
}

test "check holds every queue to the largest input burst" {
    var limits = ResourceLimits.nano;
    limits.events.queue_count_max = input_burst_count_max;
    try std.testing.expectEqual(@as(?Violation, null), limits.check());
    limits.events.queue_count_max = input_burst_count_max - 1;
    const violation = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.events, violation.budget);
    try std.testing.expectEqualStrings("queue_count_max", violation.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, violation.rule);
    try std.testing.expectEqual(input_burst_count_max - 1, violation.value);
    try std.testing.expectEqual(input_burst_count_max, violation.bound);
}

test "check reports each negative case precisely" {
    var limits = ResourceLimits.standard;
    limits.paint.svg_count_frame_max = 0;
    const zero = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.zero, zero.rule);
    try std.testing.expectEqualStrings("svg_count_frame_max", zero.field);

    limits = ResourceLimits.standard;
    limits.paint.quad_count_frame_max = MAX_QUADS_PER_FRAME + 1;
    const above = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    try std.testing.expectEqual(MAX_QUADS_PER_FRAME, above.bound);

    limits.paint.quad_count_frame_max = MAX_QUADS_PER_FRAME;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.paint.glyph_count_frame_max = MAX_GLYPHS_PER_RUN - 1;
    const below = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.below_relationship, below.rule);
    limits.paint.glyph_count_frame_max = MAX_GLYPHS_PER_RUN;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.paint.clip_depth_max = MAX_CLIP_STACK_DEPTH + 1;
    try std.testing.expectEqualStrings("clip_depth_max", limits.check().?.field);
    inline for (.{
        "path_vertex_count_frame_max",
        "polyline_point_count_frame_max",
        "point_count_frame_max",
    }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.paint, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.paint, field) = @field(PaintLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.paint, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    limits = ResourceLimits.standard;
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT - 1;
    try std.testing.expectEqual(Violation.Budget.frame, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT + 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("in_flight_count", limits.check().?.field);

    inline for (.{ "framebuffer_width_max", "framebuffer_height_max" }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.window, field) = 0;
        try std.testing.expectEqual(Violation.Budget.window, limits.check().?.budget);
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.window, field) = @field(WindowLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.window, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    limits = ResourceLimits.standard;
    const item_bytes_max = limits.atlas.itemUploadBytesMax();
    try std.testing.expectEqual(@as(u32, 258 * 258 * 4), item_bytes_max);
    limits.atlas.upload_bytes_frame_max = item_bytes_max - 1;
    try std.testing.expectEqual(Violation.Budget.atlas, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.atlas.upload_bytes_frame_max = item_bytes_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);

    limits = ResourceLimits.large;
    limits.paint.quad_count_frame_max = PaintLimits.ceiling.quad_count_frame_max;
    inline for (.{
        "path_vertex_count_frame_max",
        "polyline_point_count_frame_max",
        "point_count_frame_max",
    }) |field| {
        @field(limits.paint, field) = @field(PaintLimits.standard, field);
    }
    try std.testing.expect(limits.check() == null);
    limits.paint.quad_count_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("quad_count_frame_max", limits.check().?.field);
}

test "check bounds each a11y field by its ceiling and its relationships" {
    inline for (.{
        "element_count_max",
        "announcement_polite_pending_max",
        "announcement_message_bytes_max",
        "value_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(A11yLimits.ceiling, field);
        @field(limits.a11y, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.a11y, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.a11y, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.nano;
    limits.a11y.element_count_max = limits.build.element_count_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.a11y.element_count_max += 1;
    const nodes = limits.check().?;
    try std.testing.expectEqualStrings("element_count_max", nodes.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, nodes.rule);
    try std.testing.expectEqual(limits.build.element_count_frame_max, nodes.bound);

    limits = ResourceLimits.nano;
    limits.a11y.value_bytes_max = limits.build.text_bytes_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.a11y.value_bytes_max += 1;
    const value = limits.check().?;
    try std.testing.expectEqualStrings("value_bytes_max", value.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, value.rule);
    try std.testing.expectEqual(limits.build.text_bytes_frame_max, value.bound);
}

test "check bounds each text cache field by its ceiling and its relationships" {
    inline for (.{
        "glyph_cache_count_max",
        "shaped_run_count_max",
        "measure_slot_count_max",
        "text_size_slot_count_max",
        "preedit_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(TextLimits.ceiling, field);
        @field(limits.text, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.text, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.text, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.nano;
    inline for (.{ "measure_slot_count_max", "text_size_slot_count_max" }) |field| {
        limits = ResourceLimits.nano;
        @field(limits.text, field) = 16;
        try std.testing.expect(limits.check() == null);
        @field(limits.text, field) = measure_probe_count;
        const window = limits.check().?;
        try std.testing.expectEqualStrings(field, window.field);
        try std.testing.expectEqual(Violation.Rule.below_relationship, window.rule);
        try std.testing.expectEqual(measure_probe_count + 1, window.bound);
        @field(limits.text, field) = measure_probe_count + 1;
        const odd = limits.check().?;
        try std.testing.expectEqualStrings(field, odd.field);
        try std.testing.expectEqual(Violation.Rule.not_power_of_two, odd.rule);
        try std.testing.expectEqual(@as(u32, 16), odd.bound);
    }

    limits = ResourceLimits.nano;
    limits.events.text_bytes_max = 2 * 1024;
    limits.text.preedit_bytes_max = limits.events.text_bytes_max;
    try std.testing.expect(limits.check() == null);
    limits.text.preedit_bytes_max += 1;
    const preedit = limits.check().?;
    try std.testing.expectEqualStrings("preedit_bytes_max", preedit.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, preedit.rule);
    try std.testing.expectEqual(limits.events.text_bytes_max, preedit.bound);
}

test "check bounds each atlas cache field by its ceiling and its relationships" {
    inline for (.{
        "svg_entry_count_max",
        "svg_rasterization_count_frame_max",
        "image_entry_count_max",
        "image_path_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(AtlasLimits.ceiling, field);
        @field(limits.atlas, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.atlas, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.atlas, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.small;
    const icons_open = atlas_open_frame_count_max * limits.paint.svg_count_frame_max;
    limits.atlas.svg_entry_count_max = icons_open;
    try std.testing.expect(limits.check() == null);
    limits.atlas.svg_entry_count_max -= 1;
    const icons = limits.check().?;
    try std.testing.expectEqualStrings("svg_entry_count_max", icons.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, icons.rule);
    try std.testing.expectEqual(limits.paint.svg_count_frame_max, icons.bound);

    limits = ResourceLimits.small;
    limits.atlas.image_entry_count_max = limits.paint.image_count_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.image_entry_count_max -= 1;
    const images = limits.check().?;
    try std.testing.expectEqualStrings("image_entry_count_max", images.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, images.rule);
    try std.testing.expectEqual(limits.paint.image_count_frame_max, images.bound);

    limits = ResourceLimits.small;
    limits.paint.image_count_frame_max = 1;
    limits.atlas.image_entry_count_max = limits.atlas.image_request_count_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.image_entry_count_max -= 1;
    const requests = limits.check().?;
    try std.testing.expectEqualStrings("image_entry_count_max", requests.field);
    try std.testing.expectEqual(limits.atlas.image_request_count_max, requests.bound);

    limits = ResourceLimits.small;
    limits.paint.svg_count_frame_max = 16;
    limits.atlas.svg_entry_count_max = 32;
    limits.atlas.svg_rasterization_count_frame_max = limits.atlas.svg_entry_count_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.svg_rasterization_count_frame_max += 1;
    const work = limits.check().?;
    try std.testing.expectEqualStrings("svg_rasterization_count_frame_max", work.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, work.rule);
    try std.testing.expectEqual(limits.atlas.svg_entry_count_max, work.bound);
}

test "check bounds dialog_count_max by its ceiling and the completion ring" {
    var limits = ResourceLimits.ceiling;
    limits.events.dialog_count_max = 0;
    try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
    try std.testing.expectEqualStrings("dialog_count_max", limits.check().?.field);
    limits.events.dialog_count_max = EventLimits.ceiling.dialog_count_max;
    try std.testing.expect(limits.check() == null);
    limits.events.dialog_count_max += 1;
    const above = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.events, above.budget);
    try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    try std.testing.expectEqual(EventLimits.ceiling.dialog_count_max, above.bound);

    limits = ResourceLimits.nano;
    limits.events.dialog_count_max = 5;
    try std.testing.expect(limits.check() == null);
    limits.events.dialog_count_max += 1;
    const ring = limits.check().?;
    try std.testing.expectEqualStrings("completion_count_max", ring.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, ring.rule);
    try std.testing.expectEqual(@as(u32, 17), ring.bound);
}

test "check bounds the job fields by their ceilings and the completion ring" {
    inline for (.{
        "job_count_max",
        "job_input_bytes_max",
        "job_result_count_max",
        "job_result_bytes_max",
    }) |name| {
        var limits = ResourceLimits.ceiling;
        @field(limits.events, name) = 0;
        try std.testing.expectEqualStrings(name, limits.check().?.field);
        @field(limits.events, name) = @field(EventLimits.ceiling, name);
        try std.testing.expect(limits.check() == null);
        @field(limits.events, name) += 1;
        const above = limits.check().?;
        try std.testing.expectEqualStrings(name, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    }
    var limits = ResourceLimits.nano;
    const room = limits.events.completion_count_max - limits.events.dialog_count_max -
        image_decode_outstanding_max - limits.events.job_count_max;
    limits.events.job_result_count_max = room;
    try std.testing.expect(limits.check() == null);
    limits.events.job_result_count_max += 1;
    const ring = limits.check().?;
    try std.testing.expectEqualStrings("completion_count_max", ring.field);
    try std.testing.expectEqual(limits.events.completion_count_max + 1, ring.bound);
}

test "check bounds box depth and layers by their ceilings and the element count" {
    var limits = ResourceLimits.standard;
    limits.build.box_depth_max = 0;
    try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
    try std.testing.expectEqualStrings("box_depth_max", limits.check().?.field);
    limits.build.box_depth_max = box_depth_ceiling;
    try std.testing.expect(limits.check() == null);
    limits.build.box_depth_max = box_depth_ceiling + 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqual(box_depth_ceiling, limits.check().?.bound);

    limits = ResourceLimits.nano;
    limits.build.element_count_frame_max = 100;
    limits.build.key_count_frame_max = 100;
    limits.records.hit_record_count_frame_max = 100;
    limits.records.handler_count_frame_max = 100;
    limits.a11y.element_count_max = 100;
    limits.build.box_depth_max = 100;
    try std.testing.expect(limits.check() == null);
    limits.build.box_depth_max = 101;
    const depth = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.build, depth.budget);
    try std.testing.expectEqualStrings("box_depth_max", depth.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, depth.rule);
    try std.testing.expectEqual(@as(u32, 100), depth.bound);

    limits.build.box_depth_max = 64;
    limits.build.layer_count_frame_max = 100;
    try std.testing.expect(limits.check() == null);
    limits.build.layer_count_frame_max = 101;
    const layers = limits.check().?;
    try std.testing.expectEqualStrings("layer_count_frame_max", layers.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, layers.rule);
    try std.testing.expectEqual(@as(u32, 100), layers.bound);

    limits = ResourceLimits.ceiling;
    try std.testing.expect(limits.check() == null);
    try std.testing.expectEqual(element_count_frame_ceiling, limits.build.element_count_frame_max);
    limits.build.element_count_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("element_count_frame_max", limits.check().?.field);
}

test "check holds the handler budget to nine per text field" {
    var limits = ResourceLimits.standard;
    try std.testing.expectEqual(@as(u32, 68 * 9), limits.textFieldHandlerCount());
    limits.text.editor.count_max = 2;
    const fields_handlers = limits.textFieldHandlerCount();
    try std.testing.expectEqual(@as(u32, 70 * 9), fields_handlers);
    limits.records.handler_count_frame_max = fields_handlers;
    try std.testing.expect(limits.check() == null);
    limits.records.handler_count_frame_max = fields_handlers - 1;
    const violation = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.records, violation.budget);
    try std.testing.expectEqualStrings("handler_count_frame_max", violation.field);
    try std.testing.expectEqual(Violation.Rule.below_text_field_handlers, violation.rule);
    try std.testing.expectEqual(fields_handlers - 1, violation.value);
    try std.testing.expectEqual(fields_handlers, violation.bound);
    limits.records.handler_count_frame_max = fields_handlers;
    limits.text.input.count_max += 1;
    try std.testing.expectEqual(Violation.Rule.below_text_field_handlers, limits.check().?.rule);
    inline for (ResourceLimits.profile_names) |name| {
        const profile = @field(ResourceLimits, name);
        const handlers = profile.records.handler_count_frame_max;
        try std.testing.expect(profile.textFieldHandlerCount() <= handlers);
    }
}

test "derived budget quantities" {
    const paint = PaintLimits.standard;
    try std.testing.expectEqual(@as(u32, 4_608), packed_frame.quadCapacity(&paint));
    try std.testing.expectEqual(@as(u32, 272), packed_frame.quadCapacity(&PaintLimits.nano));
    const rungs = ResourceLimits.rung_names;
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower_bytes = @field(PaintLimits, lower_name).paintBytes();
        try std.testing.expect(lower_bytes < @field(PaintLimits, upper_name).paintBytes());
    }
    const nano_custom_bytes = 64 * 48 + 2 * 64 * 64;
    const nano_bytes = 272 * 96 + 1_044 * 96 + 24 * 32 + 341 * 4 + 1_537 * 20 + 2 * 3_072 * 8 +
        nano_custom_bytes;
    try std.testing.expectEqual(@as(u64, nano_bytes), PaintLimits.nano.paintBytes());
    // Custom fills add 48 B per instance and two frames of 64 B params per instance:
    // 44 KiB on small, 176 KiB on standard and 704 KiB on large.
    try std.testing.expect(PaintLimits.small.paintBytes() < 1_186 * 1024);
    try std.testing.expect(paint.paintBytes() < 3_070 * 1024);
    try std.testing.expect(PaintLimits.large.paintBytes() < 35 * 1024 * 1024);

    const run_bytes = 1_024 * @sizeOf(ShapedGlyph);
    const nano_dialog = 2 * 2_048 + 16 * @sizeOf([]const u8);
    const nano_scratch = textScratchBytes(&EventLimits.nano);
    try std.testing.expectEqual(@as(u32, 4 * run_bytes + nano_dialog), nano_scratch);
    try std.testing.expect(nano_scratch < textScratchBytes(&EventLimits.large));
    try std.testing.expect(textScratchBytes(&EventLimits.ceiling) < 512 * 1024);
}

test "text.fonts reports each broken face set under its own field" {
    var limits = ResourceLimits.nano;
    limits.text.fonts = .{ .variants = &.{.regular}, .mono_variants = &.{ .regular, .bold } };
    try std.testing.expect(limits.check() == null);
    limits.text.fonts = FontLimits.ceiling;
    try std.testing.expect(limits.check() == null);
    try std.testing.expectEqual(@as(usize, FontVariant.count), FontLimits.ceiling.variants.len);

    const Case = struct { fonts: FontLimits, field: []const u8, rule: Violation.Rule };
    const cases = [_]Case{
        .{ .fonts = .{ .variants = &.{} }, .field = "fonts.variants", .rule = .zero },
        .{
            .fonts = .{ .variants = &.{ .regular, .regular } },
            .field = "fonts.variants",
            .rule = .duplicate,
        },
        .{
            .fonts = .{ .variants = &.{.bold} },
            .field = "fonts.variants",
            .rule = .missing_regular,
        },
        .{
            .fonts = .{ .variants = &.{.regular}, .mono_variants = &.{ .regular, .regular } },
            .field = "fonts.mono_variants",
            .rule = .duplicate,
        },
        .{
            .fonts = .{ .variants = &.{.regular}, .mono_variants = &.{.bold} },
            .field = "fonts.mono_variants",
            .rule = .missing_regular,
        },
    };
    inline for (cases) |case| {
        limits.text.fonts = case.fonts;
        const violation = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.text, violation.budget);
        try std.testing.expectEqualStrings(case.field, violation.field);
        try std.testing.expectEqual(case.rule, violation.rule);
    }
    const too_many = FontLimits.all_variants ++ [_]FontVariant{.regular};
    limits.text.fonts = .{ .variants = too_many[0..] };
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqual(@as(u32, FontVariant.count), limits.check().?.bound);
    inline for (ResourceLimits.profile_names) |name| {
        const fonts = @field(ResourceLimits, name).text.fonts;
        try std.testing.expectEqual(@as(usize, 0), fonts.mono_variants.len);
        try std.testing.expectEqual(@field(FontLimits, name).variants.len, fonts.variants.len);
    }
}
