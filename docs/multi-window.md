Multi-Window Implementation Plan

## Current State (Completed ✅)

- [x] Centered window option
- [x] Min/max size constraints
- [x] Close callback (`on_close`)
- [x] Resize callback (`on_resize`)
- [x] Cross-platform parity (macOS + Linux)

---

## Phase 1: Remove Static Callback State ✅ COMPLETED

**Goal**: Eliminate the single-window limitation caused by module-level static variables.

**Solution**: Created `WindowContext` struct stored in window's `user_data` pointer.

### Implementation Summary

- **`src/runtime/window_context.zig`**: New per-window context struct
  - Generic over `State` type: `WindowContext(comptime State: type)`
  - Owns `Gooey`, `Builder`, and `Cx` instances
  - Provides static callback functions that retrieve context via `window.getUserData()`
  - Handles render, input, close, and resize callbacks

- **`src/runtime/runner.zig`**: Updated to use `WindowContext`
  - Removed static `CallbackState` struct entirely
  - Creates `WindowContext` on heap, stores in `window.user_data`
  - Clean deallocation via `defer win_ctx.deinit()`

- **`src/runtime/frame.zig`**: Added runtime function pointer variant
  - `renderFrameCxRuntime()` for non-comptime render functions
  - Shared implementation via `renderFrameImpl()`

### Tasks

| Task                                                 | Status | Notes                                        |
| ---------------------------------------------------- | ------ | -------------------------------------------- |
| 1.1 Create `WindowContext` struct                    | ✅     | `src/runtime/window_context.zig`             |
| 1.2 Store `WindowContext*` in `window.user_data`     | ✅     | Via `setupWindow()` method                   |
| 1.3 Update callbacks to retrieve context from window | ✅     | `onRender`, `onInput`, `onClose`, `onResize` |
| 1.4 Remove static `CallbackState`                    | ✅     | Deleted from `runner.zig`                    |
| 1.5 Add tests for single window (no regression)      | ✅     | All examples verified working                |

### Key Design Points

1. **Heap Allocation**: `WindowContext` is allocated on heap via `allocator.create()` to avoid stack size issues (per CLAUDE.md WASM stack budget rules)

2. **Owned Resources**: Each `WindowContext` owns its `Gooey` and `Builder` instances, enabling true per-window isolation

3. **Static Callbacks**: Window callbacks are static functions that retrieve the `WindowContext` from `window.getUserData()`:

   ```gooey/src/runtime/window_context.zig#L176-180
   pub fn onRender(window: *Window) void {
       const self = window.getUserData(Self) orelse return;
       // ... render using self.cx
   }
   ```

4. **Backward Compatible**: `runCx()` API unchanged - existing apps work without modification

---

## Phase 2: Window ID & Registry ✅ COMPLETED

**Goal**: Track windows by ID for cross-window references.

### Implementation Summary

- **`src/platform/window_registry.zig`**: New module with WindowId and WindowRegistry
  - `WindowId`: enum(u32) with `.invalid` sentinel for type-safe window references
  - `WindowRegistry`: HashMap-based registry with O(1) lookup, active window tracking
  - Hard limit of 32 windows (per CLAUDE.md engineering rules)
  - Full test coverage for all operations

- **Window structs updated** (macOS, Linux, Web):
  - Added `window_id: WindowId = .invalid` field to all Window types
  - Added `getWindowId()` method for consistent access
  - Updated `WindowVTable` interface with `getWindowId` for runtime polymorphism

- **Platform structs updated** (MacPlatform, LinuxPlatform, WebPlatform):
  - Added `WindowRegistry` instance to each platform
  - Added `registerWindow()`, `unregisterWindow()`, `getWindow()` methods
  - Added `getActiveWindowId()`, `setActiveWindowId()`, `windowCount()` methods
  - Added `initWithAllocator()` for allocator flexibility

### Tasks

| Task                                        | Status | Notes                                  |
| ------------------------------------------- | ------ | -------------------------------------- |
| 2.1 Define `WindowId` type                  | ✅     | `enum(u32)` with `.invalid` sentinel   |
| 2.2 Add `window_id` field to Window         | ✅     | All platforms: macOS, Linux, Web       |
| 2.3 Create `WindowRegistry` in Platform     | ✅     | `src/platform/window_registry.zig`     |
| 2.4 Add `registerWindow`/`unregisterWindow` | ✅     | Methods on all Platform types          |
| 2.5 Track active/focused window             | ✅     | `active_window: ?WindowId` in registry |
| 2.6 Add `getWindow(id)` method              | ✅     | Plus typed variant `getTyped()`        |

