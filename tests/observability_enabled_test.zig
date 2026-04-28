// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies one rtree spatial-op span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! Placeholder body in Chunk A — Chunk C wires the real recorder
//! assertions. The file is registered as a test target under BOTH
//! flag values so the build wiring is exercised even when the flag
//! is off; the test body short-circuits via the `enabled` skip-guard.
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

test "rtree.* span recorded when otel enabled (placeholder)" {
    if (!rtree.observability.enabled) return error.SkipZigTest;
    // Real assertions land in Chunk C; this file simply has to exist
    // and skip cleanly under -Dwith_otel=false so build.zig's test
    // graph compiles in both flag modes.
    _ = otel;
}
