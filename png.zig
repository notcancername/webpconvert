const std = @import("std");
const assert = std.debug.assert;
const util = @import("util.zig");
const zlib = @import("zlib.zig");

fn calculateCrc(data: []const u8) u32 {
    const c = comptime std.hash.crc.Crc(u32, std.hash.crc.Algorithm(u32){
        .polynomial = 0xedb88320,
        .initial = 0xffffffff,
        .xor_output = 0xffffffff,
        .reflect_input = true,
        .reflect_output = true,
    });
    return c.hash(data);
}

// I'm fine leaving this as-is.
pub const Chunk = struct {
    typ: [4]u8,
    data: []u8,
    crc: u32,

    const PropertyBits = packed struct {
        safe_to_copy: bool,
        reserved: bool,
        private: bool,
        ancillary: bool,
    };

    pub fn validate(c: Chunk) error{InvalidCRC}!void {
        if(c.crc != calculateCrc(&c.typ) ^ calculateCrc(c.data))
            return error.InvalidCRC;
    }

    pub fn checksum(c: *Chunk) void {
        c.crc = calculateCrc(&c.typ) ^ calculateCrc(c.data);
    }

    pub inline fn getPropertyBits(c: Chunk) PropertyBits {
        return .{
            .safe_to_copy = std.ascii.isLower(c.typ[0]),
            .reserved = std.ascii.isLower(c.typ[1]),
            .private = std.ascii.isLower(c.typ[2]),
            .ancillary = std.ascii.isLower(c.typ[3]),
        };
    }

    pub fn init(typ: [4]u8, data: []u8, crc: u32) Chunk {
        assert(data.len < std.math.maxInt(i32));
        return .{
            .typ = typ,
            .data = data,
            .crc = crc,
        };
    }

    pub fn readOrNull(reader: anytype, a: std.mem.Allocator) !?Chunk {
        return read(reader, a) catch |e| switch(e) {
            error.EndOfStream => null,
            else => e,
        };
    }

    pub fn read(reader: anytype, a: std.mem.Allocator) !Chunk {
        var c: Chunk = undefined;
        const len = try reader.readIntBig(u32);
        assert(len < std.math.maxInt(i32));

        try reader.readNoEof(&c.typ);
        c.data = try a.alloc(u8, len);
        try reader.readNoEof(c.data);
        c.crc = try reader.readIntBig(u32);
        return c;
    }

    pub fn write(c: Chunk, writer: anytype) !void {
        assert(c.data.len < std.math.maxInt(i32));
        try writer.writeIntBig(u32, @intCast(u32, c.data.len));
        try writer.writeAll(&c.typ);
        try writer.writeAll(c.data);
        try writer.writeIntBig(u32, c.crc);
    }

    pub fn deinit(c: Chunk, a: std.mem.Allocator) void {
        a.free(c.data);
    }

    pub fn format(
        v: Chunk,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        try writer.print("{s} {d} {x}", .{v.typ, v.data.len, v.crc});
    }

};

pub const pnghdr = 0x89504e470d0a1a0a;

pub const FrameInfo = struct {
    pub const PixFmt = enum {
        y1,
        y2,
        y4,
        y8,
        y16,

        ya8,
        ya16,

        rgb8,
        rgb16,

        rgba8,
        rgba16,

        pub inline fn getNbComponents(pf: PixFmt) usize {
            return switch(pf) {
                .y1, .y2, .y4, .y8, .y16 => 1,
                .ya8, .ya16 => 2,
                .rgb8, .rgb16 => 3,
                else => 4,
            };
        }

        pub inline fn getColorType(pf: PixFmt) u8 {
            return switch(pf) {
                .y1, .y2, .y4, .y8, .y16 => 0,
                .ya8, .ya16 => 4,
                .rgb8, .rgb16 => 2,
                else => 6,
            };
        }

        pub inline fn getBpc(pf: PixFmt) usize {
            return switch(pf) {
                .y1 => 1,
                .y2 => 2,
                .y4 => 4,
                .y8, .ya8, .rgb8, .rgba8 => 8,
                else => 16,
            };
        }

        pub inline fn getBpp(pf: PixFmt) usize {
            return switch(pf) {
                .y1     => 1,
                .y2     => 2,
                .y4     => 4,
                .y8     => 8,
                .ya8,
                .y16    => 16,
                .rgb8   => 24,
                .rgb16  => 48,
                .ya16,
                .rgba8  => 32,
                .rgba16 => 64,
            };
        }

        pub inline fn getBypp(pf: PixFmt) usize {
            return switch(pf) {
                .y1,
                .y2,
                .y4,
                .y8 => 1,

                .ya8,
                .y16    => 2,
                .rgb8   => 3,
                .rgb16  => 6,

                .ya16,
                .rgba8  => 4,
                .rgba16 => 8,
            };
        }
    };

    width: u32,
    height: u32,
    pix_fmt: PixFmt,

    pub fn scanlineIterator(fi: FrameInfo, data: *anyopaque) ScanlineIterator {
        return ScanlineIterator{
            .data = @ptrCast([*]u8, data)[0..fi.pix_fmt.getBypp() * fi.width * fi.height],
            .scanline_bytes = fi.pix_fmt.getBypp() * fi.width,
        };
    }

    pub const ScanlineIterator = struct {
        data: []const u8,
        scanline_bytes: usize,

        pub fn next(si: *ScanlineIterator) ?[]const u8 {
            if(si.data.len == 0) return null;
            defer si.data = si.data[si.scanline_bytes..];
            return si.data[0..si.scanline_bytes];
        }
    };

};

