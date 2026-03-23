# Mermaid Graph Renderer — Design Document

A Canvas-based graph visualization library for Gooey, structured as a sibling to `gooey-charts`.

## Why Canvas, Not UI Primitives

Gooey's layout engine is flow-based (Clay-inspired flexbox). You cannot position nodes at
arbitrary (x, y) coordinates or draw edges between them with `hstack`/`vstack`/`box`.

The Charts library is the exact template. It is a separate library that takes data, computes
layout internally, and renders via `DrawContext` paint callbacks. A graph renderer follows the
same pattern:

1. Parse Mermaid → graph data structure.
2. Run layout algorithm → node positions + edge routes.
3. Render via `DrawContext` → `fillRoundedRect` for nodes, `polyline`/`strokePath` for edges, `drawText` for labels.

`DrawContext` already has everything needed:

- `fillRoundedRect` — node boxes.
- `line`, `polyline`, `strokePath` — solid edges.
- `fillTriangle` — arrowheads.
- `drawText`, `measureText(text, font_size)` — labels (with real TextSystem support).
- `fillPath` + cubic Béziers — curved edges.
- `beginPath().cubicTo()` — spline edge routing.

**Gap: no dashed/dotted line primitive.** `DrawContext` has no dash pattern support.
Dotted edges (`-.->`) must be implemented in the renderer by emitting short line segments
with gaps. A helper like `drawDashedPolyline(ctx, points, dash_len, gap_len, width, color)`
handles this — walk the polyline, emit `ctx.line(...)` for each dash segment, skip gaps.
This is pure geometry, no DrawContext changes required.

If you tried this with `box`/`hstack`/`vstack`:

- You cannot position a node at pixel (237, 142) — the layout engine does flow positioning.
- You cannot draw a curved edge from one box to another — there is no "connector" primitive.
- Absolute positioning via `FloatingConfig` exists but is not meant for dozens of independently-positioned elements with interconnecting lines.

The Canvas API was designed exactly for this kind of custom visualization. Charts proved the pattern works.

## Proposed Architecture

Structured as `gooey-graphs`, a sibling to `gooey-charts`:

```
gooey-graphs/
  src/
    root.zig                 -- Public API (re-exports everything)
    types.zig                -- Graph, Node, Edge, Subgraph data types
    constants.zig            -- MAX_NODES, MAX_EDGES, etc.
    theme.zig                -- Node/edge colors, fonts, spacing
    parser/
      mod.zig                -- Parser module
      flowchart.zig          -- Mermaid flowchart syntax parser
      tokenizer.zig          -- Lexer for Mermaid syntax
    layout/
      mod.zig                -- Layout module
      sugiyama.zig           -- Layered DAG layout (layer assignment, ordering)
      crossing.zig           -- Edge crossing minimization (barycenter)
      coordinate.zig         -- X-coordinate assignment (Brandes-Köpf)
    renderer.zig             -- DrawContext-based rendering
```

## Data Types

Fixed-capacity, zero allocation at render time. Following the Charts pattern exactly —
`types.zig` with `DataPoint`/`Series` becomes `types.zig` with `GraphNode`/`GraphEdge`:

