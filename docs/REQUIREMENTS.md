# Requirements

Last updated: 2026-03-21

## Functional Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| RTREE-REQ-001 | The library SHALL expose an `MBR` type for spatial bounds. | `src/index/rtree.zig:4` |
| RTREE-REQ-002 | The library SHALL expose an allocator-backed `RTree` type. | `src/index/rtree.zig:73`, `src/index/rtree.zig:80` |
| RTREE-REQ-003 | The library SHALL support insertion, search, and removal. | `src/index/rtree.zig:108`, `src/index/rtree.zig:183`, `src/index/rtree.zig:201` |
| RTREE-REQ-004 | The library SHALL avoid Geode-specific lat/lon convenience APIs in the core package. | `src/index/spatial_index.zig:79`, `:133`, `:164`, `:210` stay in Geode |

## Packaging Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| RTREE-PKG-001 | Standalone imports SHALL be normalized so the repo builds without the Geode module tree. | standalone test failed during review |
| RTREE-PKG-002 | Persistence support SHALL be explicitly optional if included. | `src/index/rtree_persist.zig:32`, `src/index/rtree_persist.zig:84` |
| RTREE-PKG-003 | Geode index-manager and advanced-type wrappers SHALL remain outside this repo. | `src/index/index_manager.zig:657`, `src/index/advanced_types_index.zig:526` |

## Test Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| RTREE-TEST-001 | Port spatial functional tests. | `tests/integration/test_spatial_index.zig:5`, `:56`, `:98`, `:153`, `:199`, `:243` |
| RTREE-TEST-002 | Preserve cross-type usage coverage. | `tests/test_type_extensions.zig:124` |
| RTREE-TEST-003 | Check performance parity against Geode’s current integration benchmark. | `tests/integration/test_index_performance.zig:174` |

## Documentation Requirements

- Provide one example for bounding-box search.
- Document the expected coordinate/value semantics of `MBR`.
- Document whether persistence is part of this repo or deferred.

## Migration Requirements

1. Extract the generic core before moving any Geode wrappers.
2. Update Geode’s spatial wrapper modules to consume this repo.
3. Keep Geode-specific convenience APIs outside the library boundary.
