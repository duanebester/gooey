# Gooey Gen UI Design

High-level design for `gooey-genui`, an optional Zig library that composes
catalog-constrained Gooey interfaces with a decision model such as Jev.

## Status

**Experimental implementation.** The first vertical slice is available as the
optional `gooey-genui` sibling package. It provides bounded composition,
validation, native rendering, interaction state, and direct TypeSafe Jev
evaluation. The API and wire format may still change as the package is
exercised by applications such as `chat-zig`.

## Summary

`gooey-genui` lets an application declare trusted UI candidates and actions at
compile time. At runtime, Jev chooses which candidates to use and how to arrange
them. The library validates those choices, builds a bounded component tree, and
renders it with Gooey. Generated data can select trusted behavior, but it can
never introduce executable code.

The design borrows json-render's catalog/registry separation and its
experimental Jev composition strategy. It does not initially promise wire or
API compatibility with json-render. Unlike json-render's experiment, this
library calls TypeSafe's API directly and has no Vercel AI Gateway integration.

```diagram
┌──────────────┐   prompt + choices   ┌───────────────┐
│ Application  │─────────────────────▶│ Jev evaluator │
│ candidate set│◀─────────────────────│               │
└──────┬───────┘    typed decisions   └───────────────┘
       │
       ▼
┌──────────────┐   validated tree   ┌────────────────┐
│ Composer     │───────────────────▶│ Gooey renderer │
│ fixed bounds │                    │ + native a11y  │
└──────────────┘                    └───────┬────────┘
                                           │ allowlisted event
                                           ▼
                                    ┌──────────────┐
                                    │ Host action  │
                                    └──────────────┘
```

Jev is a decision model, not a text generator. It receives state and typed
questions, then returns choices and confidence values. The host—not Jev—owns
component definitions, props, actions, validation, and tree construction. This
is a particularly good fit for Gooey's static-allocation and bounded-work
requirements.

## Goals

1. Compose native, interactive Gooey UI from an application-defined catalog.
2. Keep model output constrained to candidate IDs, counts, and relationships.
3. Allocate all long-lived and frame-path storage during initialization.
4. Put explicit limits on input, candidates, nodes, depth, strings, state,
   actions, model calls, and render work.
5. Preserve Gooey accessibility, focus, themes, and native controls.
6. Keep the core composer model-neutral while providing a first-class Jev
   evaluator adapter.
7. Make composition testable without a network, GPU, or Gooey window.

## Non-Goals for Version 1

- Letting a model generate Zig, shaders, URLs, filesystem paths, or callbacks.
- Arbitrary model-authored component props or prose.
- Full json-render compatibility, JSON Patch streaming, watchers, repeats,
  computed values, or custom directives.
- Running model requests on the UI/render thread.
- Hiding asynchronous control flow inside the library.
- Replacing Gooey's existing hand-authored component API.
- Supporting recursive or cyclic UI graphs.

The lack of arbitrary generated prose is intentional: Jev composes a supplied
candidate set. An application that needs novel copy must prepare bounded text
candidates itself. Combining an LLM candidate-authoring pass with Jev selection
is a possible later layer, not part of the trusted composition core.

## Related Work

The two relevant public Jev experiments use different levels of control:

| Project | Jev role | Transport | Output |
| --- | --- | --- | --- |
| json-render | Select candidates, counts, root, and layout | Vercel AI Gateway | Catalog-constrained component tree |
| CopilotKit cookbook | Select one prepared panel and rank its options | Direct TypeSafe API/SDK | Application-owned panel state |

