const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const config = @import("config.zig");

const png = @import("png.zig");
const webp = @import("webp.zig");
const util = @import("util.zig");
const Rational64 = util.Rational(u64);

const program_name = "webpconvert";
const program_version = "0.0.1";

const OutputFormat = b: {
    var fields: [8192]std.builtin.Type.EnumField = undefined;

    fields[0] = .{.name = "pam", .value = 0};
    if(config.have_png) fields[1] = .{.name = "png", .value = 1};

    break :b @Type(
        std.builtin.Type{
            .Enum = .{
                .tag_type = usize,
                .fields = fields,
                .decls = .{},
                .is_exhaustive = false
            }
        }
    );
};

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
    const allocator = std.heap.c_allocator;

    const data = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var dec = try webp.DecodeState.init(data, true, .rgba);
    defer dec.deinit();

    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer stdout_buffered.flush() catch unreachable;
    const stdout = stdout_buffered.writer();

    var out_enc = try png.EncodeState.init(
        allocator,
        stdout,
        png.FrameInfo{
            .width = dec.width,
            .height = dec.height,
            .pix_fmt = .rgba8,
        },
        @intCast(u32, dec.nb_frames),
        0);
    defer out_enc.deinit();

    var prev_timestamp: u16 = 0;
    while(try dec.next()) |frame| {
        std.io.getStdErr().writer().print("frame {d}/{d}\x1b[K\r", .{out_enc.seq+1, dec.nb_frames})
            catch {};
        const delta = @intCast(u16, frame.timestamp_ms) - prev_timestamp;
        try out_enc.feed(stdout, @ptrCast(*anyopaque, frame.data.ptr), util.Rational(u16){.n = delta, .d = 1000});
        prev_timestamp = @intCast(u16, frame.timestamp_ms);
    }
    try out_enc.finish(stdout);
    std.io.getStdErr().writer().print("\n", .{}) catch {};
}
