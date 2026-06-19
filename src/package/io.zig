const std = @import("std");
const serde = @import("serde");
const proc = @import("../io/process.zig");

const Allocator = std.mem.Allocator;

pub const Requirement = struct { package: []const u8, ref: ?[]const u8 };

pub const Surface = struct {
    allocator: Allocator,
    name: []const u8,
    about: ?[]const u8,
    python: ?[]const u8,
    command: ?[]const u8,
    args: [][]const u8,
    cwd: ?[]const u8,
    env: []proc.EnvPair,

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.name);
        if (self.about) |about| self.allocator.free(about);
        if (self.python) |python| self.allocator.free(python);
        if (self.command) |command| self.allocator.free(command);
        freeStrings(self.allocator, self.args);
        if (self.cwd) |cwd| self.allocator.free(cwd);
        for (self.env) |pair| {
            self.allocator.free(pair.key);
            self.allocator.free(pair.value);
        }
        self.allocator.free(self.env);
    }

    pub fn resolve(self: *const Surface, package_root: []const u8) !ResolvedInvocation {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var argv = std.ArrayList([]const u8).empty;
        if (self.python) |python| {
            const script_path = try resolveCwd(aa, package_root, python);
            try argv.append(aa, try aa.dupe(u8, "python3"));
            try argv.append(aa, script_path);
        } else {
            try argv.append(aa, try aa.dupe(u8, self.command.?));
        }
        for (self.args) |arg| try argv.append(aa, try aa.dupe(u8, arg));
        const cwd = if (self.cwd) |cwd_raw| try resolveCwd(aa, package_root, cwd_raw) else null;
        var env = std.ArrayList(proc.EnvPair).empty;
        for (self.env) |pair| try env.append(aa, .{ .key = try aa.dupe(u8, pair.key), .value = try aa.dupe(u8, pair.value) });
        return .{ .arena = arena, .argv = try argv.toOwnedSlice(aa), .stdin = null, .cwd = cwd, .env = try env.toOwnedSlice(aa), .timeout = 0 };
    }
};

pub const ResolvedInvocation = struct {
    arena: std.heap.ArenaAllocator,
    argv: [][]const u8,
    stdin: ?[]const u8,
    cwd: ?[]const u8,
    env: []proc.EnvPair,
    timeout: u64,

    pub fn deinit(self: *ResolvedInvocation) void { self.arena.deinit(); }
};

pub fn parseRequirements(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]Requirement {
    const v = maybe orelse return &.{};
    if (v.* != .mapping) return error.InvalidPackageRequirements;
    var count: usize = 0;
    var it = v.mapping.iterator();
    while (it.next()) |_| count += 1;
    var requirements = try allocator.alloc(Requirement, count);
    var index: usize = 0;
    errdefer {
        for (requirements[0..index]) |requirement| {
            allocator.free(requirement.package);
            if (requirement.ref) |ref| allocator.free(ref);
        }
        allocator.free(requirements);
    }
    it.reset();
    while (it.next()) |entry| {
        const ref = switch (entry.value_ptr.*) {
            .string => |s| try allocator.dupe(u8, s),
            .mapping => blk: {
                const ref_value = valueField(entry.value_ptr, "ref") orelse return error.InvalidPackageRequirement;
                if (ref_value.* != .string) return error.InvalidPackageRequirement;
                break :blk try allocator.dupe(u8, ref_value.string);
            },
            else => return error.InvalidPackageRequirement,
        };
        requirements[index] = .{ .package = try allocator.dupe(u8, entry.key_ptr.*), .ref = ref };
        index += 1;
    }
    return requirements;
}

pub fn parseSurfaceList(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]Surface {
    var out = std.ArrayList(Surface).empty;
    errdefer {
        for (out.items) |*surface| surface.deinit();
        out.deinit(allocator);
    }
    const v = maybe orelse return out.toOwnedSlice(allocator);
    if (v.* != .mapping) return error.InvalidPackageSurface;
    var it = v.mapping.iterator();
    while (it.next()) |entry| try out.append(allocator, try parseSurface(allocator, entry.key_ptr.*, entry.value_ptr));
    return out.toOwnedSlice(allocator);
}

