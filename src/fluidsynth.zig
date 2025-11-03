const std = @import("std");
const c = @cImport({
    @cInclude("fluidsynth.h");
});

pub const fluid_synth_t = c.fluid_synth_t;
pub const fluid_midi_event_t = c.fluid_midi_event_t;

fn fluid_check_error(err: c_int) !void {
    if (err < 0) {
        return error.FluidSynthError;
    }
}

pub fn fluid_version_str() [:0]const u8 {
    return std.mem.span(c.fluid_version_str());
}

pub fn fluid_midi_event_get_type(evt: *const c.fluid_midi_event_t) u8 {
    return @intCast(c.fluid_midi_event_get_type(evt));
}

pub fn new_fluid_settings() !*c.fluid_settings_t {
    return c.new_fluid_settings() orelse return error.FluidSynthError;
}

pub fn delete_fluid_settings(settings: *c.fluid_settings_t) void {
    c.delete_fluid_settings(settings);
}

pub fn fluid_settings_setint(settings: *c.fluid_settings_t, name: [:0]const u8, val: c_int) !void {
    try fluid_check_error(c.fluid_settings_setint(settings, name, val));
}

pub fn fluid_settings_setstr(settings: *c.fluid_settings_t, name: [:0]const u8, str: [:0]const u8) !void {
    try fluid_check_error(c.fluid_settings_setstr(settings, name, str));
}

pub fn new_fluid_synth(settings: *c.fluid_settings_t) !*c.fluid_synth_t {
    return c.new_fluid_synth(settings) orelse return error.FluidSynthError;
}

pub fn delete_fluid_synth(synth: *c.fluid_synth_t) void {
    c.delete_fluid_synth(synth);
}

pub fn fluid_synth_sfload(synth: *c.fluid_synth_t, path: [:0]const u8, reset_presets: bool) !usize {
    const res = c.fluid_synth_sfload(synth, path, @intFromBool(reset_presets));
    try fluid_check_error(res);
    return @intCast(res);
}

pub fn fluid_synth_get_sfont_by_id(synth: *c.fluid_synth_t, id: usize) !*c.fluid_sfont_t {
    return c.fluid_synth_get_sfont_by_id(synth, @intCast(id)) orelse return error.FluidSynthError;
}

pub fn fluid_sfont_iteration_start(sfont: *c.fluid_sfont_t) void {
    c.fluid_sfont_iteration_start(sfont);
}

pub fn fluid_sfont_iteration_next(sfont: *c.fluid_sfont_t) ?*c.fluid_preset_t {
    return c.fluid_sfont_iteration_next(sfont);
}

pub fn fluid_preset_get_name(preset: *c.fluid_preset_t) [:0]const u8 {
    return std.mem.span(c.fluid_preset_get_name(preset));
}

pub fn fluid_preset_get_banknum(preset: *c.fluid_preset_t) usize {
    return @intCast(c.fluid_preset_get_banknum(preset));
}

pub fn fluid_preset_get_num(preset: *c.fluid_preset_t) usize {
    return @intCast(c.fluid_preset_get_num(preset));
}

const cb = *const fn (data: ?*anyopaque, event: *c.fluid_midi_event_t) callconv(.c) void;

pub fn new_fluid_midi_driver(settings: *c.fluid_settings_t, handler: cb, event_handler_data: ?*anyopaque) !*c.fluid_midi_driver_t {
    return c.new_fluid_midi_driver(settings, @ptrCast(handler), event_handler_data) orelse return error.FluidSynthError;
}

pub fn delete_fluid_midi_driver(driver: *c.fluid_midi_driver_t) void {
    c.delete_fluid_midi_driver(driver);
}

pub fn new_fluid_audio_driver(settings: *c.fluid_settings_t, synth: *c.fluid_synth_t) !*c.fluid_audio_driver_t {
    return c.new_fluid_audio_driver(settings, synth) orelse return error.FluidSynthError;
}

pub fn delete_fluid_audio_driver(driver: *c.fluid_audio_driver_t) void {
    c.delete_fluid_audio_driver(driver);
}

pub fn fluid_midi_event_get_key(event: *c.fluid_midi_event_t) c_int {
    return c.fluid_midi_event_get_key(event);
}

pub fn fluid_midi_event_get_velocity(event: *c.fluid_midi_event_t) c_int {
    return c.fluid_midi_event_get_velocity(event);
}

pub fn fluid_midi_event_set_key(event: *c.fluid_midi_event_t, key: c_int) !void {
    return fluid_check_error(c.fluid_midi_event_set_key(event, key));
}

pub fn fluid_midi_event_set_velocity(event: *c.fluid_midi_event_t, vel: c_int) !void {
    return fluid_check_error(c.fluid_midi_event_set_velocity(event, vel));
}

pub fn fluid_synth_handle_midi_event(synth: *c.fluid_synth_t, event: *c.fluid_midi_event_t) !void {
    return fluid_check_error(c.fluid_synth_handle_midi_event(synth, event));
}

pub fn fluid_synth_all_notes_off(synth: *c.fluid_synth_t, channel: u4) !void {
    return fluid_check_error(c.fluid_synth_all_notes_off(synth, channel));
}

pub fn fluid_synth_bank_select(synth: *c.fluid_synth_t, channel: u4, bank: c_int) !void {
    return fluid_check_error(c.fluid_synth_bank_select(synth, channel, bank));
}

pub fn fluid_synth_program_reset(synth: *c.fluid_synth_t) !void {
    return fluid_check_error(c.fluid_synth_program_reset(synth));
}

pub fn fluid_synth_set_gain(synth: *c.fluid_synth_t, gain: f32) void {
    c.fluid_synth_set_gain(synth, gain);
}

pub fn fluid_synth_get_gain(synth: *c.fluid_synth_t) f32 {
    return c.fluid_synth_get_gain(synth);
}

pub fn fluid_synth_program_change(synth: *c.fluid_synth_t, channel: u4, program: c_int) !void {
    return fluid_check_error(c.fluid_synth_program_change(synth, channel, program));
}
