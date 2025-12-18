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
const gooey = @import("gooey");

const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const TextInput = gooey.TextInput;
const Easing = gooey.Easing;

/// Holographic scanline + chromatic aberration shader
pub const hologram_shader =
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

/// Subtle warp speed distortion at edges
pub const warp_shader =
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

        cx.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 24, .bottom = 16, .left = 24, .right = 24 } },
            .background = Colors.bg_panel.withAlpha(0.9), // * fade.progress),
            .direction = .row,
            .alignment = .{ .cross = .center },
        }, .{
            ShipName{ .opacity = fade.progress },
            ui.spacer(),
            StatusIndicator{},
        });
    }
};

const ShipName = struct {
    opacity: f32 = 1.0,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            ui.text("USS AURORA", .{ .size = 22, .color = Colors.text.withAlpha(self.opacity) }),
            ui.text("NCC-1701-G", .{ .size = 12, .color = Colors.text_dim.withAlpha(self.opacity) }),
        });
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

        cx.hstack(.{ .gap = 16, .alignment = .center }, .{
            ui.text("STATUS:", .{ .size = 12, .color = Colors.text_dim }),
            ui.text(s.alert_level.label(), .{
                .size = 14,
                .color = s.alert_level.color().withAlpha(status_alpha),
            }),
            AlertBadge{},
        });
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

            cx.box(.{
                .padding = .{ .symmetric = .{ .x = 8 * scale, .y = 4 * scale } },
                .background = Colors.red.withAlpha(glow_alpha),
                .corner_radius = 10,
            }, .{
                ui.textFmt("{} ALERT", .{s.active_alerts}, .{
                    .size = 10,
                    .color = ui.Color.white,
                }),
            });
        }
    }
};

const MainDashboard = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
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
        });
    }
};

const LeftPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .width = 220,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "SHIP SYSTEMS", .icon = "x" },
            SystemGauge{ .label = "HULL", .value = cx.stateConst(AppState).hull_integrity, .color = Colors.cyan },
            SystemGauge{ .label = "SHIELDS", .value = cx.stateConst(AppState).shield_power, .color = Colors.magenta },
            SystemGauge{ .label = "FUEL", .value = cx.stateConst(AppState).fuel_level, .color = Colors.orange },
            SystemGauge{ .label = "O2", .value = cx.stateConst(AppState).oxygen_level, .color = Colors.green },
            ReactorStatus{},
        });
    }
};

const CenterPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .grow = true,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "NAVIGATION", .icon = "◎" },
            NavigationDisplay{},
            CoordinatesPanel{},
            VelocityDisplay{},
            QuickActions{},
        });
    }
};

const RightPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .width = 200,
            .gap = 12,
            .direction = .column,
        }, .{
            PanelHeader{ .title = "CONTROLS", .icon = "⚙" },
            ShipControls{},
            JumpDrive{},
        });
    }
};

const PanelHeader = struct {
    title: []const u8,
    icon: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = Colors.bg_card,
            .corner_radius = 4,
            .direction = .row,
            .gap = 8,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text(self.icon, .{ .size = 14, .color = Colors.cyan }),
            ui.text(self.title, .{ .size = 12, .color = Colors.text_dim }),
        });
    }
};

const JumpDrive = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        const status_color = if (s.jump_ready) Colors.green else if (s.destination_locked) Colors.cyan else Colors.text_dim;
        const status_text = if (s.jump_ready) "READY" else if (s.destination_locked) "CHARGING" else "STANDBY";

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 12,
            .direction = .column,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text("JUMP DRIVE", .{ .size = 10, .color = Colors.magenta_dim }),
            JumpChargeRing{},
            ui.text(status_text, .{ .size = 11, .color = status_color }),
            JumpButtons{},
        });
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

        cx.box(.{
            .width = 80 * scale,
            .height = 80 * scale,
            .background = base_color.withAlpha(intensity),
            .corner_radius = 40 * scale,
            .alignment = .{ .main = .center, .cross = .center },
            .direction = .column,
            .gap = 2,
        }, .{
            ui.textFmt("{}%", .{s.jump_charge}, .{ .size = 22, .color = base_color }),
            JumpDestLabel{},
        });
    }
};

const JumpDestLabel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.destination_locked) {
            cx.box(.{}, .{
                ui.text("LOCKED", .{ .size = 8, .color = Colors.green }),
            });
        } else {
            cx.box(.{}, .{
                ui.text("NO DEST", .{ .size = 8, .color = Colors.text_dim }),
            });
        }
    }
};

const JumpButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        if (s.jump_ready) {
            cx.box(.{ .fill_width = true }, .{
                NeonButton{
                    .label = "INITIATE JUMP",
                    .color = Colors.green,
                    .handler = cx.update(AppState, AppState.initiateJump),
                },
            });
        } else if (!s.destination_locked) {
            cx.box(.{ .fill_width = true }, .{
                NeonButton{
                    .label = "LOCK DESTINATION",
                    .color = Colors.magenta,
                    .handler = cx.update(AppState, AppState.lockDestination),
                },
            });
        } else {
            cx.box(.{
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.text("» CHARGING «", .{ .size = 10, .color = Colors.magenta_dim }),
            });
        }
    }
};

const SystemGauge = struct {
    label: []const u8,
    value: u8,
    color: ui.Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 8,
            .direction = .column,
        }, .{
            cx.box(.{ .direction = .row, .fill_width = true, .alignment = .{ .main = .space_between, .cross = .center } }, .{
                ui.text(self.label, .{ .size = 11, .color = Colors.text_dim }),
                ui.textFmt("{}%", .{self.value}, .{
                    .size = 14,
                    .color = if (self.value > 30) self.color else Colors.red,
                }),
            }),
            GaugeBar{ .value = self.value, .color = self.color, .id = self.label },
        });
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

        cx.box(.{
            .fill_width = true,
            .height = 6,
            .background = ui.Color.rgba(1, 1, 1, 0.1),
            .corner_radius = 3,
        }, .{
            cx.box(.{
                .width = fill_width,
                .height = 6,
                .background = bar_color,
                .corner_radius = 3,
            }, .{}),
        });
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

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 4,
            .direction = .column,
            .alignment = .{ .cross = .center },
        }, .{
            ui.text("REACTOR CORE", .{ .size = 10, .color = Colors.text_dim }),
            ui.textFmt("{}K", .{s.reactor_temp}, .{
                .size = 28,
                .color = temp_color.withAlpha(glow_intensity),
            }),
            ui.text(if (is_hot) "ELEVATED" else "FUSION STABLE", .{
                .size = 9,
                .color = if (is_hot) Colors.orange.withAlpha(glow_intensity) else Colors.green_dim,
            }),
        });
    }
};

const NavigationDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
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
        });
    }
};

const CircleRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.box(.{ .direction = .row, .gap = 24, .alignment = .{ .cross = .center } }, .{
            CircleGauge{ .label = "HDG", .value = s.heading, .color = Colors.cyan, .unit = "deg" },
            CircleGauge{ .label = "VEL", .value = @as(u16, @intCast(s.velocity / 100)), .color = Colors.magenta, .unit = "x100" },
            CircleGauge{ .label = "FUEL", .value = s.fuel_level, .color = Colors.orange, .unit = "%" },
        });
    }
};

const AutopilotStatus = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("-", .{
                .size = 12,
                .color = if (s.autopilot_engaged) Colors.green else Colors.red,
            }),
            ui.text(if (s.autopilot_engaged) "AUTOPILOT ENGAGED" else "MANUAL CONTROL", .{
                .size = 11,
                .color = if (s.autopilot_engaged) Colors.green else Colors.text_dim,
            }),
        });
    }
};

const CircleGauge = struct {
    label: []const u8,
    value: u16,
    color: ui.Color,
    unit: ?[]const u8 = null,

    pub fn render(self: @This(), cx: *Cx) void {
        // All gauges share the same breathing animation - that's fine!
        const breathe = cx.animateComptime("gauge-breathe", .{
            .duration_ms = 3000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        const bg_alpha = gooey.lerp(0.06, 0.12, breathe.progress);

        cx.box(.{
            .width = 100,
            .height = 100,
            .background = self.color.withAlpha(bg_alpha),
            .corner_radius = 50,
            .alignment = .{ .main = .center, .cross = .center },
            .direction = .column,
            .gap = 2,
        }, .{
            ui.text(self.label, .{ .size = 10, .color = Colors.text_dim }),
            ui.textFmt("{}", .{self.value}, .{ .size = 24, .color = self.color }),
            CircleUnit{ .unit = self.unit },
        });
    }
};

const CircleUnit = struct {
    unit: ?[]const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        if (self.unit) |u| {
            cx.box(.{}, .{
                ui.text(u, .{ .size = 9, .color = Colors.text_dim }),
            });
        }
    }
};

const CoordinatesPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .direction = .row,
            .alignment = .{ .main = .space_around },
        }, .{
            CoordDisplay{ .axis = "X", .value = s.coordinates[0] },
            CoordDisplay{ .axis = "Y", .value = s.coordinates[1] },
            CoordDisplay{ .axis = "Z", .value = s.coordinates[2] },
        });
    }
};

