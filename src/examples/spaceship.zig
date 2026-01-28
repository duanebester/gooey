//! Spaceship Dashboard - Futuristic command center UI
//!
//! Demonstrates:
//! - Custom holographic shader (scanlines + glow)
//! - Neon cyberpunk aesthetics
//! - Dashboard layout with stats, gauges, alerts
//! - Form controls styled for sci-fi interface
//! - Component composition with Cx API
//!
//! Animations:
//! 1. Header fade-in** (600ms on load)
//! 2. **Status indicator pulse** (intensity varies by alert level)
//! 3. **Alert badge pulse** (800ms urgent pulse when alerts active)
//! 4. **Jump charge ring** - charging pulse + ready glow pop with `animateOn`
//! 5. **Reactor core pulse** (faster when hot, subtle when normal)
//! 6. **Circle gauges breathing** (3s subtle background pulse)
//! 7. **Gauge bars settle** (300ms ease on value change)
//! 8. **Toggle buttons transition** (200ms on state change)
//! 9. **Neon buttons idle pulse** (2s subtle glow)

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = gooey.wasmLogFn }
else
    .{};

const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const TextInput = gooey.TextInput;
const Easing = gooey.Easing;
const Svg = gooey.Svg;

// =============================================================================
// Custom Spaceship SVG Icons (24x24 viewbox)
// =============================================================================

const SpaceIcons = struct {
    // Ship hull - spaceship silhouette
    const ship = "M12 2L4 12l2 8h12l2-8L12 2zm0 3l5 7H7l5-7zm-4 9h8v2H8v-2z";

    // Shield - protective barrier
    const shield = "M12 2L4 5v6c0 5.55 3.84 10.74 8 12 4.16-1.26 8-6.45 8-12V5l-8-3zm0 3.18l5 1.88v4.94c0 3.72-2.38 7.14-5 8.56-2.62-1.42-5-4.84-5-8.56V7.06l5-1.88z";

    // Fuel tank - energy container
    const fuel = "M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 14c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z";

    // Oxygen - air/life support
    const oxygen = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z";

    // Reactor core - nuclear/power
    const reactor = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-5-9h10v2H7v-2zm3-3h4v8h-4V8z";

    // Navigation compass - direction
    const navigation = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-1-13l-4 8h4v4l4-8h-4V7z";

    // Controls gear - settings
    const controls = "M19.14 12.94c.04-.31.06-.63.06-.94 0-.31-.02-.63-.06-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.04.31-.06.63-.06.94s.02.63.06.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z";

    // Jump drive - warp/hyperspace
    const jump_drive = "M12 2l-5.5 9h11L12 2zm0 3.84L14.11 9H9.89L12 5.84zM17.5 13c-2.49 0-4.5 2.01-4.5 4.5s2.01 4.5 4.5 4.5 4.5-2.01 4.5-4.5-2.01-4.5-4.5-4.5zm0 7c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5zM6.5 13C4.01 13 2 15.01 2 17.5S4.01 22 6.5 22 11 19.99 11 17.5 8.99 13 6.5 13zm0 7C5.12 20 4 18.88 4 17.5S5.12 15 6.5 15 9 16.12 9 17.5 7.88 20 6.5 20z";

    // Alert warning - danger triangle
    const alert = "M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z";

    // Autopilot - AI control
    const autopilot = "M20 8h-3V4H3c-1.1 0-2 .9-2 2v11h2c0 1.66 1.34 3 3 3s3-1.34 3-3h6c0 1.66 1.34 3 3 3s3-1.34 3-3h2v-5l-3-4zM6 18.5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm13.5-9l1.96 2.5H17V9.5h2.5zm-1.5 9c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z";

    // Boost - rocket flame
    const boost = "M13 2.05v2.02c3.95.49 7 3.85 7 7.93 0 1.62-.49 3.13-1.32 4.39l1.47 1.47C21.32 16.12 22 14.15 22 12c0-5.18-3.95-9.45-9-9.95zM12 6c-3.31 0-6 2.69-6 6 0 1.3.42 2.5 1.12 3.48l4.38-4.38-1.06-1.06L12 8.6l4.88 4.88-1.06 1.06-4.38-4.38-4.38 4.38c.98.7 2.18 1.12 3.48 1.12 3.31 0 6-2.69 6-6s-2.69-6-6-6zm-8.66 8.61l-1.47 1.47C2.68 17.88 2 15.85 2 14c0-5.18 3.95-9.45 9-9.95v2.02C7.05 6.56 4 9.92 4 14c0 .55.05 1.09.14 1.61l-.8-.8z";

    // Emergency stop - power off
    const emergency = "M13 3h-2v10h2V3zm4.83 2.17l-1.42 1.42C17.99 7.86 19 9.81 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.19 1.01-4.14 2.58-5.42L6.17 5.17C4.23 6.82 3 9.26 3 12c0 4.97 4.03 9 9 9s9-4.03 9-9c0-2.74-1.23-5.18-3.17-6.83z";

    // Target lock - crosshair
    const target = "M12 8c-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4zm8.94 3c-.46-4.17-3.77-7.48-7.94-7.94V1h-2v2.06C6.83 3.52 3.52 6.83 3.06 11H1v2h2.06c.46 4.17 3.77 7.48 7.94 7.94V23h2v-2.06c4.17-.46 7.48-3.77 7.94-7.94H23v-2h-2.06zM12 19c-3.87 0-7-3.13-7-7s3.13-7 7-7 7 3.13 7 7-3.13 7-7 7z";

    // Velocity speedometer
    const velocity = "M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44zm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z";

    // Coordinates - location pin
    const coords = "M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z";

    // Heading compass arrow
    const heading = "M12 2L4.5 20.29l.71.71L12 18l6.79 3 .71-.71z";

    // Status indicator dot
    const status_dot = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z";

    // Power on
    const power_on = "M16.01 7L16 3h-2v4h-4V3H8v4h-.01C7 6.99 6 7.99 6 8.99v5.49L9.5 18v3h5v-3l3.5-3.51v-5.5c0-1-1-2-1.99-1.99z";

    // Power off
    const power_off = "M16 7V3h-2v4h-4V3H8v4H6v5l4 4v5h4v-5l4-4V7h-2z";

    // Dashboard grid
    const dashboard = "M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z";

    // Star/celestial
    const star = "M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z";
};