```zig
const MAX_LABEL_LENGTH = 64;
const MAX_NODES = 256;
const MAX_EDGES = 512;
const MAX_LAYERS = 64;
const MAX_NODES_PER_LAYER = 32;

pub const NodeShape = enum(u8) {
    rectangle,      // [text]
    rounded,        // (text)
    diamond,        // {text}
    circle,         // ((text))
    hexagon,        // {{text}}
    parallelogram,  // [/text/]
    stadium,        // ([text])
};

pub const EdgeStyle = enum(u8) {
    solid,          // -->
    dotted,         // -.->
    thick,          // ==>
};

pub const GraphNode = struct {
    id: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
    id_len: u8 = 0,
    label: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
    label_len: u8 = 0,
    shape: NodeShape = .rectangle,
    color: ?Color = null,

    // Computed by layout (not set by user):
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    layer: u32 = 0,
};

pub const GraphEdge = struct {
    source_index: u16 = 0,
    target_index: u16 = 0,
    style: EdgeStyle = .solid,
    label: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
    label_len: u8 = 0,
    color: ?Color = null,
    reversed: bool = false,   // For cycle breaking
};

pub const Direction = enum(u8) {
    top_to_bottom,  // TD / TB
    bottom_to_top,  // BT
    left_to_right,  // LR
    right_to_left,  // RL
};

pub const Graph = struct {
    nodes: [MAX_NODES]GraphNode = undefined,
    node_count: u16 = 0,
    edges: [MAX_EDGES]GraphEdge = undefined,
    edge_count: u16 = 0,
    direction: Direction = .top_to_bottom,
    // ... addNode(), addEdge(), etc.

    /// Graph is ~90KB (256 × ~176 + 512 × ~88). Exceeds the 50KB WASM stack
    /// threshold from CLAUDE.md. Must be file-level static or heap-allocated —
    /// never a local variable. Follows the same pattern as Charts' Series.
    pub fn initInPlace(self: *Graph, direction: Direction) void {
        self.node_count = 0;
        self.edge_count = 0;
        self.direction = direction;
    }
};
```

## Layout Algorithm: Sugiyama (Layered Graph Drawing)

This is the hard part and the right choice for Mermaid-style diagrams, which are overwhelmingly
DAGs. The algorithm has four phases, each suited to fixed-capacity arrays.

### Phase 1 — Cycle Removal

DFS, reverse back-edges. Use an explicit stack (no recursion per CLAUDE.md). Mark reversed
edges with `edge.reversed = true` so the renderer can flip arrowheads back.

### Phase 2 — Layer Assignment

Longest-path algorithm. Each node gets a `layer: u32`. Store the result in a fixed array:

```zig
layers: [MAX_LAYERS][MAX_NODES_PER_LAYER]u16 = undefined,
layer_counts: [MAX_LAYERS]u16 = [_]u16{0} ** MAX_LAYERS,
layer_count: u16 = 0,
```

### Phase 3 — Crossing Minimization

Barycenter heuristic: for each layer, sort nodes by average position of their neighbors in the
adjacent layer. A few passes (capped at ~24 iterations) converge well. Each pass is O(V + E)
and operates on the fixed `layers` array.

### Phase 4 — X-Coordinate Assignment

Brandes-Köpf or simpler median positioning. Assigns horizontal positions within each layer.
The vertical position comes directly from `layer * layer_spacing`.

All of this is O(V + E) per pass, uses only fixed arrays, and is deterministic. No dynamic
allocation needed.

### Edge Routing

Edges between adjacent layers are straight lines. For edges spanning multiple layers, insert
**virtual nodes** (dummy nodes at intermediate layers) and route through them — this produces
the characteristic stepped/spline edges. With `DrawContext.beginPath().cubicTo()`, you can
make smooth splines through the virtual node positions.

Virtual node budget: use a **separate fixed array** for virtual nodes. This avoids overloading
node indices with two meanings (real vs virtual) and keeps call sites explicit:

```zig
const MAX_VIRTUAL_NODES = 256;

pub const VirtualNode = struct {
    x: f32 = 0,
    y: f32 = 0,
    layer: u32 = 0,
    source_edge: u16 = 0,  // Which edge this dummy belongs to.
};

// In LayoutState:
virtual_nodes: [MAX_VIRTUAL_NODES]VirtualNode = undefined,
virtual_node_count: u16 = 0,
```

## Renderer

Mirrors the Charts `render(ctx: *DrawContext)` pattern:

```zig
pub const FlowchartRenderer = struct {
    graph: *const Graph,
    width: f32 = 800,
    height: f32 = 600,
    node_padding_x: f32 = 16,
    node_padding_y: f32 = 8,
    layer_spacing: f32 = 80,
    node_spacing: f32 = 40,
    font_size: f32 = 14,
    chart_theme: ?*const GraphTheme = null,

    // Layout cache: Sugiyama is ~31µs for 50 nodes — tolerable per frame, but
    // wasteful for static graphs. Cache the result; set dirty on graph mutation.
    layout_computed: bool = false,

    pub fn render(self: *FlowchartRenderer, ctx: *DrawContext) void {
        if (!self.layout_computed) {
            // 1. Measure node sizes (using ctx.measureText for labels).
            self.measureNodes(ctx);

            // 2. Run Sugiyama layout.
            self.computeLayout();

            self.layout_computed = true;
        }

        // 3. Draw edges first (behind nodes).
        self.drawEdges(ctx);

        // 4. Draw nodes on top.
        self.drawNodes(ctx);

        // 5. Draw edge labels.
        self.drawEdgeLabels(ctx);
    }

    /// Invalidate cached layout. Call after modifying the graph.
    pub fn invalidateLayout(self: *FlowchartRenderer) void {
        self.layout_computed = false;
    }
};
```

### Node Drawing

```zig
fn drawNode(ctx: *DrawContext, node: *const GraphNode, theme: *const GraphTheme) void {
    const bg = node.color orelse theme.node_background;
    const fg = theme.node_text_color;

    switch (node.shape) {
        .rectangle => ctx.fillRoundedRect(node.x, node.y, node.width, node.height, 4, bg),
        .rounded => ctx.fillRoundedRect(node.x, node.y, node.width, node.height, 12, bg),
        .diamond => { /* rotated rect via fillPath */ },
        .circle => ctx.fillCircle(cx, cy, r, bg),
        .stadium => ctx.fillRoundedRect(node.x, node.y, node.width, node.height, node.height / 2, bg),
        // ...
    }

    // Stroke border (signature: x, y, w, h, color, stroke_width).
    ctx.strokeRect(node.x, node.y, node.width, node.height, theme.node_border_color, 1.5);

    // Draw label text, centered.
    _ = ctx.drawText(node.getLabel(), text_x, text_y, fg, font_size);
}
```

### Edge Drawing

```zig
fn drawEdge(ctx: *DrawContext, points: []const [2]f32, style: EdgeStyle, color: Color) void {
    const line_width: f32 = switch (style) {
        .solid => 1.5,
        .dotted => 1.0,
        .thick => 3.0,
    };

    // Polyline for the edge body.
    // DrawContext has no dash pattern API, so dotted edges use segmented lines.
    switch (style) {
        .solid, .thick => ctx.polyline(points, line_width, color),
        .dotted => drawDashedPolyline(ctx, points, 6.0, 4.0, line_width, color),
    }

    // Triangle for the arrowhead at the last segment.
    const tip_x = points[points.len - 1][0];
    const tip_y = points[points.len - 1][1];
    // ... compute arrowhead triangle vertices from edge direction.
    ctx.fillTriangle(ax1, ay1, ax2, ay2, tip_x, tip_y, color);
}
```

## Usage Pattern

Mirrors Charts exactly. Graph is ~90KB — must be file-level static or heap-allocated,
never a local variable (per CLAUDE.md: heap-allocate structs >50KB for WASM safety):

```zig
const gooey = @import("gooey");
const graphs = @import("gooey-graphs");
const ui = gooey.ui;

// Static graph data (must outlive paint callback).
// ~90KB — file-level static, never a local variable.
var graph: graphs.Graph = undefined;
var renderer: graphs.FlowchartRenderer = undefined;
var initialized: bool = false;

fn paintGraph(ctx: *graphs.DrawContext) void {
    renderer.render(ctx);
}

fn view(b: *ui.Builder) void {
    if (!initialized) {
        graph.initInPlace(.top_to_bottom);
        const a = graph.addNode("A", "Start", .stadium);
        const b_node = graph.addNode("B", "Process", .rectangle);
        const c = graph.addNode("C", "Decision", .diamond);
        const d = graph.addNode("D", "End", .stadium);
        _ = graph.addEdge(a, b_node, .solid);
        _ = graph.addEdge(b_node, c, .solid);
        _ = graph.addEdge(c, d, .solid);
        renderer = .{ .graph = &graph };
        initialized = true;
    }

    b.box(.{}, .{ ui.canvas(800, 600, paintGraph) });
}
```