const CoordDisplay = struct {
    axis: []const u8,
    value: i32,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .column,
            .alignment = .{ .cross = .center },
            .gap = 2,
        }, .{
            ui.text(self.axis, .{ .size = 10, .color = Colors.magenta_dim }),
            ui.textFmt("{}", .{self.value}, .{ .size = 18, .color = Colors.text }),
        });
    }
};

const VelocityDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);
        const vel_color = if (s.velocity > 0) Colors.cyan else Colors.text_dim;

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        }, .{
            ui.text("VELOCITY", .{ .size = 11, .color = Colors.text_dim }),
            cx.hstack(.{ .gap = 4, .alignment = .center }, .{
                ui.textFmt("{}", .{s.velocity}, .{ .size = 24, .color = vel_color }),
                ui.text("km/s", .{ .size = 11, .color = Colors.text_dim }),
            }),
        });
    }
};

const ShipControls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.box(.{
            .fill_width = true,
            .padding = .{ .all = 12 },
            .background = Colors.bg_card,
            .corner_radius = 6,
            .gap = 12,
            .direction = .column,
        }, .{
            ui.text("DESTINATION", .{ .size = 10, .color = Colors.text_dim }),
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
        });
    }
};

const ToggleRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 8,
        }, .{
            AutopilotToggle{ .active = s.autopilot_engaged },
            ShieldsToggle{ .active = s.shields_active },
        });
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

        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
            .background = target_color.withAlpha(current_alpha),
            .corner_radius = 4,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .on_click_handler = cx.update(AppState, AppState.toggleAutopilot),
        }, .{
            ui.text("AUTOPILOT", .{ .size = 11, .color = target_color }),
            ui.spacer(),
            ToggleStatus{ .active = self.active },
        });
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

        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
            .background = target_color.withAlpha(current_alpha),
            .corner_radius = 4,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .on_click_handler = cx.update(AppState, AppState.toggleShields),
        }, .{
            ui.text("SHIELDS", .{ .size = 11, .color = target_color }),
            ui.spacer(),
            ToggleStatus{ .active = self.active },
        });
    }
};

const ToggleStatus = struct {
    active: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const status_color = if (self.active) Colors.green else Colors.red;
        const status_text = if (self.active) "ON" else "OFF";

        cx.box(.{}, .{
            ui.text(status_text, .{ .size = 11, .color = status_color }),
        });
    }
};

const NeonButton = struct {
    label: []const u8,
    color: ui.Color = Colors.cyan,
    handler: ?gooey.core.handler.HandlerRef = null,

    pub fn render(self: @This(), cx: *Cx) void {
        // Subtle idle pulse for interactive buttons
        const pulse = cx.animateComptime("btn-pulse", .{
            .duration_ms = 2000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        const bg_alpha = gooey.lerp(0.12, 0.18, pulse.progress);

        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
            .background = self.color.withAlpha(bg_alpha),
            .corner_radius = 4,
            .alignment = .{ .main = .center, .cross = .center },
            .on_click_handler = self.handler,
        }, .{
            ui.text(self.label, .{ .size = 11, .color = self.color }),
        });
    }
};

const QuickActions = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .fill_width = true,
            .gap = 8,
            .direction = .row,
        }, .{
            NeonButton{
                .label = "BOOST SHIELDS",
                .color = Colors.cyan,
                .handler = cx.update(AppState, AppState.boostShields),
            },
            NeonButton{
                .label = "EMERGENCY STOP",
                .color = Colors.red,
                .handler = cx.update(AppState, AppState.emergencyStop),
            },
        });
    }
};

const Footer = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
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
        });
    }
};

const FooterVersion = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{}, .{
            ui.text("v2.4.7", .{ .size = 10, .color = Colors.text_dim }),
        });
    }
};

const FooterBrand = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{}, .{
            ui.text("GOOEY AEROSPACE SYSTEMS", .{ .size = 10, .color = Colors.text_dim }),
        });
    }
};

const FooterTick = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.box(.{}, .{
            ui.textFmt("TICK: {}", .{s.tick_counter}, .{ .size = 10, .color = Colors.cyan_dim }),
        });
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
    .custom_shaders = &.{ hologram_shader, warp_shader },
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

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .background = Colors.bg_dark,
        .direction = .column,
    }, .{
        Header{},
        MainDashboard{},
        Footer{},
    });
}
