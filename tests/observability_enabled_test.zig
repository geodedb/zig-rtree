// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies one rtree spatial-op span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from template — we exercise the seam directly via
//! the in-memory recorder rather than driving a real `RTree.search`.
//! The seam's behaviour is identical: `startSpatialOpSpan` ->
//! `endSpatialOpSpan` enters and leaves one tracer span. Driving a
//! real R-tree would produce extra `rtree.insert` spans during
//! fixture setup and would couple the test to the live `RTree`
//! constructor — the seam's contract is what's under test here.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const rtree = @import("rtree");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one rtree.search span recorded when otel enabled" {
    if (!rtree.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "rtree-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "rtree-test" });
    rtree.observability.global.tracer = &tracer;
    defer rtree.observability.global.tracer = null;

    // Drive the seam directly: start a search-shaped span with
    // result_count = 5.
    const span = rtree.observability.startSpatialOpSpan("search");
    rtree.observability.endSpatialOpSpan(span, true, 5);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    const recorded = recorder.spans.items[0];

    // Span name shape: "rtree.{operation}".
    try std.testing.expectEqualStrings("rtree.search", recorded.name);

    // Verify the db.system + db.operation + rtree.results attributes
    // landed on the span. The in-memory recorder stores attributes as
    // `[]KV` (string-stringified key/value pairs) — see
    // otel/src/exporters/in_memory.zig.
    var found_system: ?[]const u8 = null;
    var found_op: ?[]const u8 = null;
    var found_results: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "db.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "db.operation")) {
            found_op = kv.value;
        } else if (std.mem.eql(u8, kv.key, "rtree.results")) {
            found_results = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingDbSystemAttribute;
    try std.testing.expectEqualStrings("rtree", system_value);
    const op_value = found_op orelse return error.MissingDbOperationAttribute;
    try std.testing.expectEqualStrings("search", op_value);
    const results_value = found_results orelse return error.MissingRtreeResultsAttribute;
    try std.testing.expectEqualStrings("5", results_value);
}
