//! Vulkan instance, device, surface, and debug messenger creation.
//!
//! Free functions with targeted parameters — each takes only what it needs,
//! not the entire VulkanRenderer. One-time initialization code that won't be
//! touched after bringup; extracting it shrinks the daily working set.

const std = @import("std");
const vk = @import("vulkan.zig");

// =============================================================================
// Configuration
// =============================================================================

pub const enable_validation_layers = @import("builtin").mode == .Debug;

// =============================================================================
// Result Types
// =============================================================================

pub const InstanceResult = struct {
    instance: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
};

pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,
};

pub const PhysicalDeviceResult = struct {
    physical_device: vk.PhysicalDevice,
    families: QueueFamilies,
};

pub const DeviceResult = struct {
    device: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
};

// =============================================================================
// Limits (CLAUDE.md Rule #4)
// =============================================================================

const MAX_PHYSICAL_DEVICES: u32 = 16;
const MAX_QUEUE_FAMILIES: u32 = 32;

// =============================================================================
// Error Types
// =============================================================================

pub const InstanceError = error{
    VulkanInstanceCreationFailed,
};

pub const SurfaceError = error{
    WaylandSurfaceCreationFailed,
};

pub const DeviceSelectionError = error{
    NoVulkanDevicesFound,
    NoSuitableVulkanDevice,
};

pub const DeviceCreationError = error{
    DeviceCreationFailed,
};

// =============================================================================
// Public API
// =============================================================================

/// Create Vulkan instance and (optionally) debug messenger.
///
/// When validation layers are enabled and available, the debug messenger is
/// chained into instance creation via pNext and also created as a persistent
/// object for runtime validation messages.
pub fn createInstance() InstanceError!InstanceResult {
    const app_info = vk.ApplicationInfo{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "Gooey",
        .applicationVersion = 1,
        .pEngineName = "Gooey",
        .engineVersion = 1,
        .apiVersion = vk.c.VK_API_VERSION_1_0,
    };

    const use_validation = enable_validation_layers and vk.isValidationLayerAvailable();
    if (enable_validation_layers and !use_validation) {
        std.log.warn("Validation layers requested but VK_LAYER_KHRONOS_validation not available", .{});
    }

    const extensions = instanceExtensions(use_validation);
    const validation_layers = [_][*:0]const u8{vk.VALIDATION_LAYER_NAME};

    var debug_create_info = debugMessengerCreateInfo();

    const create_info = vk.InstanceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = if (use_validation) @ptrCast(&debug_create_info) else null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = if (use_validation) validation_layers.len else 0,
        .ppEnabledLayerNames = if (use_validation) &validation_layers else null,
        .enabledExtensionCount = @intCast(extensions.count),
        .ppEnabledExtensionNames = extensions.ptr,
    };

    var instance: vk.Instance = null;
    const result = vk.vkCreateInstance(&create_info, null, &instance);
    if (!vk.succeeded(result)) {
        std.log.err("Failed to create Vulkan instance: {}", .{result});
        return InstanceError.VulkanInstanceCreationFailed;
    }

    std.debug.assert(instance != null);

    // Create persistent debug messenger after instance creation
    var debug_messenger: vk.DebugUtilsMessengerEXT = null;
    if (use_validation) {
        debug_messenger = createDebugMessenger(instance, &debug_create_info);
    }

    return .{
        .instance = instance,
        .debug_messenger = debug_messenger,
    };
}

/// Destroy the debug messenger. Safe to call with null messenger.
pub fn destroyDebugMessenger(instance: vk.Instance, messenger: vk.DebugUtilsMessengerEXT) void {
    std.debug.assert(instance != null);
    if (messenger == null) return;

    const func = @as(
        ?*const fn (vk.Instance, vk.DebugUtilsMessengerEXT, ?*const anyopaque) callconv(.c) void,
        @ptrCast(vk.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")),
    );

    if (func) |destroy_fn| {
        destroy_fn(instance, messenger, null);
    }
}

/// Create a Wayland surface for presentation.
pub fn createWaylandSurface(
    instance: vk.Instance,
    wl_display: *anyopaque,
    wl_surface: *anyopaque,
) SurfaceError!vk.Surface {
    std.debug.assert(instance != null);

    const create_info = vk.WaylandSurfaceCreateInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .display = @ptrCast(wl_display),
        .surface = @ptrCast(wl_surface),
    };

    var surface: vk.Surface = null;
    const result = vk.vkCreateWaylandSurfaceKHR(instance, &create_info, null, &surface);
    if (!vk.succeeded(result)) {
        std.log.err("Failed to create Wayland surface: {}", .{result});
        return SurfaceError.WaylandSurfaceCreationFailed;
    }

    std.debug.assert(surface != null);
    return surface;
}

/// Pick a suitable physical device and identify its queue families.
pub fn pickPhysicalDevice(
    instance: vk.Instance,
    surface: vk.Surface,
) DeviceSelectionError!PhysicalDeviceResult {
    std.debug.assert(instance != null);
    std.debug.assert(surface != null);

    var device_count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(instance, &device_count, null);
    if (device_count == 0) {
        return DeviceSelectionError.NoVulkanDevicesFound;
    }

    std.debug.assert(device_count <= MAX_PHYSICAL_DEVICES);
    var devices: [MAX_PHYSICAL_DEVICES]vk.PhysicalDevice = [_]vk.PhysicalDevice{null} ** MAX_PHYSICAL_DEVICES;
    var count: u32 = @min(device_count, MAX_PHYSICAL_DEVICES);
    _ = vk.vkEnumeratePhysicalDevices(instance, &count, &devices);

    for (devices[0..count]) |dev| {
        if (dev == null) continue;

        if (findQueueFamilies(dev, surface)) |families| {
            var props: vk.PhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(dev, &props);
            std.log.info("Selected GPU: {s}", .{@as([*:0]const u8, @ptrCast(&props.deviceName))});

            return .{
                .physical_device = dev,
                .families = families,
            };
        }
    }

    return DeviceSelectionError.NoSuitableVulkanDevice;
}