/// Holographic scanline + chromatic aberration shader (MSL - macOS)
pub const hologram_shader_msl =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float time = uniforms.iTime;
    \\
    \\    // Subtle chromatic aberration
    \\    float aberration = 0.002 * sin(time * 2.0);
    \\    float r = iChannel0.sample(iChannel0Sampler, uv + float2(aberration, 0.0)).r;
    \\    float g = iChannel0.sample(iChannel0Sampler, uv).g;
    \\    float b = iChannel0.sample(iChannel0Sampler, uv - float2(aberration, 0.0)).b;
    \\    float3 scene = float3(r, g, b);
    \\
    \\    // Scanlines
    \\    float scanline = sin(fragCoord.y * 1.5 + time * 3.0) * 0.03 + 0.97;
    \\    scene *= scanline;
    \\
    \\    // Subtle vignette
    \\    float2 center = uv - 0.5;
    \\    float vignette = 1.0 - dot(center, center) * 0.5;
    \\    scene *= vignette;
    \\
    \\    // Occasional glitch line
    \\    float glitch = step(0.998, fract(sin(floor(time * 10.0) * 12.9898) * 43758.5453));
    \\    float glitchY = fract(sin(floor(time * 10.0) * 78.233) * 43758.5453);
    \\    if (glitch > 0.5 && abs(uv.y - glitchY) < 0.01) {
    \\        scene.rgb = scene.bgr * 1.5;
    \\    }
    \\
    \\    // Cyan/magenta tint at edges
    \\    float edgeDist = max(abs(center.x), abs(center.y)) * 2.0;
    \\    float3 edgeTint = mix(float3(0.0, 1.0, 1.0), float3(1.0, 0.0, 1.0), uv.x);
    \\    scene = mix(scene, scene + edgeTint * 0.1, smoothstep(0.7, 1.0, edgeDist));
    \\
    \\    fragColor = float4(scene, 1.0);
    \\}
;

/// Subtle warp speed distortion at edges (MSL - macOS)
pub const warp_shader_msl =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float time = uniforms.iTime * 0.3;
    \\
    \\    // Distance from center
    \\    float2 center = uv - 0.5;
    \\    float dist = length(center);
    \\    float angle = atan2(center.y, center.x);
    \\
    \\    // Warp intensity increases toward edges
    \\    float warpStrength = smoothstep(0.3, 0.8, dist) * 0.02;
    \\
    \\    // Spiral warp motion
    \\    float spiral = sin(angle * 3.0 + time * 2.0 + dist * 10.0);
    \\    float radialPulse = sin(dist * 20.0 - time * 4.0) * 0.5 + 0.5;
    \\
    \\    // Apply distortion
    \\    float2 warpOffset = center * warpStrength * spiral * radialPulse;
    \\    float2 distortedUV = uv + warpOffset;
    \\
    \\    // Sample with distortion
    \\    float3 scene = iChannel0.sample(iChannel0Sampler, distortedUV).rgb;
    \\
    \\    // Add streaking light at edges (warp stars effect)
    \\    float streak = pow(radialPulse, 3.0) * smoothstep(0.5, 0.9, dist);
    \\    float3 streakColor = mix(float3(0.0, 0.8, 1.0), float3(1.0, 0.0, 0.8), angle * 0.3 + 0.5);
    \\    scene += streakColor * streak * 0.15;
    \\
    \\    // Subtle edge glow
    \\    float edgeGlow = smoothstep(0.6, 1.0, dist) * 0.3;
    \\    scene += float3(0.0, 0.5, 1.0) * edgeGlow * (sin(time * 2.0) * 0.3 + 0.7);
    \\
    \\    fragColor = float4(scene, 1.0);
    \\}
;

