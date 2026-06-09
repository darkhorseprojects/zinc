const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const pkg_install = @import("../pkg/install.zig");
const manifest = @import("../pkg/manifest.zig");
const files = @import("../io/fs.zig");
const proc = @import("../io/process.zig");
const platform = @import("../platform/mod.zig");

const Allocator = std.mem.Allocator;

pub fn runPkg(allocator: Allocator, io: std.Io, store: *Store, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const cmd = args[0];

    if (std.mem.eql(u8, cmd, "install")) {
        if (args.len < 2) {
            try files.writeAllErr("Error: Missing package path or name.\n");
            return;
        }
        var path: []const u8 = args[1];
        var is_global = false;

        // Check for flags
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--global")) {
                is_global = true;
            } else if (std.mem.eql(u8, arg, "--local")) {
                is_global = false;
            } else {
                path = arg;
            }
        }

        try pkg_install.install(allocator, io, store, path, is_global);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len < 2) {
            try files.writeAllErr("Error: Missing package name.\n");
            return;
        }
        const name = args[1];
        try pkg_install.remove(allocator, io, store, name);
    } else if (std.mem.eql(u8, cmd, "list")) {
        const pkgs = try store.listPackages();
        defer {
            for (pkgs) |p| store.freePackage(p);
            allocator.free(pkgs);
        }

        try files.writeAllOut("Installed Packages:\n");
        for (pkgs) |p| {
            try files.writeAllOut("  - ");
            try files.writeAllOut(p.name);
            try files.writeAllOut(" (");
            try files.writeAllOut(p.version orelse "0.0.0");
            try files.writeAllOut(") [");
            try files.writeAllOut(p.scope orelse "local");
            try files.writeAllOut("] -> ");
            try files.writeAllOut(p.path orelse "");
            try files.writeAllOut("\n");
        }
    } else if (std.mem.eql(u8, cmd, "check")) {
        if (args.len < 2) {
            try files.writeAllErr("Error: Missing package name.\n");
            return;
        }
        const name = args[1];
        const pkg = (try store.getPackage(name)) orelse {
            try files.writeAllErr("Package not found.\n");
            return;
        };
        defer store.freePackage(pkg);

        // Load manifest
        const manifest_path = try std.fs.path.join(allocator, &.{ pkg.path.?, "zinc.pkg.yaml" });
        defer allocator.free(manifest_path);

        const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
        defer allocator.free(manifest_bytes);

        var parsed = try manifest.parse(allocator, manifest_bytes);
        defer parsed.deinit();

        const os = platform.currentOS();
        const os_name = @tagName(os);
        if (parsed.getScript("check", os_name)) |script_rel| {
            const check_script_path = try std.fs.path.join(allocator, &.{ pkg.path.?, script_rel });
            defer allocator.free(check_script_path);

            if (files.existsPath(check_script_path)) {
                try files.writeAllOut("Running package check script...\n");
                const run_res = try proc.run(allocator, io, &.{check_script_path}, pkg.path.?, 10 * 1024 * 1024);
                defer run_res.deinit(allocator);

                if (run_res.stdout.len > 0) try files.writeAllOut(run_res.stdout);
                if (run_res.stderr.len > 0) try files.writeAllErr(run_res.stderr);

                if (run_res.code == 0) {
                    try files.writeAllOut("Package check passed.\n");
                    var updated_pkg = pkg;
                    updated_pkg.checked_at = std.Io.Clock.now(.real, io).toSeconds();
                    try store.insertPackage(updated_pkg);
                } else {
                    try files.writeAllErr("Package check failed.\n");
                }
            } else {
                try files.writeAllOut("No check script found.\n");
            }
        } else {
            try files.writeAllOut("No check script defined for this platform.\n");
        }
    } else {
        return usage();
    }
}

fn usage() !void {
    try files.writeAllErr("Usage: zn pkg <install|remove|list|check> [args]\n");
}
