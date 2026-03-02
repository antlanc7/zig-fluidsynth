const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fluidsynth");
const Io = std.Io;

const Synth = struct {
    io: Io,
    synth: *fs.fluid_synth_t,
    timer: Io.Timestamp,
    active_sensing_timer: ?Io.Timestamp,
    transposition: i32,
    touch_disabled: bool,

    pub fn init(synth: *fs.fluid_synth_t, io: Io) Synth {
        return .{
            .io = io,
            .synth = synth,
            .timer = .now(io, .boot),
            .active_sensing_timer = null,
            .transposition = 0,
            .touch_disabled = false,
        };
    }
};

fn handle_midi_event(data: ?*anyopaque, event: *fs.fluid_midi_event_t) callconv(.c) void {
    const log = std.log.scoped(.midi_event);
    const synth_state: *Synth = @ptrCast(@alignCast(data));
    const midi_type = std.enums.fromInt(fs.MidiEventType, fs.fluid_midi_event_get_type(event)) orelse return;

    if (midi_type == .SYNC) {
        return;
    }
    if (midi_type == .ACTIVE_SENSING) {
        if (synth_state.active_sensing_timer == null) log.info("active sensing", .{});
        synth_state.active_sensing_timer = .now(synth_state.io, .boot);
        return;
    }

    const midi_key = fs.fluid_midi_event_get_key(event);
    const midi_vel = fs.fluid_midi_event_get_velocity(event);

    log.debug("[{}] {t} 0x{X} {} {}", .{
        synth_state.timer.untilNow(synth_state.io, .boot).toMilliseconds(),
        midi_type,
        midi_type,
        midi_key,
        midi_vel,
    });

    if (midi_type == .NOTE_ON or midi_type == .NOTE_OFF) {
        if (synth_state.transposition != 0) {
            fs.fluid_midi_event_set_key(event, midi_key + synth_state.transposition) catch return;
        }
        if (synth_state.touch_disabled and midi_vel != 0) {
            fs.fluid_midi_event_set_velocity(event, 64) catch return;
        }
    }

    fs.fluid_synth_handle_midi_event(synth_state.synth, event) catch return;
}

const Command = struct {
    prefix: u8,
    handler: *const fn (args: []const u8, writer: *Io.Writer, synth_state: *Synth) anyerror!void,
    description: []const u8,
};
const commands = [_]Command{
    .{ .prefix = 't', .handler = transpose_cmd, .description = "transpose" },
    .{ .prefix = 'v', .handler = toggle_touch_cmd, .description = "toggle touch sensing" },
    .{ .prefix = 'g', .handler = gain_cmd, .description = "get or set gain" },
    .{ .prefix = 'b', .handler = select_bank_cmd, .description = "select bank" },
    .{ .prefix = 'p', .handler = program_change_cmd, .description = "program change" },
    .{ .prefix = 'h', .handler = print_help, .description = "print help" },
    .{ .prefix = 'q', .handler = quit_cmd, .description = "quit" },
};

fn print_help(_: []const u8, writer: *Io.Writer, _: *Synth) !void {
    for (commands) |cmd| {
        try writer.print("{c}: {s}\n", .{ cmd.prefix, cmd.description });
    }
    try writer.flush();
}

fn transpose_cmd(args: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    try fs.fluid_synth_all_notes_off(synth, 0);
    synth_state.transposition = std.fmt.parseInt(c_int, args, 10) catch 0;
    try writer.print("transpose: {}\n", .{synth_state.transposition});
}

fn select_bank_cmd(args: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    const bank = std.fmt.parseUnsigned(c_int, args, 10) catch {
        try writer.print("invalid bank: '{s}'\n", .{args});
        return;
    };
    try fs.fluid_synth_bank_select(synth, 0, bank);
    try fs.fluid_synth_program_reset(synth);
    try writer.print("bank: {}\n", .{bank});
}

fn program_change_cmd(args: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    const program_change = std.fmt.parseUnsigned(c_int, args, 10) catch {
        try writer.print("invalid program change: '{s}'\n", .{args});
        return;
    };
    try fs.fluid_synth_program_change(synth, 0, program_change);
    try writer.print("program change: {}\n", .{program_change});
}

fn toggle_touch_cmd(args: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    _ = args;
    synth_state.touch_disabled = !synth_state.touch_disabled;
    try writer.print("touch: {s}\n", .{if (synth_state.touch_disabled) "disabled" else "enabled"});
}