/// Create a logical device with graphics and present queues.
pub fn createLogicalDevice(
    physical_device: vk.PhysicalDevice,
    families: QueueFamilies,
) DeviceCreationError!DeviceResult {
    std.debug.assert(physical_device != null);

    const queue_priority: f32 = 1.0;
    var queue_create_infos: [2]vk.DeviceQueueCreateInfo = undefined;
    var queue_create_count: u32 = 1;

    queue_create_infos[0] = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = families.graphics,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    if (families.graphics != families.present) {
        queue_create_infos[1] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = families.present,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        queue_create_count = 2;
    }

    const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

    const create_info = vk.DeviceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = queue_create_count,
        .pQueueCreateInfos = &queue_create_infos,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .pEnabledFeatures = null,
    };

    var device: vk.Device = null;
    const result = vk.vkCreateDevice(physical_device, &create_info, null, &device);
    if (!vk.succeeded(result)) {
        return DeviceCreationError.DeviceCreationFailed;
    }
    std.debug.assert(device != null);

    var graphics_queue: vk.Queue = null;
    var present_queue: vk.Queue = null;
    vk.vkGetDeviceQueue(device, families.graphics, 0, &graphics_queue);
    vk.vkGetDeviceQueue(device, families.present, 0, &present_queue);

    std.debug.assert(graphics_queue != null);
    std.debug.assert(present_queue != null);

    return .{
        .device = device,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
    };
}

// =============================================================================
// Internal Helpers
// =============================================================================

/// Find graphics and present queue families for a physical device.
/// Returns null if the device is not suitable (missing required queue families).
fn findQueueFamilies(device: vk.PhysicalDevice, surface: vk.Surface) ?QueueFamilies {
    std.debug.assert(device != null);
    std.debug.assert(surface != null);

    var queue_family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    std.debug.assert(queue_family_count <= MAX_QUEUE_FAMILIES);
    var queue_families: [MAX_QUEUE_FAMILIES]vk.QueueFamilyProperties = undefined;
    var count: u32 = @min(queue_family_count, MAX_QUEUE_FAMILIES);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &queue_families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (queue_families[0..count], 0..) |family, i| {
        const idx: u32 = @intCast(i);

        if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) {
            graphics_family = idx;
        }

        var present_support: vk.Bool32 = vk.FALSE;
        _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, surface, &present_support);
        if (present_support == vk.TRUE) {
            present_family = idx;
        }

        if (graphics_family != null and present_family != null) break;
    }

    if (graphics_family) |gf| {
        if (present_family) |pf| {
            return .{ .graphics = gf, .present = pf };
        }
    }

    return null;
}

/// Debug callback for Vulkan validation layer messages.
fn debugCallback(
    severity: c_uint,
    msg_type: c_uint,
    callback_data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = msg_type;

    const message: [*c]const u8 = if (callback_data != null) callback_data.*.pMessage else "unknown";

    if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) {
        std.log.err("[Vulkan Validation] {s}", .{message});
    } else if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) {
        std.log.warn("[Vulkan Validation] {s}", .{message});
    } else {
        std.log.info("[Vulkan Validation] {s}", .{message});
    }

    return vk.FALSE;
}

/// Build the debug messenger create info (reused for pNext chain and standalone creation).
fn debugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = null,
        .flags = 0,
        .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

/// Create the persistent debug messenger (called after instance creation).
fn createDebugMessenger(
    instance: vk.Instance,
    create_info: *const vk.DebugUtilsMessengerCreateInfoEXT,
) vk.DebugUtilsMessengerEXT {
    std.debug.assert(instance != null);

    const func = @as(
        ?*const fn (vk.Instance, *const vk.DebugUtilsMessengerCreateInfoEXT, ?*const anyopaque, *vk.DebugUtilsMessengerEXT) callconv(.c) vk.Result,
        @ptrCast(vk.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT")),
    );

    if (func) |create_fn| {
        var messenger: vk.DebugUtilsMessengerEXT = null;
        const result = create_fn(instance, create_info, null, &messenger);
        if (vk.succeeded(result)) {
            std.log.info("Vulkan validation layers enabled", .{});
            return messenger;
        }
        std.log.warn("Failed to create debug messenger: {}", .{result});
    } else {
        std.log.warn("vkCreateDebugUtilsMessengerEXT not available", .{});
    }

    return null;
}

/// Instance extensions, parameterized by whether validation is active.
const ExtensionList = struct {
    ptr: [*]const [*:0]const u8,
    count: u32,
};

fn instanceExtensions(use_validation: bool) ExtensionList {
    const base = [_][*:0]const u8{
        "VK_KHR_surface",
        "VK_KHR_wayland_surface",
    };
    const debug = [_][*:0]const u8{
        "VK_KHR_surface",
        "VK_KHR_wayland_surface",
        "VK_EXT_debug_utils",
    };

    if (use_validation) {
        return .{ .ptr = &debug, .count = debug.len };
    } else {
        return .{ .ptr = &base, .count = base.len };
    }
}
