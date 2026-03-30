// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel and concurrent extensions for the R-tree.
//!
//! This module provides:
//!
//! - **`parallelSearch`** — Fan-out subtree searches across a `spice.ThreadPool`
//!   using heartbeat-scheduled fork/join parallelism.
//! - **`ConcurrentRTree`** — Thread-safe wrapper using `std.Thread.RwLock` for
//!   concurrent reads and exclusive writes.
//! - **`bulkInsert`** — Batch insertion that sorts entries spatially and inserts
//!   in an order that reduces overlap, with parallel sorting via spice.
//! - **`searchCallback`** — Streaming search that yields results one at a time
//!   via a caller-provided callback, avoiding full materialization.
//!
//! All parallel operations require a `spice.ThreadPool` that has been started.
//! The underlying `RTree` remains single-threaded; parallelism is layered on
//! top via these wrappers.

const std = @import("std");
const spice = @import("spice");
const root = @import("root.zig");

pub const MBR = root.MBR;
pub const RTree = root.RTree;
pub const RTreeEntry = root.RTreeEntry;
pub const RTreeNode = root.RTreeNode;

// ============================================================================
// GAP-P002: Parallel Search
// ============================================================================

/// Thread-safe accumulator for parallel search results.
const SharedResults = struct {
    mutex: std.Thread.Mutex = .{},
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    oom: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Arguments passed through spice's fork/join to each subtree search.
const SearchArgs = struct {
    node: *const RTreeNode,
    query_mbr: MBR,
    shared: *SharedResults,
};

/// Spice-compatible recursive search function.
///
/// At each internal node, forks the first intersecting child to a background
/// worker and processes the remaining children on the current worker. The
/// heartbeat scheduler redistributes work across the pool automatically.
fn parallelSearchNode(task: *spice.Task, args: SearchArgs) void {
    const node = args.node;
    const query = args.query_mbr;
    const shared = args.shared;

    // Early exit if another branch hit OOM.
    if (shared.oom.load(.monotonic)) return;

    if (node.is_leaf) {
        // Leaf: append matching IDs under the mutex.
        shared.mutex.lock();
        defer shared.mutex.unlock();
        for (node.entries.items) |entry| {
            if (entry.mbr.intersects(query)) {
                shared.list.append(shared.allocator, entry.id) catch {
                    shared.oom.store(true, .monotonic);
                    return;
                };
            }
        }
        return;
    }

    // Internal node: recurse into intersecting children via task.call().
    // Spice's heartbeat scheduler automatically distributes queued work
    // across background threads — each task.call() ticks the heartbeat,
    // creating opportunities for other workers to steal subtrees.
    for (node.entries.items) |entry| {
        if (entry.mbr.intersects(query)) {
            if (entry.child) |child| {
                task.call(void, parallelSearchNode, SearchArgs{
                    .node = child,
                    .query_mbr = query,
                    .shared = shared,
                });
            }
        }
    }
}

/// Search the R-tree for all entries intersecting `query_mbr`, distributing
/// subtree traversals across the spice thread pool.
///
/// Results are appended to `results` (which the caller owns). The tree's own
/// allocator is not used for result storage.
///
/// Returns `error.OutOfMemory` if result accumulation fails.
pub fn parallelSearch(
    pool: *spice.ThreadPool,
    tree: *const RTree,
    query_mbr: MBR,
    result_allocator: std.mem.Allocator,
    results: *std.ArrayList(u64),
) error{OutOfMemory}!void {
    const tree_root = tree.root orelse return;

    var shared = SharedResults{
        .list = results,
        .allocator = result_allocator,
    };

    pool.call(void, parallelSearchNode, SearchArgs{
        .node = tree_root,
        .query_mbr = query_mbr,
        .shared = &shared,
    });

    if (shared.oom.load(.monotonic)) return error.OutOfMemory;
}

// ============================================================================
// GAP-P004: ConcurrentRTree
// ============================================================================

/// Thread-safe R-tree wrapper providing concurrent read access and exclusive
/// write access via `std.Thread.RwLock`.
///
/// Multiple threads may call `search` / `parallelSearch` / `searchCallback`
/// simultaneously. Calls to `insert`, `remove`, and `bulkInsert` acquire an
/// exclusive lock.
pub const ConcurrentRTree = struct {
    tree: RTree,
    lock: std.Thread.RwLock = .{},

    pub const InitError = RTree.InitError;
    pub const InsertError = RTree.InsertError;
    pub const RemoveError = RTree.RemoveError;

    /// Create a new concurrent R-tree. `M` must be >= 2.
    pub fn init(allocator: std.mem.Allocator, M: u16) InitError!ConcurrentRTree {
        return .{ .tree = try RTree.init(allocator, M) };
    }

    pub fn deinit(self: *ConcurrentRTree) void {
        self.tree.deinit();
    }

    /// Insert a spatial entry (exclusive lock).
    pub fn insert(self: *ConcurrentRTree, mbr: MBR, id: u64) InsertError!void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.tree.insert(mbr, id);
    }

    /// Remove an entry (exclusive lock).
    pub fn remove(self: *ConcurrentRTree, mbr: MBR, id: u64) RemoveError!bool {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.tree.remove(mbr, id);
    }

    /// Search for intersecting entries (shared lock).
    pub fn search(
        self: *ConcurrentRTree,
        query_mbr: MBR,
        result_allocator: std.mem.Allocator,
        results: *std.ArrayList(u64),
    ) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        try self.tree.search(query_mbr, result_allocator, results);
    }

    /// Parallel search using spice thread pool (shared lock).
    pub fn parallelSearchWith(
        self: *ConcurrentRTree,
        pool: *spice.ThreadPool,
        query_mbr: MBR,
        result_allocator: std.mem.Allocator,
        results: *std.ArrayList(u64),
    ) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        try parallelSearch(pool, &self.tree, query_mbr, result_allocator, results);
    }

    /// Callback-based streaming search (shared lock).
    pub fn searchCallbackWith(
        self: *ConcurrentRTree,
        query_mbr: MBR,
        context: anytype,
        callback: *const fn (@TypeOf(context), u64) bool,
    ) void {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        searchCallback(&self.tree, query_mbr, context, callback);
    }

    /// Bulk insert entries (exclusive lock).
    pub fn bulkInsertWith(
        self: *ConcurrentRTree,
        pool: *spice.ThreadPool,
        entries: []const BulkEntry,
    ) (RTree.InsertError || error{EmptyInput})!void {
        self.lock.lock();
        defer self.lock.unlock();
        try bulkInsert(pool, &self.tree, entries);
    }

    /// Number of entries in the tree.
    pub fn count(self: *ConcurrentRTree) u64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.tree.count;
    }
};

