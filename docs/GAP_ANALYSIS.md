# GAP Analysis

Last updated: 2026-03-21

Repository status: bootstrapped from `../zig-template`; no Geode code has been moved yet.

## Goal

Extract Geode’s generic R-tree implementation into a standalone reusable spatial-index library.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here |
|---|---|
| `src/index/rtree.zig:4` | Core `MBR` type |
| `src/index/rtree.zig:45` and `src/index/rtree.zig:50` | Node type and lifecycle |
| `src/index/rtree.zig:73` and `src/index/rtree.zig:80` | Core `RTree` type and initializer |
| `src/index/rtree.zig:108` | Generic insertion |
| `src/index/rtree.zig:183` | Generic search |
| `src/index/rtree.zig:201` | Generic removal |
| `src/index/rtree_persist.zig:32` and `src/index/rtree_persist.zig:84` | Optional snapshot support if persistence belongs in this repo |

Keep in Geode:

| Geode source | Why it stays |
|---|---|
| `src/index/spatial_index.zig:8`, `src/index/spatial_index.zig:56`, `src/index/spatial_index.zig:79`, `src/index/spatial_index.zig:133`, `src/index/spatial_index.zig:164`, `src/index/spatial_index.zig:210`, `src/index/spatial_index.zig:233` | Geode-specific lat/lon/radius wrappers and query helpers |
| `src/index/advanced_types_index.zig:517`, `src/index/advanced_types_index.zig:526`, `src/index/advanced_types_index.zig:539`, `src/index/advanced_types_index.zig:571` | Advanced-types integration layer |
| `src/index/index_manager.zig:657`, `src/index/index_manager.zig:674` | Geode index-manager glue |

## Concrete Gaps

| Gap | Evidence | Impact | Required fix |
|---|---|---|---|
| Standalone packaging still trips on repo-local imports | Direct standalone test failure during review | Blocks immediate externalization | Normalize imports and make optional dependencies explicit |
| Persistence ownership is undecided | `src/index/rtree_persist.zig:32`, `src/index/rtree_persist.zig:84` | Affects public API | Decide whether persistence belongs in core or in a sibling adapter |
| Spatial convenience APIs are Geode flavored | `src/index/spatial_index.zig:79`, `:133`, `:164`, `:210` | Risk of over-extraction | Keep convenience query adapters local to Geode |

## Tests And Benchmarks To Carry Over

| Geode test / benchmark | Coverage provided |
|---|---|
| `tests/integration/test_spatial_index.zig:5`, `:56`, `:98`, `:153`, `:199`, `:243` | Functional spatial-index behaviors |
| `tests/test_type_extensions.zig:124` | Cross-type spatial index usage |
| `tests/integration/test_index_performance.zig:174` | Integration benchmark for spatial indexing |

## Proposed Public API

Initial public surface should include:

- `MBR`
- `RTree`
- `insert`
- `search`
- `remove`
- optional snapshot helpers if persistence is accepted

## Extraction Plan

1. Move the generic R-tree core into this repo.
2. Decide whether persistence stays with the core or becomes a follow-on package.
3. Port functional tests for insert/search/remove.
4. Add an example for bounding-box queries.
5. Retarget Geode’s `spatial_index.zig` and `advanced_types_index.zig` to use this repo.

## Acceptance Criteria

- This repo builds without Geode.
- Geode keeps its higher-level spatial wrappers locally.
- Performance parity is checked against `tests/integration/test_index_performance.zig:174`.
