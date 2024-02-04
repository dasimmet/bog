const std = @import("std");
const bog = @import("bog");

pub fn pow(val: i64) i64 {
    return val * val;
}

pub fn main() !void {
    var state = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = state.allocator();

    const source = try std.fs.cwd().readFileAlloc(allocator, "examples/zig_from_bog.bog", 1024);
    defer allocator.free(source);

    var vm = bog.Vm.init(allocator, .{});
    defer vm.deinit();
    try vm.addPackage("pow", pow);

    const res = vm.compileAndRun(source) catch |e| switch (e) {
        else => |err| return err,
        error.TokenizeError, error.ParseError, error.CompileError => {
            try vm.errors.render(std.io.getStdErr().writer());
            return error.RunningBogFailed;
        },
    };

    const bog_integer = try res.bogToZig(i64, &vm);
    std.debug.assert(bog_integer == 8);
}
