Tree-sitter Integration: Revised Implementation Plan

## Overview

| Phase                     | Work                                      | Time           |
| ------------------------- | ----------------------------------------- | -------------- |
| **1. Core Primitives**    | `StyledRun`, `renderStyledText`, callback | 2-3 days       |
| **2. Package Scaffold**   | `gooey-syntax` structure, build.zig       | 1-2 days       |
| **3. Interface & Theme**  | `Highlighter` trait, `SyntaxTheme`        | 2 days         |
| **4. Tree-sitter Native** | C FFI, grammars, queries                  | 5-7 days       |
| **5. Tree-sitter WASM**   | JS bridge, web-tree-sitter                | 5-7 days       |
| **6. Integration**        | Wire into CodeEditor, examples            | 2-3 days       |
| **Total**                 |                                           | **17-24 days** |

---

## Phase 1: Core Primitives (2-3 days)

**Goal:** Minimal additions to gooey core.

### 1.1 `StyledRun` type

**File:** `gooey/src/text/types.zig`

```/dev/null/types.zig#L1-15
const Hsla = @import("../core/mod.zig").Hsla;

/// A styled run of text - generic primitive for per-range coloring
pub const StyledRun = struct {
    start: usize,
    end: usize,
    color: Hsla,

    pub fn init(start: usize, end: usize, color: Hsla) StyledRun {
        std.debug.assert(start <= end);
        return .{ .start = start, .end = end, .color = color };
    }
};
```

### 1.2 `renderStyledText` function

**File:** `gooey/src/text/render.zig`

- Shape text once
- Iterate glyphs, lookup color from sorted runs by `cluster` (byte offset)
- ~60 lines, mirrors existing `renderText`

### 1.3 Callback in CodeEditor

**File:** `gooey/src/widgets/code_editor_state.zig`

```/dev/null/code_editor_state.zig#L1-15
pub const HighlightFn = *const fn (
    ctx: *anyopaque,
    text: []const u8,
    visible_start: usize,
    visible_end: usize,
    out: []StyledRun,
) usize;

// Add to CodeEditorState:
highlight_fn: ?HighlightFn = null,
highlight_ctx: ?*anyopaque = null,
styled_runs: [MAX_HIGHLIGHT_SPANS]StyledRun = undefined,
```

### Deliverables

- [ ] `StyledRun` in `text/types.zig`
- [ ] `renderStyledText` in `text/render.zig`
- [ ] `HighlightFn` callback in `CodeEditorState`
- [ ] Wire into `renderHighlightedContent`
- [ ] Export in `text/mod.zig`

---

## Phase 2: Package Scaffold (1-2 days)

**Goal:** Create `gooey-syntax` package.

```/dev/null/tree#L1-15
gooey-syntax/
├── build.zig
├── build.zig.zon
├── src/
│   ├── root.zig
│   ├── highlighter.zig
│   ├── theme.zig
│   └── backends/
│       ├── tree_sitter.zig   # Native
│       └── web.zig           # WASM
├── queries/
│   └── zig/highlights.scm
└── README.md
```

**File:** `gooey-syntax/build.zig.zon`

```/dev/null/build.zig.zon#L1-12
.{
    .name = .gooey_syntax,
    .version = "0.0.1",
    .dependencies = .{
        .gooey = .{ .path = "../gooey" },
        .tree_sitter = .{
            .url = "git+https://github.com/tree-sitter/zig-tree-sitter.git#...",
            .hash = "...",
        },
    },
}
```

### Deliverables

- [ ] Package structure
- [ ] `build.zig` with tree-sitter linking
- [ ] `root.zig` exports

---

## Phase 3: Interface & Theme (2 days)

**Goal:** Public API for highlighters.

### 3.1 Highlighter interface

**File:** `gooey-syntax/src/highlighter.zig`

