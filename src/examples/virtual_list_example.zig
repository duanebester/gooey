//! Virtual list on the 0.4.0 core: 1,000 chat messages of five heights in a
//! `List` that builds only the messages in view.
//!
//! Each message's height follows from its type, so the list sums them
//! without measuring; `MessageRow.count_max` bounds that sum. 0.3.1's Top,
//! Bottom, Jump, Prev, and Next buttons and its visible-range and
//! scroll-percent readout move the scroll offset or read it, which waits on
//! the List `scroll_to` decision, so the port leaves them out; selection
//! went with them, since only those buttons selected a message.
//!
//! Run with: zig build run-virtual-list

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const List = components.List;

const assert = std.debug.assert;

pub const message_count: u32 = 1000;

const MessageType = enum {
    text_short,
    text_medium,
    text_long,
    image,
    system,
};

pub const Message = struct {
    kind: MessageType,
    sender: []const u8,
    content: []const u8,

    pub fn height(self: *const Message) f32 {
        return switch (self.kind) {
            .text_short => 48,
            .text_medium => 72,
            .text_long => 120,
            .image => 180,
            .system => 32,
        };
    }
};

/// Built at compile time, so no message is allocated or initialized at run
/// time.
pub const messages: [message_count]Message = generateMessages();

fn generateMessages() [message_count]Message {
    @setEvalBranchQuota(20_000);
    const senders = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve" };
    var result: [message_count]Message = undefined;
    for (&result, 0..) |*message, index| {
        const kind: MessageType = switch (index % 10) {
            0, 1, 2, 7, 8 => .text_short,
            3, 4 => .text_medium,
            5 => .text_long,
            6 => .image,
            9 => .system,
            else => unreachable,
        };
        message.* = .{
            .kind = kind,
            .sender = senders[index % senders.len],
            .content = switch (kind) {
                .text_short => "Hey, how's it going?",
                .text_medium => "I was thinking we should meet up this weekend to " ++
                    "discuss the project. What do you think?",
                .text_long => "Here's a longer message with more content. Sometimes " ++
                    "messages can be quite lengthy when people want to explain something " ++
                    "in detail or share a story with others.",
                .image => "[Image: photo.jpg]",
                .system => "User joined the chat",
            },
        };
    }
    return result;
}

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "VirtualList Example - Variable Height Items",
    .width = 800,
    .height = 600,
    .limits = .standard,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
        .padding = .all(16),
        .gap = 12,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 }, .gap = 8 } }, .{
            ui.text("Virtual List Demo", .{ .size = 18, .weight = .bold, .color = .text }),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            ui.text("Variable-height items - each height from its message type", .{
                .size = 12,
                .color = .muted,
            }),
        }),
        ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .symmetric(12, 8),
            .background = .surface,
            .corner_radius = .all(4),
        } }, .{
            ui.text(std.fmt.comptimePrint("{d} messages", .{message_count}), .{
                .size = 12,
                .color = .muted,
            }),
        }),
        List(MessageRow){
            .key = "chat-list",
            .count = message_count,
            .gap = 8,
            .style = .{ .background = .surface, .corner_radius = .all(8), .padding = .all(8) },
        },
    }));
}

// 0.3.1's bubble colours, as 0-1 channels (0.3.1 passed 0-255 values and
// failed its colour assertion on the first frame).
const sent_color = Color.rgb(0, 122.0 / 255.0, 1);
const received_color = Color.rgb(229.0 / 255.0, 229.0 / 255.0, 234.0 / 255.0);

pub const MessageRow = struct {
    index: u32,

    pub const count_max: u32 = message_count;

    pub fn height(_: *Cx, index: u32) f32 {
        assert(index < message_count);
        return messages[index].height();
    }

    pub fn render(self: MessageRow, cx: *Cx) void {
        assert(self.index < message_count);
        const message = &messages[self.index];
        // "Alice" is "me": her messages are blue with white text.
        const is_me = std.mem.eql(u8, message.sender, "Alice");
        const text_color: ui.ColorToken = .{ .rgba = if (is_me) Color.white else Color.black };
        switch (message.kind) {
            .system => cx.render(ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .alignment = .center,
            } }, .{ui.text(message.content, .{ .size = 11, .color = .muted })})),
            .image => cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .background = .{ .rgba = if (is_me) sent_color else received_color },
                .padding = .all(12),
                .corner_radius = .all(16),
                .alignment = .center,
            } }, .{ui.text(message.content, .{ .size = 12, .color = text_color })})),
            else => {
                var style = bubble;
                style.background = .{ .rgba = if (is_me) sent_color else received_color };
                const content = ui.text(message.content, .{ .size = 14, .color = text_color });
                if (is_me) {
                    cx.render(ui.box(.{ .style = style }, .{content}));
                } else {
                    cx.render(ui.box(.{ .style = style }, .{
                        ui.text(message.sender, .{
                            .size = 11,
                            .weight = .bold,
                            .color = text_color,
                        }),
                        content,
                    }));
                }
            },
        }
    }

    const bubble: ui.Style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .symmetric(12, 8),
        .corner_radius = .all(16),
        .gap = 2,
    };
};
