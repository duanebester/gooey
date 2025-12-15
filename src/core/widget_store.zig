//! WidgetStore - Simple retained storage for stateful widgets

const std = @import("std");
const TextInput = @import("../widgets/text_input.zig").TextInput;
const Bounds = @import("../widgets/text_input.zig").Bounds;
const ScrollContainer = @import("../widgets/scroll_container.zig").ScrollContainer;
const TextArea = @import("../widgets/text_area.zig").TextArea;
const TextAreaBounds = @import("../widgets/text_area.zig").Bounds;

pub const WidgetStore = struct {
    allocator: std.mem.Allocator,
    text_inputs: std.StringHashMap(*TextInput),
    text_areas: std.StringHashMap(*TextArea),
    scroll_containers: std.StringHashMap(*ScrollContainer),
    accessed_this_frame: std.StringHashMap(void),
    default_text_input_bounds: Bounds = .{ .x = 0, .y = 0, .width = 200, .height = 36 },
    default_text_area_bounds: TextAreaBounds = .{ .x = 0, .y = 0, .width = 300, .height = 150 },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .text_inputs = std.StringHashMap(*TextInput).init(allocator),
            .text_areas = std.StringHashMap(*TextArea).init(allocator),
            .scroll_containers = std.StringHashMap(*ScrollContainer).init(allocator),
            .accessed_this_frame = std.StringHashMap(void).init(allocator),
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

        // Clean up ScrollContainers
        var sc_it = self.scroll_containers.iterator();
        while (sc_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.scroll_containers.deinit();

        self.accessed_this_frame.deinit();
    }

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
            sc.deinit();
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
    // Frame Lifecycle
    // =========================================================================

    pub fn beginFrame(self: *Self) void {
        self.accessed_this_frame.clearRetainingCapacity();
    }

    pub fn endFrame(_: *Self) void {}

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
    }
};
