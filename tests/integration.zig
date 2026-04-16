// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for rtree
//!
//! Ported from Geode's test_spatial_index.zig and test_index_performance.zig,
//! adapted to use the standalone rtree module directly.

const std = @import("std");
const lib = @import("rtree");

/// Minimal Timer shim on top of 0.16.0 `std.Io.Clock.Timestamp` so the existing
/// benchmarks that rely on the 0.15-era `Timer` API keep working.
const Timer = struct {
    started_ns: i128,

    inline fn nowNs() i128 {
        const _io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Clock.Timestamp.now(_io, .awake).raw.nanoseconds;
    }

    fn start() error{Unsupported}!Timer {
        return .{ .started_ns = nowNs() };
    }

    fn read(self: *Timer) u64 {
        const diff = nowNs() - self.started_ns;
        return @intCast(@max(diff, 0));
    }

    fn reset(self: *Timer) void {
        self.started_ns = nowNs();
    }
};

// ============================================================================
// Functional Tests (ported from Geode test_spatial_index.zig)
// ============================================================================

test "integration: basic insert and search" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 8);
    defer tree.deinit();

    const mbr1 = lib.MBR{ .min_x = 0.0, .min_y = 0.0, .max_x = 10.0, .max_y = 10.0 };
    const mbr2 = lib.MBR{ .min_x = 5.0, .min_y = 5.0, .max_x = 15.0, .max_y = 15.0 };
    const mbr3 = lib.MBR{ .min_x = 20.0, .min_y = 20.0, .max_x = 30.0, .max_y = 30.0 };

    try tree.insert(mbr1, 1);
    try tree.insert(mbr2, 2);
    try tree.insert(mbr3, 3);

    const query = lib.MBR{ .min_x = 7.0, .min_y = 7.0, .max_x = 12.0, .max_y = 12.0 };

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(query, allocator, &results);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "integration: point queries" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 8);
    defer tree.deinit();

    const points = [_]struct { x: f64, y: f64, id: u64 }{
        .{ .x = 40.7128, .y = -74.0060, .id = 1 },
        .{ .x = 37.7749, .y = -122.4194, .id = 2 },
        .{ .x = 51.5074, .y = -0.1278, .id = 3 },
        .{ .x = 35.6762, .y = 139.6503, .id = 4 },
    };

    for (points) |p| {
        try tree.insert(.{ .min_x = p.x, .min_y = p.y, .max_x = p.x, .max_y = p.y }, p.id);
    }

    const west_us = lib.MBR{ .min_x = 30.0, .min_y = -130.0, .max_x = 50.0, .max_y = -100.0 };

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(west_us, allocator, &results);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[0]);
}

test "integration: containment queries" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 4);
    defer tree.deinit();

    const outer = lib.MBR{ .min_x = 0.0, .min_y = 0.0, .max_x = 100.0, .max_y = 100.0 };
    const middle = lib.MBR{ .min_x = 20.0, .min_y = 20.0, .max_x = 80.0, .max_y = 80.0 };
    const inner = lib.MBR{ .min_x = 40.0, .min_y = 40.0, .max_x = 60.0, .max_y = 60.0 };

    try tree.insert(outer, 1);
    try tree.insert(middle, 2);
    try tree.insert(inner, 3);

    try std.testing.expect(outer.contains(middle));
    try std.testing.expect(middle.contains(inner));
    try std.testing.expect(outer.contains(inner));

    const point_query = lib.MBR{ .min_x = 50.0, .min_y = 50.0, .max_x = 50.0, .max_y = 50.0 };

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(point_query, allocator, &results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
}

test "integration: large dataset insert and search" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 8);
    defer tree.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    const num_rectangles: u64 = 1000;
    var i: u64 = 0;
    while (i < num_rectangles) : (i += 1) {
        const x = random.float(f64) * 1000.0;
        const y = random.float(f64) * 1000.0;
        const w = random.float(f64) * 100.0;
        const h = random.float(f64) * 100.0;

        try tree.insert(.{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h }, i);
    }

    try std.testing.expectEqual(num_rectangles, tree.count);

    const search_region = lib.MBR{ .min_x = 400.0, .min_y = 400.0, .max_x = 600.0, .max_y = 600.0 };

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(search_region, allocator, &results);
    try std.testing.expect(results.items.len > 0);
    try std.testing.expect(results.items.len < num_rectangles);
}

