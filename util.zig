const std = @import("std");

pub fn Rational(comptime T: type) type {
    if(!std.meta.trait.isIntegral(T)) @compileError("");
    return struct {
        const Self = @This();

        n: T,
        d: T,

        pub fn fromInt(x: anytype) Self {
            return Self{.n = x, .d = 1};
        }

        pub fn reduce(r: Self) Self {
            const c = std.math.gcd(r.n, r.d);
            return if(c != 1) Self{.n = @divExact(r.n, c), .d = @divExact(r.d, c)} else r;
        }

        pub fn format(
            r: Self,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype
        ) !void {
            try writer.print("{[n]d}/{[d]d}", r);
        }
    };
}
