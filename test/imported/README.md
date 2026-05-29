# Imported/conformance tests

This directory tracks license/provenance for conformance data and upstream cases
used by the in-tree tests.

## Included

- `unicode/GraphemeBreakTest.txt` — Unicode 17.0.0 official grapheme break
  conformance data, copied from the shallow-cloned `uucode` UCD mirror in
  `tmp/upstream/uucode/ucd/auxiliary/GraphemeBreakTest.txt`.
- `unicode/LICENSE.txt` — Unicode License.

The same grapheme break test file is mirrored under `src/testdata/` because Zig
`@embedFile` for the root module must stay inside the module package path.

## Upstream cases adapted into `src/root.zig`

- `rivo/uniseg` (`width_test.go`) — MIT.
- `zg` (`src/DisplayWidth.zig`) — MIT; Unicode data under Unicode License.
- `zig-wcwidth` (`src/test.zig`) — MIT.
- `libvaxis` (`src/gwidth.zig`) — MIT.
- `jquast/wcwidth` (`tests/test_core.py`, `tests/test_emojis.py`) — MIT.

The upstream repositories were shallow-cloned into `tmp/upstream/` for review;
that directory is intentionally ignored and not vendored.
