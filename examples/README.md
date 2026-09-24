# Examples

Standalone MoonBit packages that demonstrate how to embed
`@labeler.dispatch_op` outside the CEF/Proton shell. Each example is
its own `moon.mod` sub-package and will be enabled via `moon.work`
workspace in the project-reorganization Phase 7.

## read_label

`examples/read_label/main.mbt` — minimal demo that reads a single label
JSON file from disk via the `read_label` IPC op, parses the normalized
schema, and prints the result.

```
moon run examples/read_label --target native -- <label_path.json>
```

The JSON must already be on disk in the modern normalized schema
(see `extensions/labeler/labeler.mbt` for the `read_label` contract).
This is the same code path the frontend uses when it issues
`ext:labeler/read_label` over the IPC bridge — only the entry point is
the direct `dispatch_op` call instead of the JSON-RPC frame.

## Workspace status (pre Phase 7)

These examples cannot be built standalone today because MoonBit 0.1.x
does not support relative-path imports between sub-packages of the same
repo. They will be enabled once the project converts to a `moon.work`
workspace (see AGENTS.md Phase 7).