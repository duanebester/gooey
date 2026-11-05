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

pub const enable_validation_layers = @import("builtin").mode == .debug;

// =============================================================================
// Result Types
// =============================================================================

pub const InstanceResult = struct {
    instance: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    /// True when every instance extension required by
    /// `VK_KHR_swapchain_maintenance1` was enabled. The device extension is
    /// only attempted when this is true.
    swapchain_maintenance1_ready: bool,
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
    /// True when `VK_KHR_swapchain_maintenance1` is enabled, allowing present
    /// fences via `VkSwapchainPresentFenceInfoKHR`.
    swapchain_maintenance1: bool,
};

// =============================================================================
// Limits (CLAUDE.md Rule #4)
// =============================================================================

const MAX_PHYSICAL_DEVICES: u32 = 16;
const MAX_QUEUE_FAMILIES: u32 = 32;
const MAX_ENUM_EXTENSIONS: u32 = 128;

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
        .apiVersion = vk.API_VERSION_1_0,
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
        .enabledExtensionCount = extensions.count,
        .ppEnabledExtensionNames = extensions.names[0..extensions.count].ptr,
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
        .swapchain_maintenance1_ready = extensions.swapchain_maintenance1_ready,
    };
}

/// Destroy the debug messenger. Safe to call with null messenger.
pub fn destroyDebugMessenger(instance: vk.Instance, messenger: vk.DebugUtilsMessengerEXT) void {
    std.debug.assert(instance != null);
    if (messenger == null) return;

    const proc = vk.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
    if (proc) |address| {
        const destroy_fn: vk.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(address);
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
    var devices: [MAX_PHYSICAL_DEVICES]vk.PhysicalDevice = @splat(null);
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
///
/// When `allow_swapchain_maintenance1` is true and the physical device
/// advertises `VK_KHR_swapchain_maintenance1`, the extension and its feature
/// are enabled so presentation can be tracked with fences. The device still
/// gets created without the extension if the driver rejects it.
pub fn createLogicalDevice(
    physical_device: vk.PhysicalDevice,
    families: QueueFamilies,
    allow_swapchain_maintenance1: bool,
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
        .pQueuePriorities = (&queue_priority)[0..1],
    };

    if (families.graphics != families.present) {
        queue_create_infos[1] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = families.present,
            .queueCount = 1,
            .pQueuePriorities = (&queue_priority)[0..1],
        };
        queue_create_count = 2;
    }

    var use_swapchain_maintenance1 = allow_swapchain_maintenance1 and
        deviceExtensionAvailable(physical_device, vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME);

    const device_extensions = [_][*:0]const u8{
        "VK_KHR_swapchain",
        vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME,
    };
    var extension_count: u32 = if (use_swapchain_maintenance1) 2 else 1;

    const maintenance_features = vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR,
        .pNext = null,
        .swapchainMaintenance1 = vk.TRUE,
    };

    var create_info = vk.DeviceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = if (use_swapchain_maintenance1) @ptrCast(&maintenance_features) else null,
        .flags = 0,
        .queueCreateInfoCount = queue_create_count,
        .pQueueCreateInfos = &queue_create_infos,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = extension_count,
        .ppEnabledExtensionNames = device_extensions[0..extension_count].ptr,
        .pEnabledFeatures = null,
    };

    var device: vk.Device = null;
    var result = vk.vkCreateDevice(physical_device, &create_info, null, &device);
    if (!vk.succeeded(result) and use_swapchain_maintenance1) {
        // The driver advertised the extension but rejected the feature or its
        // dependency chain — fall back to unsynchronized present tracking.
        std.log.warn("VK_KHR_swapchain_maintenance1 rejected by driver, retrying without it", .{});
        use_swapchain_maintenance1 = false;
        extension_count = 1;
        create_info.pNext = null;
        create_info.enabledExtensionCount = extension_count;
        create_info.ppEnabledExtensionNames = device_extensions[0..extension_count].ptr;
        device = null;
        result = vk.vkCreateDevice(physical_device, &create_info, null, &device);
    }
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
        .swapchain_maintenance1 = use_swapchain_maintenance1,
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
    severity: vk.DebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = msg_type;

    // The loader owns `callback_data`; treat both pointers as untrusted.
    const data = callback_data orelse return vk.FALSE;
    const message: [*:0]const u8 = data.pMessage orelse "unknown";

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

    const proc = vk.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
    if (proc) |address| {
        const create_fn: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(address);
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
    names: [MAX_INSTANCE_EXTENSIONS][*:0]const u8 = undefined,
    count: u32 = 0,
    /// All three extensions required by `VK_KHR_swapchain_maintenance1` were
    /// added to the list. The device extension may only be enabled when true.
    swapchain_maintenance1_ready: bool = false,
};

