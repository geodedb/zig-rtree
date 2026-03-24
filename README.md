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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