### Key Design Points

1. **Type-Safe IDs**: Using `enum(u32)` instead of raw integers prevents accidental misuse and enables compile-time validation

2. **Platform-Agnostic**: `WindowRegistry` stores `*anyopaque` pointers, decoupling it from specific Window implementations

3. **Hard Limits**: `MAX_WINDOWS = 32` enforced via assertions (per CLAUDE.md: "put a limit on everything")

4. **Automatic Active Tracking**: First registered window becomes active; unregistering active window clears it

5. **VTable Support**: `WindowVTable` interface updated with `getWindowId` for runtime polymorphism

### Design

```/dev/null/window_registry.zig#L1-50
pub const WindowId = enum(u32) {
    invalid = 0,
    _,

    pub fn isValid(self: WindowId) bool {
        return self != .invalid;
    }
};

pub const WindowRegistry = struct {
    allocator: Allocator,
    windows: std.AutoHashMap(WindowId, *Window),
    next_id: u32 = 1,
    active_window: ?WindowId = null,

    const MAX_WINDOWS: u32 = 32; // Hard limit

    pub fn init(allocator: Allocator) WindowRegistry {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(WindowId, *Window).init(allocator),
        };
    }

    pub fn createWindow(self: *WindowRegistry, options: WindowOptions) !WindowId {
        std.debug.assert(self.windows.count() < MAX_WINDOWS); // Limit per engineering rules

        const id: WindowId = @enumFromInt(self.next_id);
        self.next_id += 1;

        const window = try Window.init(self.allocator, options);
        window.window_id = id;

        try self.windows.put(id, window);

        if (self.active_window == null) {
            self.active_window = id;
        }

        return id;
    }

    pub fn closeWindow(self: *WindowRegistry, id: WindowId) void {
        if (self.windows.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
        if (self.active_window == id) {
            self.active_window = null;
        }
    }

    pub fn getWindow(self: *WindowRegistry, id: WindowId) ?*Window {
        return self.windows.get(id);
    }
};
```

---

## Phase 3: Typed Window Handles ✅ COMPLETED

**Goal**: GPUI-style typed handles for type-safe cross-window communication.

### Implementation Summary

- **`src/runtime/window_handle.zig`**: New typed handle generic
  - `WindowHandle(comptime State: type)` wraps `WindowId` with compile-time type info
  - `update()` / `updateWithCx()` for state mutations with automatic re-render
  - `read()` / `readMut()` for state access
  - `close()`, `focus()`, `setTitle()`, `requestRender()` for window operations
  - `isValid()`, `getId()`, `fromId()`, `invalid()` for handle management
  - All operations gracefully handle closed windows (return null or no-op)

- **Window structs updated** (macOS, Linux, Web):
  - Added `focus()` method to bring window to front
  - Added `close()` method for programmatic window closing
  - macOS: Uses `makeKeyAndOrderFront:` and `performClose:`
  - Linux: Best-effort (Wayland compositor controls focus) + close callback
  - Web: No-op stubs for API compatibility

- **Exports added**:
  - `src/runtime/mod.zig`: Exports `WindowHandle`
  - `src/root.zig`: Exports `WindowHandle`, `WindowContext`, `WindowId`, `WindowRegistry`

### Tasks

| Task                                       | Status | Notes                           |
| ------------------------------------------ | ------ | ------------------------------- |
| 3.1 Create `WindowHandle(State)` generic   | ✅     | `src/runtime/window_handle.zig` |
| 3.2 Add `update()` method                  | ✅     | Plus `updateWithCx()` variant   |
| 3.3 Add `read()` method                    | ✅     | Plus `readMut()` variant        |
| 3.4 Add `close()`, `focus()`, `setTitle()` | ✅     | Plus `requestRender()`          |
| 3.5 Add `isValid()` check                  | ✅     | Plus `getId()`, `fromId()`      |

### Key Design Points

1. **Type-Safe State Access**: `WindowHandle(State)` ensures you can only access windows with the correct state type at compile time

2. **Graceful Degradation**: All operations silently no-op or return null if the window has been closed, preventing crashes from stale handles

3. **Registry-Based Lookup**: Uses `WindowRegistry` for O(1) window lookup by ID, decoupled from platform-specific window pointers