No Jev integration was found in either active project commonly called OpenUI:
[`thesysdev/openui`](https://github.com/thesysdev/openui) or
[`wandb/openui`](https://github.com/wandb/openui). OpenUI Lang uses a language
model to generate a compact streaming UI language; it is not a Jev decision
composer. Open-JSON-UI and the CopilotKit Jev cookbook are also separate work.

The CopilotKit cookbook is useful precedent for this library's direct TypeSafe
transport and strict host ownership. It sends one control `choice` plus one
`score` question per candidate in a single call, validates every answer, then
maps the result to prepared UI. It does not build arbitrary component trees.
`gooey-genui` combines that direct transport boundary with json-render's
bounded tree-composition strategy.

## Package Boundary

The library should be an optional package beside `gooey-charts`, not part of
Gooey's core module:

```text
genui/
├── README.md
├── build.zig
├── build.zig.zon
└── src/
    ├── root.zig
    ├── core.zig
    ├── renderer.zig
    ├── jev/
    │   ├── client.zig
    │   ├── codec.zig
    │   ├── evaluator.zig
    │   └── live_smoke.zig
```

The build exposes one user-facing module, `gooey-genui`. Internally it has three
layers:

| Layer | Responsibility | Depends on Gooey? |
| --- | --- | --- |
| Core | Catalog metadata, values, candidates, composition, validation | No |
| Jev adapter | Typed questions, request/response codec, evaluator interface | No |
| Gooey adapter | Component registry, event bridge, iterative rendering | Yes |

The application owns credentials, retry policy, and worker threads. The Jev
client speaks TypeSafe's HTTP API directly and accepts caller-owned I/O so
`chat-zig` can use its existing worker rather than introducing a second
networking stack. There is no provider or gateway abstraction in the network
path.

## Core Model

### Catalog

A catalog is the compile-time allowlist. It defines:

- component names and descriptions;
- typed prop schemas;
- whether a component accepts children and which named slots exist;
- event names a component may emit;
- action names and typed parameters;
- the trusted Gooey registry implementation for each component.

Catalog reflection generates compact component/action tags and the Jev question
descriptions. Component names from the network are never used as dispatch
targets without resolving them through these tags.

An intended API shape is:

```zig
const catalog = genui.defineCatalog(.{
    .components = .{
        genui.component("Stack", StackProps, .{
            .description = "Arranges child content vertically or horizontally.",
            .slots = &.{"default"},
            .renderer = renderStack,
        }),
        genui.component("Text", TextProps, .{
            .description = "Displays text.",
            .renderer = renderText,
        }),
        genui.component("Button", ButtonProps, .{
            .description = "Triggers an allowlisted action.",
            .events = &.{"press"},
            .renderer = renderButton,
        }),
    },
    .actions = .{
        genui.action("submit", SubmitParams),
        genui.action("set_state", SetStateParams),
    },
});
```

`defineCatalog` is a comptime operation. It rejects duplicate names, unsupported
prop fields, invalid slots, missing renderers, and duplicate event or action
names. Candidate insertion later rejects bindings to unknown actions.

### Candidate

A candidate is a complete, trusted component instance that Jev may select:

```zig
try candidates.add(.{
    .key = "save-button",
    .component = catalog.component(.Button),
    .props = .{ .Button = .{ .label = "Save" } },
    .events = .{
        .press = catalog.bindAction(.submit, .{ .form = "profile" }),
    },
    .max_uses = 1,
    .can_be_root = false,
});
```

Candidate keys are stable host identifiers. Jev returns compact choice values
derived from them. `max_uses` bounds repetition. A shared resource tag can make
candidates mutually exclusive, matching json-render's experimental composition
model.

Candidates may contain literal values or expressions resolved from bounded
runtime state:

- `state(path)` reads a value;
- `bindState(path)` reads a value and permits a control to write it;
- `condition(path, comparison, value)` controls visibility.

Version 1 excludes item scopes, templates, computed expressions, and arbitrary
directives.

### Values and State

Dynamic state uses a fixed-capacity value arena rather than `std.json.Value`.
Values are tagged scalars, strings, arrays, or objects. Strings live in an
owned byte pool; references are indexes, never pointers into network buffers.

Paths follow RFC 6901 JSON Pointer so future json-render interchange remains
possible. Parsing and traversal are iterative and depth-bounded.

### Spec

The validated output is a compact tree:

```zig
const Node = struct {
    candidate_index: u16,
    parent_index: ?u16,
    first_child_index: ?u16,
    next_sibling_index: ?u16,
    slot_index: u8,
};

const Spec = struct {
    nodes: [limits.nodes_max]Node,
    node_count: u16,
    root_index: ?u16,
    revision: u32,
};
```

Node indexes are stable for one published revision. Candidate keys provide
identity across revisions. The validator rejects duplicate placement, cycles,
dangling references, unreachable nodes, unsupported slots, depth overflow, and
candidate overuse before a revision becomes visible to the renderer.

An optional later codec may import/export json-render's flat `{root, elements,
state}` representation. That external shape should not dictate the hot-path
internal layout.

## Composition

### Version 1: Batch Composition

New interfaces use two bounded evaluations, following json-render's Jev path:

1. **Selection:** choose the root and the use count of each candidate.
2. **Layout:** choose each selected node's parent, slot, and sibling position.
3. Validate the complete graph.
4. Atomically publish the new `Spec` revision.

The composer keeps the prior valid revision until all four steps succeed. It
does not expose a half-built interactive tree. Progress events may report
`selecting`, `laying_out`, and `validating` without changing rendered content.

Every composition has hard limits for evaluations and elapsed time. Cancellation
is checked before encoding, after transport returns, and between bounded
composition passes.

### Later: Sequential Editing

Supplying an existing spec can enable one operation per evaluation:

- add;
- replace;
- remove;
- move;
- reorder;
- finish.

Each operation is applied to a scratch spec, validated, and only then published.
This is intentionally deferred until batch creation proves the catalog and
renderer boundaries.

### Evaluator Interface

The composer depends on an evaluator, not directly on HTTP:

```zig
pub const Evaluator = struct {
    context: *anyopaque,
    evaluate_fn: *const fn (
        context: *anyopaque,
        request: *const EvaluationRequest,
        response: *EvaluationResponse,
    ) EvaluationError!void,
};
```

Calls are synchronous and run to completion. Applications execute them on a
worker thread. This keeps thread ownership and scheduling explicit.

The Jev implementation calls TypeSafe directly:

```http
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer <TYPESAFE_API_KEY>
Content-Type: application/json
```

```json
{
  "model": "jev-1.13.0",
  "state": {
    "request": "Build an account settings form",
    "context": "The user can edit their profile and save changes"
  },
  "questions": {
    "root": {
      "type": "choice",
      "instructions": "Choose the root candidate.",
      "criteria": {
        "settings-card": "A card containing account settings",
        "settings-stack": "A plain vertical settings layout"
      }
    }
  }
}
```

The direct response contains answers under the same question IDs. Choice
answers include the selected option, every option's probability, and a
confidence value. Composition uses Choice questions; the codec may also expose
TypeSafe's Score and Noul primitives for application-level ranking and routing.

`JevClient` defaults to the direct TypeSafe endpoint, but requires an explicit
model at the call site. The prototype should pin `jev-1.13.0`; applications may
explicitly choose the moving `jev-latest` alias. TypeSafe currently documents a
64k combined context budget and a 32k state-plus-longest-question budget, but
the library's smaller byte and question limits remain authoritative.

The endpoint returns one JSON document rather than a stream. The client writes
into fixed request/response buffers and classifies HTTP failures:

- `401` is an authentication error and is not retried;
- `422` is a request/schema error and is not retried;
- `429` and `529` are retryable with bounded exponential backoff;
- oversized, truncated, mismatched, or unknown answers are protocol errors.

Retry scheduling remains in the application so cancellation and worker policy
stay explicit. The TypeSafe API key is supplied from caller-owned memory and is
never copied into the catalog, spec, logs, session persistence, or render
state. The library does not read environment variables itself.

## Gooey Rendering

### Required Gooey Primitive

Gooey's current public containers accept compile-time child tuples. A runtime
tree cannot be rendered iteratively through that API without recursive
component calls. `gooey-genui` therefore requires a small Gooey extension that
shares the existing container implementation:

```zig
try cx.dynamic.beginBox(layout_id, style);
// Emit descendants while this runtime container is open.
cx.dynamic.endBox();
```

The actual API should expose paired `begin`/`end` operations for runtime
containers and direct leaf rendering while preserving dispatch, layout,
accessibility, clipping, and identity bookkeeping. Existing `ui.box` should use
the same internal implementation so behavior cannot drift.

The Gen UI renderer walks nodes with an explicit fixed-capacity stack and emits
enter/leaf/exit operations. It never recursively traverses the generated tree.
The validator's depth limit is asserted again by the renderer.

### Registry

The registry maps catalog tags to trusted Gooey implementations. A component
renderer receives resolved, typed props and a narrow dynamic-render context. It
cannot inspect credentials, issue network requests, or mutate arbitrary
application state.

The initial standard catalog should contain only:

- `Stack`;
- `Card`;
- `Text`;
- `Button`;
- `TextInput`;
- `Checkbox`;
- `Spacer`.

Charts and `AiCanvas` can be optional leaf components later. They should not be
special cases in the core composer.

### Identity and Retained Controls

Widget IDs derive from `(artifact_id, candidate_key, use_index)`, not tree
position. Moving a selected candidate therefore preserves text input, focus,
and accessibility identity. Duplicate IDs and hash collisions are rejected or
asserted at the registry boundary.

Rendering reads an immutable published spec. Composition writes a separate
scratch spec and swaps revisions on the UI thread, so the renderer never races
the worker.

## State and Actions

Generated UI emits an `ActionEvent`; it does not call host functions directly:

```zig
const ActionEvent = struct {
    artifact_id: u32,
    revision: u32,
    node_index: u16,
    action_tag: ActionTag,
    params_index: ValueIndex,
};
```

The application drains a bounded event queue and dispatches through its trusted
action registry. Dispatch revalidates the action tag and parameter type against
the catalog. Stale events from a replaced revision are dropped.

`set_state` is the only built-in action in version 1. It writes through a
declared binding, then requests a Gooey render. Application actions such as
`submit`, `approve`, or `retry` are host handlers. In `chat-zig`, a handler may
turn an event into a model-visible tool result and start another turn.

Actions are never executed during composition or validation.

## Limits and Memory

Limits are compile-time options with explicit values at the application call
site. Suggested prototype defaults are based on json-render's Jev playground,
which currently uses 14 elements and depth 4:

```zig
const Runtime = genui.Runtime(catalog, .{
    .candidates_max = 32,
    .nodes_max = 14,
    .depth_max = 4,
    .slots_per_component_max = 4,
    .children_per_node_max = 14,
    .state_values_max = 256,
    .state_bytes_max = 32 * 1024,
    .request_bytes_max = 64 * 1024,
    .response_bytes_max = 32 * 1024,
    .actions_per_event_max = 4,
    .events_queued_max = 32,
    .evaluations_max = 2,
});
```

Approximate prototype storage, excluding Gooey widget state and the host HTTP
implementation:

| Storage | Budget |
| --- | ---: |
| Candidate metadata and props | 32 KiB |
| Two specs (published + scratch) | 16 KiB |
| State value/string arena | 40 KiB |
| Jev request and response buffers | 96 KiB |
| Traversal, decisions, and events | 16 KiB |
| **Target total** | **≤ 200 KiB** |

Exact sizes must be asserted at comptime once types exist. `Runtime` is
initialized in place and should live globally or on the heap, never on the WASM
stack. Composition performs no allocation after initialization. Rendering does
no parsing, composition, or network work.

## Failure Policy

Failures are explicit and retain the last valid revision:

| Failure | Result |
| --- | --- |
| Timeout, cancellation, or transport error | Return error; keep prior spec |
| Jev unavailable/uncertain | Return status and confidence; keep prior spec |
| Unknown or duplicate choice | Reject response |
| Invalid parent, slot, count, or ordering | Reject response |
| Capacity exceeded | Fail before writing past a buffer |
| Catalog/spec mismatch during render | Stop artifact render and report error |
| Stale action event | Drop without dispatch |

There is no silent truncation. Responses that exceed a configured capacity are
errors rather than partially accepted compositions.

## Security Boundary

- Only catalog components and actions can be selected.
- Props and action parameters are typed and validated both at composition and
  dispatch.
- Model output cannot name a function pointer, URL handler, file, or module.
- Custom components independently validate sensitive strings such as URLs.
- Tree and expression traversal are iterative and bounded.
- Jev confidence is diagnostic input, not authorization. Destructive actions
  still require application policy and, where appropriate, user confirmation.
- Specs and action events contain no API credentials.

## Testing

1. **Catalog comptime tests:** duplicate names, invalid schemas, unsupported
   props, and bad events fail compilation.
2. **Composer unit tests:** scripted selection/layout responses produce an
   independently specified tree.
3. **Adversarial tests:** cycles, shared children, depth overflow, duplicate
   choices, excess counts, malformed confidence, and stale revisions fail.
4. **Codec tests:** captured Jev fixtures round-trip without network access;
   oversized and truncated documents are rejected.
5. **Property/fuzz tests:** arbitrary bounded decision responses never escape
   capacities or publish an invalid tree.
6. **Renderer tests:** emitted enter/leaf/exit traces match expected tree order
   and never exceed the explicit stack.
7. **Gooey integration test:** input state and focus survive a node move because
   identity derives from candidate keys.
8. **Accessibility test:** standard catalog components emit the same semantic
   roles, names, and states as their hand-authored Gooey equivalents.

Network integration tests are opt-in and require a test credential. The default
test suite is deterministic and offline.

## Delivery Plan

### Phase 0: Gooey Dynamic Rendering Boundary

- Refactor the existing box path into paired internal begin/end operations.
- Expose a narrow dynamic rendering namespace on `Cx`.
- Verify parity with hand-authored layout, dispatch, and accessibility.

### Phase 1: Offline Core

- Implement catalog reflection, candidates, fixed value storage, specs,
  validation, and batch composition.
- Use a scripted evaluator and render the standard catalog in a Gooey example.

### Phase 2: Jev

- Implement the direct TypeSafe `/v1/systemone` client and bounded codecs.
- Add confidence/status reporting, cancellation, and deadlines.
- Exercise prompt → selection → layout → UI in a standalone example.

### Phase 3: `chat-zig` Prototype

- Add an artifact message block and run composition on its existing worker.
- Persist the candidate-set identifier, validated spec, and state—not secrets or
  raw evaluator internals.
- Convert UI actions into provider-neutral tool results.

### Phase 4: Editing and Interchange

- Add sequential edits only after batch behavior is measured.
- Evaluate json-render flat-spec import/export and JSON Patch as optional edge
  codecs rather than internal storage.

## Decisions to Validate in the Prototype

1. Whether application-authored candidates provide enough variation without a
   separate LLM candidate-authoring pass.
2. Whether two Jev evaluations meet interactive latency expectations.
3. Whether custom components need named slots in version 1 or one default slot
   is sufficient.
4. Whether state belongs per artifact or per conversation in `chat-zig`.
5. What confidence policy should show a result, preserve the prior result, or
   ask the user for clarification.

These are product measurements, not reasons to weaken the core safety or
capacity invariants.

## References

- [json-render repository](https://github.com/vercel-labs/json-render)
- [json-render Jev documentation](https://github.com/vercel-labs/json-render/blob/main/apps/web/app/(main)/docs/jev/page.mdx)
- [Experimental composition implementation](https://github.com/vercel-labs/json-render/blob/main/packages/core/src/experimental-compose.ts)
- [Experimental evaluator implementation](https://github.com/vercel-labs/json-render/blob/main/packages/core/src/experimental-evaluator.ts)
- [json-render Jev pull request](https://github.com/vercel-labs/json-render/pull/342)
- [TypeSafe direct API reference](https://docs.typesafe.ai/api)
- [TypeSafe model reference](https://docs.typesafe.ai/models)
- [CopilotKit direct Jev Gen UI cookbook](https://github.com/CopilotKit/CopilotKit/blob/main/showcase/shell-docs/src/content/docs/cookbook/jev-generative-ui.mdx)
- [Thesys OpenUI](https://github.com/thesysdev/openui)
- [W&B OpenUI](https://github.com/wandb/openui)
- Gooey's existing bounded AI canvas: `src/ai/`
