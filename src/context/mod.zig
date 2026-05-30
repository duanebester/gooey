//! Context System
//!
//! Application context, state management, and event dispatch.
//!
//! - `Window` - Unified UI context (layout, rendering, widgets, hit testing)
//! - `App` - Application-lifetime entity storage shared across windows
//! - `FocusManager` - Focus management and keyboard navigation
//! - `DispatchTree` - Event routing through element hierarchy
//! - `Entity` / `EntityMap` - Reactive entity system for component state
//! - `HandlerRef` - Type-erased callback storage for UI events
//! - `ElementStates` - Unified keyed pool for per-element retained state
//! - `ChangeTracker` - Per-frame value-diffing storage (backs `cx.changed`)

const std = @import("std");

// =============================================================================
// Window Context (framework-level wrapper, per-window)
// =============================================================================
//
// `Window` is the framework wrapper struct. The OS-level handle it
// points at is `PlatformWindow` — the two are distinct types.

pub const window = @import("window.zig");

pub const Window = window.Window;
pub const FontConfig = window.FontConfig;

// =============================================================================
// App-scope shared resources
// =============================================================================
//
// `AppResources` bundles the three "expensive to duplicate per window"
// subsystems (`TextSystem`, `SvgAtlas`, `ImageAtlas`) into one struct
// with a single `owned: bool` discriminator.

pub const app_resources = @import("app_resources.zig");
pub const AppResources = app_resources.AppResources;

// =============================================================================
// Per-window per-frame rendering bundle
// =============================================================================
//
// `Frame` bundles the two "rebuilt every frame, owned by one Window"
// rendering subsystems (`Scene`, `DispatchTree`) into one struct with a
// single `owned: bool` discriminator. `Window` holds one `AppResources`
// (app-lifetime shared) and one `Frame` (per-window per-tick); the
// `borrowed` constructor backs the `rendered_frame` / `next_frame`
// double buffer.

pub const frame = @import("frame.zig");
pub const Frame = frame.Frame;

// =============================================================================
// Focus Management
// =============================================================================

pub const focus = @import("focus.zig");

pub const FocusManager = focus.FocusManager;
pub const FocusId = focus.FocusId;
pub const FocusHandle = focus.FocusHandle;
pub const FocusEvent = focus.FocusEvent;
pub const FocusEventType = focus.FocusEventType;
pub const FocusCallback = focus.FocusCallback;

// `Focusable` vtable. Lets `FocusManager` drive a widget's `focus()` /
// `blur()` without importing widget types — each focusable widget
// exposes `pub fn focusable(self) Focusable`.
pub const Focusable = focus.Focusable;

// =============================================================================
// Dispatch Tree (Event Routing)
// =============================================================================

pub const dispatch = @import("dispatch.zig");

pub const DispatchTree = dispatch.DispatchTree;
pub const DispatchNode = dispatch.DispatchNode;
pub const DispatchNodeId = dispatch.DispatchNodeId;

// Event types re-exported from dispatch
pub const EventPhase = dispatch.EventPhase;
pub const EventResult = dispatch.EventResult;
pub const MouseEvent = dispatch.MouseEvent;
pub const MouseButton = dispatch.MouseButton;
pub const KeyEvent = dispatch.KeyEvent;

// Listener types
pub const MouseListener = dispatch.MouseListener;
pub const ClickListener = dispatch.ClickListener;
pub const ClickListenerHandler = dispatch.ClickListenerHandler;
pub const KeyListener = dispatch.KeyListener;
pub const SimpleKeyListener = dispatch.SimpleKeyListener;
pub const ActionListener = dispatch.ActionListener;
pub const ActionListenerHandler = dispatch.ActionListenerHandler;
pub const ClickOutsideListener = dispatch.ClickOutsideListener;

// Action type ID
pub const ActionTypeId = dispatch.ActionTypeId;
pub const actionTypeId = dispatch.actionTypeId;

// =============================================================================
// Peer subsystems (hover, blur handlers, cancel registry, a11y)
// =============================================================================
//
// These live as fields on `Window` and are re-exported here so
// consumers reach the types via the same `context/mod.zig` path as the
// rest of the context API.

pub const hover = @import("hover.zig");
pub const HoverState = hover.HoverState;
pub const MAX_HOVERED_ANCESTORS = hover.MAX_HOVERED_ANCESTORS;

