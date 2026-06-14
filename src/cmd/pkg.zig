const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runPkg(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "install")) return install(allocator, io, store, args[1..]);
    if (std.mem.eql(u8, cmd, "remove")) return remove(allocator, io, store, args[1..]);
    if (std.mem.eql(u8, cmd, "check")) return check(allocator, io, store, args[1..]);
    if (std.mem.eql(u8, cmd, "update")) return update(allocator, io, store, args[1..]);
    if (std.mem.eql(u8, cmd, "list")) return list(allocator, store);
    return usage();
}

fn install(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    var scope: package.Scope = .workspace;
    var root: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--global")) scope = .global else if (std.mem.eql(u8, arg, "--workspace")) scope = .workspace else root = arg;
    }
    try package.install(allocator, io, store, root orelse return usage(), scope);
}

fn remove(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len != 1) return usage();
    try package.remove(allocator, io, store, args[0]);
}

fn check(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len != 1) return usage();
    try package.check(allocator, io, store, args[0]);
}

fn update(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    var check_only = false;
    var all = false;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check_only = true else if (std.mem.eql(u8, arg, "--all")) all = true else name = arg;
    }
    if (all) {
        const pkgs = try store.listPackages();
        defer {
            for (pkgs) |pkg| store.freePackage(pkg);
            allocator.free(pkgs);
        }
        for (pkgs) |pkg| try package.update(allocator, io, store, pkg.package, check_only);
        return;
    }
    try package.update(allocator, io, store, name orelse return usage(), check_only);
}

fn list(allocator: Allocator, store: *Substrate) !void {
    const pkgs = try store.listPackages();
    defer {
        for (pkgs) |pkg| store.freePackage(pkg);
        allocator.free(pkgs);
    }
    for (pkgs) |pkg| {
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.version);
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.root);
        if (pkg.source_git) |git| {
            try files.writeAllOut(" ");
            try files.writeAllOut(git);
            try files.writeAllOut("@");
            try files.writeAllOut(pkg.source_ref orelse "?");
        }
        try files.writeAllOut("\n");
    }
}

fn usage() error{InvalidUsage} {
    files.writeAllErr("usage: zn pkg <install|remove|check|update|list>\n") catch {};
    return error.InvalidUsage;
}
