const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fluidsynth.zig");

const MidiEventType = enum(u8) {
    // channel messages
    NOTE_OFF = 0x80,
    NOTE_ON = 0x90,
    KEY_PRESSURE = 0xa0,
    CONTROL_CHANGE = 0xb0,
    PROGRAM_CHANGE = 0xc0,
    CHANNEL_PRESSURE = 0xd0,
    PITCH_BEND = 0xe0,
    // system exclusive
    SYSEX = 0xf0,
    // system common
    TIME_CODE = 0xf1,
    SONG_POSITION = 0xf2,
    SONG_SELECT = 0xf3,
    TUNE_REQUEST = 0xf6,
    EOX = 0xf7,
    // system real-time
    SYNC = 0xf8,
    TICK = 0xf9,
    START = 0xfa,
    CONTINUE = 0xfb,
    STOP = 0xfc,
    ACTIVE_SENSING = 0xfe,
    SYSTEM_RESET = 0xff,
};

const Synth = struct {
    synth: *fs.fluid_synth_t,
    timer: std.time.Timer,
    active_sensing_timer: ?std.time.Timer,
    transposition: i32,
    touch_disabled: bool,

    pub fn init(synth: *fs.fluid_synth_t) Synth {
        return .{
            .synth = synth,
            .timer = std.time.Timer.start() catch unreachable,
            .active_sensing_timer = null,
            .transposition = 0,
            .touch_disabled = false,
        };
    }
};

fn handle_midi_event(data: ?*anyopaque, event: *fs.fluid_midi_event_t) callconv(.c) void {
    const synth_state: *Synth = @ptrCast(@alignCast(data));
    const midi_type: MidiEventType = @enumFromInt(fs.fluid_midi_event_get_type(event));

    if (midi_type == .SYNC) {
        return;
    }
    if (midi_type == .ACTIVE_SENSING) {
        if (synth_state.active_sensing_timer) |*timer| {
            timer.reset();
        } else {
            std.debug.print("active sensing\n", .{});
            synth_state.active_sensing_timer = std.time.Timer.start() catch unreachable;
        }
        return;
    }

    const midi_key = fs.fluid_midi_event_get_key(event);
    const midi_vel = fs.fluid_midi_event_get_velocity(event);

    std.log.debug("[{}] {t} 0x{X} {} {}", .{
        synth_state.timer.read() / std.time.ns_per_ms,
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

fn handle_cmd(cmd: []const u8, writer: *std.Io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    if (cmd.len == 0) return;
    // std.debug.print("stdin: {s}\n", .{msg});
    if (cmd[0] == '+' or cmd[0] == '-') {
        try fs.fluid_synth_all_notes_off(synth, 0);
        synth_state.transposition = std.fmt.parseInt(c_int, cmd, 10) catch 0;
        try writer.print("transpose: {}\n", .{synth_state.transposition});
    } else if (cmd[0] == 'b') {
        const bank = std.fmt.parseUnsigned(c_int, cmd[1..], 10) catch return;
        try fs.fluid_synth_bank_select(synth, 0, bank);
        try fs.fluid_synth_program_reset(synth);
        try writer.print("bank: {}\n", .{bank});
    } else if (cmd[0] == 't') {
        synth_state.touch_disabled = !synth_state.touch_disabled;
        try writer.print("touch: {s}\n", .{if (synth_state.touch_disabled) "disabled" else "enabled"});
    } else if (cmd[0] == 'g') {
        if (cmd.len > 1) {
            const new_gain = std.fmt.parseFloat(f32, cmd[1..]) catch {
                try writer.print("invalid gain: '{s}'\n", .{cmd[1..]});
                return;
            };
            _ = fs.fluid_synth_set_gain(synth, new_gain);
        }
        const gain = fs.fluid_synth_get_gain(synth);
        try writer.print("gain: {d:.2}\n", .{gain});
    } else if (cmd[0] == 'q') {
        return error.End;
    } else {
        const program_change = std.fmt.parseUnsigned(c_int, cmd, 10) catch return;
        try fs.fluid_synth_program_change(synth, 0, program_change);
        try writer.print("pc: {}\n", .{program_change});
    }
    try writer.flush();
}

fn stream_thread_fn(reader: *std.Io.Reader, writer: *std.Io.Writer, synth: *Synth) !void {
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        const cmd = std.mem.trim(u8, line, &std.ascii.whitespace);
        try handle_cmd(cmd, writer, synth);
    }
}

fn stdin_thread_fn(io: std.Io, synth: *Synth) std.Io.Cancelable!void {
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var reader = stdin.reader(io, &reader_buffer);
    var writer = stdout.writer(io, &writer_buffer);
    stream_thread_fn(&reader.interface, &writer.interface, synth) catch |err| {
        std.log.err("stdin stream_thread_fn: {t}", .{err});
        switch (err) {
            error.ReadFailed => if (reader.err) |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => {},
            },
            else => {},
        }
    };
}

var i: usize = 0;
fn tcp_conn_handler_thread_fn(io: std.Io, client: std.Io.net.Stream, synth: *Synth) std.Io.Cancelable!void {
    const index = i;
    std.log.debug("tcp stream_thread_fn {} start", .{index});
    i += 1;
    defer client.close(io);
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var reader = client.reader(io, &reader_buffer);
    var writer = client.writer(io, &writer_buffer);
    stream_thread_fn(&reader.interface, &writer.interface, synth) catch |err| {
        std.log.err("tcp stream_thread_fn {}: {t}", .{ index, err });
        if (reader.err) |e| switch (e) {
            error.Canceled => |c| return c,
            else => {},
        };
    };
}

fn tcp_server_thread_fn(io: std.Io, synth: *Synth) std.Io.Cancelable!void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(9999) };
    var server = address.listen(io, .{}) catch |err| {
        std.log.err("listen failed: {t}", .{err});
        switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        }
    };
    defer server.deinit(io);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        std.log.debug("accept...", .{});
        const client = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            switch (err) {
                error.Canceled => {
                    std.log.debug("accept canceled", .{});
                    return error.Canceled;
                },
                else => continue,
            }
        };
        std.log.info("accept success", .{});
        group.concurrent(io, tcp_conn_handler_thread_fn, .{ io, client, synth }) catch unreachable;
    }
}