```/dev/null/highlighter.zig#L1-35
const gooey = @import("gooey");
const StyledRun = gooey.text.StyledRun;
const SyntaxTheme = @import("theme.zig").SyntaxTheme;

pub const Highlighter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, text: []const u8) void,
        highlight: *const fn (
            ptr: *anyopaque,
            start: usize,
            end: usize,
            theme: *const SyntaxTheme,
            out: []StyledRun,
        ) usize,
        language: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn update(self: Highlighter, text: []const u8) void {
        self.vtable.update(self.ptr, text);
    }

    pub fn highlight(self: Highlighter, start: usize, end: usize, theme: *const SyntaxTheme, out: []StyledRun) usize {
        return self.vtable.highlight(self.ptr, start, end, theme, out);
    }

    pub fn deinit(self: Highlighter) void {
        self.vtable.deinit(self.ptr);
    }
};
```

### 3.2 Theme with capture mapping

**File:** `gooey-syntax/src/theme.zig`

```/dev/null/theme.zig#L1-50
const gooey = @import("gooey");
const Hsla = gooey.Hsla;
const std = @import("std");

pub const SyntaxTheme = struct {
    keyword: Hsla,
    builtin: Hsla,
    function: Hsla,
    type_name: Hsla,
    variable: Hsla,
    string: Hsla,
    number: Hsla,
    comment: Hsla,
    operator: Hsla,
    punctuation: Hsla,
    default: Hsla,

    /// Map tree-sitter capture name to color
    pub fn colorForCapture(self: *const SyntaxTheme, name: []const u8) Hsla {
        if (std.mem.startsWith(u8, name, "keyword")) return self.keyword;
        if (std.mem.startsWith(u8, name, "function")) return self.function;
        if (std.mem.startsWith(u8, name, "type")) return self.type_name;
        if (std.mem.startsWith(u8, name, "string")) return self.string;
        if (std.mem.startsWith(u8, name, "number")) return self.number;
        if (std.mem.startsWith(u8, name, "comment")) return self.comment;
        if (std.mem.startsWith(u8, name, "operator")) return self.operator;
        if (std.mem.startsWith(u8, name, "variable")) return self.variable;
        if (std.mem.startsWith(u8, name, "punctuation")) return self.punctuation;
        return self.default;
    }

    pub const dracula = SyntaxTheme{
        .keyword = Hsla.fromHex(0xff79c6ff),
        .builtin = Hsla.fromHex(0x8be9fdff),
        .function = Hsla.fromHex(0x50fa7bff),
        .type_name = Hsla.fromHex(0x8be9fdff),
        .variable = Hsla.fromHex(0xf8f8f2ff),
        .string = Hsla.fromHex(0xf1fa8cff),
        .number = Hsla.fromHex(0xbd93f9ff),
        .comment = Hsla.fromHex(0x6272a4ff),
        .operator = Hsla.fromHex(0xff79c6ff),
        .punctuation = Hsla.fromHex(0xf8f8f2ff),
        .default = Hsla.fromHex(0xf8f8f2ff),
    };

    pub const one_dark = SyntaxTheme{ /* ... */ };
};
```

### Deliverables

- [ ] `Highlighter` interface
- [ ] `SyntaxTheme` with `colorForCapture`
- [ ] Dracula, One Dark presets

---

## Phase 4: Tree-sitter Native (5-7 days)

**Goal:** Full tree-sitter integration for macOS/Linux.

### 4.1 Build integration

**File:** `gooey-syntax/build.zig` (excerpt)

```/dev/null/build.zig#L1-30
const ts_dep = b.dependency("tree_sitter", .{
    .target = target,
    .optimize = optimize,
});

mod.linkLibrary(ts_dep.artifact("tree-sitter"));

// Embed Zig grammar
const zig_grammar = b.dependency("tree_sitter_zig", .{});
mod.addImport("tree_sitter_zig", zig_grammar.module("tree-sitter-zig"));

// Embed query files
mod.addAnonymousImport("zig_highlights_scm", .{
    .root_source_file = b.path("queries/zig/highlights.scm"),
});
```

