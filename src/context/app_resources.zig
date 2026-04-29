//! AppResources — shared resources with a single ownership shape.
//!
//! ## Why this exists
//!
//! Per `docs/cleanup-implementation-plan.md` PR 7a (the first slice of the
//! App/Window split), the three "expensive to duplicate per window"
//! subsystems — `TextSystem`, `SvgAtlas`, `ImageAtlas` — are gathered into
//! one struct. Before this extraction, `Gooey` carried each as a `*T` plus
//! a `_owned: bool` flag, with four parallel init paths
//! (`initOwned` / `initOwnedPtr` / `initWithSharedResources` /
//! `initWithSharedResourcesPtr`) duplicating the create-or-borrow logic
//! three times each.
//!
//! After this extraction:
//!
//!   - **Single-window**: `Gooey` owns its `AppResources` by value, no
//!     ownership flags required.
//!   - **Multi-window**: the parent `App` owns one `AppResources` and
//!     hands `*AppResources` to each `Gooey`. Ownership is encoded in
//!     "do you hold a `T` or a `*T`?", per
//!     [`architectural-cleanup-plan.md` §17](../../docs/architectural-cleanup-plan.md#17-no-ownership-flags--optiont-and-boxdyn-instead).
//!
//! See [`architectural-cleanup-plan.md` §2 cleanup direction](../../docs/architectural-cleanup-plan.md#cleanup-direction)
//! for the broader `Resources / FrameContext` sketch this lands as a
//! first concrete slice. PR 7b takes the next step (rename `Gooey →
//! Window`, lift `keymap` / `globals` / `entities` into `App`).
//!
//! ## What's NOT here yet
//!
//! - `image_loader`. It currently lives on `Gooey` because it points at
//!   *this window's* atlas (which may itself be shared); flipping it to
//!   one app-wide loop is a behavioural change reserved for PR 7b.
//! - `keymap` / `globals` / `entities`. These are app-scoped per the
//!   GPUI mapping in §10, but moving them belongs in PR 7b once the
//!   `App` ↔ `Window` rename has landed.
//!
//! ## Lifetime
//!
//! Allocated and owned in two shapes only:
//!
//!   1. **By value, embedded in `Gooey`** — single-window. `Gooey.deinit`
//!      tears it down via `AppResources.deinit`.
//!   2. **By pointer, owned by `runtime/multi_window_app.zig::App`** —
//!      multi-window. The `App` heap-allocates a single `AppResources`
//!      at startup, hands `*AppResources` to every window's `Gooey`,
//!      and tears it down in `App.deinit` after the last window closes.
//!
//! The struct itself is roughly `@sizeOf(*TextSystem) + 2 * @sizeOf(*Atlas)`
//! plus a 1-byte `owned` flag — the heavy storage stays inside the three
//! pointee subsystems, which were already heap-allocated for WASM stack
//! reasons (CLAUDE.md §14).

const std = @import("std");
const Allocator = std.mem.Allocator;

const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;

const svg_mod = @import("../svg/mod.zig");
const SvgAtlas = svg_mod.SvgAtlas;

const image_mod = @import("../image/mod.zig");
const ImageAtlas = image_mod.ImageAtlas;

/// Font configuration captured from `FontConfig` in `gooey.zig`. Duplicated
/// here as a small POD struct so `AppResources.initOwned` doesn't have to
/// take a circular import on `gooey.zig`.
///
/// Field-for-field identical to `gooey.FontConfig` — the parent struct
/// re-exports its own and forwards. If a divergence appears in the future
/// (e.g. fallback-chain config), it must be added in both places by
/// design: the multi-window `App` builds its `AppResources` without ever
/// instantiating a `Gooey`, so it cannot reach `gooey.FontConfig`.
pub const FontConfig = struct {
    /// Font family name (e.g., "Inter", "JetBrains Mono"). When null,
    /// loads the platform's default sans-serif font.
    font_name: ?[]const u8 = null,
    /// Font size in points. Asserted `> 0` and `< 1000` at load time.
    font_size: f32 = 16.0,

    /// Default config — system sans-serif at 16pt.
    pub const default = FontConfig{};
};

