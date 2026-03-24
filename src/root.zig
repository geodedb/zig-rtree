// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # rtree
//!
//! A standalone, generic R-tree spatial index for Zig.
//!
//! Provides bounding-box insertion, intersection search, and removal
//! backed by a classic R-tree with configurable branching factor.
//!
//! The `RTree` is **not thread-safe**. Callers must synchronize
//! externally (e.g. with `std.Thread.RwLock`) when sharing across threads.
//!
//! ## Quick Start
//!
//! ```zig
//! const rtree = @import("rtree");
//! const std = @import("std");
//!
//! const allocator = std.testing.allocator;
//! var tree = try rtree.RTree.init(allocator, 8);
//! defer tree.deinit();
//!
//! try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
//!
//! var results: std.ArrayList(u64) = .empty;
//! defer results.deinit(allocator);
//! try tree.search(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, allocator, &results);
//! ```
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

/// Library version
pub const version = "0.1.0";

// ============================================================================
// Public Types
// ============================================================================

/// Minimum Bounding Rectangle — axis-aligned bounding box used as the
/// spatial key for every entry in the R-tree.
///
/// Coordinates are arbitrary `f64` values with no assumed projection or
/// coordinate system. The library is projection-agnostic — callers are
/// responsible for using a consistent coordinate space.
///
/// Invariant: `min_x <= max_x` and `min_y <= max_y`. The `RTree.insert`
/// method validates this and rejects NaN, Infinity, and inverted bounds.
pub const MBR = struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,

    /// Returns true when `self` fully encloses `other`.
    pub fn contains(self: MBR, other: MBR) bool {
        return self.min_x <= other.min_x and self.min_y <= other.min_y and
            self.max_x >= other.max_x and self.max_y >= other.max_y;
    }

    /// Returns true when the two rectangles overlap.
    pub fn intersects(self: MBR, other: MBR) bool {
        return !(self.max_x < other.min_x or self.min_x > other.max_x or
            self.max_y < other.min_y or self.min_y > other.max_y);
    }

    /// Area of the rectangle.
    pub fn area(self: MBR) f64 {
        return (self.max_x - self.min_x) * (self.max_y - self.min_y);
    }

    /// Smallest rectangle enclosing both `self` and `other`.
    pub fn unionMbr(self: MBR, other: MBR) MBR {
        return .{
            .min_x = @min(self.min_x, other.min_x),
            .min_y = @min(self.min_y, other.min_y),
            .max_x = @max(self.max_x, other.max_x),
            .max_y = @max(self.max_y, other.max_y),
        };
    }

    /// Additional area required to enlarge `self` so it also covers `other`.
    pub fn enlargement(self: MBR, other: MBR) f64 {
        const combined = self.unionMbr(other);
        return combined.area() - self.area();
    }

    /// Field-by-field equality.
    pub fn eql(self: MBR, other: MBR) bool {
        return self.min_x == other.min_x and self.min_y == other.min_y and
            self.max_x == other.max_x and self.max_y == other.max_y;
    }

    /// Returns true when all coordinates are finite and min <= max.
    pub fn isValid(self: MBR) bool {
        return std.math.isFinite(self.min_x) and std.math.isFinite(self.min_y) and
            std.math.isFinite(self.max_x) and std.math.isFinite(self.max_y) and
            self.min_x <= self.max_x and self.min_y <= self.max_y;
    }
};

/// A single entry stored in an `RTreeNode`.
pub const RTreeEntry = struct {
    mbr: MBR,
    id: u64,
    child: ?*RTreeNode = null,
};