// minimal effort
pub const EncodeState = struct {
    allocator: std.mem.Allocator,
    fi: FrameInfo,
    comp_buf: std.ArrayList(u8),
    seq: u32 = 0,

    pub fn init(
        a: std.mem.Allocator,
        writer: anytype,
        fi: FrameInfo,
        nb_frames: u32,
        nb_plays: u32,
    ) !EncodeState {
        try writer.writeIntBig(u64, pnghdr);
        var buf: [13]u8 = undefined;
        // XXX: find a nicer way to do this
        var c = Chunk{.typ = "IHDR".*, .data = &buf, .crc = undefined};
        std.mem.writeIntBig(u32, buf[0..4], fi.width);
        std.mem.writeIntBig(u32, buf[4..8], fi.height);
        buf[8] = @intCast(u8, fi.pix_fmt.getBpc());
        buf[9] = @intCast(u8, fi.pix_fmt.getColorType());
        buf[10] = 0;
        buf[11] = 0;
        buf[12] = 0;
        c.checksum();
        try c.write(writer);

        if(nb_frames > 1) {
            c.typ = "acTL".*;
            c.data = buf[0..8];
            std.mem.writeIntBig(u32, buf[0..4], nb_frames);
            std.mem.writeIntBig(u32, buf[4..8], nb_plays);
            c.checksum();
            try c.write(writer);
        }

        return EncodeState{
            .allocator = a,
            .fi = fi,
            .comp_buf = std.ArrayList(u8).init(a),
        };
    }

    pub fn feed(
        state: *EncodeState,
        writer: anytype,
        frame: *anyopaque,
        duration: util.Rational(u16)
    ) !void {
        var ds: zlib.DeflateState = undefined;
        // XXX: make this customizable
        try ds.init(null);
        const al_wr = state.comp_buf.writer();
        var buf: [26]u8 = undefined;
        var c = Chunk{.typ = "fcTL".*, .data = &buf, .crc = undefined};
        std.mem.writeIntBig(u32, buf[0..4], state.seq);
        std.mem.writeIntBig(u32, buf[4..8], state.fi.width);
        std.mem.writeIntBig(u32, buf[8..12], state.fi.height);
        @memset(buf[12..], 0, 8);
        std.mem.writeIntBig(u16, buf[20..22], duration.n);
        std.mem.writeIntBig(u16, buf[22..24], duration.d);
        buf[24] = 1;
        buf[25] = 0;
        c.checksum();
        try c.write(writer);
        // XXX: this seems fine for now, but needs some kind of improvement
        if(state.seq != 0) {
            c.typ = "fdAT".*;
            var b: [4]u8 = undefined;
            std.mem.writeIntBig(u32, &b, state.seq);
            try state.comp_buf.insertSlice(0, &b);
        } else c.typ = "IDAT".*;
        {
            // XXX: the fact that we're doing this row-wise means we're calling
            // deflate a lot. consider adding frame-wise approach
            var it = state.fi.scanlineIterator(frame);
            while(it.next()) |scanline| {
                // XXX: this whole thing is not satisfying
                var null_fbs = std.io.fixedBufferStream("\x00");
                const null_r = null_fbs.reader();
                var scanline_fbs = std.io.fixedBufferStream(scanline);
                const scanline_r = scanline_fbs.reader();
                try ds.deflate(null_r, al_wr);
                try ds.deflate(scanline_r, al_wr);
            }
        }
        try ds.end(al_wr);
        c.data = state.comp_buf.items;
        c.checksum();
        try c.write(writer);
        state.comp_buf.shrinkRetainingCapacity(0);
        state.seq += 1;
    }

    pub fn finish(_: *EncodeState, writer: anytype) !void {
        var c = Chunk{.typ = "IEND".*, .data = "", .crc = undefined};
        c.checksum();
        try c.write(writer);
    }

    pub fn deinit(state: *EncodeState) void {
        state.comp_buf.deinit();
        state.* = undefined;
    }
};
