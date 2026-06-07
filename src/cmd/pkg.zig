const std = @import("std");
const packages = @import("../pkg/mod.zig");
const resource = @import("../graph/resource.zig");
const files = @import("../io/fs.zig");
const cmd = @import("mod.zig");

const Allocator = std.mem.Allocator;

pub fn packageList(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context) !void {
    const text = try packages.listPackages(allocator, io, layout_ctx);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no packages found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn packageAdd(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, true);
    const source = parsed.value orelse return error.MissingPackageSource;
    const options = packages.InstallOptions{ .scope = parsed.scope orelse .local, .replace = parsed.replace, .model = parsed.model };
    const plan = packages.previewAdd(allocator, io, layout_ctx, source, options) catch |err| switch (err) {
        error.InvalidPackageManifest => return cmd.fail("invalid package manifest", .{}),
        error.PackageInstallTargetRequired => return cmd.fail("package install target required; pass --model <id>", .{}),
        error.PackageInstallTargetNotFound => return cmd.fail("package install target not found", .{}),
        else => return err,
    };
    defer plan.deinit(allocator, io);
    std.debug.print("Install Zinc package\n\n{s}\n", .{plan.text});
    if (!parsed.yes) try cmd.confirmOrFail("Install?");
    var package = packages.installPreviewed(allocator, io, layout_ctx, plan, source, options) catch |err| switch (err) {
        error.PackageInstallTargetRequired => return cmd.fail("package install target required; pass --model <id>", .{}),
        error.PackageInstallTargetNotFound => return cmd.fail("package install target not found", .{}),
        else => return err,
    };
    defer package.deinit(allocator);
    std.debug.print("added {s}: {s}\n", .{ cmd.scopeName(package.scope), package.path });
}

pub fn packageRemove(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    const text = try packages.show(allocator, io, layout_ctx, name, parsed.scope);
    defer allocator.free(text);
    std.debug.print("Remove Zinc package\n\n{s}\n", .{text});
    if (!parsed.yes) try cmd.confirmOrFail("Remove?");
    var package = packages.remove(allocator, io, layout_ctx, name, parsed.scope, parsed.model) catch |err| switch (err) {
        error.PackageInstallTargetRequired => return cmd.fail("package install target required; pass --model <id>", .{}),
        error.PackageInstallTargetNotFound => return cmd.fail("package install target not found", .{}),
        else => return err,
    };
    defer package.deinit(allocator);
    std.debug.print("removed {s}: {s}\n", .{ cmd.scopeName(package.scope), package.name });
}

pub fn packageUpdate(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    if (std.mem.eql(u8, name, "--all")) {
        const text = try packages.listPackages(allocator, io, layout_ctx);
        defer allocator.free(text);
        std.debug.print("Update all Zinc packages\n\n{s}\n", .{if (text.len == 0) "no packages found\n" else text});
        if (!parsed.yes) try cmd.confirmOrFail("Update all?");
        const updated = try packages.updateAll(allocator, io, layout_ctx);
        defer allocator.free(updated);
        std.debug.print("{s}", .{updated});
        return;
    }
    const plan = try packages.previewUpdate(allocator, io, layout_ctx, name, parsed.scope);
    defer plan.deinit(allocator, io);
    std.debug.print("Update Zinc package\n\n{s}\n", .{plan.text});
    if (!parsed.yes) try cmd.confirmOrFail("Update?");
    var package = try packages.update(allocator, io, layout_ctx, name, parsed.scope);
    defer package.deinit(allocator);
    std.debug.print("updated {s}: {s}\n", .{ cmd.scopeName(package.scope), package.path });
}

pub fn packageShow(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    const text = try packages.show(allocator, io, layout_ctx, name, parsed.scope);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

pub fn packageExec(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingPackageScript;
    const out = try packages.execScript(allocator, io, layout_ctx, args[0], args[1]);
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

pub fn packageCall(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    if (args.len != 2) return error.InvalidToolArguments;
    const result = try resource.callPackageTool(allocator, io, layout_ctx, args[0], args[1]);
    defer result.deinit(allocator);
    try files.writeAllOut(result.content);
    try files.writeAllOut("\n");
    if (result.is_error) return error.UserError;
}

const PackageArgs = struct { scope: ?packages.Scope = null, replace: bool = false, yes: bool = false, model: ?[]const u8 = null, value: ?[]const u8 = null };

fn parsePackageArgs(args: []const []const u8, allow_replace: bool) !PackageArgs {
    var parsed = PackageArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--local")) {
            if (parsed.scope != null) return error.ConflictingScopeFlags;
            parsed.scope = .local;
        } else if (std.mem.eql(u8, arg, "--global")) {
            if (parsed.scope != null) return error.ConflictingScopeFlags;
            parsed.scope = .global;
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelId;
            parsed.model = args[i];
        } else if (std.mem.eql(u8, arg, "--replace") and allow_replace) parsed.replace = true else if (std.mem.eql(u8, arg, "--yes")) parsed.yes = true else if (parsed.value == null) parsed.value = arg else return error.TooManyArguments;
    }
    return parsed;
}
