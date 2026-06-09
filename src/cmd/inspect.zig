const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const uri = @import("../runtime/uri.zig");
const pkg_index = @import("../pkg/index.zig");
const manifest = @import("../pkg/manifest.zig");
const files = @import("../io/fs.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

pub fn runInspect(allocator: Allocator, store: *Store, arg: []const u8) !void {
    if (std.mem.startsWith(u8, arg, "zinc://")) {
        const parsed = try uri.parse(allocator, arg);
        defer parsed.deinit(allocator);

        switch (parsed.type) {
            .run => {
                const run_obj = (try store.getRun(parsed.id)) orelse {
                    try files.writeAllErr("Run not found.\n");
                    return;
                };
                try files.writeAllOut("Run ID: ");
                try files.writeAllOut(run_obj.id);
                try files.writeAllOut("\nStatus: ");
                try files.writeAllOut(run_obj.status orelse "unknown");
                try files.writeAllOut("\nDoc ID: ");
                try files.writeAllOut(run_obj.doc_id orelse "none");
                try files.writeAllOut("\n\nActions:\n");
                
                const acts = try store.listActions(run_obj.id);
                defer {
                    for (acts) |act| store.freeAction(act);
                    allocator.free(acts);
                }
                for (acts) |act| {
                    try files.writeAllOut("  - ");
                    const seq_str = try std.fmt.allocPrint(allocator, "{d}", .{act.seq});
                    defer allocator.free(seq_str);
                    try files.writeAllOut(seq_str);
                    try files.writeAllOut(": ");
                    try files.writeAllOut(act.action orelse "");
                    try files.writeAllOut(" -> ");
                    try files.writeAllOut(act.status orelse "");
                    try files.writeAllOut("\n");
                }
            },
            .doc => {
                const doc = (try store.getDoc(parsed.id)) orelse {
                    try files.writeAllErr("Document not found.\n");
                    return;
                };
                try files.writeAllOut("Doc ID: ");
                try files.writeAllOut(doc.id);
                try files.writeAllOut("\nName: ");
                try files.writeAllOut(doc.name orelse "untitled");
                try files.writeAllOut("\nPath: ");
                try files.writeAllOut(doc.path orelse "unknown");
                try files.writeAllOut("\n\nSource:\n");
                try files.writeAllOut(doc.source);
                try files.writeAllOut("\n");
            },
            .package => {
                const pkg = (try store.getPackage(parsed.id)) orelse {
                    try files.writeAllErr("Package not found.\n");
                    return;
                };
                defer store.freePackage(pkg);

                try files.writeAllOut("Package: ");
                try files.writeAllOut(pkg.name);
                try files.writeAllOut("\nVersion: ");
                try files.writeAllOut(pkg.version orelse "unknown");
                try files.writeAllOut("\nScope: ");
                try files.writeAllOut(pkg.scope orelse "unknown");
                try files.writeAllOut("\nPath: ");
                try files.writeAllOut(pkg.path orelse "unknown");
                try files.writeAllOut("\nSource: ");
                try files.writeAllOut(pkg.source orelse "unknown");
                try files.writeAllOut("\n");
            },
            .package_shape => {
                const shape_name = parsed.extra.?;
                const shape_path = try pkg_index.resolveShape(allocator, store, parsed.id, shape_name);
                defer allocator.free(shape_path);
                
                try runInspect(allocator, store, shape_path);
            },
            .approval => {
                // Check approvals
                try files.writeAllOut("Approval ref details:\n");
                try files.writeAllOut("  ID: ");
                try files.writeAllOut(parsed.id);
                try files.writeAllOut("\n");
            },
            else => {
                try files.writeAllErr("Addressing addresses this address format is not inspectable.\n");
            },
        }
    } else {
        // Inspect local file
        if (std.mem.endsWith(u8, arg, "zinc.pkg.yaml")) {
            const bytes = try files.readLimited(allocator, arg, 10 * 1024 * 1024);
            defer allocator.free(bytes);
            var parsed = try manifest.parse(allocator, bytes);
            defer parsed.deinit();

            try files.writeAllOut("Package Manifest:\n");
            try files.writeAllOut("  Name: ");
            try files.writeAllOut(parsed.name);
            try files.writeAllOut("\n  Version: ");
            try files.writeAllOut(parsed.version);
            try files.writeAllOut("\n  About: ");
            try files.writeAllOut(parsed.about);
            try files.writeAllOut("\n");
        } else {
            // Assume circuitry shape file
            var shape = try circuitry.loadFile(std.Options.debug_io, allocator, arg);
            defer shape.deinit();

            var conf = try circuitry.confirm(allocator, &shape);
            defer conf.deinit();

            const card = conf.card;
            try files.writeAllOut("Shape Name: ");
            try files.writeAllOut(card.name);
            try files.writeAllOut("\nAbout: ");
            try files.writeAllOut(card.about orelse "none");
            try files.writeAllOut("\nTakes:\n");
            for (card.takes) |t| {
                try files.writeAllOut("  - ");
                try files.writeAllOut(t);
                try files.writeAllOut("\n");
            }
            try files.writeAllOut("Does:\n");
            for (card.does) |d| {
                try files.writeAllOut("  - ");
                try files.writeAllOut(d);
                try files.writeAllOut("\n");
            }
            try files.writeAllOut("Gives:\n");
            for (card.gives) |g| {
                try files.writeAllOut("  - ");
                try files.writeAllOut(g);
                try files.writeAllOut("\n");
            }
        }
    }
}