/// Holographic scanline + chromatic aberration shader (WGSL - Web)
pub const hologram_shader_wgsl =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    let uv = fragCoord / u.iResolution.xy;
    \\    let time = u.iTime;
    \\
    \\    // Subtle chromatic aberration
    \\    let aberration = 0.002 * sin(time * 2.0);
    \\    let r = textureSample(tex, samp, uv + vec2<f32>(aberration, 0.0)).r;
    \\    let g = textureSample(tex, samp, uv).g;
    \\    let b = textureSample(tex, samp, uv - vec2<f32>(aberration, 0.0)).b;
    \\    var scene = vec3<f32>(r, g, b);
    \\
    \\    // Scanlines
    \\    let scanline = sin(fragCoord.y * 1.5 + time * 3.0) * 0.03 + 0.97;
    \\    scene = scene * scanline;
    \\
    \\    // Subtle vignette
    \\    let center = uv - 0.5;
    \\    let vignette = 1.0 - dot(center, center) * 0.5;
    \\    scene = scene * vignette;
    \\
    \\    // Occasional glitch line
    \\    let glitch = step(0.998, fract(sin(floor(time * 10.0) * 12.9898) * 43758.5453));
    \\    let glitchY = fract(sin(floor(time * 10.0) * 78.233) * 43758.5453);
    \\    if (glitch > 0.5 && abs(uv.y - glitchY) < 0.01) {
    \\        scene = scene.bgr * 1.5;
    \\    }
    \\
    \\    // Cyan/magenta tint at edges
    \\    let edgeDist = max(abs(center.x), abs(center.y)) * 2.0;
    \\    let edgeTint = mix(vec3<f32>(0.0, 1.0, 1.0), vec3<f32>(1.0, 0.0, 1.0), uv.x);
    \\    scene = mix(scene, scene + edgeTint * 0.1, smoothstep(0.7, 1.0, edgeDist));
    \\
    \\    return vec4<f32>(scene, 1.0);
    \\}
;

/// Subtle warp speed distortion at edges (WGSL - Web)
pub const warp_shader_wgsl =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    let uv = fragCoord / u.iResolution.xy;
    \\    let time = u.iTime * 0.3;
    \\
    \\    // Distance from center
    \\    let center = uv - 0.5;
    \\    let dist = length(center);
    \\    let angle = atan2(center.y, center.x);
    \\
    \\    // Warp intensity increases toward edges
    \\    let warpStrength = smoothstep(0.3, 0.8, dist) * 0.02;
    \\
    \\    // Spiral warp motion
    \\    let spiral = sin(angle * 3.0 + time * 2.0 + dist * 10.0);
    \\    let radialPulse = sin(dist * 20.0 - time * 4.0) * 0.5 + 0.5;
    \\
    \\    // Apply distortion
    \\    let warpOffset = center * warpStrength * spiral * radialPulse;
    \\    let distortedUV = uv + warpOffset;
    \\
    \\    // Sample with distortion
    \\    var scene = textureSample(tex, samp, distortedUV).rgb;
    \\
    \\    // Add streaking light at edges (warp stars effect)
    \\    let streak = pow(radialPulse, 3.0) * smoothstep(0.5, 0.9, dist);
    \\    let streakColor = mix(vec3<f32>(0.0, 0.8, 1.0), vec3<f32>(1.0, 0.0, 0.8), angle * 0.3 + 0.5);
    \\    scene = scene + streakColor * streak * 0.15;
    \\
    \\    // Subtle edge glow
    \\    let edgeGlow = smoothstep(0.6, 1.0, dist) * 0.3;
    \\    scene = scene + vec3<f32>(0.0, 0.5, 1.0) * edgeGlow * (sin(time * 2.0) * 0.3 + 0.7);
    \\
    \\    return vec4<f32>(scene, 1.0);
    \\}
;

// =============================================================================
// Color Palette - Neon Cyberpunk
// =============================================================================

