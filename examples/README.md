# Examples

MoonBit packages that demonstrate how to embed `@labeler.dispatch_op`
outside the CEF/Proton shell.

Both examples are packages of this module, so `moon check --target native`
covers them on every CI run, and they always exercise the current source
rather than a published release.

## consumer

`examples/consumer/main.mbt` -- a self-contained consumer that uses
nothing but the public API: `dispatch_op_list()` for the op names, and one
`dispatch_op("parse_label", ...)` round-trip. It touches no filesystem, so
the output is deterministic:

```console
$ moon run examples/consumer --target native
op count = 27
{"label_text":"{\"img_name\":\"probe.png\",\"infos\":[],\"bindings\":[]}","err":""}
```

`examples/consumer/run.sh` is the other half: it does the same thing
against the **published** package instead of this source tree. It
scaffolds a throwaway module, resolves `riantr/moonbit_labeler` from
mooncakes.io, copies the two files above in, and then checks, builds and
runs them:

```console
$ examples/consumer/run.sh
...
PASS: the published package is consumable (version 0.2.18)
```

That script is what the `consumer (published package, ubuntu, native)` CI
job runs, so a change that breaks the published package -- the package
path, the `supported_targets` constraint, the dependency pins, the public
signatures -- turns the build red even when every in-tree test still
passes.

## read_label

`examples/read_label/main.mbt` -- reads the label JSON that belongs to one
image through the `read_label` op and prints the normalized result. It is
the same code path the frontend uses when it issues
`ext:labeler/read_label`, only the entry point is the direct
`dispatch_op` call instead of the JSON-RPC frame.

```console
$ moon run examples/read_label --target native -- <image_path>
```

The argument is an IMAGE path, not a label path: the op derives the label
path from the `Image@<name>` / `Label@<name>` folder layout. With no label
file next to the image the reply is
`{"image_path":...,"label_path":...,"content":"","found":false}`.

## Where the package path lives

The package path belongs in each example's `moon.pkg`, never in a
file-level `import` line:

```
import {
  "riantr/moonbit_labeler/extensions/labeler",
  "moonbitlang/core/async",
}
```

Adding a file-level `import` is a parse error in this toolchain
(`import <bare path>` is not valid syntax -- the path form belongs in
`moon.pkg`, and the code refers to the package as `@labeler`).

`moonbitlang/core/json` is not needed unless you build payloads out of
raw JSON yourself; the examples derive their request structs with
`#derive(ToJson)` instead, which keeps the sample free of nested-JSON
string escaping.
