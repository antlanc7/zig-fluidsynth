const std = @import("std");
const builtin = @import("builtin");
const fs = @cImport({
    @cInclude("fluidsynth.h");
});

fn now() std.time.Instant {
    return std.time.Instant.now() catch unreachable;
}

const Synth = struct {
    synth: *fs.fluid_synth_t,
    received_active_sensing: ?std.time.Instant,
    transposition: i32,
    touch_disabled: bool,

    pub fn init(synth: *fs.fluid_synth_t) Synth {
        return .{
            .synth = synth,
            .received_active_sensing = null,
            .transposition = 0,
            .touch_disabled = false,
        };
    }
};

fn handle_midi_event(data: ?*anyopaque, event: ?*fs.fluid_midi_event_t) callconv(.c) c_int {
    const synth_state: *Synth = @ptrCast(@alignCast(data));
    const midi_type = fs.fluid_midi_event_get_type(event);
    if (midi_type == 0xF8) {
        return fs.FLUID_OK;
    } else if (midi_type == 0xFE) {
        if (synth_state.received_active_sensing == null) std.debug.print("active sensing\n", .{});
        synth_state.received_active_sensing = now();
        return fs.FLUID_OK;
    }
    const midi_key = fs.fluid_midi_event_get_key(event);
    const midi_vel = fs.fluid_midi_event_get_velocity(event);

    // std.debug.print("{}: event {} {} {}\n", .{
    //     (now().since(start_time)) / std.time.ns_per_ms,
    //     midi_type,
    //     midi_key,
    //     midi_vel,
    // });

    if (midi_type == 144) {
        if (synth_state.transposition != 0) {
            _ = fs.fluid_midi_event_set_key(event, midi_key + synth_state.transposition);
        }
        if (synth_state.touch_disabled and midi_vel != 0) {
            _ = fs.fluid_midi_event_set_velocity(event, 64);
        }
    }

    return fs.fluid_synth_handle_midi_event(synth_state.synth, event);
}

fn fluid_check_error(err: c_int) void {
    if (err != fs.FLUID_OK) {
        std.debug.print("fluidsynth error: {}\n", .{err});
        std.process.exit(1);
    }
}

fn handle_cmd(cmd: []const u8, writer: *std.io.Writer, synth_state: *Synth) !void {
    const synth = synth_state.synth;
    if (cmd.len == 0) return;
    // std.debug.print("stdin: {s}\n", .{msg});
    if (cmd[0] == '+' or cmd[0] == '-') {
        _ = fs.fluid_synth_all_notes_off(synth, 0);
        synth_state.transposition = std.fmt.parseInt(c_int, cmd, 10) catch 0;
        try writer.print("transpose: {}\n", .{synth_state.transposition});
    } else if (cmd[0] == 'b') {
        const bank = std.fmt.parseUnsigned(c_int, cmd[1..], 10) catch return;
        _ = fs.fluid_synth_bank_select(synth, 0, bank);
        _ = fs.fluid_synth_program_reset(synth);
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
        _ = fs.fluid_synth_program_change(synth, 0, program_change);
        try writer.print("pc: {}\n", .{program_change});
    }
    try writer.flush();
}

fn stream_thread_fn(reader: *std.Io.Reader, writer: *std.Io.Writer, synth: *Synth) void {
    while (true) {
        const cmd = reader.takeDelimiterExclusive('\n') catch break;
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

fn tcp_server_thread_fn(synth: *Synth) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    if (!args.skip()) return error.NoArgs; //to skip the zig call
    const sf2_path = args.next() orelse return error.NoSf2;

    std.debug.print("Loading sf2: {s}\n", .{sf2_path});

    const settings = fs.new_fluid_settings().?;
    defer fs.delete_fluid_settings(settings);
    fluid_check_error(fs.fluid_settings_setint(settings, "midi.autoconnect", 1));

    // fluid_check_error(fs.fluid_settings_setstr(settings, "audio.driver", switch (builtin.os.tag) {
    //     .windows => "wasapi",
    //     .macos => "coreaudio",
    //     else => @panic("OS not supported"),
    // }));

    // fluid_check_error(fs.fluid_settings_setstr(settings, "midi.driver", switch (builtin.os.tag) {
    //     .windows => "winmidi",
    //     .macos => "coremidi",
    //     .linux => "oss",
    //     else => @panic("OS not supported"),
    // }));

    const synth = fs.new_fluid_synth(settings) orelse return error.NoSynth;
    var synth_state: Synth = .init(synth);
    defer fs.delete_fluid_synth(synth);

    const sfont_id = fs.fluid_synth_sfload(synth, sf2_path, 1);
    const sfont = fs.fluid_synth_get_sfont_by_id(synth, sfont_id).?;
    fs.fluid_sfont_iteration_start(sfont);
    while (fs.fluid_sfont_iteration_next(sfont)) |preset| {
        const preset_name = fs.fluid_preset_get_name(preset);
        const preset_banknum = fs.fluid_preset_get_banknum(preset);
        const preset_num = fs.fluid_preset_get_num(preset);
        std.debug.print("preset: b{} {} {s}\n", .{ preset_banknum, preset_num, preset_name });
    }

    const mdriver = fs.new_fluid_midi_driver(settings, handle_midi_event, synth) orelse return error.NoMidiDriver;
    defer fs.delete_fluid_midi_driver(mdriver);

    const adriver = fs.new_fluid_audio_driver(settings, synth) orelse return error.NoAudioDriver;
    defer fs.delete_fluid_audio_driver(adriver);

    std.debug.print("adriver: {x}\n", .{@intFromPtr(adriver)});

    const stdin_thread = try std.Thread.spawn(.{}, stdin_thread_fn, .{&synth_state});
    stdin_thread.detach();

    const tcp_server_thread = try std.Thread.spawn(.{}, tcp_server_thread_fn, .{&synth_state});
    tcp_server_thread.detach();

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        if (synth_state.received_active_sensing) |active_sensing| {
            if (now().since(active_sensing) > 500 * std.time.ns_per_ms) {
                std.debug.print("active sensing timeout, quitting...\n", .{});
                break;
            }
        }
    }
}
