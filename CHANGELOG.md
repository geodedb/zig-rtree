# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.18] - 2026-11-17

### Changed

- thread-pool v0.2.10 -> v0.2.11 and otel v0.1.28 -> v0.1.30, whose tree (slog, json, config, yaml, metrics, tls, grpc-zig v0.1.16) is on thread-pool v0.2.11, so this library and its consumers resolve a single otel and thread-pool (SONNY-6630).

## [0.1.16] - 2026-10-12

### Changed

- Pin OTEL v0.1.27 to converge the final dependency graph after its CI header-provisioning fix. Runtime algorithms and benchmark budgets remain unchanged.

### Added

- Core R-tree spatial index: `MBR`, `RTreeEntry`, `RTreeNode`, `RTree`
- Insert, search (intersection), and remove operations
- Input validation: rejects NaN, Infinity, inverted MBR bounds, and M < 2
- Bounding-box query example (`examples/basic.zig`)
- Unit tests (22) and integration tests (9) including performance benchmark
- Integration tests ported from Geode's spatial index test suite

[Unreleased]: https://gitlab.com/devnw/zig/rtree/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/rtree/-/releases/v0.1.0

## [0.1.12] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

## [0.1.11] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.1.10] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).
