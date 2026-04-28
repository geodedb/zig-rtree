// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies the no-op invariant when -Dwith_otel=false (the default).
//!
//! rtree publishes its public surface as the "rtree" module rooted at
//! src/root.zig. The seam is exposed as `rtree.observability` so this
//! test can drive the disabled-mode invariants through the public root.

const std = @import("std");
const rtree = @import("rtree");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    // The "default" assertion only holds for the disabled build. When
    // the operator forces -Dwith_otel=true, this test runs against the
    // enabled module and must skip rather than misreport the default.
    if (build_options.with_otel) return error.SkipZigTest;
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, rtree.observability.enabled);
}

test "spatial-op span helper is a no-op when otel disabled" {
    if (rtree.observability.enabled) return error.SkipZigTest;
    var span = rtree.observability.startSpatialOpSpan("search");
    rtree.observability.endSpatialOpSpan(span, true, 0);
    // Belt-and-suspenders: callers may also invoke `span.end(null)`
    // directly. The seam's `endSpatialOpSpan` already covers the
    // lifecycle; this line just verifies the no-op fallback's signature
    // matches the real API's `Span.end(?u64) void`.
    span.end(null);
}

test "client/server seams remain no-ops when otel disabled" {
    if (rtree.observability.enabled) return error.SkipZigTest;
    var span = rtree.observability.startClientSpan(.{
        .method = "GET",
        .url = "https://example.test/",
    });
    rtree.observability.endClientSpan(span, 200);
    span.end(null);
}
