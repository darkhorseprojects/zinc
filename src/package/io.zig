const std = @import("std");
const serde = @import("serde");
const proc = @import("../io/process.zig");

const Allocator = std.mem.Allocator;

pub const Source = struct { uri: []const u8, ref: ?[]const u8, path: ?[]const u8 };
pub const Interface = struct {
    request: ?ContextSelection,
    output: []OutputMapping,

    pub fn deinit(self: *Interface, allocator: Allocator) void {
        if (self.request) |selection| selection.deinit(allocator);
        for (self.output) |mapping| freeStrings(allocator, mapping.selector);
        allocator.free(self.output);
    }
};
pub const ContextSelection = union(enum) {
    all,
    path: [][]const u8,
    map: []ContextMap,

    pub fn deinit(self: ContextSelection, allocator: Allocator) void {
        switch (self) {
            .all => {},
            .path => |items| freeStrings(allocator, items),
            .map => |items| {
                for (items) |item| {
                    item.selection.deinit(allocator);
                    allocator.free(item.name);
                }
                allocator.free(items);
            },
        }
    }
};
pub const ContextMap = struct { name: []const u8, selection: ContextSelection };
pub const OutputMapping = struct { local: []const u8, selector: [][]const u8 };
pub const Software = struct {
    allocator: Allocator,
    name: []const u8,
    python: ?[]const u8,
    command: ?[]const u8,
    args: [][]const u8,
    cwd: ?[]const u8,
    env: []proc.EnvPair,

    pub fn deinit(self: *Software) void {
        self.allocator.free(self.name);
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

    pub fn resolve(self: *const Software, package_root: []const u8) !ResolvedInvocation {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var argv = std.ArrayList([]const u8).empty;
        if (self.python) |python| {
            const source_path = try resolveCwd(aa, package_root, python);
            try argv.append(aa, try aa.dupe(u8, "python3"));
            try argv.append(aa, source_path);
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

    pub fn deinit(self: *ResolvedInvocation) void {
        self.arena.deinit();
    }
};

pub fn parseSource(allocator: Allocator, maybe: ?*const serde.yaml.Value) !?Source {
    const v = maybe orelse return null;
    if (v.* != .mapping) return error.InvalidPackageSource;
    const uri = stringField(v, "uri") orelse return error.PackageSourceUriMissing;
    return .{
        .uri = try allocator.dupe(u8, uri),
        .ref = try stringDup(allocator, valueField(v, "ref")),
        .path = try stringDup(allocator, valueField(v, "path")),
    };
}

pub fn parseInterface(allocator: Allocator, maybe: ?*const serde.yaml.Value) !Interface {
    const v = maybe orelse return .{ .request = null, .output = try allocator.alloc(OutputMapping, 0) };
    if (v.* != .mapping) return error.InvalidPackageInterface;
    return .{
        .request = try parseContextSelection(allocator, valueField(v, "request")),
        .output = try parseOutputMappings(allocator, valueField(v, "output")),
    };
}

fn parseContextSelection(allocator: Allocator, maybe: ?*const serde.yaml.Value) !?ContextSelection {
    const v = maybe orelse return null;
    if (v.* == .string) {
        if (std.mem.eql(u8, v.string, "context")) return .all;
        return .{ .path = try splitPath(allocator, v.string) };
    }
    if (v.* == .mapping) {
        var out = std.ArrayList(ContextMap).empty;
        errdefer {
            for (out.items) |item| {
                item.selection.deinit(allocator);
                allocator.free(item.name);
            }
            out.deinit(allocator);
        }
        var it = v.mapping.iterator();
        while (it.next()) |entry| {
            try out.append(allocator, .{ .name = try allocator.dupe(u8, entry.key_ptr.*), .selection = (try parseContextSelection(allocator, entry.value_ptr)) orelse .{ .path = try splitPath(allocator, entry.key_ptr.*) } });
        }
        return .{ .map = try out.toOwnedSlice(allocator) };
    }
    return error.InvalidContextSelection;
}

fn parseOutputMappings(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]OutputMapping {
    var out = std.ArrayList(OutputMapping).empty;
    errdefer {
        for (out.items) |mapping| {
            allocator.free(mapping.local);
            freeStrings(allocator, mapping.selector);
        }
        out.deinit(allocator);
    }
    const v = maybe orelse return out.toOwnedSlice(allocator);
    if (v.* != .mapping) return error.InvalidOutputMappings;
    var it = v.mapping.iterator();
    while (it.next()) |entry| {
        const selector = stringScalar(entry.value_ptr) orelse return error.InvalidOutputMapping;
        try out.append(allocator, .{ .local = try allocator.dupe(u8, entry.key_ptr.*), .selector = try splitPath(allocator, selector) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseSoftwareList(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]Software {
    var out = std.ArrayList(Software).empty;
    errdefer {
        for (out.items) |*software| software.deinit();
        out.deinit(allocator);
    }
    const v = maybe orelse return out.toOwnedSlice(allocator);
    if (v.* != .mapping) return error.InvalidPackageSoftware;
    var it = v.mapping.iterator();
    while (it.next()) |entry| try out.append(allocator, try parseSoftware(allocator, entry.key_ptr.*, entry.value_ptr));
    return out.toOwnedSlice(allocator);
}

fn parseSoftware(allocator: Allocator, name: []const u8, raw: *const serde.yaml.Value) !Software {
    if (raw.* != .mapping) return error.InvalidPackageSoftware;
    const python = try stringDup(allocator, valueField(raw, "python"));
    const command = try stringDup(allocator, valueField(raw, "command"));
    if (python == null and command == null) return error.SoftwareRunMissing;
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .python = python,
        .command = command,
        .args = try stringSequence(allocator, valueField(raw, "args")),
        .cwd = try stringDup(allocator, valueField(raw, "cwd")),
        .env = try envPairs(allocator, valueField(raw, "env")),
    };
}

pub fn splitPath(allocator: Allocator, raw: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, raw, '.');
    while (it.next()) |part| try out.append(allocator, try allocator.dupe(u8, part));
    return out.toOwnedSlice(allocator);
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

pub fn stringField(node: *const serde.yaml.Value, key: []const u8) ?[]const u8 {
    return stringScalar(valueField(node, key) orelse return null);
}

pub fn stringScalar(v: *const serde.yaml.Value) ?[]const u8 {
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

fn stringDup(allocator: Allocator, maybe: ?*const serde.yaml.Value) !?[]const u8 {
    const v = maybe orelse return null;
    const s = stringScalar(v) orelse return null;
    return try allocator.dupe(u8, s);
}

pub fn nodeText(allocator: Allocator, node: *const serde.yaml.Value) ![]u8 {
    return switch (node.*) {
        .string => try allocator.dupe(u8, node.string),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{node.integer}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{node.float}),
        .boolean => if (node.boolean) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false"),
        else => error.ManifestNodeNotScalar,
    };
}