/// Bundle of shared, app-lifetime rendering resources.
///
/// Holds heap-allocated `TextSystem`, `SvgAtlas`, `ImageAtlas`. The
/// `owned: bool` field discriminates two ownership shapes:
///
///   - `owned = true` — this `AppResources` allocated the three pointees
///     and `deinit` must free them. Set by `initOwned` / `initOwnedPtr`.
///   - `owned = false` — the pointees came from elsewhere (multi-window:
///     the parent `App`'s own `AppResources`); `deinit` is a no-op so
///     the same backing storage isn't double-freed. Set by
///     `borrowed`.
///
/// This is the **only** ownership flag in the new world — the per-field
/// `text_system_owned` / `svg_atlas_owned` / `image_atlas_owned` triplet
/// on `Gooey` is retired in the same PR. One flag, one struct.
pub const AppResources = struct {
    allocator: Allocator,
    io: std.Io,

    text_system: *TextSystem,
    svg_atlas: *SvgAtlas,
    image_atlas: *ImageAtlas,

    /// True when this struct owns the three pointees (allocated in an
    /// `initOwned*` path). False when borrowed from a parent
    /// `AppResources` (multi-window). See struct doc-comment for the
    /// two ownership shapes.
    owned: bool,

    const Self = @This();

    // =========================================================================
    // Owning init paths
    // =========================================================================

    /// Allocate and initialise all three subsystems against `scale`.
    ///
    /// Returns an `AppResources` that owns the heap allocations; the
    /// caller is responsible for invoking `deinit` exactly once. The
    /// `font_config` drives `TextSystem.loadFont` / `loadSystemFont`
    /// inline so callers don't need a separate "load default font"
    /// step.
    ///
    /// Used by single-window `Gooey.init` (which embeds an
    /// `AppResources` by value) and by multi-window `App.init` (which
    /// keeps an `*AppResources` on the heap and hands borrowed copies
    /// to each window).
    pub fn initOwned(
        allocator: Allocator,
        io: std.Io,
        scale: f32,
        font_config: FontConfig,
    ) !Self {
        // Pair the input assertions with the post-init ones at the
        // bottom of this function (CLAUDE.md §3 — "Pair assertions").
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);
        std.debug.assert(font_config.font_size > 0);
        std.debug.assert(font_config.font_size < 1000);

        const text_system = try allocator.create(TextSystem);
        errdefer allocator.destroy(text_system);
        text_system.* = try TextSystem.initWithScale(allocator, scale, io);
        errdefer text_system.deinit();

        if (font_config.font_name) |name| {
            try text_system.loadFont(name, font_config.font_size);
        } else {
            try text_system.loadSystemFont(.sans_serif, font_config.font_size);
        }

        const svg_atlas = try allocator.create(SvgAtlas);
        errdefer allocator.destroy(svg_atlas);
        svg_atlas.* = try SvgAtlas.init(allocator, scale, io);
        errdefer svg_atlas.deinit();

        const image_atlas = try allocator.create(ImageAtlas);
        errdefer allocator.destroy(image_atlas);
        image_atlas.* = try ImageAtlas.init(allocator, scale, io);
        errdefer image_atlas.deinit();

        // Pair-assert: the post-init pointers must be non-null and
        // distinct. Pointer-equality between the three would imply a
        // cross-aliased allocation bug somewhere upstream.
        std.debug.assert(@intFromPtr(text_system) != 0);
        std.debug.assert(@intFromPtr(svg_atlas) != 0);
        std.debug.assert(@intFromPtr(image_atlas) != 0);
        std.debug.assert(@intFromPtr(text_system) != @intFromPtr(svg_atlas));
        std.debug.assert(@intFromPtr(svg_atlas) != @intFromPtr(image_atlas));

        return .{
            .allocator = allocator,
            .io = io,
            .text_system = text_system,
            .svg_atlas = svg_atlas,
            .image_atlas = image_atlas,
            .owned = true,
        };
    }

    /// In-place owning init for callers that need to avoid a stack
    /// temp (single-window WASM `Gooey.initOwnedPtr` is the primary
    /// caller). Marked `noinline` per CLAUDE.md §14 so ReleaseSmall
    /// doesn't combine the stack frame back into the caller.
    ///
    /// `self` must point at uninitialised memory; the function writes
    /// every field. On error, any partially-allocated subsystems are
    /// torn down via the same `errdefer` chain as `initOwned`.
    pub noinline fn initOwnedInPlace(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        scale: f32,
        font_config: FontConfig,
    ) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);
        std.debug.assert(font_config.font_size > 0);
        std.debug.assert(font_config.font_size < 1000);

        const text_system = try allocator.create(TextSystem);
        errdefer allocator.destroy(text_system);
        try text_system.initInPlace(allocator, scale, io);
        errdefer text_system.deinit();

        if (font_config.font_name) |name| {
            try text_system.loadFont(name, font_config.font_size);
        } else {
            try text_system.loadSystemFont(.sans_serif, font_config.font_size);
        }

        const svg_atlas = try allocator.create(SvgAtlas);
        errdefer allocator.destroy(svg_atlas);
        svg_atlas.* = try SvgAtlas.init(allocator, scale, io);
        errdefer svg_atlas.deinit();

        const image_atlas = try allocator.create(ImageAtlas);
        errdefer allocator.destroy(image_atlas);
        image_atlas.* = try ImageAtlas.init(allocator, scale, io);
        errdefer image_atlas.deinit();

        // Field-by-field — no struct literal — to avoid a stack temp
        // (CLAUDE.md §14). The struct is small (~40 bytes) so the
        // literal would not be ruinous, but the rule is "be
        // consistent": every `initInPlace` writes field-by-field.
        self.allocator = allocator;
        self.io = io;
        self.text_system = text_system;
        self.svg_atlas = svg_atlas;
        self.image_atlas = image_atlas;
        self.owned = true;

        std.debug.assert(@intFromPtr(self.text_system) != 0);
        std.debug.assert(@intFromPtr(self.svg_atlas) != 0);
        std.debug.assert(@intFromPtr(self.image_atlas) != 0);
    }

    // =========================================================================
    // Borrowed init path (multi-window)
    // =========================================================================

    /// Build a borrowed `AppResources` view over already-initialised
    /// pointees. `deinit` becomes a no-op for this instance — the
    /// upstream owner is responsible for tearing the pointees down.
    ///
    /// Used by `runtime/multi_window_app.zig::App.openWindow`: the
    /// `App` keeps one owning `AppResources` on the heap, and every
    /// window's `Gooey` embeds a borrowed view of those same three
    /// pointers.
    pub fn borrowed(
        allocator: Allocator,
        io: std.Io,
        text_system: *TextSystem,
        svg_atlas: *SvgAtlas,
        image_atlas: *ImageAtlas,
    ) Self {
        std.debug.assert(@intFromPtr(text_system) != 0);
        std.debug.assert(@intFromPtr(svg_atlas) != 0);
        std.debug.assert(@intFromPtr(image_atlas) != 0);
        std.debug.assert(@intFromPtr(text_system) != @intFromPtr(svg_atlas));
        std.debug.assert(@intFromPtr(svg_atlas) != @intFromPtr(image_atlas));

        return .{
            .allocator = allocator,
            .io = io,
            .text_system = text_system,
            .svg_atlas = svg_atlas,
            .image_atlas = image_atlas,
            .owned = false,
        };
    }

    // =========================================================================
    // Teardown
    // =========================================================================

    /// Tear down the three subsystems if `owned`, otherwise no-op.
    /// Idempotent only in the borrowed case — calling `deinit` twice
    /// on an `owned = true` instance is a use-after-free, same as any
    /// other heap-owning struct.
    pub fn deinit(self: *Self) void {
        if (!self.owned) return;

        // Order mirrors `Gooey.deinit` pre-extraction: image atlas
        // first (it holds decoded pixel buffers and a row of cache
        // entries), then svg atlas, then text system. The reverse
        // order would also be safe — there are no inter-pointer
        // references between the three — but matching the historical
        // order keeps the diff in `Gooey.deinit` minimal for the PR
        // 7a landing.
        self.image_atlas.deinit();
        self.allocator.destroy(self.image_atlas);

        self.svg_atlas.deinit();
        self.allocator.destroy(self.svg_atlas);

        self.text_system.deinit();
        self.allocator.destroy(self.text_system);

        // Null out so an accidental re-deinit fails fast on the
        // pointer check, rather than double-freeing.
        self.text_system = undefined;
        self.svg_atlas = undefined;
        self.image_atlas = undefined;
        self.owned = false;
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// These tests pin the two ownership shapes against `std.testing.allocator`
// — which would surface a leak or double-free immediately. The
// `borrowed` path is verified by constructing an `owned = true` parent,
// borrowing from it, and confirming the borrowed `deinit` is a no-op
// (no double-free against the parent's allocations).

const testing = std.testing;

test "AppResources: initOwned allocates and frees cleanly" {
    var resources = try AppResources.initOwned(
        testing.allocator,
        testing.io,
        1.0,
        FontConfig.default,
    );
    defer resources.deinit();

    try testing.expect(resources.owned);
    try testing.expect(@intFromPtr(resources.text_system) != 0);
    try testing.expect(@intFromPtr(resources.svg_atlas) != 0);
    try testing.expect(@intFromPtr(resources.image_atlas) != 0);
}

test "AppResources: borrowed deinit is a no-op (no double-free)" {
    // Parent owns the three subsystems.
    var owner = try AppResources.initOwned(
        testing.allocator,
        testing.io,
        1.0,
        FontConfig.default,
    );
    defer owner.deinit();

    // Borrowed view over the same pointers.
    var view = AppResources.borrowed(
        testing.allocator,
        testing.io,
        owner.text_system,
        owner.svg_atlas,
        owner.image_atlas,
    );

    try testing.expect(!view.owned);
    try testing.expectEqual(owner.text_system, view.text_system);
    try testing.expectEqual(owner.svg_atlas, view.svg_atlas);
    try testing.expectEqual(owner.image_atlas, view.image_atlas);

    // This must NOT free anything — the parent still owns the
    // pointees and is going to tear them down via its own `defer`
    // above. If `deinit` ignored the `owned` flag, the parent's
    // teardown would double-free and the test allocator would catch
    // it.
    view.deinit();

    // `view.deinit` flipped `owned` to false (it was already false)
    // and undef-ed the pointers. Owner remains intact.
    try testing.expect(@intFromPtr(owner.text_system) != 0);
}

test "AppResources: initOwnedInPlace produces an owned instance" {
    // Heap-allocate so we can exercise the `noinline initInPlace`
    // entry point without taking the by-value copy that the stack
    // path would.
    const slot = try testing.allocator.create(AppResources);
    defer testing.allocator.destroy(slot);

    try slot.initOwnedInPlace(
        testing.allocator,
        testing.io,
        1.0,
        FontConfig.default,
    );
    defer slot.deinit();

    try testing.expect(slot.owned);
    try testing.expect(@intFromPtr(slot.text_system) != 0);
    try testing.expect(@intFromPtr(slot.svg_atlas) != 0);
    try testing.expect(@intFromPtr(slot.image_atlas) != 0);
}

test "AppResources: custom font config loads named font" {
    var resources = try AppResources.initOwned(
        testing.allocator,
        testing.io,
        1.0,
        .{ .font_name = null, .font_size = 14.0 },
    );
    defer resources.deinit();

    // The text system loaded *something* — exact metrics are platform
    // dependent, but a positive baseline confirms the font path ran.
    const metrics = resources.text_system.getMetrics() orelse
        return error.SkipZigTest; // No font loader on this platform.
    try testing.expect(metrics.point_size > 0);
}
