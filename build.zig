const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const fluidsynth_mod = b.addModule("fluidsynth", .{
        .root_source_file = b.path("src/fluidsynth.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluidsynth", .module = fluidsynth_mod },
            .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
        },
    });

    const gui = b.addExecutable(.{ .name = "gui", .root_module = gui_mod });
    const gui_check = b.addExecutable(.{ .name = "gui_check", .root_module = gui_mod });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluidsynth", .module = fluidsynth_mod },
        },
    });

    const exe_check = b.addExecutable(.{ .name = "zig_fluidsynth_check", .root_module = exe_mod });
    const check = b.step("check", "compile zig_fluidsynth to check for compile errors");
    check.dependOn(&exe_check.step);
    check.dependOn(&gui_check.step);

    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("fluidsynth_win", .{})) |fluidsynth| {
            fluidsynth_mod.addIncludePath(fluidsynth.path("include"));
            fluidsynth_mod.addLibraryPath(fluidsynth.path("lib"));
            fluidsynth_mod.linkSystemLibrary("libfluidsynth-3", .{});
            const fluidsynth_dll = b.addInstallBinFile(fluidsynth.path("bin/libfluidsynth-3.dll"), "libfluidsynth-3.dll");
            const sndfile_dll = b.addInstallBinFile(fluidsynth.path("bin/sndfile.dll"), "sndfile.dll");
            const sdl3_dll = b.addInstallBinFile(fluidsynth.path("bin/SDL3.dll"), "SDL3.dll");
            b.getInstallStep().dependOn(&sndfile_dll.step);
            b.getInstallStep().dependOn(&sdl3_dll.step);
            b.getInstallStep().dependOn(&fluidsynth_dll.step);
        }
    } else {
        fluidsynth_mod.linkSystemLibrary("fluidsynth", .{});
    }

    const exe = b.addExecutable(.{ .name = "zig_fluidsynth", .root_module = exe_mod });
    const exe_artifact = b.addInstallArtifact(exe, .{});
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&exe_artifact.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const gui_artifact = b.addInstallArtifact(gui, .{});
    const run_gui_cmd = b.addRunArtifact(gui);
    run_gui_cmd.step.dependOn(&gui_artifact.step);
    if (b.args) |args| {
        run_gui_cmd.addArgs(args);
    }
    const run_gui_step = b.step("gui", "Run the gui app");
    run_gui_step.dependOn(&run_gui_cmd.step);
}
