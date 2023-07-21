const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const wasm_target = std.zig.CrossTarget.parse(.{ .arch_os_abi = "wasm32-freestanding" }) catch @panic("wasm target not exist?");
    // const wasm_exe = b.addSharedLibrary(.{
    //     .name = "main",
    //     .root_source_file = .{ .path = "src/web.zig" },
    //     .target = wasm_target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(wasm_exe);

    // makeBin(b, "uci", target, optimize);
    makeBin(b, "fish", target, optimize);
    makeBin(b, "bench", target, optimize);
    makeBin(b, "perft", target, optimize);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn makeBin(b: *std.Build, comptime name: [] const u8, target: std.zig.CrossTarget, optimize: std.builtin.Mode) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = "src/" ++ name ++ ".zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step(name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);
}

// TODO
// zig build-lib src/web.zig -target wasm32-freestanding -dynamic -rdynamic -O ReleaseFast && mv web.wasm web/main.wasm