const Colors = struct {
    const bg_dark = ui.Color.rgb(0.02, 0.02, 0.05);
    const bg_panel = ui.Color.rgba(0.05, 0.08, 0.12, 0.9);
    const bg_card = ui.Color.rgba(0.08, 0.12, 0.18, 0.95);

    const cyan = ui.Color.rgb(0.0, 0.9, 1.0);
    const cyan_dim = ui.Color.rgb(0.0, 0.5, 0.6);
    const magenta = ui.Color.rgb(1.0, 0.0, 0.8);
    const magenta_dim = ui.Color.rgb(0.6, 0.0, 0.5);
    const green = ui.Color.rgb(0.0, 1.0, 0.4);
    const green_dim = ui.Color.rgb(0.0, 0.6, 0.2);
    const orange = ui.Color.rgb(1.0, 0.5, 0.0);
    const red = ui.Color.rgb(1.0, 0.2, 0.2);
    const yellow = ui.Color.rgb(1.0, 0.9, 0.0);

    const text = ui.Color.rgb(0.9, 0.95, 1.0);
    const text_dim = ui.Color.rgb(0.4, 0.5, 0.6);
    const text_glow = ui.Color.rgb(0.7, 0.9, 1.0);
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    // Ship systems
    hull_integrity: u8 = 94,
    shield_power: u8 = 78,
    fuel_level: u8 = 62,
    oxygen_level: u8 = 100,
    reactor_temp: u16 = 847,

    // Navigation
    coordinates: [3]i32 = .{ 247, -89, 1842 },
    velocity: u16 = 12450,
    heading: u16 = 127,

    // Jump drive
    jump_charge: u8 = 0,
    jump_ready: bool = false,
    destination_locked: bool = false,

    // Alerts
    alert_level: AlertLevel = .nominal,
    active_alerts: u8 = 0,

    // Controls
    destination_input: []const u8 = "",
    autopilot_engaged: bool = true,
    shields_active: bool = true,

    // Animation tick
    last_tick: i64 = 0,
    tick_counter: u32 = 0,

    const AlertLevel = enum {
        nominal,
        caution,
        warning,
        critical,

        fn color(self: AlertLevel) ui.Color {
            return switch (self) {
                .nominal => Colors.green,
                .caution => Colors.yellow,
                .warning => Colors.orange,
                .critical => Colors.red,
            };
        }

        fn label(self: AlertLevel) []const u8 {
            return switch (self) {
                .nominal => "NOMINAL",
                .caution => "CAUTION",
                .warning => "WARNING",
                .critical => "CRITICAL",
            };
        }
    };

    pub fn tick(self: *AppState) void {
        const now = platform.time.milliTimestamp();
        if (now - self.last_tick < 500) return;
        self.last_tick = now;
        self.tick_counter +%= 1;

        // Simulate fluctuating values
        const seed = self.tick_counter;
        self.reactor_temp = 840 + @as(u16, @intCast(seed % 20));
        self.velocity = 12400 + @as(u16, @intCast((seed * 7) % 100));

        // Random coordinate drift
        if (seed % 4 == 0) {
            self.coordinates[2] += 1;
        }

        // Jump drive charging
        if (self.jump_charge < 100 and self.destination_locked) {
            self.jump_charge += 2;
            if (self.jump_charge >= 100) {
                self.jump_ready = true;
            }
        }
    }

    pub fn lockDestination(self: *AppState) void {
        if (self.destination_input.len > 0) {
            self.destination_locked = true;
            self.jump_charge = 0;
            self.jump_ready = false;
        }
    }

    pub fn initiateJump(self: *AppState) void {
        if (self.jump_ready) {
            self.jump_charge = 0;
            self.jump_ready = false;
            self.destination_locked = false;
            self.alert_level = .caution;
            self.active_alerts = 1;
        }
    }

    pub fn toggleAutopilot(self: *AppState) void {
        self.autopilot_engaged = !self.autopilot_engaged;
    }

    pub fn toggleShields(self: *AppState) void {
        self.shields_active = !self.shields_active;
        self.shield_power = if (self.shields_active) 78 else 0;
    }

    pub fn boostShields(self: *AppState) void {
        if (self.shields_active and self.shield_power < 100) {
            self.shield_power = @min(100, self.shield_power + 10);
        }
    }

    pub fn emergencyStop(self: *AppState) void {
        self.velocity = 0;
        self.autopilot_engaged = false;
        self.alert_level = .caution;
        self.active_alerts = 1;
    }
};

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        // Fade in header on load
        const fade = cx.animateComptime("header-fade", .{ .duration_ms = 600 });

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 24, .bottom = 16, .left = 24, .right = 24 } },
            .background = Colors.bg_panel.withAlpha(0.9), // * fade.progress),
            .direction = .row,
            .alignment = .{ .cross = .center },
        }, .{
            ShipName{ .opacity = fade.progress },
            ui.spacer(),
            StatusIndicator{},
        }));
    }
};

const ShipName = struct {
    opacity: f32 = 1.0,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            Svg{
                .path = SpaceIcons.ship,
                .size = 28,
                .color = Colors.cyan.withAlpha(self.opacity),
            },
            ui.text("USS AURORA", .{ .size = 22, .color = Colors.text.withAlpha(self.opacity) }),
            ui.text("NCC-1701-G", .{ .size = 12, .color = Colors.text_dim.withAlpha(self.opacity) }),
        }));
    }
};
const StatusIndicator = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        // Pulse effect for non-nominal status
        const pulse = cx.animateComptime("status-pulse", .{
            .duration_ms = 1500,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        // More intense pulse for worse alert levels
        const pulse_intensity: f32 = switch (s.alert_level) {
            .nominal => 0.0,
            .caution => 0.15,
            .warning => 0.25,
            .critical => 0.4,
        };

        const status_alpha = 1.0 - (pulse_intensity * (1.0 - pulse.progress));

        cx.render(ui.hstack(.{ .gap = 16, .alignment = .center }, .{
            ui.text("STATUS:", .{ .size = 12, .color = Colors.text_dim }),
            ui.text(s.alert_level.label(), .{
                .size = 14,
                .color = s.alert_level.color().withAlpha(status_alpha),
            }),
            AlertBadge{},
        }));
    }
};

