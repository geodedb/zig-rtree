// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel and concurrent extensions for the R-tree.
//!
//! This module provides:
//!
//! - **`parallelSearch`** — Fan-out subtree searches across a `ThreadPool`
//!   using flat chunking with submitBatch/WaitGroup parallelism.
//! - **`ConcurrentRTree`** — Thread-safe wrapper using `std.Io.RwLock` for
//!   concurrent reads and exclusive writes.
//! - **`bulkInsert`** — Batch insertion that sorts entries spatially and inserts
//!   in an order that reduces overlap, with parallel sorting via thread-pool.
//! - **`searchCallback`** — Streaming search that yields results one at a time
//!   via a caller-provided callback, avoiding full materialization.
//!
//! All parallel operations require a `ThreadPool` that has been initialized.
//! The underlying `RTree` remains single-threaded; parallelism is layered on
//! top via these wrappers.

const std = @import("std");
const tp = @import("thread_pool");
const root = @import("root.zig");

/// Obtain a zero-arg Io handle for uncancelable sync primitives.
inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const MBR = root.MBR;
pub const RTree = root.RTree;
pub const RTreeEntry = root.RTreeEntry;
pub const RTreeNode = root.RTreeNode;

const MAX_CHUNKS = 64;

// ============================================================================
// GAP-P002: Parallel Search
// ============================================================================

/// Thread-safe accumulator for parallel search results.
const SharedResults = struct {
    mutex: std.Io.Mutex = .init,
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    oom: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Arguments passed to each subtree search task.
const SearchTaskArgs = struct {
    node: *const RTreeNode,
    query_mbr: MBR,
    shared: *SharedResults,
};

/// Recursively search a subtree, appending matching IDs to shared results.
fn searchSubtree(node: *const RTreeNode, query: MBR, shared: *SharedResults) void {
    if (shared.oom.load(.monotonic)) return;

    if (node.is_leaf) {
        shared.mutex.lockUncancelable(io());
        defer shared.mutex.unlock(io());
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

    for (node.entries.items) |entry| {
        if (entry.mbr.intersects(query)) {
            if (entry.child) |child| {
                searchSubtree(child, query, shared);
            }
        }
    }
}

/// Task function wrapper for thread-pool dispatch.
fn searchTaskFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const args: *SearchTaskArgs = @ptrCast(@alignCast(ctx));
    searchSubtree(args.node, args.query_mbr, args.shared);
}

/// Search the R-tree for all entries intersecting `query_mbr`, distributing
/// subtree traversals across the thread pool.
///
/// Results are appended to `results` (which the caller owns). The tree's own
/// allocator is not used for result storage.
///
/// Returns `error.OutOfMemory` if result accumulation fails.
pub fn parallelSearch(
    pool: *tp.ThreadPool,
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

    // Collect top-level intersecting children for parallel dispatch.
    if (tree_root.is_leaf) {
        // Single leaf: search directly.
        searchSubtree(tree_root, query_mbr, &shared);
        if (shared.oom.load(.monotonic)) return error.OutOfMemory;
        return;
    }

    // Gather intersecting children of the root for parallel dispatch.
    var task_args: [MAX_CHUNKS]SearchTaskArgs = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    for (tree_root.entries.items) |entry| {
        if (!entry.mbr.intersects(query_mbr)) continue;
        const child = entry.child orelse continue;
        if (n >= MAX_CHUNKS) {
            // Overflow: search remaining subtrees sequentially.
            searchSubtree(child, query_mbr, &shared);
            continue;
        }
        task_args[n] = .{ .node = child, .query_mbr = query_mbr, .shared = &shared };
        batch[n] = .{ .task_fn = searchTaskFn, .ctx = @ptrCast(&task_args[n]) };
        n += 1;
    }

    if (n == 0) {
        if (shared.oom.load(.monotonic)) return error.OutOfMemory;
        return;
    }

    var wg = pool.waitGroup();
    wg.add(@intCast(n));
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // On submit error: execute remaining tasks sequentially.
        for (task_args[0..n]) |*args| {
            searchSubtree(args.node, args.query_mbr, &shared);
            wg.done();
        }
        if (shared.oom.load(.monotonic)) return error.OutOfMemory;
        return;
    };
    wg.wait();

    if (shared.oom.load(.monotonic)) return error.OutOfMemory;
}

