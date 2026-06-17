const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runPkg(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "install")) return install(allocator, io, store, args[1..]) catch |err| {
        try files.writeAllErr("pkg install failed: ");
        try files.writeAllErr(@errorName(err));
        try files.writeAllErr("\n");
        return err;
    };
    if (std.mem.eql(u8, cmd, "remove")) return remove(allocator, io, store, args[1..]) catch |err| {
        try files.writeAllErr("pkg remove failed: ");
        try files.writeAllErr(@errorName(err));
        try files.writeAllErr("\n");
        return err;
    };
    if (std.mem.eql(u8, cmd, "list")) return list(allocator, store) catch |err| {
        try files.writeAllErr("pkg list failed: ");
        try files.writeAllErr(@errorName(err));
        try files.writeAllErr("\n");
        return err;
    };
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
        if (pkg.source_uri) |uri| {
            try files.writeAllOut(" ");
            try files.writeAllOut(uri);
            if (pkg.source_ref) |ref| {
                try files.writeAllOut("@");
                try files.writeAllOut(ref);
            }
        }
        try files.writeAllOut("\n");
    }
}

fn usage() error{InvalidUsage} {
    files.writeAllErr("usage: zn pkg <install|remove|list>\n") catch {};
    return error.InvalidUsage;
}