const AlertBadge = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.active_alerts > 0) {
            // Urgent pulse for alerts
            const pulse = cx.animateComptime("alert-pulse", .{
                .duration_ms = 800,
                .easing = Easing.easeInOut,
                .mode = .ping_pong,
            });

            const scale = 1.0 + pulse.progress * 0.08;
            const glow_alpha = gooey.lerp(0.8, 1.0, pulse.progress);

            cx.render(ui.box(.{
                .padding = .{ .symmetric = .{ .x = 8 * scale, .y = 4 * scale } },
                .background = Colors.red.withAlpha(glow_alpha),
                .corner_radius = 10,
            }, .{
                ui.hstack(.{ .gap = 4, .alignment = .center }, .{
                    Svg{
                        .path = SpaceIcons.alert,
                        .size = 12,
                        .color = ui.Color.white,
                    },
                    ui.textFmt("{} ALERT", .{s.active_alerts}, .{
                        .size = 10,
                        .color = ui.Color.white,
                    }),
                }),
            }));
        }
    }
};

const MainDashboard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .padding = .{ .all = 16 },
            .gap = 16,
            .direction = .row,
        }, .{
            // Left column - Systems
            LeftPanel{},
            // Center - Navigation
            CenterPanel{},
            // Right - Controls
            RightPanel{},
        }));
    }
};

const LeftPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = 220,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "SHIP SYSTEMS", .icon = SpaceIcons.ship },
            SystemGauge{ .label = "HULL", .value = cx.stateConst(AppState).hull_integrity, .color = Colors.cyan, .icon = SpaceIcons.ship },
            SystemGauge{ .label = "SHIELDS", .value = cx.stateConst(AppState).shield_power, .color = Colors.magenta, .icon = SpaceIcons.shield },
            SystemGauge{ .label = "FUEL", .value = cx.stateConst(AppState).fuel_level, .color = Colors.orange, .icon = SpaceIcons.fuel },
            SystemGauge{ .label = "O2", .value = cx.stateConst(AppState).oxygen_level, .color = Colors.green, .icon = SpaceIcons.oxygen },
            ReactorStatus{},
        }));
    }
};

const CenterPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "NAVIGATION", .icon = SpaceIcons.navigation },
            NavigationDisplay{},
            CoordinatesPanel{},
            VelocityDisplay{},
            QuickActions{},
        }));
    }
};

const RightPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = 200,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "CONTROLS", .icon = SpaceIcons.controls },
            ShipControls{},
            JumpDrive{},
        }));
    }
};

const PanelHeader = struct {
    title: []const u8,
    icon: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = Colors.bg_card,
            .corner_radius = 4,
            .direction = .row,
            .gap = 8,
            .alignment = .{ .cross = .center },
        }, .{
            Svg{
                .path = self.icon,
                .size = 14,
                .color = Colors.text_glow,
            },
            ui.text(self.title, .{ .size = 11, .color = Colors.text_glow }),
        }));
    }
};

const JumpDrive = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        const status_color = if (s.jump_ready) Colors.green else if (s.destination_locked) Colors.cyan else Colors.text_dim;
        const status_text = if (s.jump_ready) "READY" else if (s.destination_locked) "CHARGING" else "STANDBY";

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 12,
            .direction = .column,
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.jump_drive,
                    .size = 14,
                    .color = null,
                    .stroke_color = Colors.magenta_dim,
                    .stroke_width = 1.5,
                },
                ui.text("JUMP DRIVE", .{ .size = 10, .color = Colors.magenta_dim }),
            }),
            ui.text(status_text, .{ .size = 12, .color = status_color }),
            JumpChargeRing{},
            JumpButtons{},
        }));
    }
};

const JumpChargeRing = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        // Determine ring state and animation
        const is_charging = s.destination_locked and !s.jump_ready;
        const is_ready = s.jump_ready;

        // Charging animation - faster rotation effect via opacity
        const charge_pulse = cx.animateComptime("jump-charge-pulse", .{
            .duration_ms = if (is_charging) 600 else 2000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        // Ready glow - strong pulse when jump is ready
        const ready_glow = cx.animateOnComptime("jump-ready-glow", is_ready, .{
            .duration_ms = 400,
            .easing = Easing.easeOutBack,
        });

        const base_color = if (is_ready) Colors.green else if (is_charging) Colors.magenta else Colors.magenta_dim;

        // Intensity varies with state
        const intensity: f32 = if (is_ready)
            gooey.lerp(0.2, 0.4, ready_glow.progress)
        else if (is_charging)
            gooey.lerp(0.1, 0.25, charge_pulse.progress)
        else
            0.1;

        // Scale pop when ready
        const scale: f32 = if (is_ready) 1.0 + (1.0 - ready_glow.progress) * 0.1 else 1.0;

        // Choose icon based on state
        const ring_icon = if (is_ready) SpaceIcons.star else if (is_charging) SpaceIcons.target else SpaceIcons.jump_drive;

        cx.render(ui.box(.{
            .width = 80 * scale,
            .height = 80 * scale,
            .background = base_color.withAlpha(intensity),
            .corner_radius = 40 * scale,
            .alignment = .{ .main = .center, .cross = .center },
            .direction = .column,
            .gap = 2,
        }, .{
            Svg{
                .path = ring_icon,
                .size = 18,
                .color = if (is_ready) Colors.green else null,
                .stroke_color = if (is_ready) null else base_color,
                .stroke_width = 1.5,
            },
            ui.textFmt("{}%", .{s.jump_charge}, .{ .size = 18, .color = base_color }),
            JumpDestLabel{},
        }));
    }
};

