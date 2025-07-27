const std = @import("std");
var use_llvm: bool = true;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.Mode,
        "optimize",
        "Prioritize performance, safety, or binary size (-O flag)",
    ) orelse .ReleaseSafe;
    use_llvm = b.option(bool, "use_llvm", "use llvm backend?") orelse use_llvm;

    // const wasm_target = std.zig.CrossTarget.parse(.{ .arch_os_abi = "wasm32-freestanding" }) catch @panic("wasm target not exist?");
    // const wasm_exe = b.addSharedLibrary(.{
    //     .name = "main",
    //     .root_source_file = .{ .path = "src/web.zig" },
    //     .target = wasm_target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(wasm_exe);

    makeBin(b, "uci", target, optimize);
    makeBin(b, "fish", target, optimize);
    makeBin(b, "bench", target, optimize);
    makeBin(b, "perft", target, optimize);
    makeBin(b, "precalc", target, optimize);
    makeBin(b, "book", target, optimize);
    makeBin(b, "bestmoves", target, optimize);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn makeBin(b: *std.Build, comptime name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.Mode) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    // run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step(name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);
}

// TODO
// zig build-lib src/web.zig -target wasm32-freestanding -dynamic -rdynamic -O ReleaseFast && mv web.wasm web/main.wasm