pub const blur_handlers = @import("blur_handlers.zig");
pub const BlurHandlerRegistry = blur_handlers.BlurHandlerRegistry;
pub const MAX_BLUR_HANDLERS = blur_handlers.MAX_BLUR_HANDLERS;

pub const cancel_registry = @import("cancel_registry.zig");
pub const CancelRegistry = cancel_registry.CancelRegistry;
pub const MAX_CANCEL_GROUPS = cancel_registry.MAX_CANCEL_GROUPS;

pub const a11y_system = @import("a11y_system.zig");
pub const A11ySystem = a11y_system.A11ySystem;

// Generic fixed-capacity slot map backing `BlurHandlerRegistry`,
// `CancelRegistry`, and `ElementStates`.
pub const subscriber_set = @import("subscriber_set.zig");
pub const SubscriberSet = subscriber_set.SubscriberSet;
pub const SubscriberSetOptions = subscriber_set.Options;
pub const SubscriberInsertion = subscriber_set.Insertion;

// =============================================================================
// Unified element state pool
// =============================================================================
//
// `ElementStates` is the keyed `(id_hash, type_id) -> *S` pool for
// per-element retained widget state. A new stateful widget needs no
// framework change: it calls `cx.withElementState(id, …)` and the pool
// routes the lookup to the right slot.

pub const element_states = @import("element_states.zig");
pub const ElementStates = element_states.ElementStates;
pub const MAX_ELEMENT_STATES = element_states.MAX_ELEMENT_STATES;
pub const ElementStateKey = element_states.Key;
pub const ElementStateTypeId = element_states.TypeId;
pub const elementStateTypeId = element_states.typeId;

// =============================================================================
// DrawPhase + Globals
// =============================================================================
//
// `DrawPhase` tags the per-frame lifecycle so phase-restricted methods
// can assert their invariants at entry. `Globals` is a type-keyed
// singleton store for cross-cutting state (theme, keymap, debugger).

pub const draw_phase = @import("draw_phase.zig");
pub const DrawPhase = draw_phase.DrawPhase;
pub const assertPhase = draw_phase.assertPhase;
pub const assertAdvance = draw_phase.assertAdvance;

pub const global = @import("global.zig");
pub const Globals = global.Globals;
pub const MAX_GLOBALS = global.MAX_GLOBALS;
pub const GlobalTypeId = global.TypeId;
pub const globalTypeId = global.typeId;

// =============================================================================
// Drag & Drop
// =============================================================================

pub const drag = @import("drag.zig");

pub const DragState = drag.DragState;
pub const PendingDrag = drag.PendingDrag;
pub const DragTypeId = drag.DragTypeId;
pub const dragTypeId = drag.dragTypeId;
pub const DRAG_THRESHOLD = drag.DRAG_THRESHOLD;

// =============================================================================
// Entity System
// =============================================================================

pub const entity = @import("entity.zig");

pub const Entity = entity.Entity;
pub const EntityId = entity.EntityId;
pub const EntityMap = entity.EntityMap;
pub const EntityContext = entity.EntityContext;
pub const isView = entity.isView;
pub const typeId = entity.typeId;

// =============================================================================
// App (application-lifetime, shared across windows)
// =============================================================================
//
// `App` lifts entity storage off `Window` so models can be shared
// across windows (cross-window observation).

pub const app = @import("app.zig");
pub const App = app.App;

// =============================================================================
// Handler System
// =============================================================================

pub const handler = @import("handler.zig");

pub const HandlerRef = handler.HandlerRef;
pub const OnSelectHandler = handler.OnSelectHandler;
pub const packArg = handler.packArg;
pub const unpackArg = handler.unpackArg;

// Retained-state storage lives on the surviving subsystems directly:
//   - per-element state → `window.element_states.*`
//   - animation pools → `window.animations.*` (or `cx.animations.*`)
//   - value-change diffing → `window.change_tracker.*` (or `cx.changed`)
//
// `change_tracker.zig` is imported by `cx.zig`'s `changed` helper for
// its free `hashValue` function; it is deliberately not re-exported as
// part of the public `context` namespace.

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
    // Compile-time `_owned: bool` audit — lives next to `Window` so it
    // reaches sibling sub-structs without an extra import hop. The
    // allow-list and rationale are in the audit file's header.
    std.testing.refAllDecls(@import("owned_flag_audit.zig"));
}