const JumpDestLabel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.destination_locked) {
            cx.render(ui.box(.{}, .{
                ui.text("LOCKED", .{ .size = 8, .color = Colors.green }),
            }));
        } else {
            cx.render(ui.box(.{}, .{
                ui.text("NO DEST", .{ .size = 8, .color = Colors.text_dim }),
            }));
        }
    }
};

const JumpButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.jump_ready) {
            cx.render(ui.box(.{ .fill_width = true }, .{
                NeonButton{
                    .label = "INITIATE JUMP",
                    .color = Colors.green,
                    .icon = SpaceIcons.jump_drive,
                    .handler = cx.update(AppState, AppState.initiateJump),
                },
            }));
        } else if (!s.destination_locked) {
            cx.render(ui.box(.{ .fill_width = true }, .{
                NeonButton{
                    .label = "LOCK DESTINATION",
                    .color = Colors.magenta,
                    .icon = SpaceIcons.target,
                    .handler = cx.update(AppState, AppState.lockDestination),
                },
            }));
        } else {
            cx.render(ui.box(.{
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.text("» CHARGING «", .{ .size = 10, .color = Colors.magenta_dim }),
            }));
        }
    }
};

const SystemGauge = struct {
    label: []const u8,
    value: u8,
    color: ui.Color,
    icon: []const u8 = SpaceIcons.dashboard,

    pub fn render(self: @This(), cx: *Cx) void {
        const is_critical = self.value <= 30;
        const display_color = if (is_critical) Colors.red else self.color;

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 8,
            .direction = .column,
        }, .{
            ui.box(.{ .direction = .row, .fill_width = true, .alignment = .{ .main = .space_between, .cross = .center } }, .{
                ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                    Svg{
                        .path = self.icon,
                        .size = 14,
                        .color = display_color.withAlpha(0.8),
                    },
                    ui.text(self.label, .{ .size = 11, .color = Colors.text_dim }),
                }),
                ui.textFmt("{}%", .{self.value}, .{
                    .size = 14,
                    .color = display_color,
                }),
            }),
            GaugeBar{ .value = self.value, .color = display_color, .id = self.label },
        }));
    }
};

const GaugeBar = struct {
    value: u8,
    color: ui.Color,
    id: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        // Animate the gauge fill on value changes
        const fill_anim = cx.animateOn(self.id, self.value, .{
            .duration_ms = 300,
            .easing = Easing.easeOutCubic,
        });

        // Smooth transition (though we'd need previous value for true lerp)
        // For now, just add a nice settle effect
        const fill_scale = 0.97 + fill_anim.progress * 0.03;

        const bar_color = if (self.value > 30) self.color else Colors.red;
        const fill_width = @as(f32, @floatFromInt(self.value)) / 100.0 * fill_scale;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = 6,
            .background = Colors.bg_dark,
            .corner_radius = 3,
        }, .{
            ui.box(.{
                .width_percent = fill_width,
                .height = 6,
                .background = bar_color,
                .corner_radius = 3,
            }, .{}),
        }));
    }
};

const ReactorStatus = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        // Pulse intensity based on temperature
        const is_hot = s.reactor_temp > 850;
        const pulse = cx.animateComptime("reactor-pulse", .{
            .duration_ms = if (is_hot) 1000 else 2500,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        const temp_color = if (is_hot) Colors.orange else Colors.green;
        const glow_intensity: f32 = if (is_hot) gooey.lerp(0.8, 1.0, pulse.progress) else 1.0;

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 8,
            .direction = .column,
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.reactor,
                    .size = 14,
                    .color = temp_color.withAlpha(glow_intensity * 0.7),
                },
                ui.text("REACTOR CORE", .{ .size = 10, .color = Colors.text_dim }),
            }),
            ui.textFmt("{}K", .{s.reactor_temp}, .{
                .size = 28,
                .color = temp_color.withAlpha(glow_intensity),
            }),
            ui.text(if (is_hot) "⚠ OVERHEATING" else if (s.reactor_temp > 3500) "HOT" else "NOMINAL", .{
                .size = 9,
                .color = temp_color.withAlpha(0.7),
            }),
        }));
    }
};

const NavigationDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = Colors.bg_card,
            .corner_radius = 8,
            .gap = 20,
            .direction = .column,
            .alignment = .{ .cross = .center },
        }, .{
            // Row of circular displays
            CircleRow{},
            // Autopilot status
            AutopilotStatus{},
        }));
    }
};

const CircleRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.box(.{ .direction = .row, .gap = 24, .alignment = .{ .cross = .center } }, .{
            CircleGauge{ .label = "HDG", .value = s.heading, .color = Colors.cyan, .unit = "deg", .icon = SpaceIcons.heading },
            CircleGauge{ .label = "VEL", .value = @as(u16, @intCast(s.velocity / 100)), .color = Colors.magenta, .unit = "x100", .icon = SpaceIcons.velocity },
            CircleGauge{ .label = "FUEL", .value = s.fuel_level, .color = Colors.orange, .unit = "%", .icon = SpaceIcons.fuel },
        }));
    }
};

