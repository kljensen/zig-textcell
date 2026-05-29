# Security review

Date: 2026-05-29
Scope: `src/root.zig`, generated Unicode table usage, build/CI, test/imported data, and developer scripts.

## Threat model

`zig-textcell` accepts attacker-controlled byte slices from terminal filters, logs, or TUI applications. Security goals:

- never read/write outside caller-provided slices;
- never panic on malformed UTF-8 in normal public APIs;
- make forward progress for all inputs;
- avoid integer overflow in aggregate width calculations;
- avoid algorithmic behavior worse than linear in input length times static table lookup cost;
- preserve original bytes while making terminal-escape non-goals explicit.

Out of scope: sanitizing terminal escape sequences, policy decisions for terminal-specific rendering quirks, and protecting callers that mutate/free the backing slice during iteration.

## Findings and mitigations

No critical or high-severity issues were found.

### Medium: CI toolchain supply-chain risk

CI previously downloaded Zig directly without checksum verification and used default workflow permissions. Mitigations:

- CI now pins `actions/checkout` to a commit SHA.
- CI sets `permissions: contents: read`.
- CI verifies the Zig 0.15.2 Linux tarball SHA256 before extraction.

Residual risk: the checksum is maintained manually. Future Zig upgrades must update both version and hash from the official `download/index.json`.

### Medium: unbounded grapheme cluster size

Unicode permits arbitrarily long clusters through combining marks, prepend characters, ZWJ sequences, and related rules. The library itself returns slices and does not allocate, but downstream consumers could copy clusters into fixed buffers.

Mitigation: README and `GraphemeCluster.bytes` docs now state that a cluster may span the remaining input and must not be assumed small.

Residual risk: a future optional `max_cluster_bytes` iterator policy may be useful for hostile terminal streams.

### Medium: internal decoder precondition

`decodeNext` requires `index < bytes.len`. Current callers already enforce this.

Mitigation: added `std.debug.assert(index < bytes.len)` so future internal misuse fails loudly in safe/debug builds.

### Low: test helper fixed buffers

The Unicode conformance parser uses fixed test buffers. They are not part of the public API.

Mitigation: `appendUtf8` now bounds-checks output space and expected/actual break arrays are checked before appending.

### Low: generated Unicode data provenance

Generated tables are committed and the generator reads a local UCD checkout. Tampered UCD data could produce incorrect classifications.

Mitigations already present:

- generated file header names Unicode 17.0.0 and Unicode License;
- Unicode `GraphemeBreakTest.txt` conformance data is committed and run by `zig build test`;
- curated width tests pin important East Asian Width, emoji, control, and variation-selector behavior.

Future hardening: add source-file SHA256 verification to `tools/update_unicode_data.py` before regeneration.

## Public API review

- `Iterator.next()` always advances for non-empty remaining input because `decodeNext` consumes at least one byte.
- `Iterator.next()` returns original byte slices only; no allocation or copying.
- `stringWidth()` uses saturating signed addition and clamps negative totals to zero.
- `codepointWidth()` returns `i4`; only documented values -1, 0, 1, 2, and 3 are currently produced.
- Invalid UTF-8 is represented as replacement-character semantics for width while preserving original bytes.
- Table lookups are binary searches over static generated ranges.

## Fuzzing

`zig build test` runs the seed corpus for `test "fuzz textcell invariants"`. The fuzz target checks:

- iterator progress;
- complete, non-overlapping coverage of the original input bytes;
- cluster width consistency with `graphemeWidthSigned`;
- `stringWidth` agreement with signed cluster accumulation;
- no panics for arbitrary byte slices.

Run continuous fuzzing manually with:

```sh
zig build test --fuzz --test-filter "fuzz textcell invariants"
```

## Terminal escape warning

The library intentionally does not parse or remove terminal escapes. Consumers that print `cluster.bytes` to a terminal must sanitize attacker-controlled CSI/OSC/DCS/APC sequences themselves. Widths for strings containing escape sequences are not terminal-control-aware.

## Current status

Reviewed changes were validated with:

```sh
ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache-global zig build test
ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache-global zig build test -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache-global tools/check_downstream_import.sh
```
