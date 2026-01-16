//! VirtualList Example - Virtualized List with Variable-Height Items
//!
//! This example demonstrates how to use VirtualList for efficient rendering
//! of large datasets where items have different heights. Only visible items
//! are rendered, and heights are cached after first render.
//!
//! Run with: zig build run-virtual-list

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;

const Cx = gooey.Cx;
const Color = gooey.Color;
const VirtualListState = gooey.VirtualListState;
const ScrollStrategy = gooey.ScrollStrategy;
const Button = gooey.Button;

const ui = gooey.ui;

// =============================================================================
// Constants
// =============================================================================

const MESSAGE_COUNT: u32 = 1000;
const DEFAULT_MESSAGE_HEIGHT: f32 = 48.0;

// =============================================================================
// Message Data
// =============================================================================

const MessageType = enum {
    text_short,
    text_medium,
    text_long,
    image,
    system,
};

const Message = struct {
    msg_type: MessageType,
    sender: []const u8,
    content: []const u8,
    timestamp: []const u8,

    /// Returns the height for this message type
    pub fn height(self: Message) f32 {
        return switch (self.msg_type) {
            .text_short => 48.0,
            .text_medium => 72.0,
            .text_long => 120.0,
            .image => 180.0,
            .system => 32.0,
        };
    }
};

// Pre-generated message templates (avoids dynamic allocation)
const MESSAGES = generateMessages();

fn generateMessages() [MESSAGE_COUNT]Message {
    @setEvalBranchQuota(20000);
    var messages: [MESSAGE_COUNT]Message = undefined;

    const senders = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve" };
    const timestamps = [_][]const u8{ "9:00 AM", "9:15 AM", "9:30 AM", "10:00 AM", "10:30 AM", "11:00 AM", "11:30 AM", "12:00 PM" };

    for (0..MESSAGE_COUNT) |i| {
        const idx: u32 = @intCast(i);
        const msg_type: MessageType = switch (idx % 10) {
            0, 1, 2 => .text_short,
            3, 4 => .text_medium,
            5 => .text_long,
            6 => .image,
            7, 8 => .text_short,
            9 => .system,
            else => unreachable,
        };

        messages[i] = .{
            .msg_type = msg_type,
            .sender = senders[idx % senders.len],
            .content = switch (msg_type) {
                .text_short => "Hey, how's it going?",
                .text_medium => "I was thinking we should meet up this weekend to discuss the project. What do you think?",
                .text_long => "Here's a longer message with more content. Sometimes messages can be quite lengthy when people want to explain something in detail or share a story with others.",
                .image => "[Image: photo.jpg]",
                .system => "User joined the chat",
            },
            .timestamp = timestamps[idx % timestamps.len],
        };
    }

    return messages;
}

// =============================================================================
// Application State
// =============================================================================

const State = struct {
    /// Retained state for the virtual list (variable heights)
    list_state: VirtualListState = VirtualListState.init(MESSAGE_COUNT, DEFAULT_MESSAGE_HEIGHT),

    /// Currently selected message index
    selected_index: ?u32 = null,

    // =========================================================================
    // Event Handlers
    // =========================================================================

    pub fn scrollToTop(self: *State) void {
        self.list_state.scrollToTop();
    }

    pub fn scrollToBottom(self: *State) void {
        self.list_state.scrollToBottom();
    }

    pub fn jumpToMiddle(self: *State) void {
        self.selected_index = 500;
        self.list_state.scrollToItem(500, .center);
    }

    pub fn selectNext(self: *State) void {
        const current = self.selected_index orelse 0;
        if (current < self.list_state.item_count - 1) {
            self.selected_index = current + 1;
            self.list_state.scrollToItem(current + 1, .nearest);
        }
    }

    pub fn selectPrevious(self: *State) void {
        if (self.selected_index) |idx| {
            if (idx > 0) {
                self.selected_index = idx - 1;
                self.list_state.scrollToItem(idx - 1, .nearest);
            }
        } else {
            self.selected_index = 0;
        }
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = State{};

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const theme = cx.builder().theme();

        cx.render(ui.hstack(.{ .gap = 8 }, .{
            ui.text("Virtual List Demo", .{
                .size = 18,
                .weight = .bold,
                .color = theme.text,
            }),
            ui.spacer(),
            ui.text("Variable-height items - heights cached after render", .{
                .size = 12,
                .color = theme.muted,
            }),
        }));
    }
};

const StatsBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        const b = cx.builder();
        const theme = b.theme();
        const range = s.list_state.visibleRange();

        // Format stats
        var buf: [256]u8 = undefined;
        const stats = std.fmt.bufPrint(&buf, "Showing items {d}-{d} of {d} | Scroll: {d:.0}%", .{
            range.start,
            range.end,
            s.list_state.item_count,
            s.list_state.scrollPercent() * 100,
        }) catch "Stats error";

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = theme.surface,
            .corner_radius = 4,
        }, .{
            ui.text(stats, .{ .size = 12, .color = theme.muted }),
        }));
    }
};

const ChatList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        const theme = cx.theme();

        // Use cx.virtualList() - render callback receives *Cx and returns height
        cx.virtualList(
            "chat-list",
            &s.list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .background = theme.surface,
                .corner_radius = 8,
                .padding = .{ .all = 8 },
                .gap = 8,
            },
            renderMessage,
        );
    }

    /// Render a single message - returns the actual height
    fn renderMessage(index: u32, cx: *Cx) f32 {
        const s = cx.stateConst(State);
        const theme = cx.theme();
        const msg = &MESSAGES[index];

        const is_selected = if (s.selected_index) |sel| sel == index else false;
        const item_height = msg.height();

        // "Alice" is "me" - messages go on the right
        const is_me = std.mem.eql(u8, msg.sender, "Alice");

        // Chat bubble colors
        const bubble_color = if (is_selected)
            theme.primary
        else if (msg.msg_type == .system)
            Color.rgba(128, 128, 128, 0.1)
        else if (is_me)
            Color.rgba(0, 122, 255, 1.0) // Blue for sent messages
        else
            Color.rgba(229, 229, 234, 1.0); // Light gray for received

        const text_color = if (is_selected or is_me) Color.white else Color.rgba(0, 0, 0, 1.0);
        const muted_color = if (is_selected) Color.rgba(255, 255, 255, 0.7) else theme.muted;

        // Render based on message type
        switch (msg.msg_type) {
            .system => {
                // System messages - centered, smaller
                cx.render(ui.box(.{
                    .fill_width = true,
                    .height = item_height,
                    .direction = .row,
                    .alignment = .{ .main = .center, .cross = .center },
                }, .{
                    ui.text(msg.content, .{ .size = 11, .color = muted_color }),
                }));
            },
            .image => {
                // Image messages - single box with fixed height
                cx.render(ui.box(.{
                    .fill_width = true,
                    .height = item_height,
                    .background = bubble_color,
                    .padding = .{ .all = 12 },
                    .corner_radius = 16,
                    .alignment = .{ .main = .center, .cross = .center },
                }, .{
                    ui.text(msg.content, .{ .size = 12, .color = text_color }),
                }));
            },
            else => {
                // Regular text messages - chat bubble style
                cx.render(ui.box(.{
                    .fill_width = true,
                    .height = item_height,
                    .background = bubble_color,
                    .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
                    .corner_radius = 16,
                    .direction = .column,
                    .gap = 2,
                }, .{
                    // Sender name (only show for others)
                    ui.when(!is_me, .{
                        ui.text(msg.sender, .{ .size = 11, .weight = .bold, .color = text_color }),
                    }),
                    // Message content
                    ui.text(msg.content, .{ .size = 14, .color = text_color }),
                }));
            },
        }

        // Return the actual height for caching
        return item_height;
    }
};

const Controls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 8 }, .{
            Button{
                .label = "Top",
                .on_click_handler = cx.update(State, State.scrollToTop),
            },
            Button{
                .label = "Bottom",
                .on_click_handler = cx.update(State, State.scrollToBottom),
            },
            Button{
                .label = "Jump to #500",
                .on_click_handler = cx.update(State, State.jumpToMiddle),
            },
            ui.spacer(),
            Button{
                .label = "↑ Prev",
                .on_click_handler = cx.update(State, State.selectPrevious),
            },
            Button{
                .label = "↓ Next",
                .on_click_handler = cx.update(State, State.selectNext),
            },
        }));
    }
};

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const theme = cx.builder().theme();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = theme.bg,
        .padding = .{ .all = 16 },
        .direction = .column,
        .gap = 12,
    }, .{
        Header{},
        StatsBar{},
        ChatList{},
        Controls{},
    }));
}

// =============================================================================
// Entry Point
// =============================================================================

const App = gooey.App(State, &state, render, .{
    .title = "VirtualList Example - Variable Height Items",
    .width = 800,
    .height = 600,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