const MAX_INSTANCE_EXTENSIONS: u32 = 8;

fn instanceExtensions(use_validation: bool) ExtensionList {
    var list = ExtensionList{};

    addInstanceExtension(&list, "VK_KHR_surface");
    addInstanceExtension(&list, "VK_KHR_wayland_surface");
    if (use_validation) addInstanceExtension(&list, "VK_EXT_debug_utils");

    // VK_KHR_swapchain_maintenance1 depends on VK_KHR_surface_maintenance1,
    // which in turn depends on VK_KHR_get_surface_capabilities2. The device
    // extension also depends on VK_KHR_get_physical_device_properties2 (the
    // instance is Vulkan 1.0). Enable all three only when the loader has them.
    const has_properties2 = instanceExtensionAvailable(vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
    const has_capabilities2 = instanceExtensionAvailable(vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME);
    const has_surface_maintenance1 = has_capabilities2 and
        instanceExtensionAvailable(vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME);

    if (has_properties2) addInstanceExtension(&list, vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
    if (has_capabilities2) addInstanceExtension(&list, vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME);
    if (has_surface_maintenance1) addInstanceExtension(&list, vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME);

    list.swapchain_maintenance1_ready = has_properties2 and has_capabilities2 and has_surface_maintenance1;
    return list;
}

fn addInstanceExtension(list: *ExtensionList, name: [*:0]const u8) void {
    std.debug.assert(list.count < MAX_INSTANCE_EXTENSIONS);
    list.names[list.count] = name;
    list.count += 1;
}

fn instanceExtensionAvailable(name: [*:0]const u8) bool {
    var count: u32 = 0;
    if (!vk.succeeded(vk.vkEnumerateInstanceExtensionProperties(null, &count, null))) return false;
    if (count == 0) return false;

    var props: [MAX_ENUM_EXTENSIONS]vk.ExtensionProperties = undefined;
    var available: u32 = @min(count, MAX_ENUM_EXTENSIONS);
    if (!vk.succeeded(vk.vkEnumerateInstanceExtensionProperties(null, &available, &props))) return false;

    for (props[0..available]) |prop| {
        const prop_name: [*:0]const u8 = @ptrCast(&prop.extensionName);
        if (std.mem.eql(u8, std.mem.span(prop_name), std.mem.span(name))) return true;
    }
    return false;
}

fn deviceExtensionAvailable(physical_device: vk.PhysicalDevice, name: [*:0]const u8) bool {
    std.debug.assert(physical_device != null);

    var count: u32 = 0;
    if (!vk.succeeded(vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &count, null))) return false;
    if (count == 0) return false;

    var props: [MAX_ENUM_EXTENSIONS]vk.ExtensionProperties = undefined;
    var available: u32 = @min(count, MAX_ENUM_EXTENSIONS);
    if (!vk.succeeded(vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &available, &props))) return false;

    for (props[0..available]) |prop| {
        const prop_name: [*:0]const u8 = @ptrCast(&prop.extensionName);
        if (std.mem.eql(u8, std.mem.span(prop_name), std.mem.span(name))) return true;
    }
    return false;
}