// ============================================================================
// GAP-P004: ConcurrentRTree
// ============================================================================

/// Thread-safe R-tree wrapper providing concurrent read access and exclusive
/// write access via `std.Io.RwLock`.
///
/// Multiple threads may call `search` / `parallelSearch` / `searchCallback`
/// simultaneously. Calls to `insert`, `remove`, and `bulkInsert` acquire an
/// exclusive lock.
pub const ConcurrentRTree = struct {
    tree: RTree,
    lock: std.Io.RwLock = .init,

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
        self.lock.lockUncancelable(io());
        defer self.lock.unlock(io());
        try self.tree.insert(mbr, id);
    }

    /// Remove an entry (exclusive lock).
    pub fn remove(self: *ConcurrentRTree, mbr: MBR, id: u64) RemoveError!bool {
        self.lock.lockUncancelable(io());
        defer self.lock.unlock(io());
        return try self.tree.remove(mbr, id);
    }

    /// Search for intersecting entries (shared lock).
    pub fn search(
        self: *ConcurrentRTree,
        query_mbr: MBR,
        result_allocator: std.mem.Allocator,
        results: *std.ArrayList(u64),
    ) !void {
        self.lock.lockSharedUncancelable(io());
        defer self.lock.unlockShared(io());
        try self.tree.search(query_mbr, result_allocator, results);
    }

    /// Parallel search using thread pool (shared lock).
    pub fn parallelSearchWith(
        self: *ConcurrentRTree,
        pool: *tp.ThreadPool,
        query_mbr: MBR,
        result_allocator: std.mem.Allocator,
        results: *std.ArrayList(u64),
    ) !void {
        self.lock.lockSharedUncancelable(io());
        defer self.lock.unlockShared(io());
        try parallelSearch(pool, &self.tree, query_mbr, result_allocator, results);
    }

    /// Callback-based streaming search (shared lock).
    pub fn searchCallbackWith(
        self: *ConcurrentRTree,
        query_mbr: MBR,
        context: anytype,
        callback: *const fn (@TypeOf(context), u64) bool,
    ) void {
        self.lock.lockSharedUncancelable(io());
        defer self.lock.unlockShared(io());
        searchCallback(&self.tree, query_mbr, context, callback);
    }

    /// Bulk insert entries (exclusive lock).
    pub fn bulkInsertWith(
        self: *ConcurrentRTree,
        pool: *tp.ThreadPool,
        entries: []const BulkEntry,
    ) (RTree.InsertError || error{EmptyInput})!void {
        self.lock.lockUncancelable(io());
        defer self.lock.unlock(io());
        try bulkInsert(pool, &self.tree, entries);
    }

    /// Number of entries in the tree.
    pub fn count(self: *ConcurrentRTree) u64 {
        self.lock.lockSharedUncancelable(io());
        defer self.lock.unlockShared(io());
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

/// Arguments for a parallel sort chunk task.
const SortChunkArgs = struct {
    items: []BulkEntry,
};

/// Task function: sort a single chunk using std.mem.sort.
fn sortChunkFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const args: *SortChunkArgs = @ptrCast(@alignCast(ctx));
    std.mem.sort(BulkEntry, args.items, {}, bulkEntryLessThan);
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
/// overlap and improve tree quality. The sort is parallelized via thread-pool
/// flat chunking.
///
/// This is faster than N sequential `insert()` calls for large batches because
/// spatially-ordered insertion produces better node packing and fewer splits.
///
/// Each entry's MBR is validated; invalid entries return `error.InvalidMBR`.
pub fn bulkInsert(
    pool: *tp.ThreadPool,
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

    // Parallel sort: split into up to MAX_CHUNKS chunks, sort each in parallel,
    // then merge sequentially. Falls back to sequential sort on any error.
    const num_chunks = @min(MAX_CHUNKS, entries.len);

    if (num_chunks <= 1) {
        std.mem.sort(BulkEntry, sorted, {}, bulkEntryLessThan);
    } else {
        // Sort each chunk in parallel.
        var chunk_args: [MAX_CHUNKS]SortChunkArgs = undefined;
        var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
        const chunk_size = (sorted.len + num_chunks - 1) / num_chunks;

        var actual_chunks: usize = 0;
        var offset: usize = 0;
        while (offset < sorted.len) {
            const end = @min(offset + chunk_size, sorted.len);
            chunk_args[actual_chunks] = .{ .items = sorted[offset..end] };
            batch[actual_chunks] = .{ .task_fn = sortChunkFn, .ctx = @ptrCast(&chunk_args[actual_chunks]) };
            actual_chunks += 1;
            offset = end;
        }

        var wg = pool.waitGroup();
        wg.add(@intCast(actual_chunks));
        _ = pool.submitBatch(batch[0..actual_chunks], .{ .wait_group = &wg }) catch {
            // Fallback: sort sequentially.
            std.mem.sort(BulkEntry, sorted, {}, bulkEntryLessThan);
            // Drain wg since tasks were not dispatched.
            var i: usize = 0;
            while (i < actual_chunks) : (i += 1) wg.done();
            // Insert in sorted order.
            for (sorted) |entry| {
                try tree.insert(entry.mbr, entry.id);
            }
            return;
        };
        wg.wait();

        // Merge sorted chunks sequentially using a scratch buffer.
        const scratch = try tree.allocator.alloc(BulkEntry, sorted.len);
        defer tree.allocator.free(scratch);

        var merge_size: usize = chunk_size;
        while (merge_size < sorted.len) {
            var pos: usize = 0;
            while (pos < sorted.len) {
                const left_end = @min(pos + merge_size, sorted.len);
                const right_end = @min(pos + merge_size * 2, sorted.len);
                if (left_end < right_end) {
                    merge(sorted[pos..right_end], scratch[pos..right_end], left_end - pos);
                }
                pos += merge_size * 2;
            }
            merge_size *= 2;
        }
    }

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
/// This is a single-threaded operation (no thread pool required).
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
    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 2, .min_threads = 2 });
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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 1, .min_threads = 1 });
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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 2, .min_threads = 2 });
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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 1, .min_threads = 1 });
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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 1, .min_threads = 1 });
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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 2, .min_threads = 2 });
    defer pool.deinit();

    var items = [_]BulkEntry{
        .{ .mbr = .{ .min_x = 9, .min_y = 0, .max_x = 10, .max_y = 1 }, .id = 1 },
        .{ .mbr = .{ .min_x = 1, .min_y = 0, .max_x = 2, .max_y = 1 }, .id = 2 },
        .{ .mbr = .{ .min_x = 5, .min_y = 0, .max_x = 6, .max_y = 1 }, .id = 3 },
        .{ .mbr = .{ .min_x = 3, .min_y = 0, .max_x = 4, .max_y = 1 }, .id = 4 },
        .{ .mbr = .{ .min_x = 7, .min_y = 0, .max_x = 8, .max_y = 1 }, .id = 5 },
    };

    // Use bulkInsert-style parallel sort: sort chunks then merge.
    const num_chunks = @min(MAX_CHUNKS, items.len);
    const chunk_size = (items.len + num_chunks - 1) / num_chunks;

    var chunk_args: [MAX_CHUNKS]SortChunkArgs = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var actual_chunks: usize = 0;
    var offset: usize = 0;
    while (offset < items.len) {
        const end = @min(offset + chunk_size, items.len);
        chunk_args[actual_chunks] = .{ .items = items[offset..end] };
        batch[actual_chunks] = .{ .task_fn = sortChunkFn, .ctx = @ptrCast(&chunk_args[actual_chunks]) };
        actual_chunks += 1;
        offset = end;
    }

    var wg = pool.waitGroup();
    wg.add(@intCast(actual_chunks));
    _ = try pool.submitBatch(batch[0..actual_chunks], .{ .wait_group = &wg });
    wg.wait();

    // Merge chunks.
    var scratch: [5]BulkEntry = undefined;
    var merge_size: usize = chunk_size;
    while (merge_size < items.len) {
        var pos: usize = 0;
        while (pos < items.len) {
            const left_end = @min(pos + merge_size, items.len);
            const right_end = @min(pos + merge_size * 2, items.len);
            if (left_end < right_end) {
                merge(items[pos..right_end], scratch[pos..right_end], left_end - pos);
            }
            pos += merge_size * 2;
        }
        merge_size *= 2;
    }

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

    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 2, .min_threads = 2 });
    defer pool.deinit();

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);
    try tree.parallelSearchWith(&pool, .{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 3 }, allocator, &results);

    try std.testing.expect(results.items.len > 0);
}
