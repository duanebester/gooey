//! Context System
//!
//! Application context, state management, and event dispatch.
//!
//! - `Gooey` - Unified UI context (layout, rendering, widgets, hit testing)
//! - `FocusManager` - Focus management and keyboard navigation
//! - `DispatchTree` - Event routing through element hierarchy
//! - `Entity` / `EntityMap` - Reactive entity system for component state
//! - `HandlerRef` - Type-erased callback storage for UI events
//! - `WidgetStore` - Retained storage for stateful widgets

const std = @import("std");

// =============================================================================
// Gooey Context
// =============================================================================

pub const gooey = @import("gooey.zig");

pub const Gooey = gooey.Gooey;
pub const FontConfig = gooey.FontConfig;

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

// PR 4 — `Focusable` vtable. Lets `FocusManager` drive a widget's
// `focus()` / `blur()` without the focus manager (which lives in
// `context/`) having to import widget types. Each focusable widget
// exposes `pub fn focusable(self) Focusable` and registers the trait
// alongside its `FocusHandle` — see `docs/cleanup-implementation-plan.md`
// PR 4 and `docs/architectural-cleanup-plan.md` §4.
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
pub const ClickListenerWithContext = dispatch.ClickListenerWithContext;
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
// PR 3 — context/ subsystem extractions
// =============================================================================
//
// These four subsystems used to live as fields and methods directly on
// `Gooey`. They are now peer modules. Re-exported here so consumers can
// `@import("context/mod.zig")` and reach the types via the same path as
// the rest of the context API.

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

// Generic fixed-capacity slot map (cleanup item #8). Backs both
// `BlurHandlerRegistry` and `CancelRegistry` in PR 3, and will back
// `element_states` in PR 8.
pub const subscriber_set = @import("subscriber_set.zig");
pub const SubscriberSet = subscriber_set.SubscriberSet;
pub const SubscriberSetOptions = subscriber_set.Options;
pub const SubscriberInsertion = subscriber_set.Insertion;

// =============================================================================
// PR 6 — DrawPhase + Globals
// =============================================================================
//
// `DrawPhase` tags the per-frame lifecycle so phase-restricted methods
// can assert their invariants at entry. `Globals` is a type-keyed
// singleton store for cross-cutting state (theme, keymap, debugger)
// that previously lived as direct fields on `Gooey`.
//
// See `docs/cleanup-implementation-plan.md` PR 6.

pub const draw_phase = @import("draw_phase.zig");
pub const DrawPhase = draw_phase.DrawPhase;
pub const assertPhase = draw_phase.assertPhase;
pub const assertPhaseOneOf = draw_phase.assertPhaseOneOf;
pub const assertInFrame = draw_phase.assertInFrame;
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
// Handler System
// =============================================================================

pub const handler = @import("handler.zig");

pub const HandlerRef = handler.HandlerRef;
pub const packArg = handler.packArg;
pub const unpackArg = handler.unpackArg;

// =============================================================================
// Widget Store
// =============================================================================

pub const widget_store = @import("widget_store.zig");

pub const WidgetStore = widget_store.WidgetStore;

// Note: `change_tracker.zig` is intentionally not re-exported here.
// It is an implementation detail of `WidgetStore`, not part of the public API.

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
