const std = @import("std");
const fs = @import("fluidsynth");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "ZigFluidSynthf",
            // .icon = window_icon_png,
            .window_init_options = .{},
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

const State = struct {
    choice: usize,
};

var state: State = undefined;

fn init(_: *dvui.Window) !void {
    state = .{ .choice = 0 };
}

fn deinit() void {}

fn frame() !dvui.App.Result {
    const entries = [_][]const u8{ "ciao", "addio" };

    if (dvui.dropdown(@src(), &entries, .{ .choice = &state.choice }, .{}, .{})) {
        dvui.log.debug("choice: {d}", .{state.choice});
    }

    const entry = dvui.textEntry(@src(), .{}, .{});
    const entry_text = entry.textGet();
    if (entry.text_changed) {
        dvui.log.debug("entry.text: {s}", .{entry_text});
    }
    entry.deinit();

    const combobox = dvui.comboBox(@src(), .{}, .{});
    _ = combobox.entries(&entries);
    const combobox_text = combobox.te.textGet();
    if (combobox.te.text_changed) {
        dvui.log.debug("combobox.text: {s}", .{combobox_text});
    }
    combobox.deinit();

    const show_spinner = std.mem.eql(u8, combobox_text, "ciao");
    if (show_spinner) {
        dvui.spinner(@src(), .{});
    }

    return .ok;
}
