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

        // pub fn to(r: Self, comptime D: type) D {
        //     return @as(D, switch(@typeInfo(D)) {
        //         .Int, .ComptimeInt => r.n / r.d,
        //         .Float, .ComptimeFloat => @intToFloat(D, r.n) / @intToFloat(D, r.d),
        //         else => @compileError(""),
        //     });
        // }

        // pub fn mul(r: Self, x: anytype) Self {
        //     return reduce(switch(@typeInfo(@TypeOf(x))) {
        //         .Int, .ComptimeInt => Self{r.n * x, r.d},
        //         .Float, .ComptimeFloat => Self{@floatToInt(T, @intToFloat(@TypeOf(x), r.n)) * x, r.d},
        //         .Struct => Self{r.n * x.n, r.d * x.d},
        //         else => @compileError(""),
        //     });
        // }

        // pub fn div(r: Self, x: anytype) Self {
        //     return reduce(switch(@typeInfo(@TypeOf(x))) {
        //         .Int, .ComptimeInt => Self{r.n, r.d * x},
        //         .Float, .ComptimeFloat => Self{r.n, @floatToInt(T, @intToFloat(@TypeOf(x), r.d)) * x},
        //         .Struct => Self{r.n * x.d, r.d * x.n},
        //         else => @compileError(""),
        //     });
        // }

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