fn gain_cmd(args: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    if (args.len > 0) { // if cmd is "g", just print the gain
        const new_gain = std.fmt.parseFloat(f32, args) catch {
            try writer.print("invalid gain: '{s}'\n", .{args});
            return;
        };
        _ = fs.fluid_synth_set_gain(synth, new_gain);
    }
    const gain = fs.fluid_synth_get_gain(synth);
    try writer.print("gain: {d:.2}\n", .{gain});
}

fn quit_cmd(_: []const u8, _: *Io.Writer, _: *Synth) !void {
    return error.End;
}

fn handle_cmd(cmd: []const u8, writer: *Io.Writer, synth_state: *Synth) !void {
    if (cmd.len == 0) return;
    const prefix = cmd[0];
    for (commands) |c| {
        if (c.prefix == prefix) {
            const args = std.mem.trim(u8, cmd[1..], &std.ascii.whitespace);
            try c.handler(args, writer, synth_state);
            break;
        }
    } else {
        try writer.print("unknown command: '{s}'\n", .{cmd});
    }
}

fn stream_thread_fn(reader: *Io.Reader, writer: *Io.Writer, synth: *Synth) !void {
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        const cmd = std.mem.trim(u8, line, &std.ascii.whitespace);
        try handle_cmd(cmd, writer, synth);
        try writer.flush();
    }
}

fn stdin_thread_fn(io: Io, synth: *Synth) Io.Cancelable!void {
    const log = std.log.scoped(.stdin);
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();
    var reader = stdin.reader(io, &reader_buffer);
    var writer = stdout.writer(io, &writer_buffer);
    stream_thread_fn(&reader.interface, &writer.interface, synth) catch |err| switch (err) {
        error.ReadFailed => if (reader.err) |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                log.err("{t}", .{e});
                return;
            },
        },
        error.EndOfStream, error.End => return,
        else => {},
    };
}

fn tcp_conn_handler_thread_fn(io: Io, client: Io.net.Stream, synth: *Synth) Io.Cancelable!void {
    const log = std.log.scoped(.tcp_handler);
    defer {
        log.debug("client disconnected: {f}", .{client.socket.address});
        client.close(io);
    }
    log.debug("client connected: {f}", .{client.socket.address});
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var reader = client.reader(io, &reader_buffer);
    var writer = client.writer(io, &writer_buffer);
    stream_thread_fn(&reader.interface, &writer.interface, synth) catch |err| switch (err) {
        error.ReadFailed => if (reader.err) |r_err| switch (r_err) {
            error.Canceled => return error.Canceled,
            else => |e| log.err("reader err: {t}", .{e}),
        },
        error.EndOfStream, error.End => return,
        else => |e| log.err("{t}", .{e}),
    };
}

fn tcp_server_thread_fn(io: Io, synth: *Synth) Io.Cancelable!void {
    const log = std.log.scoped(.tcp);
    const address: Io.net.IpAddress = .{ .ip4 = .unspecified(9999) };
    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("listen failed: {t}", .{e});
            return;
        },
    };
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    log.debug("accepting...", .{});
    while (true) {
        const client = server.accept(io) catch |err| switch (err) {
            error.Canceled => {
                log.info("accept canceled", .{});
                return error.Canceled;
            },
            else => |e| {
                log.err("accept failed: {t}", .{e});
                continue;
            },
        };
        group.concurrent(io, tcp_conn_handler_thread_fn, .{ io, client, synth }) catch unreachable;
    }
}

fn active_sensing_thread_fn(io: Io, synth_state: *Synth) Io.Cancelable!void {
    const log = std.log.scoped(.active_sensing);
    const interval: Io.Duration = .fromMilliseconds(500);
    while (true) {
        io.sleep(interval, .boot) catch |err| switch (err) {
            error.Canceled => {
                log.info("canceled", .{});
                return error.Canceled;
            },
        };

        if (synth_state.active_sensing_timer) |*timer| {
            if (timer.untilNow(synth_state.io, .boot).nanoseconds > interval.nanoseconds) {
                log.warn("timeout, quitting...", .{});
                break;
            }
        }
    }
}

const audio_driver = switch (builtin.target.os.tag) {
    .windows => "wasapi",
    .macos => "coreaudio",
    .linux => "alsa",
    else => @compileError("OS not supported"),
};