/// Internal or leaf node of the R-tree.
pub const RTreeNode = struct {
    entries: std.ArrayList(RTreeEntry),
    is_leaf: bool,
    level: u16,

    pub fn init(is_leaf: bool, level: u16) RTreeNode {
        return .{
            .entries = .empty,
            .is_leaf = is_leaf,
            .level = level,
        };
    }

    pub fn deinit(self: *RTreeNode, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Computes the MBR that encloses every entry in this node.
    pub fn computeMBR(self: *const RTreeNode) ?MBR {
        if (self.entries.items.len == 0) return null;

        var mbr = self.entries.items[0].mbr;
        for (self.entries.items[1..]) |entry| {
            mbr = mbr.unionMbr(entry.mbr);
        }
        return mbr;
    }
};

// ============================================================================
// R-Tree
// ============================================================================

/// A classic R-tree spatial index with quadratic split (Guttman 1984).
///
/// `M` controls the maximum number of entries per node (branching factor).
/// Nodes split when they exceed `M` entries. `M` must be >= 2.
///
/// **Thread safety:** This type is not thread-safe. Concurrent access from
/// multiple threads requires external synchronization (e.g. `std.Thread.RwLock`).
pub const RTree = struct {
    allocator: std.mem.Allocator,
    root: ?*RTreeNode,
    M: u16,
    height: u16,
    count: u64,

    pub const InitError = error{InvalidBranchingFactor};
    pub const InsertError = error{ InvalidMBR, OutOfMemory };
    pub const RemoveError = error{OutOfMemory};

    /// Create a new R-tree. `M` must be >= 2.
    pub fn init(allocator: std.mem.Allocator, M: u16) InitError!RTree {
        if (M < 2) return error.InvalidBranchingFactor;
        return .{
            .allocator = allocator,
            .root = null,
            .M = M,
            .height = 0,
            .count = 0,
        };
    }

    pub fn deinit(self: *RTree) void {
        if (self.root) |root| {
            self.deinitNode(root);
        }
    }

    fn deinitNode(self: *RTree, node: *RTreeNode) void {
        if (!node.is_leaf) {
            for (node.entries.items) |entry| {
                if (entry.child) |child| {
                    self.deinitNode(child);
                }
            }
        }
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }

    /// Minimum entries per node (used for condensation on remove).
    fn minEntries(self: *const RTree) usize {
        return @max(1, self.M / 2);
    }

    /// Insert a spatial entry with the given bounding box and id.
    ///
    /// Returns `error.InvalidMBR` if any coordinate is NaN, Infinity,
    /// or if min > max on either axis.
    pub fn insert(self: *RTree, mbr: MBR, id: u64) InsertError!void {
        if (!mbr.isValid()) return error.InvalidMBR;

        if (self.root == null) {
            self.root = try self.createNode(true, 0);
            self.height = 1;
        }

        const entry = RTreeEntry{ .mbr = mbr, .id = id };

        if (try self.insertEntry(self.root.?, entry)) |split_entry| {
            const new_root = try self.createNode(false, self.root.?.level + 1);

            const old_root_mbr = self.root.?.computeMBR() orelse mbr;
            try new_root.entries.append(self.allocator, .{ .mbr = old_root_mbr, .id = 0, .child = self.root });
            try new_root.entries.append(self.allocator, split_entry);

            self.root = new_root;
            self.height += 1;
        }

        self.count += 1;
    }

    fn createNode(self: *RTree, is_leaf: bool, level: u16) !*RTreeNode {
        const node = try self.allocator.create(RTreeNode);
        node.* = RTreeNode.init(is_leaf, level);
        try node.entries.ensureTotalCapacity(self.allocator, @as(usize, self.M) + 1);
        return node;
    }

    fn insertEntry(self: *RTree, node: *RTreeNode, entry: RTreeEntry) !?RTreeEntry {
        if (node.is_leaf) {
            try node.entries.append(self.allocator, entry);

            if (node.entries.items.len > self.M) {
                return try self.splitNode(node);
            }
            return null;
        }

        var best_idx: usize = 0;
        var best_enlargement = std.math.inf(f64);
        var best_area = std.math.inf(f64);

        for (node.entries.items, 0..) |e, i| {
            const enl = e.mbr.enlargement(entry.mbr);
            const a = e.mbr.area();
            if (enl < best_enlargement or (enl == best_enlargement and a < best_area)) {
                best_enlargement = enl;
                best_area = a;
                best_idx = i;
            }
        }

        const chosen = &node.entries.items[best_idx];

        if (try self.insertEntry(chosen.child.?, entry)) |split_entry| {
            chosen.mbr = chosen.child.?.computeMBR() orelse entry.mbr;
            try node.entries.append(self.allocator, split_entry);

            if (node.entries.items.len > self.M) {
                return try self.splitNode(node);
            }
        } else {
            chosen.mbr = chosen.mbr.unionMbr(entry.mbr);
        }

        return null;
    }

    /// Quadratic split (Guttman 1984).
    ///
    /// PickSeeds: select the pair of entries that would waste the most
    /// area if placed in the same group.
    /// PickNext: greedily assign remaining entries to the group needing
    /// least enlargement.
    fn splitNode(self: *RTree, node: *RTreeNode) !RTreeEntry {
        const items = node.entries.items;
        const n = items.len;

        // PickSeeds — find pair with maximum wasted area
        var seed1: usize = 0;
        var seed2: usize = 1;
        var worst_waste: f64 = -std.math.inf(f64);

        for (0..n) |i| {
            for ((i + 1)..n) |j| {
                const combined = items[i].mbr.unionMbr(items[j].mbr);
                const waste = combined.area() - items[i].mbr.area() - items[j].mbr.area();
                if (waste > worst_waste) {
                    worst_waste = waste;
                    seed1 = i;
                    seed2 = j;
                }
            }
        }

        const new_node = try self.createNode(node.is_leaf, node.level);

        // Track which entries are assigned (true = group1/node, false = unassigned)
        // We'll build group2 in new_node; group1 stays in node.
        var assigned = [_]bool{false} ** 256; // max M+1 is bounded by u16
        std.debug.assert(n <= 256);

        // Seed1 stays in node (group1), seed2 goes to new_node (group2)
        assigned[seed1] = true;
        assigned[seed2] = true;
        try new_node.entries.append(self.allocator, items[seed2]);

        var group1_mbr = items[seed1].mbr;
        var group2_mbr = items[seed2].mbr;

        const m = self.minEntries();

        // PickNext — assign remaining entries
        var remaining = n - 2;
        while (remaining > 0) {
            // Count entries in each group
            var group1_count: usize = 0;
            const group2_count = new_node.entries.items.len;
            for (assigned[0..n]) |a| {
                if (a) group1_count += 1;
            }
            group1_count -= 1; // subtract seed2 which is assigned=true but in group2

            // If one group needs all remaining to reach minimum, assign them all there
            if (group1_count + remaining <= m) {
                for (0..n) |i| {
                    if (!assigned[i] and i != seed2) {
                        try new_node.entries.append(self.allocator, items[i]);
                        assigned[i] = true;
                        remaining -= 1;
                    }
                }
                continue;
            }
            if (group2_count + remaining <= m) {
                // Remaining must stay in group1 — just mark them assigned
                for (0..n) |i| {
                    if (!assigned[i] and i != seed2) {
                        assigned[i] = true;
                        group1_mbr = group1_mbr.unionMbr(items[i].mbr);
                        remaining -= 1;
                    }
                }
                continue;
            }

            // Find the entry with the greatest preference for one group
            var best_idx: usize = 0;
            var best_diff: f64 = -std.math.inf(f64);
            var best_to_group2 = false;
            var found = false;

            for (0..n) |i| {
                if (assigned[i] or i == seed2) continue;
                const d1 = group1_mbr.enlargement(items[i].mbr);
                const d2 = group2_mbr.enlargement(items[i].mbr);
                const diff = @abs(d1 - d2);
                if (!found or diff > best_diff) {
                    best_diff = diff;
                    best_idx = i;
                    best_to_group2 = d2 < d1;
                    found = true;
                }
            }

            assigned[best_idx] = true;
            if (best_to_group2) {
                try new_node.entries.append(self.allocator, items[best_idx]);
                group2_mbr = group2_mbr.unionMbr(items[best_idx].mbr);
            } else {
                group1_mbr = group1_mbr.unionMbr(items[best_idx].mbr);
            }
            remaining -= 1;
        }

        // Rebuild node (group1) — keep only entries that stayed
        var kept: usize = 0;
        for (0..n) |i| {
            if (assigned[i] and i != seed2 and !self.isInNewNode(new_node, items[i])) {
                node.entries.items[kept] = items[i];
                kept += 1;
            }
        }
        node.entries.shrinkRetainingCapacity(kept);

        const new_mbr = new_node.computeMBR() orelse MBR{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
        return RTreeEntry{ .mbr = new_mbr, .id = 0, .child = new_node };
    }

    fn isInNewNode(self: *const RTree, new_node: *RTreeNode, entry: RTreeEntry) bool {
        _ = self;
        for (new_node.entries.items) |e| {
            if (e.mbr.eql(entry.mbr) and e.id == entry.id and e.child == entry.child) return true;
        }
        return false;
    }

    /// Collect all entry ids whose bounding box intersects `query_mbr`.
    ///
    /// The caller must provide the `result_allocator` that owns the
    /// `results` list — the tree does not use its own allocator for
    /// result storage.
    pub fn search(self: *const RTree, query_mbr: MBR, result_allocator: std.mem.Allocator, results: *std.ArrayList(u64)) !void {
        if (self.root) |root| {
            try self.searchNode(root, query_mbr, result_allocator, results);
        }
    }

    fn searchNode(self: *const RTree, node: *RTreeNode, query_mbr: MBR, result_allocator: std.mem.Allocator, results: *std.ArrayList(u64)) !void {
        for (node.entries.items) |entry| {
            if (entry.mbr.intersects(query_mbr)) {
                if (node.is_leaf) {
                    try results.append(result_allocator, entry.id);
                } else if (entry.child) |child| {
                    try self.searchNode(child, query_mbr, result_allocator, results);
                }
            }
        }
    }

    /// Remove the entry matching both `mbr` (exact equality) and `id`.
    /// Returns true if found and removed. Underfull nodes are condensed
    /// by reinserting their entries.
    pub fn remove(self: *RTree, mbr: MBR, id: u64) RemoveError!bool {
        if (self.root == null) return false;

        var orphans: std.ArrayList(RTreeEntry) = .empty;
        defer orphans.deinit(self.allocator);

        if (self.removeFromNode(self.root.?, mbr, id, &orphans)) {
            self.count -= 1;

            // Shrink root if it has a single child
            while (self.root != null and !self.root.?.is_leaf and self.root.?.entries.items.len == 1) {
                const old_root = self.root.?;
                self.root = old_root.entries.items[0].child;
                old_root.deinit(self.allocator);
                self.allocator.destroy(old_root);
                self.height -= 1;
            }

            if (self.root != null and self.root.?.entries.items.len == 0) {
                self.root.?.deinit(self.allocator);
                self.allocator.destroy(self.root.?);
                self.root = null;
                self.height = 0;
            }

            // Reinsert orphaned entries from condensed nodes
            for (orphans.items) |orphan| {
                try self.reinsertLeafEntry(orphan.mbr, orphan.id);
            }

            return true;
        }

        return false;
    }

    /// Insert a leaf entry without incrementing count (for reinsertion after condensation).
    fn reinsertLeafEntry(self: *RTree, mbr: MBR, id: u64) !void {
        if (self.root == null) {
            self.root = try self.createNode(true, 0);
            self.height = 1;
        }

        const entry = RTreeEntry{ .mbr = mbr, .id = id };

        if (try self.insertEntry(self.root.?, entry)) |split_entry| {
            const new_root = try self.createNode(false, self.root.?.level + 1);

            const old_root_mbr = self.root.?.computeMBR() orelse mbr;
            try new_root.entries.append(self.allocator, .{ .mbr = old_root_mbr, .id = 0, .child = self.root });
            try new_root.entries.append(self.allocator, split_entry);

            self.root = new_root;
            self.height += 1;
        }
    }

    fn removeFromNode(self: *RTree, node: *RTreeNode, mbr: MBR, id: u64, orphans: *std.ArrayList(RTreeEntry)) bool {
        if (node.is_leaf) {
            for (node.entries.items, 0..) |entry, i| {
                if (entry.id == id and entry.mbr.eql(mbr)) {
                    _ = node.entries.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        for (node.entries.items, 0..) |entry, i| {
            if (entry.mbr.intersects(mbr)) {
                if (entry.child) |child| {
                    if (self.removeFromNode(child, mbr, id, orphans)) {
                        const m = self.minEntries();
                        if (child.entries.items.len < m) {
                            // Condense: collect orphaned leaf entries for reinsertion
                            self.collectLeafEntries(child, orphans);
                            self.deinitNode(child);
                            _ = node.entries.swapRemove(i);
                        } else if (child.entries.items.len == 0) {
                            child.deinit(self.allocator);
                            self.allocator.destroy(child);
                            _ = node.entries.swapRemove(i);
                        } else {
                            node.entries.items[i].mbr = child.computeMBR() orelse mbr;
                        }
                        return true;
                    }
                }
            }
        }

        return false;
    }

    /// Recursively collect all leaf entries from a subtree (for reinsertion after condensation).
    fn collectLeafEntries(self: *const RTree, node: *RTreeNode, orphans: *std.ArrayList(RTreeEntry)) void {
        if (node.is_leaf) {
            for (node.entries.items) |entry| {
                orphans.append(self.allocator, .{ .mbr = entry.mbr, .id = entry.id }) catch {};
            }
        } else {
            for (node.entries.items) |entry| {
                if (entry.child) |child| {
                    self.collectLeafEntries(child, orphans);
                }
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "MBR contains" {
    const outer = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const inner = MBR{ .min_x = 2, .min_y = 2, .max_x = 8, .max_y = 8 };
    const outside = MBR{ .min_x = 11, .min_y = 11, .max_x = 20, .max_y = 20 };

    try std.testing.expect(outer.contains(inner));
    try std.testing.expect(!inner.contains(outer));
    try std.testing.expect(!outer.contains(outside));
}

test "MBR intersects" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const overlapping = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const disjoint = MBR{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 };

    try std.testing.expect(a.intersects(overlapping));
    try std.testing.expect(!a.intersects(disjoint));
}

test "MBR area" {
    const mbr = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try std.testing.expectEqual(@as(f64, 100.0), mbr.area());

    const point = MBR{ .min_x = 5, .min_y = 5, .max_x = 5, .max_y = 5 };
    try std.testing.expectEqual(@as(f64, 0.0), point.area());
}

test "MBR unionMbr" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const b = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const u = a.unionMbr(b);

    try std.testing.expectEqual(@as(f64, 0.0), u.min_x);
    try std.testing.expectEqual(@as(f64, 0.0), u.min_y);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_x);
    try std.testing.expectEqual(@as(f64, 15.0), u.max_y);
}

test "MBR enlargement" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const b = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    const enl = a.enlargement(b);
    try std.testing.expectEqual(@as(f64, 125.0), enl);
}

test "MBR eql" {
    const a = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const b = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const c = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 11 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "MBR isValid" {
    const valid = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try std.testing.expect(valid.isValid());

    const point = MBR{ .min_x = 5, .min_y = 5, .max_x = 5, .max_y = 5 };
    try std.testing.expect(point.isValid());

    const inverted = MBR{ .min_x = 10, .min_y = 0, .max_x = 0, .max_y = 10 };
    try std.testing.expect(!inverted.isValid());

    const nan_mbr = MBR{ .min_x = std.math.nan(f64), .min_y = 0, .max_x = 10, .max_y = 10 };
    try std.testing.expect(!nan_mbr.isValid());

    const inf_mbr = MBR{ .min_x = 0, .min_y = 0, .max_x = std.math.inf(f64), .max_y = 10 };
    try std.testing.expect(!inf_mbr.isValid());
}

test "RTree init rejects M < 2" {
    try std.testing.expectError(error.InvalidBranchingFactor, RTree.init(std.testing.allocator, 0));
    try std.testing.expectError(error.InvalidBranchingFactor, RTree.init(std.testing.allocator, 1));

    var tree = try RTree.init(std.testing.allocator, 2);
    defer tree.deinit();
    try std.testing.expectEqual(@as(u16, 2), tree.M);
}

test "RTree init and deinit empty" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try std.testing.expectEqual(@as(?*RTreeNode, null), tree.root);
    try std.testing.expectEqual(@as(u64, 0), tree.count);
    try std.testing.expectEqual(@as(u16, 0), tree.height);
}

test "RTree insert rejects invalid MBR" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try std.testing.expectError(error.InvalidMBR, tree.insert(.{
        .min_x = std.math.nan(f64),
        .min_y = 0,
        .max_x = 10,
        .max_y = 10,
    }, 1));

    try std.testing.expectError(error.InvalidMBR, tree.insert(.{
        .min_x = 0,
        .min_y = 0,
        .max_x = std.math.inf(f64),
        .max_y = 10,
    }, 2));

    try std.testing.expectError(error.InvalidMBR, tree.insert(.{
        .min_x = 10,
        .min_y = 0,
        .max_x = 0,
        .max_y = 10,
    }, 3));

    try std.testing.expectEqual(@as(u64, 0), tree.count);
}

test "RTree insert single" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    try std.testing.expectEqual(@as(u64, 1), tree.count);
    try std.testing.expect(tree.root != null);
}

test "RTree insert and search" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try tree.insert(.{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 }, 2);
    try tree.insert(.{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 }, 3);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 7, .min_y = 7, .max_x = 12, .max_y = 12 }, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "RTree search no results" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 50, .min_y = 50, .max_x = 60, .max_y = 60 }, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "RTree search on empty tree" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "RTree remove" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    const mbr = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    try tree.insert(mbr, 1);
    try std.testing.expectEqual(@as(u64, 1), tree.count);

    const removed = try tree.remove(mbr, 1);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u64, 0), tree.count);
    try std.testing.expectEqual(@as(?*RTreeNode, null), tree.root);
}