### 4.2 Tree-sitter wrapper

**File:** `gooey-syntax/src/backends/tree_sitter.zig`

```/dev/null/tree_sitter.zig#L1-90
const std = @import("std");
const gooey = @import("gooey");
const StyledRun = gooey.text.StyledRun;
const SyntaxTheme = @import("../theme.zig").SyntaxTheme;
const Highlighter = @import("../highlighter.zig").Highlighter;

const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const TreeSitterHighlighter = struct {
    allocator: std.mem.Allocator,
    parser: *ts.TSParser,
    tree: ?*ts.TSTree = null,
    query: *ts.TSQuery,
    language_name: []const u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        language: *ts.TSLanguage,
        query_source: []const u8,
        name: []const u8,
    ) !Self {
        const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
        errdefer ts.ts_parser_delete(parser);

        if (!ts.ts_parser_set_language(parser, language)) {
            return error.IncompatibleLanguage;
        }

        var err_offset: u32 = 0;
        var err_type: ts.TSQueryError = .TSQueryErrorNone;
        const query = ts.ts_query_new(
            language,
            query_source.ptr,
            @intCast(query_source.len),
            &err_offset,
            &err_type,
        ) orelse return error.QueryParseFailed;

        return .{
            .allocator = allocator,
            .parser = parser,
            .query = query,
            .language_name = name,
        };
    }

    pub fn update(self: *Self, text: []const u8) void {
        if (self.tree) |old| ts.ts_tree_delete(old);
        self.tree = ts.ts_parser_parse_string(
            self.parser,
            null,
            text.ptr,
            @intCast(text.len),
        );
    }

    pub fn highlight(
        self: *Self,
        start: usize,
        end: usize,
        theme: *const SyntaxTheme,
        out: []StyledRun,
    ) usize {
        const tree = self.tree orelse return 0;
        const cursor = ts.ts_query_cursor_new() orelse return 0;
        defer ts.ts_query_cursor_delete(cursor);

        ts.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        ts.ts_query_cursor_exec(cursor, self.query, ts.ts_tree_root_node(tree));

        var match: ts.TSQueryMatch = undefined;
        var count: usize = 0;

        while (ts.ts_query_cursor_next_match(cursor, &match) and count < out.len) {
            for (match.captures[0..match.capture_count]) |cap| {
                var name_len: u32 = 0;
                const name_ptr = ts.ts_query_capture_name_for_id(self.query, cap.index, &name_len);
                const name = name_ptr[0..name_len];

                out[count] = StyledRun.init(
                    ts.ts_node_start_byte(cap.node),
                    ts.ts_node_end_byte(cap.node),
                    theme.colorForCapture(name),
                );
                count += 1;
                if (count >= out.len) break;
            }
        }
        return count;
    }

    pub fn deinit(self: *Self) void {
        if (self.tree) |t| ts.ts_tree_delete(t);
        ts.ts_query_delete(self.query);
        ts.ts_parser_delete(self.parser);
    }

    pub fn highlighter(self: *Self) Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Highlighter.VTable{
        .update = @ptrCast(&update),
        .highlight = @ptrCast(&highlight),
        .language = langFn,
        .deinit = @ptrCast(&deinit),
    };

    fn langFn(ptr: *anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.language_name;
    }
};
```

### 4.3 Query file

**File:** `gooey-syntax/queries/zig/highlights.scm`

```/dev/null/highlights.scm#L1-30
; Keywords
["const" "var" "fn" "pub" "struct" "enum" "union" "error"] @keyword
["if" "else" "while" "for" "switch" "break" "continue" "return" "defer"] @keyword
["try" "catch" "orelse"] @keyword
["comptime" "inline" "noalias" "volatile" "allowzero"] @keyword

; Builtins (@...)
((IDENTIFIER) @builtin (#match? @builtin "^@"))

; Types (PascalCase heuristic)
((IDENTIFIER) @type (#match? @type "^[A-Z][a-zA-Z0-9]*$"))

; Functions
(call_expression function: (IDENTIFIER) @function)
(function_declaration name: (IDENTIFIER) @function)

; Literals
(string_literal) @string
(char_literal) @string
(number_literal) @number
["true" "false"] @number
["null" "undefined"] @number

; Comments
(line_comment) @comment
```