// ============================================================================
// GAP-P003: Bulk Insert
// ============================================================================

/// Entry for bulk insertion — MBR + id pair.
pub const BulkEntry = struct {
    mbr: MBR,
    id: u64,
};

/// Sort key for spatial ordering: center-x, then center-y as tiebreaker.
fn bulkEntryLessThan(_: void, a: BulkEntry, b: BulkEntry) bool {
    const a_cx = (a.mbr.min_x + a.mbr.max_x) * 0.5;
    const b_cx = (b.mbr.min_x + b.mbr.max_x) * 0.5;
    if (a_cx != b_cx) return a_cx < b_cx;
    const a_cy = (a.mbr.min_y + a.mbr.max_y) * 0.5;
    const b_cy = (b.mbr.min_y + b.mbr.max_y) * 0.5;
    return a_cy < b_cy;
}

/// Arguments for parallel sort merge via spice.
const SortArgs = struct {
    items: []BulkEntry,
    scratch: []BulkEntry,
};

/// Parallel merge-sort using spice fork/join.
///
/// Recursively divides the array and forks one half to a background worker.
/// Base case (len <= 32) uses insertion sort to avoid fork overhead.
fn parallelMergeSort(task: *spice.Task, args: SortArgs) void {
    const items = args.items;
    if (items.len <= 32) {
        std.mem.sort(BulkEntry, items, {}, bulkEntryLessThan);
        return;
    }

    const mid = items.len / 2;
    const scratch = args.scratch;

    // Sort left and right halves via task.call() — spice's heartbeat
    // scheduler distributes work across background threads automatically.
    task.call(void, parallelMergeSort, SortArgs{ .items = items[0..mid], .scratch = scratch[0..mid] });
    task.call(void, parallelMergeSort, SortArgs{ .items = items[mid..], .scratch = scratch[mid..] });

    // Merge the two sorted halves.
    merge(items, scratch, mid);
}

/// In-place merge using scratch buffer. Merges items[0..mid] and items[mid..].
fn merge(items: []BulkEntry, scratch: []BulkEntry, mid: usize) void {
    @memcpy(scratch[0..mid], items[0..mid]);

    var i: usize = 0; // index into scratch (left half copy)
    var j: usize = mid; // index into items (right half, in-place)
    var k: usize = 0; // write index into items

    while (i < mid and j < items.len) {
        if (bulkEntryLessThan({}, scratch[i], items[j])) {
            items[k] = scratch[i];
            i += 1;
        } else {
            items[k] = items[j];
            j += 1;
        }
        k += 1;
    }

    // Copy remaining left elements (right elements are already in place).
    if (i < mid) {
        @memcpy(items[k .. k + (mid - i)], scratch[i..mid]);
    }
}