4. **Minimal Memory Footprint**: `WindowHandle` is just a `WindowId` (4 bytes) - no state duplication

5. **Cross-Platform**: `focus()` and `close()` implemented on all platforms with appropriate behavior (Wayland best-effort, Web no-op)

### Design

```/dev/null/window_handle.zig#L1-55
pub fn WindowHandle(comptime State: type) type {
    return struct {
        id: WindowId,

        const Self = @This();

        /// Update this window's state and trigger re-render
        pub fn update(self: Self, app: *App, f: *const fn(*State) void) void {
            const window = app.registry.getWindow(self.id) orelse return;
            const ctx = window.getUserData(WindowContext(State)) orelse return;
            f(ctx.state);
            window.requestRender();
        }

        /// Update with context (access to Cx for side effects)
        pub fn updateCx(self: Self, app: *App, f: *const fn(*Cx, *State) void) void {
            const window = app.registry.getWindow(self.id) orelse return;
            const ctx = window.getUserData(WindowContext(State)) orelse return;
            f(&ctx.cx, ctx.state);
            window.requestRender();
        }

        /// Read this window's state (immutable)
        pub fn read(self: Self, app: *App) ?*const State {
            const window = app.registry.getWindow(self.id) orelse return null;
            const ctx = window.getUserData(WindowContext(State)) orelse return null;
            return ctx.state;
        }

        /// Close this window
        pub fn close(self: Self, app: *App) void {
            app.registry.closeWindow(self.id);
        }

        /// Focus this window (bring to front)
        pub fn focus(self: Self, app: *App) void {
            if (app.registry.getWindow(self.id)) |window| {
                window.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
            }
            app.registry.active_window = self.id;
        }

        /// Set window title
        pub fn setTitle(self: Self, app: *App, title: []const u8) void {
            if (app.registry.getWindow(self.id)) |window| {
                window.setTitle(title);
            }
        }

        /// Check if window still exists
        pub fn isValid(self: Self, app: *App) bool {
            return app.registry.getWindow(self.id) != null;
        }
    };
}
```

---

## Phase 4: Multi-Window Gooey API ✅ COMPLETED

**Goal**: High-level API for opening/managing multiple windows.

### Implementation Summary

Created `MultiWindowApp` struct in `src/runtime/multi_window_app.zig` that provides:

- **App struct**: Owns platform, registry, and shared resources (text system, SVG atlas, image atlas)
- **openWindow()**: Opens typed windows with `WindowHandle(State)` return for cross-window communication
- **Shared resources**: Text system and atlases are created once and shared across all windows
- **Quit behavior**: Configurable `quit_when_last_window_closes` (default: true)
- **Window lifecycle**: `closeWindow()`, `closeWindowById()`, `windowCount()`, `activeWindow()`

Key files:

- `src/runtime/multi_window_app.zig` - Main `App` struct implementation
- `src/runtime/mod.zig` - Module exports (`MultiWindowApp`, `AppWindowOptions`, `MAX_WINDOWS`)
- `src/root.zig` - Public API exports
- `src/examples/multi_window.zig` - Working example with main window + dialog

### Tasks

| Task                                               | Effort | Notes                                   |
| -------------------------------------------------- | ------ | --------------------------------------- |
| 4.1 Create `App` struct (owns platform + registry) | Medium | Replaces implicit globals               |
| 4.2 Add `openWindow()` method                      | Large  | Creates window + context + handle       |
| 4.3 Per-window Gooey instance                      | Large  | Each window needs layout/scene/dispatch |
| 4.4 Shared resources (text system, SVG atlas)      | Medium | Share expensive resources               |
| 4.5 Event routing                                  | Medium | Which window gets events?               |
| 4.6 Window close behavior                          | Medium | Close one vs quit app                   |
| 4.7 Update `runCx` to use new infra                | Medium | Backward compatible (runCx unchanged)   |

### Key Design Points

1. **Shared vs Per-Window Resources**:
   - Shared: `TextSystem`, `SvgAtlas`, `ImageAtlas` (expensive, one per App)
   - Per-window: `Gooey`, `LayoutEngine`, `Scene`, `DispatchTree` (via `WindowContext`)

2. **Resource Ownership**:
   - `App` owns shared resources and registry
   - Each window's `WindowContext` owns per-window resources
   - Clean shutdown: `App.deinit()` closes all windows and frees shared resources

3. **Backward Compatibility**:
   - `runCx()` unchanged - single-window apps work as before
   - `MultiWindowApp` is additive - use when you need multiple windows