### Deliverables

- [ ] `TreeSitterHighlighter` struct
- [ ] Build integration with `zig-tree-sitter`
- [ ] Zig grammar + highlights.scm
- [ ] Factory function: `createHighlighter("zig")`
- [ ] Tests

---

## Phase 5: Tree-sitter WASM (5-7 days)

**Goal:** JavaScript bridge using web-tree-sitter.

### 5.1 JavaScript side

**File:** `gooey-syntax/web/syntax.js`

```/dev/null/syntax.js#L1-50
import Parser from 'web-tree-sitter';

const parsers = new Map();
const trees = new Map();
const queries = new Map();
let nextHandle = 1;

export async function initHighlighter(langName) {
    await Parser.init();
    const parser = new Parser();
    const lang = await Parser.Language.load(`/grammars/tree-sitter-${langName}.wasm`);
    parser.setLanguage(lang);

    const querySource = await fetch(`/queries/${langName}/highlights.scm`).then(r => r.text());
    const query = lang.query(querySource);

    const handle = nextHandle++;
    parsers.set(handle, parser);
    queries.set(handle, query);
    return handle;
}

export function updateText(handle, text) {
    const parser = parsers.get(handle);
    const oldTree = trees.get(handle);
    const newTree = parser.parse(text, oldTree);
    trees.set(handle, newTree);
}

export function getHighlights(handle, start, end, outPtr, maxRuns) {
    const tree = trees.get(handle);
    const query = queries.get(handle);
    if (!tree || !query) return 0;

    const captures = query.captures(tree.rootNode, { startIndex: start, endIndex: end });
    const runs = [];

    for (const { node, name } of captures) {
        if (runs.length >= maxRuns) break;
        runs.push({
            start: node.startIndex,
            end: node.endIndex,
            capture: name,
        });
    }

    // Write to WASM memory at outPtr
    writeRunsToMemory(outPtr, runs);
    return runs.length;
}
```

### 5.2 Zig extern bindings

**File:** `gooey-syntax/src/backends/web.zig`

```/dev/null/web.zig#L1-60
const std = @import("std");
const gooey = @import("gooey");
const StyledRun = gooey.text.StyledRun;
const SyntaxTheme = @import("../theme.zig").SyntaxTheme;
const Highlighter = @import("../highlighter.zig").Highlighter;

// JS imports
extern "env" fn js_syntax_init(lang_ptr: [*]const u8, lang_len: u32) u32;
extern "env" fn js_syntax_update(handle: u32, text_ptr: [*]const u8, text_len: u32) void;
extern "env" fn js_syntax_highlight(
    handle: u32,
    start: u32,
    end: u32,
    out_ptr: [*]WebRun,
    max_runs: u32,
) u32;

const WebRun = extern struct {
    start: u32,
    end: u32,
    capture_ptr: [*]const u8,
    capture_len: u32,
};

pub const WebHighlighter = struct {
    handle: u32,
    language_name: []const u8,

    const Self = @This();

    pub fn init(language: []const u8) !Self {
        const handle = js_syntax_init(language.ptr, @intCast(language.len));
        if (handle == 0) return error.InitFailed;
        return .{ .handle = handle, .language_name = language };
    }

    pub fn update(self: *Self, text: []const u8) void {
        js_syntax_update(self.handle, text.ptr, @intCast(text.len));
    }

    pub fn highlight(
        self: *Self,
        start: usize,
        end: usize,
        theme: *const SyntaxTheme,
        out: []StyledRun,
    ) usize {
        var web_runs: [4096]WebRun = undefined;
        const count = js_syntax_highlight(
            self.handle,
            @intCast(start),
            @intCast(end),
            &web_runs,
            @intCast(@min(out.len, web_runs.len)),
        );

        for (web_runs[0..count], 0..) |wr, i| {
            const capture = wr.capture_ptr[0..wr.capture_len];
            out[i] = StyledRun.init(wr.start, wr.end, theme.colorForCapture(capture));
        }
        return count;
    }

    pub fn highlighter(self: *Self) Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Highlighter.VTable{ /* ... */ };
};
```