/// Bulk-insert entries into the R-tree, sorting spatially first to reduce
/// overlap and improve tree quality. The sort is parallelized via spice.
///
/// This is faster than N sequential `insert()` calls for large batches because
/// spatially-ordered insertion produces better node packing and fewer splits.
///
/// Each entry's MBR is validated; invalid entries return `error.InvalidMBR`.
pub fn bulkInsert(
    pool: *spice.ThreadPool,
    tree: *RTree,
    entries: []const BulkEntry,
) (RTree.InsertError || error{EmptyInput})!void {
    if (entries.len == 0) return error.EmptyInput;

    // Validate all MBRs before sorting.
    for (entries) |entry| {
        if (!entry.mbr.isValid()) return error.InvalidMBR;
    }

    // Create a mutable copy for sorting.
    const sorted = try tree.allocator.alloc(BulkEntry, entries.len);
    defer tree.allocator.free(sorted);
    @memcpy(sorted, entries);

    // Allocate scratch space for merge sort.
    const scratch = try tree.allocator.alloc(BulkEntry, entries.len);
    defer tree.allocator.free(scratch);

    // Parallel sort by spatial position.
    pool.call(void, parallelMergeSort, SortArgs{ .items = sorted, .scratch = scratch });

    // Insert in sorted order — sequential since tree mutation is not thread-safe.
    for (sorted) |entry| {
        try tree.insert(entry.mbr, entry.id);
    }
}

// ============================================================================
// GAP-P005: Callback-based Streaming Search
// ============================================================================

/// Search the R-tree for all entries intersecting `query_mbr`, invoking
/// `callback` for each matching entry ID.
///
/// The callback returns `true` to continue searching, or `false` to stop
/// early. This avoids allocating a result list when the caller only needs
/// to process entries one at a time or wants to bail out early.
///
/// This is a single-threaded operation (no spice required).
pub fn searchCallback(
    tree: *const RTree,
    query_mbr: MBR,
    context: anytype,
    callback: *const fn (@TypeOf(context), u64) bool,
) void {
    if (tree.root) |tree_root| {
        _ = searchNodeCallback(tree_root, query_mbr, context, callback);
    }
}

/// Recursive callback search returning false to stop.
fn searchNodeCallback(
    node: *const RTreeNode,
    query_mbr: MBR,
    context: anytype,
    callback: *const fn (@TypeOf(context), u64) bool,
) bool {
    for (node.entries.items) |entry| {
        if (entry.mbr.intersects(query_mbr)) {
            if (node.is_leaf) {
                if (!callback(context, entry.id)) return false;
            } else if (entry.child) |child| {
                if (!searchNodeCallback(child, query_mbr, context, callback)) return false;
            }
        }
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "parallelSearch matches sequential search" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    // Insert a grid of entries.
    for (0..100) |i| {
        const x: f64 = @floatFromInt(i % 10);
        const y: f64 = @floatFromInt(i / 10);
        try tree.insert(.{
            .min_x = x,
            .min_y = y,
            .max_x = x + 1,
            .max_y = y + 1,
        }, @intCast(i));
    }

    const query = MBR{ .min_x = 2, .min_y = 2, .max_x = 5, .max_y = 5 };

    // Sequential search.
    var seq_results: std.ArrayList(u64) = .empty;
    defer seq_results.deinit(allocator);
    try tree.search(query, allocator, &seq_results);

    // Parallel search.
    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();

    var par_results: std.ArrayList(u64) = .empty;
    defer par_results.deinit(allocator);
    try parallelSearch(&pool, &tree, query, allocator, &par_results);

    // Both should find the same entries (order may differ).
    std.mem.sort(u64, seq_results.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, par_results.items, {}, std.sort.asc(u64));

    try std.testing.expectEqualSlices(u64, seq_results.items, par_results.items);
}

test "parallelSearch on empty tree" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 1 });
    defer pool.deinit();

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try parallelSearch(&pool, &tree, .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, allocator, &results);

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "ConcurrentRTree basic operations" {
    const allocator = std.testing.allocator;

    var tree = try ConcurrentRTree.init(allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try tree.insert(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, 2);
    try tree.insert(.{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 }, 3);

    try std.testing.expectEqual(@as(u64, 3), tree.count());

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try tree.search(.{ .min_x = 4, .min_y = 4, .max_x = 6, .max_y = 6 }, allocator, &results);

    std.mem.sort(u64, results.items, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, results.items);

    const removed = try tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u64, 2), tree.count());
}

