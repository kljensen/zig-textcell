#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const textcells_path = b.option([]const u8, "textcells-path", "Path to zig-textcell checkout") orelse ".";

    const textcells = b.addModule("textcells", .{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ textcells_path, "src/root.zig" }) },
        .target = target,
        .optimize = optimize,
    });

    const consumer = b.createModule(.{
        .root_source_file = b.path("consumer.zig"),
        .target = target,
        .optimize = optimize,
    });
    consumer.addImport("textcells", textcells);

    const tests = b.addTest(.{ .root_module = consumer });
    const run_tests = b.addRunArtifact(tests);
    b.default_step.dependOn(&run_tests.step);
}
ZIG

cat >"$tmpdir/consumer.zig" <<'ZIG'
const std = @import("std");
const textcells = @import("textcells");

test "package can be consumed downstream" {
    try std.testing.expectEqual(@as(usize, 5), textcells.stringWidth("a界👩‍🚀"));

    var it = textcells.Iterator.init("e\u{301} 👩🏽‍🚀");
    try std.testing.expectEqualStrings("e\u{301}", it.next().?.bytes);
    try std.testing.expectEqualStrings(" ", it.next().?.bytes);
    const astronaut = it.next().?;
    try std.testing.expectEqualStrings("👩🏽‍🚀", astronaut.bytes);
    try std.testing.expectEqual(@as(usize, 2), astronaut.width);
}
ZIG

cd "$tmpdir"
zig build -Dtextcells-path="$repo_root"
