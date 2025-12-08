const std = @import("std");
const gooey = @import("gooey");

const ViewContext = gooey.ViewContext;
const RenderOutput = gooey.RenderOutput;
const Context = gooey.Context;
const Entity = gooey.Entity;

const CounterView = struct {
    count: i32,
    label: []const u8,

    // This makes CounterView "Renderable"
    pub fn render(self: *CounterView, _: *ViewContext(CounterView)) RenderOutput {
        std.debug.print("Rendering CounterView: {s} = {}\n", .{ self.label, self.count });

        // In the future, this would build an element tree
        // For now, we just signal that rendering happened
        return RenderOutput.withContent();
    }

    pub fn increment(self: *CounterView, cx: *ViewContext(CounterView)) void {
        self.count += 1;
        cx.notify(); // This marks the entity dirty -> triggers re-render!
    }

    pub fn decrement(self: *CounterView, cx: *ViewContext(CounterView)) void {
        self.count -= 1;
        cx.notify();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize app
    var app = try gooey.App.init(allocator);
    defer app.deinit();

    // Create window
    var window = try app.createWindow(.{
        .title = "Reactive Counter Demo",
        .width = 400,
        .height = 300,
    });
    defer window.deinit();

    // Connect window to app for reactive rendering
    app.connectWindow(window);

    // Create our reactive view entity
    var counter = app.new(CounterView, struct {
        fn build(_: *Context(CounterView)) CounterView {
            return .{
                .count = 0,
                .label = "Clicks",
            };
        }
    }.build);
    defer counter.release();

    // Set as root view - now it will auto-render when dirty!
    window.setRootView(CounterView, counter);

    // Set up render callback to convert RenderOutput to Scene
    window.setRenderCallback(struct {
        fn onRender(win: *gooey.Window, output: RenderOutput) void {
            if (output.has_content) {
                // Here you would build your scene based on the render output
                // For now, just request a display refresh
                win.requestRender();
            }
        }
    }.onRender);

    // Store references for input handler
    const State = struct {
        var app_ref: *gooey.App = undefined;
        var counter_ref: Entity(CounterView) = undefined;
    };
    State.app_ref = &app;
    State.counter_ref = counter;

    // Set up input handling
    window.setInputCallback(struct {
        fn onInput(_: *gooey.Window, event: gooey.InputEvent) bool {
            if (event == .key_down) {
                const k = event.key_down;
                if (k.key == .up) {
                    // Increment via entity system
                    State.app_ref.update(CounterView, State.counter_ref, struct {
                        fn update(view: *CounterView, cx: *Context(CounterView)) void {
                            _ = cx;
                            view.count += 1;
                            // Note: We need ViewContext here for notify()
                            // For now, manually mark dirty:
                        }
                    }.update);
                    State.app_ref.markDirty(State.counter_ref.entityId());
                    return true;
                }
                if (k.key == .down) {
                    State.app_ref.update(CounterView, State.counter_ref, struct {
                        fn update(view: *CounterView, _: *Context(CounterView)) void {
                            view.count -= 1;
                        }
                    }.update);
                    State.app_ref.markDirty(State.counter_ref.entityId());
                    return true;
                }
            }
            return false;
        }
    }.onInput);

    std.debug.print("Press UP/DOWN arrows to change counter\n", .{});

    // Run the app - DisplayLink will call render when dirty
    app.run(null);
}