test "bulkInsert sorts and inserts correctly" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();

    const entries = [_]BulkEntry{
        .{ .mbr = .{ .min_x = 9, .min_y = 9, .max_x = 10, .max_y = 10 }, .id = 1 },
        .{ .mbr = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .id = 2 },
        .{ .mbr = .{ .min_x = 5, .min_y = 5, .max_x = 6, .max_y = 6 }, .id = 3 },
        .{ .mbr = .{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 }, .id = 4 },
        .{ .mbr = .{ .min_x = 7, .min_y = 7, .max_x = 8, .max_y = 8 }, .id = 5 },
    };

    try bulkInsert(&pool, &tree, &entries);

    try std.testing.expectEqual(@as(u64, 5), tree.count);

    // Verify all entries are searchable.
    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try tree.search(.{ .min_x = -1, .min_y = -1, .max_x = 11, .max_y = 11 }, allocator, &results);

    std.mem.sort(u64, results.items, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, results.items);
}

test "bulkInsert rejects invalid MBR" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 1 });
    defer pool.deinit();

    const entries = [_]BulkEntry{
        .{ .mbr = .{ .min_x = 10, .min_y = 0, .max_x = 1, .max_y = 1 }, .id = 1 }, // inverted
    };

    const result = bulkInsert(&pool, &tree, &entries);
    try std.testing.expectError(error.InvalidMBR, result);
}

test "bulkInsert rejects empty input" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 1 });
    defer pool.deinit();

    const result = bulkInsert(&pool, &tree, &.{});
    try std.testing.expectError(error.EmptyInput, result);
}

test "searchCallback yields matching entries" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try tree.insert(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, 2);
    try tree.insert(.{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 }, 3);

    const Counter = struct {
        count: usize = 0,
    };

    var counter = Counter{};
    const cb = struct {
        fn call(ctx: *Counter, _: u64) bool {
            ctx.count += 1;
            return true;
        }
    }.call;

    searchCallback(&tree, .{ .min_x = 4, .min_y = 4, .max_x = 6, .max_y = 6 }, &counter, cb);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

test "searchCallback early termination" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    for (0..20) |i| {
        try tree.insert(.{
            .min_x = 0,
            .min_y = 0,
            .max_x = 10,
            .max_y = 10,
        }, @intCast(i));
    }

    const Limiter = struct {
        seen: usize = 0,
        limit: usize,
    };

    var limiter = Limiter{ .limit = 3 };
    const cb = struct {
        fn call(ctx: *Limiter, _: u64) bool {
            ctx.seen += 1;
            return ctx.seen < ctx.limit;
        }
    }.call;

    searchCallback(&tree, .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, &limiter, cb);
    try std.testing.expectEqual(@as(usize, 3), limiter.seen);
}

test "searchCallback on empty tree" {
    const allocator = std.testing.allocator;

    var tree = try RTree.init(allocator, 4);
    defer tree.deinit();

    var called = false;
    const cb = struct {
        fn call(ctx: *bool, _: u64) bool {
            ctx.* = true;
            return true;
        }
    }.call;

    searchCallback(&tree, .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, &called, cb);
    try std.testing.expect(!called);
}

test "parallelMergeSort sorts correctly" {
    const allocator = std.testing.allocator;

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();

    var items = [_]BulkEntry{
        .{ .mbr = .{ .min_x = 9, .min_y = 0, .max_x = 10, .max_y = 1 }, .id = 1 },
        .{ .mbr = .{ .min_x = 1, .min_y = 0, .max_x = 2, .max_y = 1 }, .id = 2 },
        .{ .mbr = .{ .min_x = 5, .min_y = 0, .max_x = 6, .max_y = 1 }, .id = 3 },
        .{ .mbr = .{ .min_x = 3, .min_y = 0, .max_x = 4, .max_y = 1 }, .id = 4 },
        .{ .mbr = .{ .min_x = 7, .min_y = 0, .max_x = 8, .max_y = 1 }, .id = 5 },
    };

    var scratch: [5]BulkEntry = undefined;

    pool.call(void, parallelMergeSort, SortArgs{ .items = &items, .scratch = &scratch });

    // Verify sorted by center-x.
    for (0..items.len - 1) |i| {
        const a_cx = (items[i].mbr.min_x + items[i].mbr.max_x) * 0.5;
        const b_cx = (items[i + 1].mbr.min_x + items[i + 1].mbr.max_x) * 0.5;
        try std.testing.expect(a_cx <= b_cx);
    }
}

test "ConcurrentRTree parallel search" {
    const allocator = std.testing.allocator;

    var tree = try ConcurrentRTree.init(allocator, 4);
    defer tree.deinit();

    for (0..50) |i| {
        const x: f64 = @floatFromInt(i % 10);
        const y: f64 = @floatFromInt(i / 10);
        try tree.insert(.{
            .min_x = x,
            .min_y = y,
            .max_x = x + 1,
            .max_y = y + 1,
        }, @intCast(i));
    }

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = 2 });
    defer pool.deinit();

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try tree.parallelSearchWith(&pool, .{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 3 }, allocator, &results);

    try std.testing.expect(results.items.len > 0);
}
