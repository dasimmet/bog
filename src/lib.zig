//! ABI WARNING -- REMEMBER TO CHANGE include/bog.h
const std = @import("std");
const span = std.mem.span;
const bog = @import("bog.zig");
const gpa = std.heap.c_allocator;

const Error = enum(c_int) {
    None,
    OutOfMemory,
    TokenizeError,
    ParseError,
    CompileError,
    RuntimeError,
    MalformedByteCode,
    NotAMap,
    NoSuchMember,
    NotAFunction,
    InvalidArgCount,
    NativeFunctionsUnsupported,
    IoError,
};

export fn bog_Vm_init(vm: **bog.Vm, import_files: bool) Error {
    const ptr = gpa.create(bog.Vm) catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
    };
    ptr.* = bog.Vm.init(gpa, .{ .import_files = import_files });

    vm.* = ptr;
    return .None;
}

export fn bog_Vm_deinit(vm: *bog.Vm) void {
    vm.deinit();
}

fn bog_Vm_addStd(vm: *bog.Vm) callconv(.C) Error {
    vm.addStd() catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
    };
    return .None;
}

fn bog_Vm_addStdNoIo(vm: *bog.Vm) callconv(.C) Error {
    vm.addStdNoIo() catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
    };
    return .None;
}

comptime {
    const build_options = @import("build_options");
    if (!build_options.no_std)
        @export(bog_Vm_addStd, .{ .name = "bog_Vm_addStd", .linkage = .Strong });
    if (!build_options.no_std_no_io)
        @export(bog_Vm_addStdNoIo, .{ .name = "bog_Vm_addStdNoIo", .linkage = .Strong });
}

export fn bog_Vm_run(vm: *bog.Vm, res: **bog.Value, source: [*:0]const u8) Error {
    res.* = vm.compileAndRun(span(source)) catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
        error.TokenizeError => return .TokenizeError,
        error.ParseError => return .ParseError,
        error.CompileError => return .CompileError,
        else => undefined,
    };

    return .None;
}

export fn bog_Vm_call(vm: *bog.Vm, res: **bog.Value, container: *bog.Value, func_name: [*:0]const u8) Error {
    const func_name_value = bog.Value.string(func_name);
    const func = container.map.get(&func_name_value).?;
    res.* = vm.run(func.frame) catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
        error.FatalError => return .RuntimeError,
        error.Suspended => return .RuntimeError,
    };

    return .None;
}

export fn bog_Vm_renderErrors(vm: *bog.Vm, source: [*:0]const u8, out: *std.c.FILE) Error {
    _ = source;
    vm.errors.render(std.io.cWriter(out)) catch return .IoError;

    return .None;
}

export fn bog_Errors_init(errors: **bog.Errors) Error {
    const ptr = gpa.create(bog.Errors) catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
    };
    ptr.* = bog.Errors.init(gpa);

    errors.* = ptr;
    return .None;
}

export fn bog_Errors_deinit(errors: *bog.Errors) void {
    errors.deinit();
}

export fn bog_Errors_render(errors: *bog.Errors, source: [*:0]const u8, out: *std.c.FILE) Error {
    _ = source;
    errors.render(std.io.cWriter(out)) catch return .IoError;

    return .None;
}

export fn bog_parse(tree: *bog.Tree, path: [*:0]const u8, source: [*:0]const u8, errors: *bog.Errors) Error {
    tree.* = bog.parse(gpa, span(source), span(path), errors) catch |e| switch (e) {
        error.OutOfMemory => return .OutOfMemory,
        error.TokenizeError => return .TokenizeError,
        error.ParseError => return .ParseError,
        error.NeedInput => unreachable,
    };

    return .None;
}

export fn bog_Tree_deinit(tree: *bog.Tree) void {
    tree.deinit(gpa);
}

export fn bog_Tree_render(tree: *bog.Tree, out: *std.c.FILE, changed: ?*bool) Error {
    const c = tree.render(std.io.cWriter(out)) catch return .IoError;
    if (changed) |some| {
        some.* = c;
    }
    return .None;
}
