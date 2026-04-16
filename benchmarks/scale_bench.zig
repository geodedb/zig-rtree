// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Incremental scale benchmark for rtree.
//!
//! Runs the same battery of operations at progressively larger dataset sizes
//! and emits structured JSON to stdout for tracking over time.
//! A human-readable summary table is printed to stderr via std.debug.print.
//!
//! Run via: zig build scale-bench
//! Save:   zig build scale-bench 2>/dev/null > results.json

const std = @import("std");
const rtree = @import("rtree");
const tp = @import("thread_pool");
const builtin = @import("builtin");

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
// Scale tier definitions
// ---------------------------------------------------------------------------

const Tier = struct {
    name: []const u8,
    entry_count: usize,
    M: u16,
    search_iters: usize,
};

const tiers = [_]Tier{
    .{ .name = "1K", .entry_count = 1_000, .M = 8, .search_iters = 5000 },
    .{ .name = "10K", .entry_count = 10_000, .M = 8, .search_iters = 2000 },
    .{ .name = "50K", .entry_count = 50_000, .M = 16, .search_iters = 500 },
    .{ .name = "100K", .entry_count = 100_000, .M = 32, .search_iters = 200 },
    .{ .name = "250K", .entry_count = 250_000, .M = 32, .search_iters = 100 },
    .{ .name = "500K", .entry_count = 500_000, .M = 64, .search_iters = 50 },
};

// Per-tier timeout: 5 minutes.
const tier_timeout_ns: u64 = 5 * 60 * std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

const TierResult = struct {
    name: []const u8,
    entry_count: usize,
    M: u16,
    insert_ops_sec: f64 = 0,
    search_ns: f64 = 0,
    parallel_search_ns: f64 = 0,
    bulk_insert_ops_sec: f64 = 0,
    remove_ns: f64 = 0,
    callback_search_ns: f64 = 0,
    search_result_count: usize = 0,
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Data generation
// ---------------------------------------------------------------------------

/// Generate a reproducible grid of entries across [0, side) x [0, side).
fn generateEntries(allocator: std.mem.Allocator, count: usize) ![]parallel.BulkEntry {
    const entries = try allocator.alloc(parallel.BulkEntry, count);
    const side: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(count)))));
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

/// Build a search query centered on the grid (covers ~5% of the space).
fn searchQuery(count: usize) MBR {
    const side: f64 = @ceil(@sqrt(@as(f64, @floatFromInt(count))));
    const center = side / 2.0;
    const extent = side * 0.1; // ~5% region on each axis = ~1% of area
    return .{
        .min_x = center - extent,
        .min_y = center - extent,
        .max_x = center + extent,
        .max_y = center + extent,
    };
}

// ---------------------------------------------------------------------------
// Tier runner
// ---------------------------------------------------------------------------

