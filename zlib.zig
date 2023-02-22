const std = @import("std");
const c = @cImport(@cInclude("zlib.h"));

pub const DeflateState = struct {
    const buf_size = @as(usize, 64) << 10;

    st: c.z_stream = undefined,

    pub fn init(ds: *DeflateState, level: ?u4) !void {
        // XXX: we should use a Zig allocator here, but they need the size and I
        // can't be fucked to store it.
        ds.st.zalloc = null;
        ds.st.zfree = null;
        ds.st.@"opaque" = null;
        if(c.deflateInit(&ds.st, level orelse c.Z_DEFAULT_COMPRESSION) != c.Z_OK)
            return error.DeflateInitFailed;
    }

    pub fn deflate(ds: *DeflateState, reader: anytype, writer: anytype) !void {
        var in_buf: [buf_size]u8 = undefined;
        var out_buf: [buf_size]u8 = undefined;
        var eof: bool = false;
        var ret: c_int = c.Z_OK;
        while(true) {
            ds.st.avail_in = @intCast(c_uint, try reader.readAll(&in_buf));
            if(ds.st.avail_in < buf_size) eof = true;
            if(ds.st.avail_in == 0) break;
            ds.st.next_in = @ptrCast([*]u8, &in_buf);
            while(true) {
                ds.st.avail_out = buf_size;
                ds.st.next_out = @ptrCast([*]u8, &out_buf);
                ret = c.deflate(&ds.st, c.Z_PARTIAL_FLUSH);
                if(ret != c.Z_OK and ret != c.Z_STREAM_END) {
                    return error.DeflateFailed;
                }
                try writer.writeAll(out_buf[0..buf_size - ds.st.avail_out]);
                if(ds.st.avail_out > 0) break;
            }
            if(eof) break;
        }
    }

    pub fn end(ds: *DeflateState, writer: anytype) !void {
        var out_buf: [buf_size]u8 = undefined;
        ds.st.next_out = @ptrCast([*]u8, &out_buf);
        ds.st.avail_out = buf_size;

        while(true) {
            const ret = c.deflate(&ds.st, c.Z_FINISH);
            try writer.writeAll(out_buf[0..buf_size - ds.st.avail_out]);
            ds.st.next_out = @ptrCast([*]u8, &out_buf);
            ds.st.avail_out = buf_size;
            if(ret != c.Z_OK) {
            if(ret == c.Z_STREAM_END) break;
                return error.DeflateFailed;
            }
        }
        if(c.deflateEnd(&ds.st) != c.Z_OK)
            return error.DeflateEndFailed;
        ds.* = undefined;
    }
};

test {
    const data = "a" ** 16384;
    var out_al = std.ArrayList(u8).init(std.testing.allocator);
    defer out_al.deinit();
    const writer = out_al.writer();
    var fbs_reader = std.io.fixedBufferStream(data);
    const reader = fbs_reader.reader();
    var comp: DeflateState = undefined;
    try comp.init(null);
    try comp.deflate(reader, writer);
    try comp.end(writer);
    std.debug.print("compressed: (len: {d})\n{s}\n", .{out_al.items.len, std.fmt.fmtSliceHexLower(out_al.items)});
}
