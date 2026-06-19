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
    if (std.mem.eql(u8, cmd, "update")) return update(allocator, io, store, args[1..]) catch |err| {
        try files.writeAllErr("pkg update failed: ");
        try files.writeAllErr(@errorName(err));
        try files.writeAllErr("\n");
        return err;
    };
    if (std.mem.eql(u8, cmd, "requires")) return requirements(allocator, store, args[1..]) catch |err| {
        try files.writeAllErr("pkg requirements failed: ");
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
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.uri);
        try files.writeAllOut("\n");
    }
}

fn update(allocator: Allocator, io: std.Io, store: *Substrate, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    var scope: package.Scope = .workspace;
    var selector: ?[]const u8 = null;
    var opts = package.UpdateOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--global")) {
            scope = .global;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            scope = .workspace;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "--ref")) {
            i += 1;
            if (i >= args.len) return error.MissingVersion;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--version")) opts.requested_version = value else opts.requested_ref = value;
        } else if (selector == null) {
            selector = arg;
        } else return usage();
    }
    try package.update(allocator, io, store, selector orelse return usage(), scope, opts);
}

fn requirements(allocator: Allocator, store: *Substrate, args: []const []const u8) !void {
    var selector: []const u8 = "all";
    var missing_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--missing")) missing_only = true else if (std.mem.eql(u8, arg, "all")) selector = "all" else selector = arg;
    }
    const rows = try package.listRequirements(allocator, store, selector, missing_only);
    defer {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }
    for (rows) |row| {
        try files.writeAllOut(row.owner);
        try files.writeAllOut(" -> ");
        try files.writeAllOut(row.package);
        if (row.ref) |ref| {
            try files.writeAllOut("@");
            try files.writeAllOut(ref);
        }
        if (row.installed) {
            try files.writeAllOut(" installed");
            if (row.version) |version| {
                try files.writeAllOut(" ");
                try files.writeAllOut(version);
            }
            if (row.root) |root| {
                try files.writeAllOut(" ");
                try files.writeAllOut(root);
            }
        } else {
            try files.writeAllOut(" missing");
        }
        try files.writeAllOut("\n");
    }
}

fn usage() error{InvalidUsage} {
    files.writeAllErr("usage: zn pkg <install|remove|list|update|requirements> [args]\n") catch {};
    return error.InvalidUsage;
}