fn active_sensing_thread_fn(io: std.Io, synth_state: *Synth) std.Io.Cancelable!void {
    while (true) {
        io.sleep(.fromMilliseconds(500), .boot) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };

        if (synth_state.active_sensing_timer) |*timer| {
            if (timer.read() > 500 * std.time.ns_per_ms) {
                std.log.warn("active sensing timeout, quitting...", .{});
                break;
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    std.log.info("fluidsynth version: {s}", .{fs.fluid_version_str()});
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    if (!args.skip()) return error.NoArgs; //to skip the zig call
    const sf2_path = args.next() orelse return error.NoSf2;

    std.log.info("Loading sf2: {s}", .{sf2_path});

    const settings = try fs.new_fluid_settings();
    defer fs.delete_fluid_settings(settings);
    try fs.fluid_settings_setint(settings, "midi.autoconnect", 1);

    try fs.fluid_settings_setstr(settings, "audio.driver", switch (builtin.os.tag) {
        .windows => "wasapi",
        .macos => "coreaudio",
        .linux => "alsa",
        else => @compileError("OS not supported"),
    });

    try fs.fluid_settings_setstr(settings, "midi.driver", switch (builtin.os.tag) {
        .windows => "winmidi",
        .macos => "coremidi",
        .linux => "alsa_seq",
        else => @compileError("OS not supported"),
    });

    const synth = fs.new_fluid_synth(settings) catch return error.NoSynth;
    var synth_state: Synth = .init(synth);
    defer fs.delete_fluid_synth(synth);

    const sfont_id = try fs.fluid_synth_sfload(synth, sf2_path, true);
    const sfont = try fs.fluid_synth_get_sfont_by_id(synth, sfont_id);
    fs.fluid_sfont_iteration_start(sfont);
    while (fs.fluid_sfont_iteration_next(sfont)) |preset| {
        const preset_name = fs.fluid_preset_get_name(preset);
        const preset_banknum = fs.fluid_preset_get_banknum(preset);
        const preset_num = fs.fluid_preset_get_num(preset);
        std.log.info("preset: b{} {} {s}", .{ preset_banknum, preset_num, preset_name });
    }

    const mdriver = fs.new_fluid_midi_driver(settings, handle_midi_event, &synth_state) catch return error.NoMidiDriver;
    defer fs.delete_fluid_midi_driver(mdriver);

    const adriver = fs.new_fluid_audio_driver(settings, synth) catch return error.NoAudioDriver;
    defer fs.delete_fluid_audio_driver(adriver);

    var stdin_future = try io.concurrent(stdin_thread_fn, .{ io, &synth_state });
    defer stdin_future.cancel(io) catch {};

    var tcp_future = try io.concurrent(tcp_server_thread_fn, .{ io, &synth_state });
    defer tcp_future.cancel(io) catch {};

    var active_sensing_future = try io.concurrent(active_sensing_thread_fn, .{ io, &synth_state });
    defer active_sensing_future.cancel(io) catch {};

    _ = try io.select(.{ &stdin_future, &tcp_future, &active_sensing_future });
}