test "RTree remove requires exact MBR match" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    const mbr1 = MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const mbr2 = MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    try tree.insert(mbr1, 1);
    try tree.insert(mbr2, 1);

    const removed = try tree.remove(mbr2, 1);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u64, 1), tree.count);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);
    try tree.search(mbr1, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "RTree remove nonexistent" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);

    const removed = try tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 99);
    try std.testing.expect(!removed);
    try std.testing.expectEqual(@as(u64, 1), tree.count);
}

test "RTree remove from empty" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    const removed = try tree.remove(.{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 }, 1);
    try std.testing.expect(!removed);
}

test "RTree split on overflow" {
    var tree = try RTree.init(std.testing.allocator, 2);
    defer tree.deinit();

    try tree.insert(.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, 1);
    try tree.insert(.{ .min_x = 2, .min_y = 2, .max_x = 3, .max_y = 3 }, 2);
    try tree.insert(.{ .min_x = 4, .min_y = 4, .max_x = 5, .max_y = 5 }, 3);

    try std.testing.expectEqual(@as(u64, 3), tree.count);
    try std.testing.expect(tree.height >= 2);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = -1, .min_y = -1, .max_x = 6, .max_y = 6 }, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
}

test "RTree many inserts and searches" {
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const x: f64 = @floatFromInt(i % 10);
        const y: f64 = @floatFromInt(i / 10);
        try tree.insert(.{
            .min_x = x,
            .min_y = y,
            .max_x = x + 0.5,
            .max_y = y + 0.5,
        }, i);
    }

    try std.testing.expectEqual(@as(u64, 100), tree.count);

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = 2, .min_y = 2, .max_x = 5, .max_y = 5 }, std.testing.allocator, &results);
    try std.testing.expect(results.items.len > 0);
    try std.testing.expect(results.items.len < 100);
}

