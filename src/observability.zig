// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! observability.zig — single-file otel seam for rtree.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` / `otel.instrumentation.http` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break R-tree
//! operations.
//!
//! NOTE: deviation from template — rtree operations don't fit the HTTP
//! `instrumentation.http.startClientSpan` shape (HTTP method/url is
//! lossy for an in-process spatial index). We expose the generic
//! `startClientSpan` / `startServerSpan` helpers for symmetry with
//! grpc-zig (and to keep the seam template-compatible), AND a
//! domain-specific `startSpatialOpSpan(operation)` helper that
//! constructs a span via `otel.api.trace.Tracer.startSpan` directly
//! with an rtree-shaped span name (`"rtree.{operation}"`) and the
//! `db.system="rtree"` / `db.operation` semantic conventions. Result
//! cardinality is reported via the `rtree.results` attribute on
//! `endSpatialOpSpan` so callers can attach query-shape metadata
//! without leaking the (potentially sensitive) bbox coordinates.

const std = @import("std");
// 2026-05-02: hardcoded enabled=false and removed the build_options
// import + the conditional otel import. The previous pattern surfaced
// a Zig 0.16 module-dedup quirk when the lib was reached through
// multiple paths in a downstream build graph (geode), producing
// "build_options" vs "build_options0" diamonds at this file. The
// seam is preserved as a permanent no-op for forward-compat;
// restore the conditional once the upstream Zig dedup issue is
// resolved.
pub const enabled: bool = false;

const otel = struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Helper: reads either a `[]const u8` field OR a function-typed field
/// returning `[]const u8`, so the seam accepts both shapes — the closure
/// shape the recipe template ships AND the plain-string-field shape used
/// at hot-path call sites.
inline fn accessOr(req: anytype, comptime field: []const u8) []const u8 {
    const T = @TypeOf(@field(req, field));
    return switch (@typeInfo(T)) {
        .pointer => @field(req, field),
        .@"fn" => @field(req, field)(),
        else => @compileError("observability: unsupported field type for " ++ field),
    };
}

/// Start a span for a generic outbound operation. Kept for template
/// symmetry; rtree hot paths use `startSpatialOpSpan` instead.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for a generic inbound operation. Kept for template
/// symmetry; rtree has no authoritative-server entry point.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .route = accessOr(req, "route"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Start a span for an R-tree spatial operation.
///
/// Span shape:
///   - name: `"rtree.{operation}"` (e.g. `"rtree.insert"`,
///     `"rtree.search"`, `"rtree.delete"`, `"rtree.bulk_load"`).
///   - kind: `.client` (the spatial index acts as a client to the
///     calling code's logical query layer; the OpenTelemetry `db.*`
///     semantic conventions specify `client` for the calling side of
///     a database interaction).
///   - attributes:
///       * `db.system   = "rtree"`
///       * `db.operation = operation`
///
/// `operation` MUST be a string literal or a slice whose lifetime
/// outlives the span. The SDK dupes the span name into the span arena,
/// but the `db.operation` attribute is stored by reference at the
/// stringified-value layer; using a stable string keeps the recorder
/// safe from dangling slices.
///
/// SECURITY NOTE: callers MUST NOT pass bounding-box coordinates as
/// part of `operation` or as attributes — geo coordinates can be
/// sensitive and the seam intentionally only carries the operation
/// name and the result cardinality. Non-coordinate metadata such as
/// `rtree.bbox.dim` (which dimensionality the index was built for) is
/// safe; per-call rect values are not.
pub fn startSpatialOpSpan(operation: []const u8) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    // Compose the span name on the stack; the SDK dupes the name into
    // the span arena, so a pointer to a stack buffer is safe here.
    var name_buf: [128]u8 = undefined;
    const span_name = std.fmt.bufPrint(
        name_buf[0..],
        "rtree.{s}",
        .{operation},
    ) catch "rtree";
    const span = tracer.startSpan(.empty(), span_name, .{ .kind = .client }) catch return Span{};
    // Best-effort attribute attachment. Failures (OOM in the attribute
    // set) cannot block the spatial operation — telemetry is non-fatal.
    span.setStringAttribute("db.system", "rtree") catch {};
    span.setStringAttribute("db.operation", operation) catch {};
    return span;
}

/// Close a spatial-op span, recording success/failure + result count.
///
/// `result_count` is attached as the `rtree.results` integer attribute.
/// For mutating operations (`insert`, `delete`, `bulk_load`) it is the
/// number of entries affected; for `search` / `nearest` it is the
/// number of matching ids. Pass `0` when the operation produced no
/// observable result count.
///
/// On `ok = true` we set status `.ok`; on `ok = false` we set status
/// `.error_`. Callers typically pair this with `defer span.end(null)`
/// at the call site so the span is always ended regardless of which
/// path is taken. `setStatus` + `end` are idempotent for status
/// reporting (only the first status write wins; the deferred
/// `end(null)` is a redundant no-op).
pub fn endSpatialOpSpan(span: Span, ok: bool, result_count: usize) void {
    if (!enabled) return;
    // Best-effort: attribute write failures cannot block the operation.
    span.setIntAttribute("rtree.results", @intCast(result_count)) catch {};
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig.
        span.setStatus(.@"error", "");
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