const AutopilotStatus = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            Svg{
                .path = SpaceIcons.autopilot,
                .size = 16,
                .color = if (s.autopilot_engaged) Colors.green else Colors.red,
            },
            ui.text(if (s.autopilot_engaged) "AUTOPILOT ENGAGED" else "MANUAL CONTROL", .{
                .size = 11,
                .color = if (s.autopilot_engaged) Colors.green else Colors.text_dim,
            }),
        }));
    }
};

const CircleGauge = struct {
    label: []const u8,
    value: u16,
    color: ui.Color,
    unit: ?[]const u8 = null,
    icon: []const u8 = SpaceIcons.dashboard,

    pub fn render(self: @This(), cx: *Cx) void {
        // All gauges share the same breathing animation - that's fine!
        const breathe = cx.animateComptime("gauge-breathe", .{
            .duration_ms = 3000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        const bg_alpha = gooey.lerp(0.06, 0.12, breathe.progress);

        cx.render(ui.box(.{
            .width = 100,
            .height = 100,
            .background = self.color.withAlpha(bg_alpha),
            .corner_radius = 50,
            .alignment = .{ .main = .center, .cross = .center },
            .direction = .column,
            .gap = 2,
        }, .{
            Svg{
                .path = self.icon,
                .size = 16,
                .color = null,
                .stroke_color = self.color.withAlpha(0.6),
                .stroke_width = 1.5,
            },
            ui.textFmt("{}", .{self.value}, .{ .size = 24, .color = self.color }),
            CircleUnit{ .unit = self.unit },
        }));
    }
};

const CircleUnit = struct {
    unit: ?[]const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        if (self.unit) |u| {
            cx.render(ui.box(.{}, .{
                ui.text(u, .{ .size = 9, .color = Colors.text_dim }),
            }));
        }
    }
};

const CoordinatesPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 12,
            .direction = .column,
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.coords,
                    .size = 14,
                    .color = null,
                    .stroke_color = Colors.magenta_dim,
                    .stroke_width = 1.5,
                },
                ui.text("COORDINATES", .{ .size = 10, .color = Colors.text_dim }),
            }),
            ui.box(.{ .direction = .row, .alignment = .{ .main = .space_around } }, .{
                CoordDisplay{ .axis = "X", .value = s.coordinates[0] },
                CoordDisplay{ .axis = "Y", .value = s.coordinates[1] },
                CoordDisplay{ .axis = "Z", .value = s.coordinates[2] },
            }),
        }));
    }
};

const CoordDisplay = struct {
    axis: []const u8,
    value: i32,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .column,
            .alignment = .{ .cross = .center },
            .gap = 2,
        }, .{
            ui.text(self.axis, .{ .size = 10, .color = Colors.magenta_dim }),
            ui.textFmt("{}", .{self.value}, .{ .size = 18, .color = Colors.text }),
        }));
    }
};

const VelocityDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);
        const vel_color = if (s.velocity > 0) Colors.cyan else Colors.text_dim;

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.velocity,
                    .size = 16,
                    .color = null,
                    .stroke_color = Colors.cyan_dim,
                    .stroke_width = 1.5,
                },
                ui.text("VELOCITY", .{ .size = 11, .color = Colors.text_dim }),
            }),
            ui.hstack(.{ .gap = 4, .alignment = .center }, .{
                ui.textFmt("{}", .{s.velocity}, .{ .size = 24, .color = vel_color }),
                ui.text("km/s", .{ .size = 11, .color = Colors.text_dim }),
            }),
        }));
    }
};

const ShipControls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 12,
            .direction = .column,
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.target,
                    .size = 12,
                    .color = null,
                    .stroke_color = Colors.cyan_dim,
                    .stroke_width = 1.5,
                },
                ui.text("DESTINATION", .{ .size = 10, .color = Colors.text_dim }),
            }),
            TextInput{
                .id = "destination",
                .placeholder = "Enter coordinates...",
                .width = 170,
                .bind = &s.destination_input,
                .background = ui.Color.rgba(0, 0, 0, 0.3),
                .border_color = Colors.cyan_dim,
                .border_color_focused = Colors.cyan,
                .text_color = Colors.text,
                .placeholder_color = Colors.text_dim,
                .corner_radius = 4,
                .padding = 8,
            },
            ToggleRow{},
        }));
    }
};

const ToggleRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 8,
        }, .{
            AutopilotToggle{ .active = s.autopilot_engaged },
            ShieldsToggle{ .active = s.shields_active },
        }));
    }
};

const AutopilotToggle = struct {
    active: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        // Animate toggle state changes
        const toggle_anim = cx.animateOnComptime("autopilot-toggle", self.active, .{
            .duration_ms = 200,
            .easing = Easing.easeOut,
        });

        const target_color = if (self.active) Colors.green else Colors.red;
        // Blend from previous state
        const current_alpha = gooey.lerp(0.1, 0.15, toggle_anim.progress);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
            .background = target_color.withAlpha(current_alpha),
            .corner_radius = 4,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .on_click_handler = cx.update(AppState, AppState.toggleAutopilot),
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.autopilot,
                    .size = 14,
                    .color = target_color,
                },
                ui.text("AUTOPILOT", .{ .size = 11, .color = target_color }),
            }),
            ui.spacer(),
            ToggleStatus{ .active = self.active },
        }));
    }
};

