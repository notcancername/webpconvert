const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const config = @import("config.zig");

const png = @import("png.zig");
const webp = @import("webp.zig");
const util = @import("util.zig");

const program_name = "webpconvert";
const program_version = "0.0.1";

fn usage(arg0: []const u8) !noreturn {
    try std.io.getStdErr().writer().print(
        program_name ++ " version " ++ program_version ++ "\n" ++
            "Usage:\n" ++
            "{s} [format] \n" ++
            "    reads a WebP image from stdin and outputs a decoded image to stdout\n" ++
            "Supported output formats: pam " ++
            (if(config.have_png) "png " else " ") ++
            "\n",
        .{arg0},
    );
    std.os.exit(1);
}

pub fn main() !void {
    // replace this with the GPA from time to time to check for memory leaks
    var allocator = std.heap.c_allocator;
    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer stdout_buffered.flush() catch unreachable;
    const stdout = stdout_buffered.writer();

    const data = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var dec = try webp.DecodeState.init(data, true, .rgba);
    defer dec.deinit();

    var out_enc = try png.EncodeState.init(
        allocator,
        stdout,
        png.FrameInfo{
            .width = dec.width,
            .height = dec.height,
            .pix_fmt = .rgba8,
        },
        @intCast(u32, dec.nb_frames),
        0
    );
    defer out_enc.deinit();

    // for all frames, calculate the difference between their timestamp and the
    // previous one to get the delay in milliseconds.
    var prev_timestamp: u16 = 0;
    while(try dec.next()) |frame| {
        const delta = @intCast(u16, frame.timestamp_ms) - prev_timestamp;
        // encode!
        try out_enc.feed(
            stdout,
            @ptrCast(*anyopaque, frame.data.ptr),
            util.Rational(u16){.n = delta, .d = 1000}
        );
        prev_timestamp = @intCast(u16, frame.timestamp_ms);
        std.io.getStdErr().writer().print("frame {d}/{d}\x1b[K\r", .{out_enc.seq+1, dec.nb_frames})
            catch {};
    }
    try out_enc.finish(stdout);
    std.io.getStdErr().writer().print("\n", .{}) catch {};
}
