# textcells.zig

`textcells.zig` is planned as a small Zig library for answering the terminal
question: **what visible text unit comes next, and how many fixed-width terminal
cells does it occupy?**

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

Lower-level helpers should likely include:

- `stringWidth(bytes: []const u8) usize`
- `codepointWidth(cp: u21) i4`
- `graphemeWidth(bytes: []const u8) usize`
- an iterator that survives invalid UTF-8 with replacement-character semantics

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

## Test strategy

Prefer official Unicode conformance data where possible, then supplement with
real-world tests from the related projects above. Keep imported tests attributed
and license-compatible.