test "integration: MBR operations" {
    const MBR = lib.MBR;

    const mbr1 = MBR{ .min_x = 0.0, .min_y = 0.0, .max_x = 10.0, .max_y = 10.0 };
    const mbr2 = MBR{ .min_x = 5.0, .min_y = 5.0, .max_x = 15.0, .max_y = 15.0 };
    const mbr3 = MBR{ .min_x = 20.0, .min_y = 20.0, .max_x = 30.0, .max_y = 30.0 };

    try std.testing.expect(mbr1.intersects(mbr2));
    try std.testing.expect(!mbr1.intersects(mbr3));

    try std.testing.expectEqual(@as(f64, 100.0), mbr1.area());
    try std.testing.expectEqual(@as(f64, 100.0), mbr2.area());

    const u = mbr1.unionMbr(mbr2);
    try std.testing.expectEqual(@as(f64, 0.0), u.min_x);
    try std.testing.expectEqual(@as(f64, 0.0), u.min_y);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_x);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_y);

    const enl = mbr1.enlargement(mbr2);
    try std.testing.expect(enl > 0);
}

test "integration: insert then remove then search" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 4);
    defer tree.deinit();

    const mbr1 = lib.MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const mbr2 = lib.MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const mbr3 = lib.MBR{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 };

    try tree.insert(mbr1, 1);
    try tree.insert(mbr2, 2);
    try tree.insert(mbr3, 3);

    try std.testing.expect(try tree.remove(mbr2, 2));
    try std.testing.expectEqual(@as(u64, 2), tree.count);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(.{ .min_x = 7, .min_y = 7, .max_x = 12, .max_y = 12 }, allocator, &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 1), results.items[0]);
}

test "integration: geographic region search" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 8);
    defer tree.deinit();

    try tree.insert(.{ .min_x = -74.0, .min_y = 40.0, .max_x = -73.0, .max_y = 41.0 }, 100);
    try tree.insert(.{ .min_x = -122.5, .min_y = 37.0, .max_x = -121.5, .max_y = 38.0 }, 200);
    try tree.insert(.{ .min_x = -0.5, .min_y = 51.0, .max_x = 0.5, .max_y = 52.0 }, 300);

    const europe_query = lib.MBR{ .min_x = -10.0, .min_y = 45.0, .max_x = 10.0, .max_y = 60.0 };

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(europe_query, allocator, &results);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(u64, 300), results.items[0]);
}

// ============================================================================
// Performance Benchmark (ported from Geode test_index_performance.zig)
// ============================================================================

test "integration: spatial index performance" {
    const allocator = std.testing.allocator;

    var tree = try lib.RTree.init(allocator, 8);
    defer tree.deinit();

    var timer = try Timer.start();

    const grid_size: u64 = 100;
    var x: f64 = 0;
    while (x < @as(f64, @floatFromInt(grid_size))) : (x += 1) {
        var y: f64 = 0;
        while (y < @as(f64, @floatFromInt(grid_size))) : (y += 1) {
            const id: u64 = @intFromFloat(x * @as(f64, @floatFromInt(grid_size)) + y);
            try tree.insert(.{ .min_x = x, .min_y = y, .max_x = x + 0.5, .max_y = y + 0.5 }, id);
        }
    }
    const insert_time = timer.read();

    try std.testing.expectEqual(grid_size * grid_size, tree.count);

    const search_regions = [_]struct { size: f64 }{
        .{ .size = 1.0 },
        .{ .size = 5.0 },
        .{ .size = 10.0 },
    };

    std.debug.print("\nSpatial Index Performance:\n", .{});
    std.debug.print("  Insert {} rectangles: {}ns\n", .{ grid_size * grid_size, insert_time });

    for (search_regions) |region| {
        const query = lib.MBR{
            .min_x = 45.0,
            .min_y = 45.0,
            .max_x = 45.0 + region.size,
            .max_y = 45.0 + region.size,
        };

        timer.reset();
        var results: std.ArrayList(u64) = .empty;
        defer results.deinit(allocator);

        try tree.search(query, allocator, &results);
        const search_time = timer.read();

        std.debug.print("  Search {d}x{d} region: {}ns (found {})\n", .{
            region.size,
            region.size,
            search_time,
            results.items.len,
        });

        try std.testing.expect(results.items.len > 0);
    }
}

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", lib.version);
}
