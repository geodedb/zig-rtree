# rtree

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A standalone, generic R-tree spatial index for Zig.

## Features

- **Zero Dependencies**: Pure Zig standard library only
- **Input Validated**: Rejects NaN, Infinity, and inverted bounding boxes
- **Cross-Platform**: Linux, macOS, Windows support
- **Well Tested**: Comprehensive unit and integration tests

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .rtree = .{
        .url = "https://gitlab.com/devnw/zig/rtree/-/archive/v0.1.0/rtree-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const rtree = b.dependency("rtree", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("rtree", rtree.module("rtree"));
```

## Quick Start

```zig
const std = @import("std");
const rtree = @import("rtree");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create an R-tree with branching factor 8 (M must be >= 2).
    var tree = try rtree.RTree.init(allocator, 8);
    defer tree.deinit();

    // Insert bounding boxes with unique ids.
    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try tree.insert(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, 2);

    // Search for entries intersecting a query rectangle.
    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try tree.search(.{ .min_x = 7, .min_y = 7, .max_x = 12, .max_y = 12 }, allocator, &results);
    // results.items contains { 1, 2 }

    // Remove by exact MBR + id.
    _ = try tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
}
```

See [`examples/basic.zig`](examples/basic.zig) for a full runnable example.

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
zig build

# Run unit tests
zig build test --summary all

# Run integration tests
zig build test-integration --summary all

# Run the example
zig build example

# Or use Make convenience targets
make dev    # fmt + check + test
make ci     # clean + build + all tests
```

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Observability

rtree ships an opt-in OpenTelemetry seam. Build with
`-Dwith_otel=true` to compile in instrumentation; the default
(`-Dwith_otel=false`) leaves every span site as a comptime no-op so
the optimizer eliminates the entry/exit calls and the `otel`
dependency is never fetched.

Each public R-tree operation emits exactly one span per call, named
`rtree.{operation}` (e.g. `rtree.insert`, `rtree.search`,
`rtree.delete`, `rtree.bulk_load`) with the OpenTelemetry `db.*`
semantic-convention attributes plus an rtree-specific result count:

- `db.system     = "rtree"`
- `db.operation  = <method>` (e.g. `insert`, `search`, `delete`,
  `bulk_load`)
- `rtree.results = <count>` (entries inserted/matched/removed; 0 for
  the void-returning `searchCallback` variant)

Bounding-box coordinates are intentionally NOT attached to spans —
geo coordinates can be sensitive and the seam carries only the
operation name and result cardinality.

```bash
zig build test                  # default: -Dwith_otel=false (no-op)
zig build test -Dwith_otel=true # otel compiled in, spans emitted
```

When enabled, the consumer's process bootstrap calls
`rtree.observability_init.Otel.init(allocator, "service-name")` and
parks the returned value at a stable address (a `var` in `main` or
a heap allocation), then calls `installGlobals(&that_value)` so the
seam can publish its tracer pointer. Span emission is non-fatal:
every emit is `catch {}`-discarded so a failed exporter cannot
propagate into spatial-index operations.

For the full integration recipe and template files, see
`otel/docs/integration/RECIPE.md` in the otel repo.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
