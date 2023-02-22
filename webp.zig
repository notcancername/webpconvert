const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude(@import("config.zig").webp_decode_include);
    @cInclude(@import("config.zig").webp_demux_include);
});

// At runtime, these would be sins of the highest order, but comptime makes this
// legal.
fn lower(comptime s: []const u8) []const u8 {
    var buf: [s.len]u8 = undefined;
    for(s) |v, i| buf[i] = std.ascii.toLower(v);
    return &buf;
}

fn toPascalCase(comptime s: []const u8) []const u8 {
    var ss = s;
    var buf: [s.len]u8 = undefined;
    var i = 1;
    buf[0] = std.ascii.toUpper(ss[0]);
    ss = ss[1..];

    while(ss.len > 0) {
        if(ss[0] == '_') {
            buf[i] = std.ascii.toUpper(ss[1]);
            ss = ss[1..];
        } else {
            buf[i] = std.ascii.toLower(ss[0]);
        }
        i += 1;
        ss = ss[1..];
    }
    return buf[0..i];
}

pub const Error = error{Unknown} || b: {
    @setEvalBranchQuota(10000);
    var counter = 0;
    var s: [8192]std.builtin.Type.Error = undefined;
    for(@typeInfo(c).Struct.decls) |field| {
        if(!std.mem.startsWith(u8, field.name, "VP8_STATUS_")) continue;
        if(std.mem.eql(u8, field.name[11..], "OK")) continue;
        s[counter].name = toPascalCase(lower(field.name[11..]));
        counter += 1;
    }

    break :b @Type(std.builtin.Type{.ErrorSet = s[0..counter]});
};

fn tryWebp(code: c.VP8StatusCode) Error!void {
    @setEvalBranchQuota(10000);
    if(code != c.VP8_STATUS_OK) {
        if(builtin.mode != .ReleaseFast) {
            inline for(@typeInfo(c).Struct.decls) |field| {
                if(comptime !std.mem.startsWith(u8, field.name, "VP8_STATUS_")) continue;
                if(comptime std.mem.eql(u8, field.name[11..], "OK")) continue;
                if(code == @field(c, field.name))
                    return @field(Error, toPascalCase(lower(field.name[11..])));
            }
        }
        return error.Unknown;
    }
}

test "tryWebp" {
    try tryWebp(0);
    if(tryWebp(c.VP8_STATUS_NOT_ENOUGH_DATA) != Error.NotEnoughData)
        return error.No;
}

pub const Frame = struct {
    data: []u8,
    timestamp_ms: u64,

    fn dup(self: Frame, allocator: std.mem.Allocator) error{OutOfMemory}!Frame {
        return Frame{
            .data = try allocator.dupe(u8, self.data),
            .timestamp_ms = self.timestamp_ms,
        };
    }
};

pub const DecodeState = struct {
    dec: *c.WebPAnimDecoder,
    width: u14,
    height: u14,
    frame_len: usize,
    nb_frames: usize,

    pub const Colorspace = enum(c_ushort) {
        rgba = c.MODE_RGBA,
        bgra = c.MODE_BGRA,
        rgba_premultiplied = c.MODE_rgbA,
        bgra_premultiplied = c.MODE_bgrA,
    };

    pub fn init(
        data: []const u8,
        want_threading: bool,
        colorspace: Colorspace
    ) Error!DecodeState {
        var opts: c.WebPAnimDecoderOptions = undefined;
        if(c.WebPAnimDecoderOptionsInit(&opts) == 0)
            return error.Unknown;

        opts.color_mode = @enumToInt(colorspace);
        opts.use_threads = if(want_threading) 1 else 0;

        var s = DecodeState{
            .dec = @as(
                *c.WebPAnimDecoder,
                c.WebPAnimDecoderNew(&c.WebPData{.bytes = data.ptr, .size = data.len}, &opts)
                    orelse return error.Unknown
            ),
            .width = undefined,
            .height = undefined,
            .frame_len = undefined,
            .nb_frames = undefined,
        };

        errdefer c.WebPAnimDecoderDelete(s.dec);

        var info: c.WebPAnimInfo = undefined;
        if(c.WebPAnimDecoderGetInfo(s.dec, &info) == 0)
            return error.Unknown;

        s.width = @intCast(u14, info.canvas_width);
        s.height = @intCast(u14, info.canvas_height);
        s.frame_len = @as(usize, info.canvas_width) * info.canvas_height * 4;
        s.nb_frames = @as(usize, info.frame_count);
        return s;
    }

    /// Return is callee-owned.
    pub fn next(state: *DecodeState) !?Frame {
        if(c.WebPAnimDecoderHasMoreFrames(state.dec) != 0) {
            var buf: [*]u8 = undefined;
            var timestamp: c_int = undefined;
            return if(c.WebPAnimDecoderGetNext(state.dec, @ptrCast([*c][*c]u8, &buf), &timestamp) != 0)
                return Frame{.data = buf[0..state.frame_len], .timestamp_ms = @intCast(u64, timestamp)}
            else return error.Unknown;
        }
        return null;
    }

    pub fn deinit(state: *DecodeState) void {
        c.WebPAnimDecoderDelete(state.dec);
        state.* = undefined;
    }
};

const FramesWithInfo = struct{
    rows: u16,
    cols: u16,
    frames: []Frame,

    pub fn deinit(frames: FramesWithInfo, allocator: std.mem.Allocator) void {
        for(frames.frames) |frame| allocator.free(frame.data);
        allocator.free(frames.frames);
    }
};

pub fn decodeAll(
    data: []const u8,
    allocator: std.mem.Allocator,
    colorspace: DecodeState.Colorspace,
) !FramesWithInfo {
    var dec = try DecodeState.init(data, true, colorspace);
    defer dec.deinit();

    var frames = try allocator.alloc(Frame, dec.nb_frames);
    var idx: usize = 0;

    while(try dec.next()) |frame| : (idx += 1)
        frames[idx] = try frame.dup(allocator);

    return FramesWithInfo{.cols = dec.width, .rows = dec.height, .frames = frames};
}