4. **Current Implementation Note**:
   - App's shared atlases are wired to each `Window` via `setTextAtlas/setSvgAtlas/setImageAtlas`
   - Each `WindowContext`'s `Gooey` still creates its own internal copies (used during layout)
   - Future optimization: Add `Gooey.initWithSharedResources()` to truly share atlas memory

### Design

```/dev/null/multi_window_app.zig#L1-90
pub const App = struct {
    allocator: Allocator,
    platform: Platform,
    registry: WindowRegistry,

    // Shared resources (expensive to duplicate)
    text_system: *TextSystem,
    svg_atlas: *SvgAtlas,
    image_atlas: *ImageAtlas,

    // Quit behavior
    quit_when_last_window_closes: bool = true,
    running: bool = false,

    pub fn init(allocator: Allocator) !App {
        var platform = try Platform.init();
        return .{
            .allocator = allocator,
            .platform = platform,
            .registry = WindowRegistry.init(allocator),
            .text_system = try TextSystem.init(allocator),
            .svg_atlas = try SvgAtlas.init(allocator),
            .image_atlas = try ImageAtlas.init(allocator),
        };
    }

    /// Open a new window with its own state
    pub fn openWindow(
        self: *App,
        comptime State: type,
        state: *State,
        comptime render: fn(*Cx) void,
        options: WindowOptions,
    ) !WindowHandle(State) {
        const id = try self.registry.createWindow(options);
        const window = self.registry.getWindow(id).?;

        // Create per-window context
        const ctx = try self.allocator.create(WindowContext(State));
        ctx.* = try WindowContext(State).init(
            self.allocator,
            window,
            state,
            self.text_system,  // Share
            self.svg_atlas,    // Share
        );
        ctx.render_fn = render;

        window.setUserData(ctx);
        window.setRenderCallback(WindowContext(State).onRender);
        window.setInputCallback(WindowContext(State).onInput);
        window.setCloseCallback(WindowContext(State).onClose);

        return WindowHandle(State){ .id = id };
    }

    /// Close a specific window
    pub fn closeWindow(self: *App, id: WindowId) void {
        if (self.registry.getWindow(id)) |window| {
            // Clean up window context
            if (window.getUserData(anyopaque)) |ctx_ptr| {
                // ... deinit context
            }
        }
        self.registry.closeWindow(id);

        // Check if we should quit
        if (self.quit_when_last_window_closes and self.registry.windows.count() == 0) {
            self.quit();
        }
    }

    /// Get the currently focused window
    pub fn activeWindow(self: *App) ?WindowId {
        return self.registry.active_window;
    }

    /// Run the event loop
    pub fn run(self: *App) void {
        self.running = true;
        self.platform.run();
    }

    /// Signal quit
    pub fn quit(self: *App) void {
        self.running = false;
        self.platform.quit();
    }

    pub fn deinit(self: *App) void {
        // Close all windows
        var iter = self.registry.windows.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.registry.deinit();
        self.text_system.deinit();
        self.platform.deinit();
    }
};
```

---

## Phase 5: Dialog Windows (Practical Use Case) ✅ COMPLETED

**Goal**: Simple modal dialogs as real windows.

### Implementation Summary

Implemented cross-window communication and fixed shared resource glitching:

1. **Shared Resources Fix**: Added `Gooey.initWithSharedResources()` and `initWithSharedResourcesPtr()` that accept external text system and atlases instead of creating duplicates. This fixes font glitching where layout measured with one atlas but rendering used another.

2. **Cross-Window State Updates**: Dialog windows can now update parent window state through direct references. The `DialogState` stores a pointer to `MainState` enabling real-time cross-window communication.

3. **Updated Example**: The `multi_window.zig` example now demonstrates:
   - Dialog that edits the main window's counter value
   - Apply/Cancel buttons for committing or discarding changes
   - Visual feedback showing modified state
   - Proper window close handling

Key changes:

- `src/context/gooey.zig` - Added `initWithSharedResources()`, changed `svg_atlas` and `image_atlas` to pointers with ownership flags
- `src/runtime/window_context.zig` - Added `initWithSharedResources()` for multi-window mode
- `src/runtime/multi_window_app.zig` - Updated `createWindowContext()` to pass shared resources
- `src/runtime/render.zig` - Updated atlas access to dereference pointers
- `src/examples/multi_window.zig` - Complete rewrite demonstrating cross-window updates