fn parseSurface(allocator: Allocator, name: []const u8, raw: *const serde.yaml.Value) !Surface {
    if (raw.* != .mapping) return error.InvalidPackageSurface;
    const python = try stringDup(allocator, valueField(raw, "python"));
    const command = try stringDup(allocator, valueField(raw, "command"));
    if (python == null and command == null) return error.SurfaceRunMissing;
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .about = try stringDup(allocator, valueField(raw, "about")),
        .python = python,
        .command = command,
        .args = try stringSequence(allocator, valueField(raw, "args")),
        .cwd = try stringDup(allocator, valueField(raw, "cwd")),
        .env = try envPairs(allocator, valueField(raw, "env")),
    };
}

fn stringSequence(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    const v = maybe orelse return out.toOwnedSlice(allocator);
    if (v.* == .string) return try allocator.dupe([]const u8, &.{v.string});
    if (v.* != .sequence) return error.InvalidStringSequence;
    for (v.sequence) |item| {
        const s = stringScalar(&item) orelse return error.InvalidStringSequence;
        try out.append(allocator, try allocator.dupe(u8, s));
    }
    return out.toOwnedSlice(allocator);
}

fn envPairs(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]proc.EnvPair {
    var out = std.ArrayList(proc.EnvPair).empty;
    errdefer {
        for (out.items) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        out.deinit(allocator);
    }
    const v = maybe orelse return out.toOwnedSlice(allocator);
    if (v.* != .mapping) return error.InvalidEnv;
    var it = v.mapping.iterator();
    while (it.next()) |entry| {
        const raw_value = stringScalar(entry.value_ptr) orelse return error.InvalidEnv;
        try out.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, raw_value) });
    }
    return out.toOwnedSlice(allocator);
}

fn resolveCwd(allocator: Allocator, package_root: []const u8, cwd: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(cwd)) return try allocator.dupe(u8, cwd);
    return try std.fs.path.join(allocator, &.{ package_root, cwd });
}

pub fn freeStrings(allocator: Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub fn valueField(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

pub fn stringField(node: *const serde.yaml.Value, key: []const u8) ?[]const u8 { return stringScalar(valueField(node, key) orelse return null); }

pub fn stringScalar(v: *const serde.yaml.Value) ?[]const u8 {
    return switch (v.*) { .string => |s| s, else => null };
}

fn stringDup(allocator: Allocator, maybe: ?*const serde.yaml.Value) !?[]const u8 {
    const v = maybe orelse return null;
    const s = stringScalar(v) orelse return null;
    return try allocator.dupe(u8, s);
}

pub fn nodeText(allocator: Allocator, node: *const serde.yaml.Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendNodeText(allocator, &out, node, 0);
    return out.toOwnedSlice(allocator);
}

fn appendNodeText(allocator: Allocator, out: *std.ArrayList(u8), node: *const serde.yaml.Value, indent: usize) !void {
    switch (node.*) {
        .string => |s| try out.appendSlice(allocator, s),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .sequence => |items| for (items) |item| {
            try indentOut(allocator, out, indent);
            try out.appendSlice(allocator, "- ");
            try appendNodeText(allocator, out, &item, indent + 2);
            try out.appendSlice(allocator, "\n");
        },
        .mapping => |*entries| {
            var it = entries.iterator();
            while (it.next()) |entry| {
                try indentOut(allocator, out, indent);
                try out.print(allocator, "{s}: ", .{entry.key_ptr.*});
                try appendNodeText(allocator, out, entry.value_ptr, indent + 2);
                try out.appendSlice(allocator, "\n");
            }
        },
        .null_val => try out.appendSlice(allocator, "null"),
    }
}

fn indentOut(allocator: Allocator, out: *std.ArrayList(u8), indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.append(allocator, ' ');
}