const ShieldsToggle = struct {
    active: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        // Animate toggle state changes
        const toggle_anim = cx.animateOnComptime("shields-toggle", self.active, .{
            .duration_ms = 200,
            .easing = Easing.easeOut,
        });

        const target_color = if (self.active) Colors.green else Colors.red;
        const current_alpha = gooey.lerp(0.1, 0.15, toggle_anim.progress);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
            .background = target_color.withAlpha(current_alpha),
            .corner_radius = 4,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .on_click_handler = cx.update(AppState, AppState.toggleShields),
        }, .{
            ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                Svg{
                    .path = SpaceIcons.shield,
                    .size = 14,
                    .color = target_color,
                },
                ui.text("SHIELDS", .{ .size = 11, .color = target_color }),
            }),
            ui.spacer(),
            ToggleStatus{ .active = self.active },
        }));
    }
};

const ToggleStatus = struct {
    active: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const status_color = if (self.active) Colors.green else Colors.red;
        const status_text = if (self.active) "ON" else "OFF";

        cx.render(ui.box(.{}, .{
            ui.text(status_text, .{ .size = 11, .color = status_color }),
        }));
    }
};

const NeonButton = struct {
    label: []const u8,
    color: ui.Color = Colors.cyan,
    icon: ?[]const u8 = null,
    handler: ?gooey.context.handler.HandlerRef = null,

    pub fn render(self: @This(), cx: *Cx) void {
        // Subtle idle pulse for interactive buttons
        const pulse = cx.animateComptime("btn-pulse", .{
            .duration_ms = 2000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        const bg_alpha = gooey.lerp(0.12, 0.18, pulse.progress);

        if (self.icon) |icon_path| {
            // Button with icon
            cx.render(ui.box(.{
                .fill_width = true,
                .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
                .background = self.color.withAlpha(bg_alpha),
                .corner_radius = 4,
                .direction = .row,
                .gap = 6,
                .alignment = .{ .main = .center, .cross = .center },
                .on_click_handler = self.handler,
            }, .{
                Svg{
                    .path = icon_path,
                    .size = 12,
                    .color = null,
                    .stroke_color = self.color,
                    .stroke_width = 1.5,
                },
                ui.text(self.label, .{ .size = 11, .color = self.color }),
            }));
        } else {
            // Button without icon
            cx.render(ui.box(.{
                .fill_width = true,
                .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
                .background = self.color.withAlpha(bg_alpha),
                .corner_radius = 4,
                .alignment = .{ .main = .center, .cross = .center },
                .on_click_handler = self.handler,
            }, .{
                ui.text(self.label, .{ .size = 11, .color = self.color }),
            }));
        }
    }
};

const QuickActions = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .gap = 8,
            .direction = .row,
        }, .{
            NeonButton{
                .label = "BOOST SHIELDS",
                .color = Colors.cyan,
                .icon = SpaceIcons.boost,
                .handler = cx.update(AppState, AppState.boostShields),
            },
            NeonButton{
                .label = "EMERGENCY STOP",
                .color = Colors.red,
                .icon = SpaceIcons.emergency,
                .handler = cx.update(AppState, AppState.emergencyStop),
            },
        }));
    }
};

const Footer = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 24, .y = 12 } },
            .background = Colors.bg_panel,
            .direction = .row,
            .alignment = .{ .cross = .center },
        }, .{
            FooterVersion{},
            ui.spacer(),
            FooterBrand{},
            ui.spacer(),
            FooterTick{},
        }));
    }
};

const FooterVersion = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 6, .alignment = .center }, .{
            Svg{
                .path = SpaceIcons.dashboard,
                .size = 12,
                .color = null,
                .stroke_color = Colors.text_dim,
                .stroke_width = 1.5,
            },
            ui.text("v2.4.7", .{ .size = 10, .color = Colors.text_dim }),
        }));
    }
};

const FooterBrand = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 6, .alignment = .center }, .{
            Svg{
                .path = SpaceIcons.star,
                .size = 12,
                .color = Colors.cyan_dim,
            },
            ui.text("GOOEY AEROSPACE SYSTEMS", .{ .size = 10, .color = Colors.text_dim }),
            Svg{
                .path = SpaceIcons.star,
                .size = 12,
                .color = Colors.cyan_dim,
            },
        }));
    }
};

const FooterTick = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.box(.{}, .{
            ui.textFmt("TICK: {}", .{s.tick_counter}, .{ .size = 10, .color = Colors.cyan_dim }),
        }));
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var app_state = AppState{};

const App = gooey.App(AppState, &app_state, render, .{
    .title = "Spaceship Dashboard",
    .width = 900,
    .height = 650,
    .custom_shaders = &.{
        .{ .msl = hologram_shader_msl, .wgsl = hologram_shader_wgsl },
        .{ .msl = warp_shader_msl, .wgsl = warp_shader_wgsl },
    },
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    s.tick();

    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = Colors.bg_dark,
        .direction = .column,
    }, .{
        Header{},
        MainDashboard{},
        Footer{},
    }));
}
