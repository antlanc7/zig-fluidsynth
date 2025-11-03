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
    } else {
        const program_change = std.fmt.parseUnsigned(c_int, cmd, 10) catch return;
        try fs.fluid_synth_program_change(synth, 0, program_change);
        try writer.print("pc: {}\n", .{program_change});
    }
    try writer.flush();
}

fn stream_thread_fn(reader: *std.Io.Reader, writer: *std.Io.Writer, synth: *Synth) void {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch break;
        const cmd = std.mem.trim(u8, line, &std.ascii.whitespace);
        handle_cmd(cmd, writer, synth) catch break;
    }
}

fn stdin_thread_fn(synth: *Synth) void {
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    var reader = stdin.reader(&reader_buffer);
    var writer = stdout.writer(&writer_buffer);
    stream_thread_fn(&reader.interface, &writer.interface, synth);
}

fn tcp_conn_handler_thread_fn(client: std.net.Server.Connection, synth: *Synth) void {
    defer client.stream.close();
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var reader = client.stream.reader(&reader_buffer);
    var writer = client.stream.writer(&writer_buffer);
    stream_thread_fn(reader.interface(), &writer.interface, synth);
}

fn tcp_server_thread_fn(allocator: std.mem.Allocator, synth: *Synth) void {
    const address = std.net.Address.parseIp4("0.0.0.0", 9999) catch unreachable;
    var server = address.listen(.{}) catch return;
    defer server.deinit();

    var pool: std.Thread.Pool = undefined;
    pool.init(std.Thread.Pool.Options{ .allocator = allocator, .n_jobs = 5 }) catch return;
    defer pool.deinit();

    while (true) {
        const client = server.accept() catch break;
        pool.spawn(tcp_conn_handler_thread_fn, .{ client, synth }) catch break;
    }
}

pub fn main() !void {
    std.log.info("fluidsynth version: {s}\n", .{fs.fluid_version_str()});
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
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

    const stdin_thread = try std.Thread.spawn(.{}, stdin_thread_fn, .{&synth_state});
    stdin_thread.detach();

    const tcp_server_thread = try std.Thread.spawn(.{}, tcp_server_thread_fn, .{ allocator, &synth_state });
    tcp_server_thread.detach();

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        if (synth_state.active_sensing_timer) |*timer| {
            if (timer.read() > 500 * std.time.ns_per_ms) {
                std.log.warn("active sensing timeout, quitting...", .{});
                break;
            }
        }
    }
}
