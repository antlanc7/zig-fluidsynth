# Zig-Fluidsynth

A **CLI frontend for [FluidSynth](https://www.fluidsynth.org/)**, written in [Zig](https://ziglang.org/).  

## Features

- 🎹 Play MIDI keyboard input using a SoundFont file  
- 🖥️ Simple command-line interface via tty or TCP
- 🧩 Cross-platform: works on Windows, macOS, and Linux

## Installation

### Dependencies

This project depends on the **FluidSynth** library.

#### Windows
A precompiled version of FluidSynth is automatically fetched by the Zig build system.

#### macOS
Install with Homebrew:
```bash
brew install fluid-synth
```

#### Linux (Debian / Ubuntu)
Install via apt:
```bash
sudo apt install libfluidsynth-dev libfluidsynth3
```

## Building

Once dependencies are installed:

```bash
zig build
```

This produces a runnable binary in `zig-out/bin`.

## Usage

Run the CLI directly:

```bash
zig-out/bin/zig-fluidsynth path/to/soundfont.sf2
```
## License

[MIT License](LICENSE)