test "RTree condensation on remove" {
    // Use M=4 (minEntries=2). Insert 10 entries to build a multi-level tree,
    // then remove entries to trigger condensation of underfull nodes.
    var tree = try RTree.init(std.testing.allocator, 4);
    defer tree.deinit();

    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        const x: f64 = @floatFromInt(i);
        try tree.insert(.{ .min_x = x, .min_y = 0, .max_x = x + 0.5, .max_y = 0.5 }, i);
    }

    try std.testing.expectEqual(@as(u64, 20), tree.count);
    const initial_height = tree.height;
    try std.testing.expect(initial_height >= 2);

    // Remove most entries — should trigger condensation
    i = 0;
    while (i < 16) : (i += 1) {
        const x: f64 = @floatFromInt(i);
        const removed = try tree.remove(.{ .min_x = x, .min_y = 0, .max_x = x + 0.5, .max_y = 0.5 }, i);
        try std.testing.expect(removed);
    }

    try std.testing.expectEqual(@as(u64, 4), tree.count);

    // Remaining entries should all be searchable
    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(std.testing.allocator);

    try tree.search(.{ .min_x = -1, .min_y = -1, .max_x = 100, .max_y = 100 }, std.testing.allocator, &results);
    try std.testing.expectEqual(@as(usize, 4), results.items.len);
}

test "RTreeNode computeMBR empty" {
    var node = RTreeNode.init(true, 0);
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?MBR, null), node.computeMBR());
}

test {
    std.testing.refAllDecls(@This());
}
