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
};

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

pub const State = struct {
    pub fn top(_: *State, list: gooey.ElementId, effects: *gooey.Effects) void {
        effects.scrollTo(list, .start);
    }

    pub fn bottom(_: *State, list: gooey.ElementId, effects: *gooey.Effects) void {
        effects.scrollTo(list, .end);
    }

    pub fn jump(_: *State, list: gooey.ElementId, effects: *gooey.Effects) void {
        List(MessageRow).scrollTo(effects, list, 500, .center);
    }
};

pub const App = gooey.App(State, render, .{
    .title = "VirtualList Example - Variable Height Items",
    .width = 800,
    .height = 600,
    .limits = .standard,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    const list = cx.id(.{ .name = "page" }).child(.{ .name = "chat-list" });
    cx.render(ui.box(.{ .key = .{ .name = "page" }, .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
        .padding = .all(16),
        .gap = 12,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 }, .gap = 8 } }, .{
            ui.text("Virtual List Demo", .{ .size = 18, .weight = .bold, .color = .text }),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            ui.text("Variable-height items - each measured from its text", .{
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
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            components.Button{ .label = "Top", .on_click = cx.on(State.top, .{ .arg = list }) },
            components.Button{
                .label = "Bottom",
                .on_click = cx.on(State.bottom, .{ .arg = list }),
            },
            components.Button{
                .label = "Jump to 500",
                .on_click = cx.on(State.jump, .{ .arg = list }),
            },
        }),
        List(MessageRow){
            .key = "chat-list",
            .count = message_count,
            .gap = 8,
            .style = .{ .background = .surface, .corner_radius = .all(8), .padding = .all(8) },
        },
    }));
}

const sent_color = Color.rgb(0, 122.0 / 255.0, 1);
const received_color = Color.rgb(229.0 / 255.0, 229.0 / 255.0, 234.0 / 255.0);

pub const MessageRow = struct {
    index: u32,

    pub const count_max: u32 = message_count;

    pub fn height(cx: *Cx, index: u32, width: f32) f32 {
        assert(index < message_count);
        assert(width >= 0);
        const message = &messages[index];
        switch (message.kind) {
            .image => return image_height,
            .system => {
                const line = cx.measureText(message.content, system_text, width);
                return line.height + system_padding_y * 2;
            },
            else => {
                const text_width = @max(0, width - bubble_padding_x * 2);
                const body = cx.measureText(message.content, body_text, text_width);
                var row_height = body.height + bubble_padding_y * 2;
                if (!isMe(message)) {
                    const sender = cx.measureText(message.sender, sender_text, text_width);
                    row_height += sender.height + bubble_gap;
                }
                assert(row_height > 0);
                return row_height;
            },
        }
    }

    fn isMe(message: *const Message) bool {
        return std.mem.eql(u8, message.sender, "Alice");
    }

    pub fn render(self: MessageRow, cx: *Cx) void {
        assert(self.index < message_count);
        const message = &messages[self.index];
        const is_me = isMe(message);
        const text_color: ui.ColorToken = .{ .rgba = if (is_me) Color.white else Color.black };
        switch (message.kind) {
            .system => cx.render(ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .alignment = .center,
            } }, .{ui.text(message.content, system_text)})),
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
                var content_style = body_text;
                content_style.color = text_color;
                const content = ui.text(message.content, content_style);
                if (is_me) {
                    cx.render(ui.box(.{ .style = style }, .{content}));
                } else {
                    cx.render(ui.box(.{ .style = style }, .{
                        ui.text(message.sender, sender_style: {
                            var style_sender = sender_text;
                            style_sender.color = text_color;
                            break :sender_style style_sender;
                        }),
                        content,
                    }));
                }
            },
        }
    }

    const bubble_padding_x: f32 = 12;
    const bubble_padding_y: f32 = 8;
    const bubble_gap: f32 = 2;
    const system_padding_y: f32 = 8;
    const image_height: f32 = 180;

    const body_text: ui.Text = .{ .size = 14, .wrap = .words };
    const sender_text: ui.Text = .{ .size = 11, .weight = .bold };
    const system_text: ui.Text = .{ .size = 11, .color = .muted };

    const bubble: ui.Style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .symmetric(bubble_padding_x, bubble_padding_y),
        .corner_radius = .all(16),
        .gap = bubble_gap,
    };
};