const midi_driver = switch (builtin.target.os.tag) {
    .windows => "winmidi",
    .macos => "coremidi",
    .linux => "alsa_seq",
    else => @compileError("OS not supported"),
};

fn fluid_log(level: c_int, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const log = std.log.scoped(.fluidsynth);
    const msg = std.mem.trim(u8, std.mem.span(message), &std.ascii.whitespace);
    switch (level) {
        fs.FLUID_PANIC => log.err("{s}", .{msg}),
        fs.FLUID_ERR => log.err("{s}", .{msg}),
        fs.FLUID_WARN => log.warn("{s}", .{msg}),
        fs.FLUID_INFO => log.info("{s}", .{msg}),
        fs.FLUID_DBG => log.debug("{s}", .{msg}),
        else => unreachable,
    }
}

fn set_fluid_log() void {
    _ = fs.fluid_set_log_function(fs.FLUID_PANIC, fluid_log, null);
    _ = fs.fluid_set_log_function(fs.FLUID_ERR, fluid_log, null);
    _ = fs.fluid_set_log_function(fs.FLUID_WARN, fluid_log, null);
    _ = fs.fluid_set_log_function(fs.FLUID_INFO, fluid_log, null);
    _ = fs.fluid_set_log_function(fs.FLUID_DBG, fluid_log, null);
}

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .fluidsynth, .level = .info },
    },
};

pub fn main(init: std.process.Init) !void {
    const log = std.log.scoped(.main);
    const io = init.io;
    log.info("fluidsynth version: {s}", .{fs.fluid_version_str()});
    set_fluid_log();
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    if (!args.skip()) return error.NoArgs; //to skip the zig call
    const sf2_path = args.next() orelse return error.NoSf2;

    log.info("Loading sf2: {s}", .{sf2_path});

    const settings = try fs.new_fluid_settings();
    defer fs.delete_fluid_settings(settings);
    try fs.fluid_settings_setint(settings, "midi.autoconnect", 1);
    try fs.fluid_settings_setstr(settings, "audio.driver", audio_driver);
    try fs.fluid_settings_setstr(settings, "midi.driver", midi_driver);

    const synth = fs.new_fluid_synth(settings) catch return error.NoSynth;
    var synth_state: Synth = .init(synth, io);
    defer fs.delete_fluid_synth(synth);

    const sfont_id = try fs.fluid_synth_sfload(synth, sf2_path, true);
    const sfont = try fs.fluid_synth_get_sfont_by_id(synth, sfont_id);
    fs.fluid_sfont_iteration_start(sfont);
    while (fs.fluid_sfont_iteration_next(sfont)) |preset| {
        const preset_name = fs.fluid_preset_get_name(preset);
        const preset_banknum = fs.fluid_preset_get_banknum(preset);
        const preset_num = fs.fluid_preset_get_num(preset);
        log.info("preset: b{} {} {s}", .{ preset_banknum, preset_num, preset_name });
    }

    const mdriver = fs.new_fluid_midi_driver(settings, handle_midi_event, &synth_state);
    if (mdriver == null) {
        log.err("No MIDI device found", .{});
    }
    defer if (mdriver) |md| fs.delete_fluid_midi_driver(md);

    const adriver = fs.new_fluid_audio_driver(settings, synth) catch return error.NoAudioDriver;
    defer fs.delete_fluid_audio_driver(adriver);

    const TasksUnion = union(enum) {
        stdin: Io.Cancelable!void,
        tcp: Io.Cancelable!void,
        active_sensing: Io.Cancelable!void,
    };

    var group_buffer: [1]TasksUnion = undefined;
    var group = Io.Select(TasksUnion).init(io, &group_buffer);
    defer group.cancelDiscard();
    try group.concurrent(.stdin, stdin_thread_fn, .{ io, &synth_state });
    if (builtin.target.os.tag != .windows) {
        // TODO: tcp server accept on windows fails to be canceled https://codeberg.org/ziglang/zig/issues/30865
        // for now we just don't support tcp server on windows
        try group.concurrent(.tcp, tcp_server_thread_fn, .{ io, &synth_state });
    }
    try group.concurrent(.active_sensing, active_sensing_thread_fn, .{ io, &synth_state });

    const quitted = try group.await(); // await first task to exit
    log.info("quitting cause of {t}...", .{quitted});
}