fn runTier(allocator: std.mem.Allocator, pool: *tp.ThreadPool, tier: Tier) !TierResult {
    var result = TierResult{
        .name = tier.name,
        .entry_count = tier.entry_count,
        .M = tier.M,
    };

    const entries = try generateEntries(allocator, tier.entry_count);
    defer allocator.free(entries);

    const query = searchQuery(tier.entry_count);
    var tier_timer = try Timer.start();

    // --- Sequential Insert ---
    var tree = try RTree.init(allocator, tier.M);
    defer tree.deinit();
    {
        var timer = try Timer.start();
        for (entries) |e| {
            try tree.insert(e.mbr, e.id);
        }
        const elapsed = timer.read();
        result.insert_ops_sec = @as(f64, @floatFromInt(tier.entry_count)) /
            (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    }

    if (tier_timer.read() > tier_timeout_ns) {
        result.skipped = true;
        result.skip_reason = "timeout after insert";
        return result;
    }

    // --- Sequential Search ---
    {
        var results_list: std.ArrayList(u64) = .empty;
        defer results_list.deinit(allocator);

        var timer = try Timer.start();
        for (0..tier.search_iters) |_| {
            results_list.clearRetainingCapacity();
            try tree.search(query, allocator, &results_list);
        }
        const elapsed = timer.read();
        result.search_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(tier.search_iters));
        result.search_result_count = results_list.items.len;
    }

    if (tier_timer.read() > tier_timeout_ns) {
        result.skipped = true;
        result.skip_reason = "timeout after search";
        return result;
    }

    // --- Parallel Search ---
    {
        var results_list: std.ArrayList(u64) = .empty;
        defer results_list.deinit(allocator);

        var timer = try Timer.start();
        for (0..tier.search_iters) |_| {
            results_list.clearRetainingCapacity();
            try parallel.parallelSearch(pool, &tree, query, allocator, &results_list);
        }
        const elapsed = timer.read();
        result.parallel_search_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(tier.search_iters));
    }

    if (tier_timer.read() > tier_timeout_ns) {
        result.skipped = true;
        result.skip_reason = "timeout after parallel search";
        return result;
    }

    // --- Callback Search ---
    {
        const Counter = struct { n: usize = 0 };
        const cb = struct {
            fn call(ctx: *Counter, _: u64) bool {
                ctx.n += 1;
                return true;
            }
        }.call;

        var timer = try Timer.start();
        for (0..tier.search_iters) |_| {
            var counter = Counter{};
            parallel.searchCallback(&tree, query, &counter, cb);
        }
        const elapsed = timer.read();
        result.callback_search_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(tier.search_iters));
    }

    if (tier_timer.read() > tier_timeout_ns) {
        result.skipped = true;
        result.skip_reason = "timeout after callback search";
        return result;
    }

    // --- Remove (1000 entries — fixed count avoids excessive condensation at large scale) ---
    {
        const remove_count = @min(tier.entry_count / 10, 1000);
        var timer = try Timer.start();
        for (entries[0..remove_count]) |e| {
            _ = try tree.remove(e.mbr, e.id);
        }
        const elapsed = timer.read();
        result.remove_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(remove_count));
    }

    // Clean up tree for bulk insert test.
    tree.deinit();
    tree = try RTree.init(allocator, tier.M);

    // --- Bulk Insert ---
    {
        var timer = try Timer.start();
        try parallel.bulkInsert(pool, &tree, entries);
        const elapsed = timer.read();
        result.bulk_insert_ops_sec = @as(f64, @floatFromInt(tier.entry_count)) /
            (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    }

    return result;
}

// ---------------------------------------------------------------------------
// Stdout buffered writer (for JSON)
// ---------------------------------------------------------------------------

const StdoutWriter = struct {
    file: std.Io.File,
    buf: [8192]u8 = undefined,
    writer: ?std.Io.File.Writer = null,

    /// Must be called after the struct is in its final stack location.
    fn open(self: *StdoutWriter) void {
        const _io = std.Io.Threaded.global_single_threaded.io();
        self.writer = self.file.writer(_io, &self.buf);
    }

    fn writeAll(self: *StdoutWriter, data: []const u8) !void {
        try self.writer.?.interface.writeAll(data);
    }

    fn writeFmt(self: *StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.?.interface.print(fmt, args);
    }

    fn flush(self: *StdoutWriter) !void {
        try self.writer.?.interface.flush();
    }
};

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