### Tasks

| Task                                          | Effort | Notes                           |
| --------------------------------------------- | ------ | ------------------------------- |
| 5.1 `openDialog()` API                        | Medium | ✅ Via openWindow + state refs  |
| 5.2 Modal behavior (disable parent)           | Medium | ⏳ Future: platform-specific    |
| 5.3 Built-in dialogs (confirm, alert, prompt) | Medium | ⏳ Future: convenience wrappers |
| 5.4 Result passing                            | Medium | ✅ Via state pointer refs       |

### Key Design Points

1. **Shared Resources**: `Gooey` now stores `svg_atlas` and `image_atlas` as pointers with `_owned` flags, matching the `text_system` pattern. Multi-window apps share these across windows.

2. **Cross-Window Pattern**: Dialog state contains a pointer back to parent state, enabling direct updates without complex message passing.

3. **Font Glitching Fix**: The root cause was layout using Gooey's internal text system for measurement while Window rendered with App's shared atlas. Now both use the same shared resources.

### Design

```/dev/null/dialogs.zig#L1-45
/// Open a modal dialog that returns a result
pub fn openDialog(
    app: *App,
    comptime Result: type,
    comptime DialogState: type,
    initial_state: DialogState,
    comptime render: fn(*Cx) void,
    options: DialogOptions,
) !?Result {
    // Create dialog window
    var state = initial_state;
    state._result = null;
    state._should_close = false;

    const handle = try app.openWindow(DialogState, &state, render, .{
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .centered = true,
        // Modal styling
        .titlebar_transparent = true,
    });

    // Disable parent window interaction (platform-specific)
    if (options.parent) |parent_id| {
        if (app.registry.getWindow(parent_id)) |parent| {
            parent.setEnabled(false);
        }
    }

    // Run dialog event loop (blocking)
    while (handle.isValid(app) and !state._should_close) {
        app.platform.pollEvents();
    }

    // Re-enable parent
    if (options.parent) |parent_id| {
        if (app.registry.getWindow(parent_id)) |parent| {
            parent.setEnabled(true);
            parent.focus();
        }
    }

    return state._result;
}

// Usage:
const confirmed = try app.openDialog(bool, ConfirmDialog, .{
    .title = "Delete file?",
    .message = "This cannot be undone.",
}, ConfirmDialog.render, .{
    .parent = main_window.id,
});
```

---

## Implementation Order

```/dev/null/implementation_order.txt#L1-25
Week 1: Phase 1 (Remove Static State)
├── 1.1-1.3: WindowContext struct and integration
├── 1.4: Remove static CallbackState
└── 1.5: Regression tests

Week 2: Phase 2 (Window Registry)
├── 2.1-2.2: WindowId type and field
├── 2.3-2.4: WindowRegistry in Platform
└── 2.5-2.6: Active window tracking

Week 3: Phase 3 (Typed Handles)
├── 3.1-3.2: WindowHandle with update()
├── 3.3-3.4: read(), close(), focus()
└── 3.5: Validity checks

Week 4: Phase 4 (Multi-Window API)
├── 4.1-4.2: App struct with openWindow()
├── 4.3-4.4: Per-window vs shared resources
├── 4.5-4.6: Event routing, close behavior
└── 4.7: Backward-compatible runCx

Week 5: Phase 5 (Dialogs)
├── 5.1-5.2: openDialog() with modal behavior
├── 5.3: Built-in confirm/alert/prompt
└── 5.4: Result passing
```

---

## Risk Assessment

| Risk                               | Mitigation                                                    |
| ---------------------------------- | ------------------------------------------------------------- |
| Breaking existing apps             | Keep `runCx` working unchanged; new API is additive           |
| Memory leaks with multiple windows | RAII pattern; window close cleans up context                  |
| Event routing confusion            | Clear rules: keyboard → focused, mouse → under cursor         |
| Shared resource contention         | Text system already thread-safe; atlas has generation counter |
| Performance regression             | Profile before/after; window context lookup is O(1)           |
| Stack size on WASM                 | Already solved with heap allocation pattern                   |

---

## Success Criteria

1. **Existing apps work unchanged** - `runCx` single-window apps don't break
2. **Two-window demo** - Open editor + preview window, content syncs
3. **Dialog demo** - Confirmation dialog blocks parent, returns result
4. **Clean close** - Closing one window doesn't crash; closing last quits app
5. **Cross-platform** - Works on macOS and Linux (web is single-window)
