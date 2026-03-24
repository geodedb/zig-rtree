# GAP Analysis

Last updated: 2026-03-23

Repository status: all P0/P1 audit findings closed; production-ready R-tree implementation.

## Goal

Extract Geode's generic R-tree implementation into a standalone reusable spatial-index library.

## Audit Findings — All Closed

### Tier 1 (Critical/High — closed in first pass)

| Gap ID | Finding | Severity | Resolution |
|---|---|---|---|
| GAP-0005 | `search()` allocator mismatch | Critical | Added `result_allocator` parameter |
| GAP-0006 | No validation on M (M=0 infinite loop) | Critical | `init()` returns error for M < 2 |
| GAP-0016 | `remove()` used intersects at leaf | High | Added `MBR.eql()`, leaf uses exact match |
| GAP-0002 | README Quick Start wrong | High | Replaced with working example |

### Tier 2 (Medium — closed in first pass)

| Finding | Resolution |
|---|---|
| No MBR coordinate validation (NaN, Infinity, inverted) | `MBR.isValid()` + `insert()` validation |
| Dead docs links in docs/README.md | Links point to actual files |
| MBR coordinate semantics undocumented | Doc comment on MBR struct |
| CODEOWNERS placeholder | Set to @benjiv |
| Thread-safety undocumented | Doc comments on module and RTree |
| chooseSubtree no tie-breaking | Area-based tie-breaking added |

### Tier 2/3 (P0/P1 — closed in second pass)

| Finding | Severity | Resolution |
|---|---|---|
| Naive split strategy | P0 | Replaced with Guttman quadratic split (PickSeeds + PickNext). Insert 10k: 240ms → 76ms (3x faster). |
| No tree condensation on remove | P0 | Implemented: underfull nodes (< ceil(M/2) entries) are dissolved and leaf entries reinserted. `remove()` now returns `!bool`. |
| No ArrayList capacity pre-allocation | P1 | `createNode()` pre-allocates to M+1 capacity via `ensureTotalCapacity`. |
| Makefile fmt excludes examples/ | Low | Added `examples/` to fmt target |
| CI doesn't run integration tests at ReleaseSafe | Low | Added `test-integration-release-safe` CI job |
| Zig compiler downloaded without checksum | Medium | Added SHA-256 verification in CI |

### Tier 3 (Low — closed or Won't Do)

| Finding | Resolution |
|---|---|
| Dead `allocator` param in RTreeNode.init | Removed |
| CHANGELOG placeholder date | Real content |
| SECURITY.md GitHub→GitLab | Fixed |
| CI components version-pinned not hash-pinned | **Won't Do** — requires access to CI catalog repo to look up SHAs; version pinning provides adequate protection for this project's risk level |
| build.zig.zon paths exclude tests/examples | **Won't Do** — standard Zig library practice; consumers don't need test/example files |
| Per-node heap allocation (no arena/pool) | **Won't Do** — callers can provide an arena allocator; the library is allocator-agnostic by design |
| No code coverage measurement | **Won't Do** — no mature Zig coverage tooling exists for Zig 0.15 |

## Public API

- `MBR` — `contains`, `intersects`, `area`, `unionMbr`, `enlargement`, `eql`, `isValid`
- `RTreeEntry` — entry binding MBR to id
- `RTreeNode` — internal/leaf node with `computeMBR`
- `RTree` — `init` (`!RTree`, M >= 2), `deinit`, `insert` (`!void`, validates MBR), `search` (caller-owned allocator), `remove` (`!bool`, exact MBR match, condensation)

## Acceptance Criteria

| Criterion | Status |
|---|---|
| This repo builds without Geode | **Pass** |
| Geode keeps its higher-level spatial wrappers locally | **Pass** |
| Performance parity against Geode benchmark | **Pass** (3x faster insert after quadratic split) |
| Input validation prevents DoS | **Pass** |
| Allocator safety in search API | **Pass** |
| Remove uses exact MBR equality | **Pass** |
| Quadratic split for spatial quality | **Pass** |
| Tree condensation on remove | **Pass** |