fn writeJsonOutput(out: *StdoutWriter, results: []const TierResult) !void {
    try out.writeAll("{\n");
    try out.writeAll("  \"version\": 1,\n");

    // Timestamp
    const _io = std.Io.Threaded.global_single_threaded.io();
    const now_ts = std.Io.Clock.Timestamp.now(_io, .real);
    const epoch_secs: u64 = @intCast(@divTrunc(now_ts.raw.nanoseconds, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try out.writeFmt("  \"timestamp\": \"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",\n", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });

    try out.writeAll("  \"git_commit\": \"unknown\",\n");

    // System info
    try out.writeFmt("  \"system\": {{ \"os\": \"{s}\", \"arch\": \"{s}\" }},\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

    // Tiers
    try out.writeAll("  \"tiers\": [\n");
    for (results, 0..) |r, i| {
        try out.writeAll("    {\n");
        try out.writeFmt("      \"name\": \"{s}\",\n", .{r.name});
        try out.writeFmt("      \"entry_count\": {d},\n", .{r.entry_count});
        try out.writeFmt("      \"M\": {d},\n", .{r.M});
        if (r.skipped) {
            try out.writeAll("      \"skipped\": true,\n");
            if (r.skip_reason) |reason| {
                try out.writeFmt("      \"skip_reason\": \"{s}\",\n", .{reason});
            }
        }
        try out.writeFmt("      \"insert_ops_sec\": {d:.0},\n", .{r.insert_ops_sec});
        try out.writeFmt("      \"search_ns\": {d:.0},\n", .{r.search_ns});
        try out.writeFmt("      \"parallel_search_ns\": {d:.0},\n", .{r.parallel_search_ns});
        try out.writeFmt("      \"bulk_insert_ops_sec\": {d:.0},\n", .{r.bulk_insert_ops_sec});
        try out.writeFmt("      \"remove_ns\": {d:.0},\n", .{r.remove_ns});
        try out.writeFmt("      \"callback_search_ns\": {d:.0},\n", .{r.callback_search_ns});
        try out.writeFmt("      \"search_result_count\": {d}\n", .{r.search_result_count});
        if (i < results.len - 1) {
            try out.writeAll("    },\n");
        } else {
            try out.writeAll("    }\n");
        }
    }
    try out.writeAll("  ]\n");
    try out.writeAll("}\n");
    try out.flush();
}

// ---------------------------------------------------------------------------
// Human-readable summary (stderr)
// ---------------------------------------------------------------------------

fn writeSummary(results: []const TierResult) void {
    print("\n", .{});
    print("{s}\n", .{"=" ** 105});
    print("  rtree incremental scale benchmark\n", .{});
    print("{s}\n\n", .{"=" ** 105});

    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>14} {s:>14} {s:>12} {s:>14}\n", .{
        "Tier", "Count", "Insert", "Search", "Par.Search", "Callback", "Remove", "BulkInsert",
    });
    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>14} {s:>14} {s:>12} {s:>14}\n", .{
        "", "", "ops/sec", "ns/op", "ns/op", "ns/op", "ns/op", "ops/sec",
    });
    print("  {s}\n", .{"-" ** 101});

    for (results) |r| {
        if (r.skipped) {
            print("  {s:<6} {d:>8} SKIPPED", .{ r.name, r.entry_count });
            if (r.skip_reason) |reason| {
                print(" ({s})", .{reason});
            }
            print("\n", .{});
            continue;
        }
        print("  {s:<6} {d:>8} {d:>12.0} {d:>12.0} {d:>14.0} {d:>14.0} {d:>12.0} {d:>14.0}\n", .{
            r.name,
            r.entry_count,
            r.insert_ops_sec,
            r.search_ns,
            r.parallel_search_ns,
            r.callback_search_ns,
            r.remove_ns,
            r.bulk_insert_ops_sec,
        });
    }

    print("\n{s}\n\n", .{"=" ** 105});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    // Use page_allocator for benchmarks — GPA's debug bookkeeping adds
    // overhead and can segfault under heavy allocation in ReleaseFast.
    const allocator = std.heap.page_allocator;

    var pool = try tp.ThreadPool.init(allocator, .{});
    defer pool.deinit();

    var results: [tiers.len]TierResult = undefined;

    for (tiers, 0..) |tier, i| {
        print("  Running tier {s} ({d} entries)...\n", .{ tier.name, tier.entry_count });
        results[i] = try runTier(allocator, &pool, tier);
    }

    writeSummary(&results);

    var out = StdoutWriter{ .file = .{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } } };
    out.open();
    try writeJsonOutput(&out, &results);
}
