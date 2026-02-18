// TODO: Io.Select does not handle cancelable tasks and does not implement .concurrent.
// Check https://codeberg.org/ziglang/zig/pulls/30836
// Also issue https://codeberg.org/ziglang/zig/issues/31270

const std = @import("std");
const Io = std.Io;
const Group = Io.Group;
const Queue = Io.Queue;
const Cancelable = Io.Cancelable;
const ConcurrentError = Io.ConcurrentError;

pub fn Select(comptime U: type) type {
    return struct {
        io: Io,
        group: Group,
        queue: Queue(U),
        outstanding: usize,

        const S = @This();

        pub const Union = U;

        pub const Field = std.meta.FieldEnum(U);

        pub fn init(io: Io, buffer: []U) S {
            return .{
                .io = io,
                .queue = .init(buffer),
                .group = .init,
                .outstanding = 0,
            };
        }

        /// Calls `function` with `args` asynchronously. The resource spawned is
        /// owned by the select.
        ///
        /// `function` must have return type matching the `field` field of `Union`.
        ///
        /// `function` *may* be called immediately, before `async` returns.
        ///
        /// When this function returns, it is guaranteed that `function` has
        /// already been called and completed, or it has successfully been
        /// assigned a unit of concurrency.
        ///
        /// After this is called, `await` or `cancel` must be called before the
        /// select is deinitialized.
        ///
        /// Threadsafe.
        ///
        /// Related:
        /// * `Io.async`
        /// * `Group.async`
        pub fn async(
            s: *S,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) void {
            const Context = struct {
                select: *S,
                args: @TypeOf(args),
                fn start(type_erased_context: *const anyopaque) Cancelable!void {
                    const context: *const @This() = @ptrCast(@alignCast(type_erased_context));
                    const raw_result = @call(.auto, function, context.args) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                    };
                    const elem = @unionInit(U, @tagName(field), raw_result);
                    context.select.queue.putOneUncancelable(context.select.io, elem) catch |err| switch (err) {
                        error.Closed => unreachable,
                    };
                }
            };
            const context: Context = .{ .select = s, .args = args };
            _ = @atomicRmw(usize, &s.outstanding, .Add, 1, .monotonic);
            s.io.vtable.groupAsync(s.io.userdata, &s.group, @ptrCast(&context), .of(Context), Context.start);
        }

        /// Calls `function` with `args` concurrently. The resource spawned is
        /// owned by the select.
        ///
        /// `function` must have return type matching the `field` field of `Union`.
        ///
        /// After this function returns successfully, it is guaranteed that
        /// `function` has been assigned a unit of concurrency, and `await` or
        /// `cancel` must be called before the select is deinitialized.
        ///
        ///
        /// Threadsafe.
        ///
        /// Related:
        /// * `Io.concurrent`
        /// * `Group.concurrent`
        pub fn concurrent(
            s: *S,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) ConcurrentError!void {
            const Context = struct {
                select: *S,
                args: @TypeOf(args),
                fn start(type_erased_context: *const anyopaque) Cancelable!void {
                    const context: *const @This() = @ptrCast(@alignCast(type_erased_context));
                    const raw_result = @call(.auto, function, context.args) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                    };
                    const elem = @unionInit(U, @tagName(field), raw_result);
                    context.select.queue.putOneUncancelable(context.select.io, elem) catch |err| switch (err) {
                        error.Closed => unreachable,
                    };
                }
            };
            const context: Context = .{ .select = s, .args = args };
            try s.io.vtable.groupConcurrent(s.io.userdata, &s.group, @ptrCast(&context), .of(Context), Context.start);
            _ = @atomicRmw(usize, &s.outstanding, .Add, 1, .monotonic);
        }

        /// Blocks until another task of the select finishes.
        ///
        /// Asserts there is at least one more `outstanding` task.
        ///
        /// Not threadsafe.
        pub fn await(s: *S) Cancelable!U {
            s.outstanding -= 1;
            return s.queue.getOne(s.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };
        }

        /// Equivalent to `await` but requests cancelation on all remaining
        /// tasks owned by the select.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        ///
        /// It is illegal to call `await` after this.
        ///
        /// Idempotent. Not threadsafe.
        pub fn cancel(s: *S) void {
            s.outstanding = 0;
            s.group.cancel(s.io);
        }
    };
}
