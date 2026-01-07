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
pub const setRootState = handler.setRootState;
pub const clearRootState = handler.clearRootState;
pub const getRootState = handler.getRootState;
pub const packArg = handler.packArg;
pub const unpackArg = handler.unpackArg;

// =============================================================================
// Widget Store
// =============================================================================

pub const widget_store = @import("widget_store.zig");

pub const WidgetStore = widget_store.WidgetStore;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
