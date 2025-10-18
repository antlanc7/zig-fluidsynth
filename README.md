# Zig-Fluidsynth

A CLI Frontend for libfluidsynth

Works on terminal but it also expose a TCP server.

The project depends on system installed `fluidsynth`, and so it's working only on Unix (tested on MacOS and Linux).  
On Windows I couldn't figure out a standard way to link fluidsynth.

> TODO: Investigate a way to compile `fluidsynth` with `build.zig` to use it as a dependency with `zig fetch` without dynamic linking (this would work also for Windows).

