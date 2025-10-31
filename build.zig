const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe_check = b.addExecutable(.{ .name = "zig_fluidsynth_check", .root_module = exe_mod });
    b.step("check", "compile zig_fluidsynth to check for compile errors").dependOn(&exe_check.step);

    if (builtin.os.tag == .windows) {
        if (b.lazyDependency("fluidsynth_win", .{})) |fluidsynth| {
            exe_mod.addIncludePath(fluidsynth.path("include"));
            exe_mod.addLibraryPath(fluidsynth.path("lib"));
            exe_mod.linkSystemLibrary("libfluidsynth-3", .{});
            const fluidsynth_dll = b.addInstallBinFile(fluidsynth.path("bin/libfluidsynth-3.dll"), "libfluidsynth-3.dll");
            const sndfile_dll = b.addInstallBinFile(fluidsynth.path("bin/sndfile.dll"), "sndfile.dll");
            const sdl3_dll = b.addInstallBinFile(fluidsynth.path("bin/SDL3.dll"), "SDL3.dll");
            b.getInstallStep().dependOn(&sndfile_dll.step);
            b.getInstallStep().dependOn(&sdl3_dll.step);
            b.getInstallStep().dependOn(&fluidsynth_dll.step);
        }
    } else {
        exe_mod.linkSystemLibrary("fluidsynth", .{});
    }

    const exe = b.addExecutable(.{ .name = "zig_fluidsynth", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