### From Mermaid Text (Phase 6)

```zig
const source =
    \\graph TD
    \\    A([Start]) --> B[Process]
    \\    B --> C{Decision}
    \\    C -->|Yes| D([End])
    \\    C -->|No| B
;

var graph: graphs.Graph = undefined;
const ok = graphs.parseMermaid(source, &graph);
// ok is true if parsing succeeded; graph is populated in-place.
```

## Back-of-Envelope Performance Sketch

For a typical Mermaid diagram (50 nodes, 80 edges):

- **Node measurement:** 50 × `measureText(label, font_size)` calls — each is a glyph cache lookup, ~50ns each = ~2.5µs.
- **Sugiyama layout:** O(V + E) × ~24 crossing-reduction passes = ~24 × 130 = ~3,120 iterations. At ~10ns per iteration (array index lookups) = ~31µs.
- **Rendering:**
  - 50 `fillRoundedRect` + 50 `drawText` = 100 scene insertions.
  - 80 edges × ~3 segments average = 80 `polyline` calls + 80 `fillTriangle` = 160 scene insertions.
  - Total: ~260 GPU primitives. Well within a single frame budget.
- **Memory:** `Graph` struct ≈ `256 × sizeof(GraphNode) + 512 × sizeof(GraphEdge)` ≈ 256 × 176 + 512 × 88 ≈ 45KB + 45KB = ~90KB. Layout scratch arrays add ~16KB. Virtual nodes add ~4KB. Total ~110KB — exceeds the 50KB WASM stack threshold; must be file-level static or heap-allocated, never a local variable.

## Phased Implementation Plan

| Phase        | What                                                                | Effort |
| ------------ | ------------------------------------------------------------------- | ------ |
| **Phase 1**  | `types.zig` + `constants.zig` — Graph data structures               | Small  |
| **Phase 2**  | Manual graph construction API (`addNode`, `addEdge`, `initInPlace`) | Small  |
| **Phase 3a** | Sugiyama layout engine (the meaty part)                             | Large  |
| **Phase 3b** | Mermaid parser — parallel with 3a, no dependency                    | Medium |
| **Phase 4**  | `renderer.zig` — Canvas-based drawing (incl. `drawDashedPolyline`)  | Medium |
| **Phase 5**  | `theme.zig` — Light/dark themes, node colors                        | Small  |
| **Phase 6**  | Edge labels, subgraphs, more node shapes                            | Medium |
| **Phase 7**  | Interactivity (hover, click via hit testing)                        | Medium |

Phase 3a is where the real engineering is. But it is also a well-studied algorithm with clear
fixed-capacity implementations. The Sugiyama phases map cleanly to separate ≤70-line functions.
Phase 3b (Mermaid parser) is independent — it produces a `Graph`, the layout consumes it —
so the two can be developed and tested in parallel.

## Open Questions

- **Subgraph support:** Mermaid supports `subgraph` blocks that group nodes visually. This adds
  a nesting dimension to layout. Could be handled by computing sub-layouts and treating each
  subgraph as a mega-node in the parent layout.
- **Sequence diagrams:** A fundamentally different layout (columns for actors, rows for messages).
  Would need a separate renderer, but could share the parser infrastructure and Canvas rendering.
- **Zoom/pan:** For large graphs, scrolling via Gooey's `scroll` container works at the UI level.
  True zoom requires scaling the `DrawContext` and re-rendering at different detail levels.
- **Animation:** Edge drawing animations or node transition animations could use Gooey's
  animation system to interpolate node positions between layout passes.
