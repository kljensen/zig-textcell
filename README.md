# zig-textcell

`zig-textcell` is a small Zig library for answering the terminal question:
**what visible text unit comes next, and how many fixed-width terminal cells does
it occupy?**

The immediate consumer is `lulzcat`, a Zig `lolcat` variant that needs to color
Unicode text by visible terminal position instead of by byte or code point.

## Goals

- Iterate UTF-8 text by extended grapheme cluster.
- Return terminal display width for each cluster.
- Handle common hard cases correctly: combining marks, emoji variation
  selectors, zero-width joiner emoji sequences, regional-indicator flags, CJK
  wide/fullwidth characters, and control characters.
- Offer a streaming/no-allocation API suitable for CLI filters.
- Stay buildable on Zig `0.15.2` unless a later Zig version becomes clearly
  worth requiring.
- Build confidence from upstream and Unicode conformance tests.

## Non-goals for the first version

- Full general-purpose Unicode library functionality.
- Normalization, collation, case mapping, word wrapping, or locale-sensitive
  tailoring.
- Terminal-emulator-specific quirks beyond documented width policy knobs.

## Sketch API

```zig
const textcells = @import("textcells");

var it = textcells.Iterator.init("e\u{301} 👩🏽‍🚀 界");
while (it.next()) |cluster| {
    // cluster.bytes is the original UTF-8 slice for one visible unit.
    // cluster.width is the number of terminal cells to advance.
}
```

Public helpers include:

- `Iterator.init(bytes: []const u8) Iterator`
- `Iterator.next() ?GraphemeCluster`
- `stringWidth(bytes: []const u8) usize`
- `codepointWidth(cp: u21) i4`
- `graphemeWidth(bytes: []const u8) usize`

The iterator preserves original byte slices and survives invalid UTF-8 with
replacement-character width semantics.

## Width policy

Defaults target practical terminal filters:

- printable ASCII and most neutral/narrow codepoints: width 1
- NUL, C0/C1 controls, combining marks, ZWJ, ZWSP/ZWNJ, and most format marks:
  width 0
- backspace and DEL: width -1 at `codepointWidth`, clamped so aggregate string
  and cluster widths never underflow
- East Asian Wide/Fullwidth codepoints: width 2
- East Asian Ambiguous codepoints: width 1
- emoji-presentation codepoints: width 2
- variation selector 15 (`U+FE0E`): forces text presentation width 1 for the
  cluster
- variation selector 16 (`U+FE0F`): forces emoji presentation width 2 for the
  cluster
- regional indicators: lone indicators and flag pairs report width 2, while
  pairs are clustered per UAX #29
- ZWJ emoji sequences and emoji modifier sequences: width 2
- invalid UTF-8: preserved as original byte slices and measured as U+FFFD width
  1; ill-formed multibyte prefixes consume their maximal available continuation
  subpart as one replacement unit

Grapheme clusters are unbounded by design: pathological input can make one
cluster span the entire remaining byte slice. Consumers must not assume a small
maximum cluster byte length.

No terminal escape-sequence parser is included. Ambiguous-width CJK tailoring and
alternative control policies can be added later as explicit options.

## Security notes

Input bytes may be attacker-controlled. The library does not allocate, does not
perform I/O, and preserves original bytes for callers. That also means terminal
escape sequences are passed through verbatim in `cluster.bytes`; consumers that
write to a terminal must strip or sanitize CSI/OSC/DCS/APC and related controls
before display. Escape sequences are not parsed for layout and may measure wider
than a terminal ultimately advances.

See `SECURITY_REVIEW.md` for the current threat model and review notes.

## Related projects

- [`rivo/uniseg`](https://github.com/rivo/uniseg) — Go library for Unicode text
  segmentation, word wrapping, and string width calculation. This is the closest
  model for the desired API, especially `FirstGraphemeCluster` returning both a
  cluster and its width.
- [`unicode-rs/unicode-segmentation`](https://github.com/unicode-rs/unicode-segmentation)
  — Rust grapheme/word/sentence boundary iterators implementing UAX #29.
- [`unicode-width`](https://crates.io/crates/unicode-width) — Rust terminal
  display-width calculations.
- [`unicode-display-width`](https://crates.io/crates/unicode-display-width) —
  Rust display-width crate that handles grapheme clusters.
- [`pascalkuthe/grapheme-width-rs`](https://github.com/pascalkuthe/grapheme-width-rs)
  — Rust crate for terminal width of a single Unicode grapheme.
- [`atman/zg`](https://codeberg.org/atman/zg) — Zig Unicode text processing
  library with grapheme and display-width modules; promising, but current main
  targets newer Zig than `0.15.2`.
- [`jacobsandlund/uucode`](https://github.com/jacobsandlund/uucode) — Fast,
  configurable Zig Unicode library with UTF-8 iteration, graphemes, and wcwidth
  extensions; also currently oriented toward newer Zig.
- [`dude_the_builder/ziglyph`](https://codeberg.org/dude_the_builder/ziglyph) —
  Zig Unicode library with display width and graphemes; now superseded by `zg`.
- [`joachimschmidt557/zig-wcwidth`](https://github.com/joachimschmidt557/zig-wcwidth)
  — Zig `wcwidth` implementation that works on Zig `0.15.x`; useful reference
  for codepoint width tables but does not solve grapheme clustering alone.
- [`rockorager/libvaxis`](https://github.com/rockorager/libvaxis) — Zig TUI
  library with practical grapheme-width handling using Unicode data.
- [`jquast/wcwidth`](https://github.com/jquast/wcwidth) — Python `wcwidth`
  implementation with a broad test corpus used by many terminal projects.

## Unicode data

Generated tables in `src/unicode_data.zig` come from Unicode 17.0.0 data. To
refresh them from a local UCD checkout:

```sh
python3 tools/update_unicode_data.py --ucd path/to/ucd
```

The development handoff used `tmp/upstream/uucode/ucd` as that UCD checkout.

## Checks

```sh
zig build test
tools/check_downstream_import.sh
```

`zig build test` includes a fuzzable invariant test and runs its seed corpus in
normal test mode. To start Zig's continuous fuzzer locally:

```sh
zig build test --fuzz --test-filter "fuzz textcell invariants"
```

The downstream check builds a temporary consumer package that imports this
checkout as module `textcells`; it is a stand-in for the `lulzcat` integration
until that application wires the dependency directly.

## Test strategy

The test suite includes Unicode 17.0.0 `GraphemeBreakTest.txt` conformance data
plus curated display-width cases adapted from the related projects above. Keep
imported tests attributed and license-compatible.
