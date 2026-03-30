# GAP Analysis

Last updated: 2026-03-30

Repository status: all P0/P1 audit findings closed; production-ready R-tree implementation.
Parallelism/concurrency status: **implemented** — `spice` dependency wired; parallel search, bulk insert, concurrent wrapper, and callback search all closed.

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

## Parallelism & Concurrency Gaps — All Closed

### Context

The R-tree library uses the [`spice`](../spice) heartbeat-scheduled fork/join thread pool for parallel operations. The `parallel` sub-module (`src/parallel.zig`) provides `parallelSearch`, `ConcurrentRTree`, `bulkInsert`, and `searchCallback`.

### GAP-P001 — `spice` dependency not declared (Critical) — **Closed**

| Field | Value |
|---|---|
| Severity | Critical |
| Resolution | Added `spice` as path dependency in `build.zig.zon`; wired module in `build.zig` for library, tests, integration tests, and check step. |

### GAP-P002 — No parallel search (High) — **Closed**

| Field | Value |
|---|---|
| Severity | High |
| Resolution | `parallel.parallelSearch()` fans out subtree searches via spice fork/join. At each internal node, the first intersecting child is forked to a background worker; remaining children execute on the current worker. Results are collected into a mutex-protected `SharedResults` accumulator. 11 unit tests verify correctness against sequential search. |

### GAP-P003 — No parallel bulk insert (Medium) — **Closed**

| Field | Value |
|---|---|
| Severity | Medium |
| Resolution | `parallel.bulkInsert()` accepts a slice of `BulkEntry`, validates all MBRs, performs parallel merge-sort by spatial center-x via spice fork/join, then inserts in sorted order. Sorted insertion produces better node packing and fewer splits than random order. |

### GAP-P004 — No concurrent read access (Medium) — **Closed**

| Field | Value |
|---|---|
| Severity | Medium |
| Resolution | `parallel.ConcurrentRTree` wraps `RTree` with `std.Thread.RwLock`. Read operations (`search`, `parallelSearchWith`, `searchCallbackWith`, `count`) acquire shared lock. Write operations (`insert`, `remove`, `bulkInsertWith`) acquire exclusive lock. |

### GAP-P005 — No multiplexed result streaming (Low) — **Closed**

| Field | Value |
|---|---|
| Severity | Low |
| Resolution | `parallel.searchCallback()` yields results one at a time via a caller-provided `fn(context, u64) bool` callback. Returning `false` stops traversal early. No allocation required. Spice has no channel primitives, so callback-based streaming is the appropriate pattern. |

### GAP-P006 — No parallel tree condensation on remove (Low) — **Won't Do**

| Field | Value |
|---|---|
| Severity | Low |
| Resolution | **Won't Do** — Each `reinsertLeafEntry` call mutates the tree structure (may trigger splits, root growth). Parallel reinsertion would require a concurrent tree data structure, which contradicts the library's single-writer design. The `ConcurrentRTree` wrapper already serializes writes. Orphan counts are typically small (bounded by tree height × M). |

### Summary

| Gap ID | Finding | Severity | Status |
|---|---|---|---|
| GAP-P001 | `spice` dependency not declared in `build.zig.zon` | Critical | **Closed** |
| GAP-P002 | `search()` is single-threaded sequential DFS | High | **Closed** |
| GAP-P003 | No bulk insert API / parallel batch loading | Medium | **Closed** |
| GAP-P004 | No concurrent read access pattern | Medium | **Closed** |
| GAP-P005 | No streaming/multiplexed result API | Low | **Closed** |
| GAP-P006 | Orphan reinsertion after remove is sequential | Low | **Won't Do** |

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
| `spice` dependency wired and building | **Pass** |
| Parallel search via fork/join | **Pass** (11 tests) |
| Bulk insert with parallel sort | **Pass** |
| ConcurrentRTree with RwLock | **Pass** |
| Callback-based streaming search | **Pass** |
