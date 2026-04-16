// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Quick benchmark for rtree core operations.
//!
//! Measures insert, search, parallel search, bulk insert, remove, and
//! callback search across a single dataset size (10K entries, M=8).
//!
//! Run via: zig build bench

const std = @import("std");
const rtree = @import("rtree");
const tp = @import("thread_pool");

const RTree = rtree.RTree;
const MBR = rtree.MBR;
const parallel = rtree.parallel;

const print = std.debug.print;

/// Minimal Timer shim on top of 0.16.0 `std.Io.Clock.Timestamp`.
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
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BenchEntry = struct {
    mbr: MBR,
    id: u64,
};

/// Generate a reproducible grid of entries across [0, grid_size) x [0, grid_size).
fn generateEntries(allocator: std.mem.Allocator, count: usize) ![]BenchEntry {
    const entries = try allocator.alloc(BenchEntry, count);
    const side: usize = @intFromFloat(@sqrt(@as(f64, @floatFromInt(count))));
    for (entries, 0..) |*e, i| {
        const x: f64 = @floatFromInt(i % side);
        const y: f64 = @floatFromInt(i / side);
        e.* = .{
            .mbr = .{ .min_x = x, .min_y = y, .max_x = x + 0.5, .max_y = y + 0.5 },
            .id = @intCast(i),
        };
    }
    return entries;
}

fn formatNs(ns: u64) struct { val: f64, unit: []const u8 } {
    if (ns >= 1_000_000_000) return .{ .val = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, .unit = "s" };
    if (ns >= 1_000_000) return .{ .val = @as(f64, @floatFromInt(ns)) / 1_000_000.0, .unit = "ms" };
    if (ns >= 1_000) return .{ .val = @as(f64, @floatFromInt(ns)) / 1_000.0, .unit = "us" };
    return .{ .val = @as(f64, @floatFromInt(ns)), .unit = "ns" };
}

fn opsPerSec(count: usize, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const count: usize = 10_000;
    const M: u16 = 8;

    const entries = try generateEntries(allocator, count);
    defer allocator.free(entries);

    print("\n", .{});
    print("{s}\n", .{"=" ** 78});
    print("  rtree quick benchmark  (N={d}, M={d})\n", .{ count, M });
    print("{s}\n\n", .{"=" ** 78});

    print("  {s:<28} {s:>10} {s:>12} {s:>10} {s:>12}\n", .{
        "Benchmark", "Count", "Total", "Avg", "ops/sec",
    });
    print("  {s}\n", .{"-" ** 74});

    // --- Insert ---
    {
        var tree = try RTree.init(allocator, M);
        defer tree.deinit();

        var timer = try Timer.start();
        for (entries) |e| {
            try tree.insert(e.mbr, e.id);
        }
        const elapsed = timer.read();
        const f = formatNs(elapsed);
        const avg_f = formatNs(elapsed / count);
        print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
            "insert", count, f.val, f.unit, avg_f.val, avg_f.unit, opsPerSec(count, elapsed),
        });

        // --- Sequential Search ---
        {
            const query = MBR{ .min_x = 40, .min_y = 40, .max_x = 60, .max_y = 60 };
            const iters: usize = 1000;
            var results: std.ArrayList(u64) = .empty;
            defer results.deinit(allocator);

            var timer2 = try Timer.start();
            for (0..iters) |_| {
                results.clearRetainingCapacity();
                try tree.search(query, allocator, &results);
            }
            const elapsed2 = timer2.read();
            const f2 = formatNs(elapsed2);
            const avg_f2 = formatNs(elapsed2 / iters);
            print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
                "search (20x20 region)", iters, f2.val, f2.unit, avg_f2.val, avg_f2.unit, opsPerSec(iters, elapsed2),
            });
        }

        // --- Parallel Search ---
        {
            var pool = try tp.ThreadPool.init(allocator, .{});
            defer pool.deinit();

            const query = MBR{ .min_x = 40, .min_y = 40, .max_x = 60, .max_y = 60 };
            const iters: usize = 1000;
            var results: std.ArrayList(u64) = .empty;
            defer results.deinit(allocator);

            var timer2 = try Timer.start();
            for (0..iters) |_| {
                results.clearRetainingCapacity();
                try parallel.parallelSearch(&pool, &tree, query, allocator, &results);
            }
            const elapsed2 = timer2.read();
            const f2 = formatNs(elapsed2);
            const avg_f2 = formatNs(elapsed2 / iters);
            print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
                "parallel search (20x20)", iters, f2.val, f2.unit, avg_f2.val, avg_f2.unit, opsPerSec(iters, elapsed2),
            });
        }

        // --- Callback Search ---
        {
            const query = MBR{ .min_x = 40, .min_y = 40, .max_x = 60, .max_y = 60 };
            const iters: usize = 1000;

            const Counter = struct { n: usize = 0 };
            const cb = struct {
                fn call(ctx: *Counter, _: u64) bool {
                    ctx.n += 1;
                    return true;
                }
            }.call;

            var timer2 = try Timer.start();
            for (0..iters) |_| {
                var counter = Counter{};
                parallel.searchCallback(&tree, query, &counter, cb);
            }
            const elapsed2 = timer2.read();
            const f2 = formatNs(elapsed2);
            const avg_f2 = formatNs(elapsed2 / iters);
            print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
                "callback search (20x20)", iters, f2.val, f2.unit, avg_f2.val, avg_f2.unit, opsPerSec(iters, elapsed2),
            });
        }

        // --- Remove ---
        {
            const remove_count = count / 2;
            var timer2 = try Timer.start();
            for (entries[0..remove_count]) |e| {
                _ = try tree.remove(e.mbr, e.id);
            }
            const elapsed2 = timer2.read();
            const f2 = formatNs(elapsed2);
            const avg_f2 = formatNs(elapsed2 / remove_count);
            print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
                "remove", remove_count, f2.val, f2.unit, avg_f2.val, avg_f2.unit, opsPerSec(remove_count, elapsed2),
            });
        }
    }

    // --- Bulk Insert ---
    {
        var tree = try RTree.init(allocator, M);
        defer tree.deinit();

        var pool = try tp.ThreadPool.init(allocator, .{});
        defer pool.deinit();

        const bulk_entries = try allocator.alloc(parallel.BulkEntry, count);
        defer allocator.free(bulk_entries);
        for (entries, 0..) |e, i| {
            bulk_entries[i] = .{ .mbr = e.mbr, .id = e.id };
        }

        var timer = try Timer.start();
        try parallel.bulkInsert(&pool, &tree, bulk_entries);
        const elapsed = timer.read();
        const f = formatNs(elapsed);
        const avg_f = formatNs(elapsed / count);
        print("  {s:<28} {d:>10} {d:>9.2} {s:<2} {d:>7.1} {s:<2} {d:>12.0}\n", .{
            "bulk insert (sorted)", count, f.val, f.unit, avg_f.val, avg_f.unit, opsPerSec(count, elapsed),
        });
    }

    print("\n{s}\n\n", .{"=" ** 78});
}