### Deliverables

- [ ] JavaScript `syntax.js` module
- [ ] `WebHighlighter` Zig struct
- [ ] Memory protocol for passing runs
- [ ] Pre-compiled `.wasm` grammars (fetch or bundle)
- [ ] Integration with existing `web/index.html`

---

## Phase 6: Integration (2-3 days)

**Goal:** Wire everything together, examples.

### 6.1 Factory function

**File:** `gooey-syntax/src/root.zig`

```/dev/null/root.zig#L1-30
const std = @import("std");
const builtin = @import("builtin");
const Highlighter = @import("highlighter.zig").Highlighter;

pub const SyntaxTheme = @import("theme.zig").SyntaxTheme;

const is_wasm = builtin.cpu.arch == .wasm32;

pub fn createHighlighter(allocator: std.mem.Allocator, language: []const u8) !Highlighter {
    if (is_wasm) {
        const web = @import("backends/web.zig");
        const hl = try allocator.create(web.WebHighlighter);
        hl.* = try web.WebHighlighter.init(language);
        return hl.highlighter();
    } else {
        const ts = @import("backends/tree_sitter.zig");
        const hl = try allocator.create(ts.TreeSitterHighlighter);
        hl.* = try ts.TreeSitterHighlighter.initForLanguage(allocator, language);
        return hl.highlighter();
    }
}

// Re-exports
pub const TreeSitterHighlighter = @import("backends/tree_sitter.zig").TreeSitterHighlighter;
pub const WebHighlighter = @import("backends/web.zig").WebHighlighter;
```

### 6.2 Example usage

**File:** `my_app/src/main.zig`

```/dev/null/main.zig#L1-35
const gooey = @import("gooey");
const syntax = @import("gooey-syntax");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create editor
    var editor = gooey.widgets.CodeEditorState.init(allocator, bounds);
    editor.setText(zig_source_code);

    // Create highlighter
    var highlighter = try syntax.createHighlighter(allocator, "zig");
    defer highlighter.deinit();

    const theme = syntax.SyntaxTheme.dracula;

    // Wire callback
    editor.highlight_fn = struct {
        fn cb(ctx: *anyopaque, text: []const u8, start: usize, end: usize, out: []gooey.text.StyledRun) usize {
            const hl: *syntax.Highlighter = @ptrCast(@alignCast(ctx));
            const th: *const syntax.SyntaxTheme = // ...
            hl.update(text);
            return hl.highlight(start, end, th, out);
        }
    }.cb;
    editor.highlight_ctx = @ptrCast(&highlighter);

    // Run app...
}
```

### Deliverables

- [ ] `createHighlighter` factory
- [ ] Example: syntax-highlighted CodeEditor
- [ ] Documentation / README
- [ ] CI for native + WASM builds

---

## Summary

| Phase                 | Days      | Dependencies               |
| --------------------- | --------- | -------------------------- |
| 1. Core Primitives    | 2-3       | None                       |
| 2. Package Scaffold   | 1-2       | Phase 1                    |
| 3. Interface & Theme  | 2         | Phase 2                    |
| 4. Tree-sitter Native | 5-7       | Phase 3, `zig-tree-sitter` |
| 5. Tree-sitter WASM   | 5-7       | Phase 3, `web-tree-sitter` |
| 6. Integration        | 2-3       | Phase 4 or 5               |
| **Total**             | **17-24** |                            |

Phases 4 and 5 can run in parallel if you have bandwidth.
