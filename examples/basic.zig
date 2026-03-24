// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Bounding-box query example for rtree.
//!
//! Demonstrates creating an R-tree, inserting spatial entries,
//! running an intersection search, and removing an entry.

const std = @import("std");
const rtree = @import("rtree");

const print = std.debug.print;

pub fn main() !void {
    print("rtree — Bounding-Box Query Example\n", .{});
    print("===================================\n\n", .{});

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tree = try rtree.RTree.init(allocator, 8);
    defer tree.deinit();

    const cities = [_]struct { name: []const u8, mbr: rtree.MBR, id: u64 }{
        .{ .name = "New York", .mbr = .{ .min_x = -74.3, .min_y = 40.5, .max_x = -73.7, .max_y = 40.9 }, .id = 1 },
        .{ .name = "San Francisco", .mbr = .{ .min_x = -122.5, .min_y = 37.7, .max_x = -122.3, .max_y = 37.8 }, .id = 2 },
        .{ .name = "London", .mbr = .{ .min_x = -0.5, .min_y = 51.3, .max_x = 0.3, .max_y = 51.7 }, .id = 3 },
        .{ .name = "Tokyo", .mbr = .{ .min_x = 139.6, .min_y = 35.5, .max_x = 139.9, .max_y = 35.8 }, .id = 4 },
        .{ .name = "Sydney", .mbr = .{ .min_x = 151.0, .min_y = -34.0, .max_x = 151.3, .max_y = -33.7 }, .id = 5 },
    };

    for (cities) |c| {
        try tree.insert(c.mbr, c.id);
        print("  Inserted: {s} (id={d})\n", .{ c.name, c.id });
    }

    print("\nTree has {d} entries, height={d}\n\n", .{ tree.count, tree.height });

    const europe = rtree.MBR{ .min_x = -10.0, .min_y = 35.0, .max_x = 40.0, .max_y = 72.0 };
    print("Searching Europe region [{d},{d}]x[{d},{d}]:\n", .{
        europe.min_x, europe.min_y, europe.max_x, europe.max_y,
    });

    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(allocator);

    try tree.search(europe, allocator, &results);

    for (results.items) |id| {
        for (cities) |c| {
            if (c.id == id) {
                print("  Found: {s}\n", .{c.name});
            }
        }
    }

    print("\n{d} result(s)\n\n", .{results.items.len});

    const removed = try tree.remove(cities[2].mbr, cities[2].id);
    print("Removed London: {}\n", .{removed});
    print("Tree now has {d} entries\n", .{tree.count});
}
