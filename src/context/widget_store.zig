//! WidgetStore - Simple retained storage for stateful widgets
//!
//! Now includes animation state management.

const std = @import("std");
const TextInput = @import("../widgets/text_input_state.zig").TextInput;
const Bounds = @import("../widgets/text_input_state.zig").Bounds;
const ScrollContainer = @import("../widgets/scroll_container.zig").ScrollContainer;
const TextArea = @import("../widgets/text_area_state.zig").TextArea;
const TextAreaBounds = @import("../widgets/text_area_state.zig").Bounds;
const CodeEditorState = @import("../widgets/code_editor_state.zig").CodeEditorState;
const CodeEditorBounds = @import("../widgets/code_editor_state.zig").Bounds;
const animation = @import("../animation/animation.zig");
const AnimationState = animation.AnimationState;
const AnimationConfig = animation.AnimationConfig;
const AnimationHandle = animation.AnimationHandle;
const AnimationId = animation.AnimationId;

pub const WidgetStore = struct {
    allocator: std.mem.Allocator,
    text_inputs: std.StringHashMap(*TextInput),
    text_areas: std.StringHashMap(*TextArea),
    code_editors: std.StringHashMap(*CodeEditorState),
    scroll_containers: std.StringHashMap(*ScrollContainer),
    accessed_this_frame: std.StringHashMap(void),

    // u32-keyed animation storage
    animations: std.AutoArrayHashMap(u32, AnimationState),
    active_animation_count: u32 = 0,

    default_text_input_bounds: Bounds = .{ .x = 0, .y = 0, .width = 200, .height = 36 },
    default_text_area_bounds: TextAreaBounds = .{ .x = 0, .y = 0, .width = 300, .height = 150 },
    default_code_editor_bounds: CodeEditorBounds = .{ .x = 0, .y = 0, .width = 400, .height = 300 },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .text_inputs = std.StringHashMap(*TextInput).init(allocator),
            .text_areas = std.StringHashMap(*TextArea).init(allocator),
            .code_editors = std.StringHashMap(*CodeEditorState).init(allocator),
            .scroll_containers = std.StringHashMap(*ScrollContainer).init(allocator),
            .accessed_this_frame = std.StringHashMap(void).init(allocator),
            .animations = std.AutoArrayHashMap(u32, AnimationState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up TextInputs
        var it = self.text_inputs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.text_inputs.deinit();

        // Clean up TextAreas
        var ta_it = self.text_areas.iterator();
        while (ta_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.text_areas.deinit();

        // Clean up CodeEditors
        var ce_it = self.code_editors.iterator();
        while (ce_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.code_editors.deinit();

        // Clean up ScrollContainers
        var sc_it = self.scroll_containers.iterator();
        while (sc_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.scroll_containers.deinit();

        // Clean up animation keys
        self.animations.deinit();

        self.accessed_this_frame.deinit();
    }

    // =========================================================================
    // Animation Methods (OPTIMIZED with u32 keys)
    // =========================================================================

    /// Get or create animation by hashed ID (no string allocation)
    pub fn animateById(self: *Self, anim_id: u32, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        if (!gop.found_existing) {
            gop.value_ptr.* = AnimationState.init(config);
        }

        const handle = animation.calculateProgress(gop.value_ptr);
        if (handle.running) {
            self.active_animation_count += 1;
        }
        return handle;
    }

    /// String-based API (hashes at call site)
    pub fn animate(self: *Self, id: []const u8, config: AnimationConfig) AnimationHandle {
        return self.animateById(animation.hashString(id), config);
    }

    /// Restart animation by hashed ID
    /// Restart animation by hashed ID
    pub fn restartAnimationById(self: *Self, anim_id: u32, config: AnimationConfig) AnimationHandle {
        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        // Always reset the animation state (whether existing or new)
        gop.value_ptr.* = AnimationState.init(config);

        // If it was existing, preserve generation continuity
        if (gop.found_existing) {
            gop.value_ptr.generation +%= 1;
        }

        self.active_animation_count += 1;
        return animation.calculateProgress(gop.value_ptr);
    }

    /// String-based restart API
    pub fn restartAnimation(self: *Self, id: []const u8, config: AnimationConfig) AnimationHandle {
        return self.restartAnimationById(animation.hashString(id), config);
    }

    /// OPTIMIZED animateOn - single HashMap lookup!
    /// Trigger hash is now stored IN the AnimationState
    pub fn animateOnById(self: *Self, anim_id: u32, trigger_hash: u64, config: AnimationConfig) AnimationHandle {
        const platform_time = @import("../platform/mod.zig");

        const gop = self.animations.getOrPut(anim_id) catch {
            return AnimationHandle.complete;
        };

        if (gop.found_existing) {
            // Check if trigger changed
            if (gop.value_ptr.trigger_hash != trigger_hash) {
                // Trigger changed - restart animation and update hash
                gop.value_ptr.start_time = platform_time.time.milliTimestamp();
                gop.value_ptr.duration_ms = config.duration_ms;
                gop.value_ptr.delay_ms = config.delay_ms;
                gop.value_ptr.easing = config.easing;
                gop.value_ptr.mode = config.mode;
                gop.value_ptr.running = true;
                gop.value_ptr.forward = true;
                gop.value_ptr.generation +%= 1;
                gop.value_ptr.trigger_hash = trigger_hash;
            }
        } else {
            // New animation - start in settled/idle state (not running).
            // This prevents components like modals from briefly appearing
            // on the first frame before any state change has occurred.
            gop.value_ptr.* = AnimationState.initSettled(config, trigger_hash);
        }

        const handle = animation.calculateProgress(gop.value_ptr);
        if (handle.running) {
            self.active_animation_count += 1;
        }
        return handle;
    }

    /// String-based animateOn API
    pub fn animateOn(self: *Self, id: []const u8, trigger_hash: u64, config: AnimationConfig) AnimationHandle {
        return self.animateOnById(animation.hashString(id), trigger_hash, config);
    }

    pub fn isAnimatingById(self: *Self, anim_id: u32) bool {
        if (self.animations.getPtr(anim_id)) |state| {
            return state.running;
        }
        return false;
    }

    pub fn isAnimating(self: *Self, id: []const u8) bool {
        return self.isAnimatingById(animation.hashString(id));
    }

    pub fn getAnimationById(self: *Self, anim_id: u32) ?AnimationHandle {
        if (self.animations.getPtr(anim_id)) |state| {
            const handle = animation.calculateProgress(state);
            if (handle.running) {
                self.active_animation_count += 1;
            }
            return handle;
        }
        return null;
    }

    pub fn getAnimation(self: *Self, id: []const u8) ?AnimationHandle {
        return self.getAnimationById(animation.hashString(id));
    }

    pub fn removeAnimationById(self: *Self, anim_id: u32) void {
        _ = self.animations.swapRemove(anim_id);
    }

    pub fn removeAnimation(self: *Self, id: []const u8) void {
        self.removeAnimationById(animation.hashString(id));
    }

    /// Check if any animations are active this frame
    pub fn hasActiveAnimations(self: *const Self) bool {
        return self.active_animation_count > 0;
    }

    // =========================================================================
    // Frame Lifecycle
    // =========================================================================

    pub fn beginFrame(self: *Self) void {
        self.accessed_this_frame.clearRetainingCapacity();
        self.active_animation_count = 0; // Reset - will be incremented as animations are queried
    }

    pub fn endFrame(_: *Self) void {}

    // =========================================================================
    // TextInput (existing code)
    // =========================================================================

    pub fn textInput(self: *Self, id: []const u8) ?*TextInput {
        if (self.text_inputs.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const input = self.allocator.create(TextInput) catch return null;
        errdefer self.allocator.destroy(input);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(input);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        input.* = TextInput.initWithId(self.allocator, self.default_text_input_bounds, owned_key);

        self.text_inputs.put(owned_key, input) catch {
            input.deinit();
            self.allocator.destroy(input);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return input;
    }

    pub fn textInputOrPanic(self: *Self, id: []const u8) *TextInput {
        return self.textInput(id) orelse @panic("Failed to allocate TextInput");
    }

    // =========================================================================
    // TextArea
    // =========================================================================

    pub fn textArea(self: *Self, id: []const u8) ?*TextArea {
        if (self.text_areas.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const ta = self.allocator.create(TextArea) catch return null;
        errdefer self.allocator.destroy(ta);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(ta);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        ta.* = TextArea.initWithId(self.allocator, self.default_text_area_bounds, owned_key);

        self.text_areas.put(owned_key, ta) catch {
            ta.deinit();
            self.allocator.destroy(ta);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return ta;
    }

    pub fn textAreaOrPanic(self: *Self, id: []const u8) *TextArea {
        return self.textArea(id) orelse @panic("Failed to allocate TextArea");
    }

    pub fn getTextArea(self: *Self, id: []const u8) ?*TextArea {
        return self.text_areas.get(id);
    }

    pub fn removeTextArea(self: *Self, id: []const u8) void {
        if (self.text_areas.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getFocusedTextArea(self: *Self) ?*TextArea {
        var it = self.text_areas.valueIterator();
        while (it.next()) |ta| {
            if (ta.*.isFocused()) {
                return ta.*;
            }
        }
        return null;
    }

    // =========================================================================
    // CodeEditor
    // =========================================================================

    pub fn codeEditor(self: *Self, id: []const u8) ?*CodeEditorState {
        if (self.code_editors.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const ce = self.allocator.create(CodeEditorState) catch return null;
        errdefer self.allocator.destroy(ce);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(ce);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        ce.* = CodeEditorState.initWithId(self.allocator, self.default_code_editor_bounds, owned_key);

        self.code_editors.put(owned_key, ce) catch {
            ce.deinit();
            self.allocator.destroy(ce);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return ce;
    }

    pub fn codeEditorOrPanic(self: *Self, id: []const u8) *CodeEditorState {
        return self.codeEditor(id) orelse @panic("Failed to allocate CodeEditorState");
    }

    pub fn getCodeEditor(self: *Self, id: []const u8) ?*CodeEditorState {
        return self.code_editors.get(id);
    }

    pub fn removeCodeEditor(self: *Self, id: []const u8) void {
        if (self.code_editors.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getFocusedCodeEditor(self: *Self) ?*CodeEditorState {
        var it = self.code_editors.valueIterator();
        while (it.next()) |ce| {
            if (ce.*.isFocused()) {
                return ce.*;
            }
        }
        return null;
    }

    // =========================================================================
    // ScrollContainer (existing)
    // =========================================================================

    pub fn scrollContainer(self: *Self, id: []const u8) ?*ScrollContainer {
        if (self.scroll_containers.getEntry(id)) |entry| {
            const stable_key = entry.key_ptr.*;
            if (!self.accessed_this_frame.contains(stable_key)) {
                self.accessed_this_frame.put(stable_key, {}) catch {};
            }
            return entry.value_ptr.*;
        }

        const sc = self.allocator.create(ScrollContainer) catch return null;
        errdefer self.allocator.destroy(sc);

        const owned_key = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(sc);
            return null;
        };
        errdefer self.allocator.free(owned_key);

        sc.* = ScrollContainer.init(self.allocator, owned_key);

        self.scroll_containers.put(owned_key, sc) catch {
            sc.deinit();
            self.allocator.destroy(sc);
            self.allocator.free(owned_key);
            return null;
        };

        self.accessed_this_frame.put(owned_key, {}) catch {};
        return sc;
    }

    pub fn getScrollContainer(self: *Self, id: []const u8) ?*ScrollContainer {
        return self.scroll_containers.get(id);
    }

    // =========================================================================
    // TextInput helpers (existing)
    // =========================================================================

    pub fn removeTextInput(self: *Self, id: []const u8) void {
        if (self.text_inputs.fetchRemove(id)) |kv| {
            _ = self.accessed_this_frame.remove(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    pub fn getTextInput(self: *Self, id: []const u8) ?*TextInput {
        return self.text_inputs.get(id);
    }

    pub fn hasTextInput(self: *Self, id: []const u8) bool {
        return self.text_inputs.contains(id);
    }

    pub fn textInputCount(self: *Self) usize {
        return self.text_inputs.count();
    }

    pub fn getFocusedTextInput(self: *Self) ?*TextInput {
        var it = self.text_inputs.valueIterator();
        while (it.next()) |input| {
            if (input.*.isFocused()) {
                return input.*;
            }
        }
        return null;
    }

    pub fn focusTextInput(self: *Self, id: []const u8) void {
        if (self.getFocusedTextInput()) |current| {
            current.blur();
        }
        if (self.text_inputs.get(id)) |input| {
            input.focus();
        }
    }

    pub fn blurAll(self: *Self) void {
        var it = self.text_inputs.valueIterator();
        while (it.next()) |input| {
            input.*.blur();
        }
        var ta_it = self.text_areas.valueIterator();
        while (ta_it.next()) |ta| {
            ta.*.blur();
        }
        var ce_it = self.code_editors.valueIterator();
        while (ce_it.next()) |ce| {
            ce.*.blur();
        }
    }
};
