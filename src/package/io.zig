const std = @import("std");
const serde = @import("serde");
const proc = @import("../io/process.zig");

const Allocator = std.mem.Allocator;

pub const Source = struct { uri: []const u8, ref: ?[]const u8, path: ?[]const u8 };
pub const Interface = struct {
    request_all: bool,
    output: []OutputMapping,

    pub fn deinit(self: *Interface, allocator: Allocator) void {
        for (self.output) |mapping| freeStrings(allocator, mapping.selector);
        allocator.free(self.output);
    }
};
pub const OutputMapping = struct { local: []const u8, selector: [][]const u8 };
pub const Link = struct { package: []const u8, ref: ?[]const u8 };
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
    const v = maybe orelse return .{ .request_all = false, .output = try allocator.alloc(OutputMapping, 0) };
    if (v.* != .mapping) return error.InvalidPackageInterface;
    const request_all = if (valueField(v, "request")) |request|
        request.* == .string and std.mem.eql(u8, request.string, "context")
    else
        false;
    return .{ .request_all = request_all, .output = try parseOutputMappings(allocator, valueField(v, "output")) };
}

pub fn parseLinks(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]Link {
    const v = maybe orelse return &.{};
    if (v.* != .mapping) return error.InvalidPackageLinks;

    var count: usize = 0;
    var it = v.mapping.iterator();
    while (it.next()) |_| count += 1;
    var links = try allocator.alloc(Link, count);
    var index: usize = 0;
    errdefer {
        for (links[0..index]) |link| {
            allocator.free(link.package);
            if (link.ref) |ref| allocator.free(ref);
        }
        allocator.free(links);
    }

    it.reset();
    while (it.next()) |entry| {
        const ref = switch (entry.value_ptr.*) {
            .string => |s| try allocator.dupe(u8, s),
            .mapping => blk: {
                const ref_value = valueField(entry.value_ptr, "ref") orelse return error.InvalidPackageLink;
                if (ref_value.* != .string) return error.InvalidPackageLink;
                break :blk try allocator.dupe(u8, ref_value.string);
            },
            else => return error.InvalidPackageLink,
        };
        links[index] = .{ .package = try allocator.dupe(u8, entry.key_ptr.*), .ref = ref };
        index += 1;
    }
    return links;
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
    const v = maybe orelse {
        const owned = try out.toOwnedSlice(allocator);
        out.deinit(allocator);
        return owned;
    };
    if (v.* != .mapping) return error.InvalidOutputMappings;
    var it = v.mapping.iterator();
    while (it.next()) |entry| {
        const selector = stringScalar(entry.value_ptr) orelse return error.InvalidOutputMapping;
        try out.append(allocator, .{ .local = try allocator.dupe(u8, entry.key_ptr.*), .selector = try splitPath(allocator, selector) });
    }
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
}

pub fn parseSoftwareList(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![]Software {
    var out = std.ArrayList(Software).empty;
    errdefer {
        for (out.items) |*software| software.deinit();
        out.deinit(allocator);
    }
    const v = maybe orelse {
        const owned = try out.toOwnedSlice(allocator);
        out.deinit(allocator);
        return owned;
    };
    if (v.* != .mapping) return error.InvalidPackageSoftware;
    var it = v.mapping.iterator();
    while (it.next()) |entry| try out.append(allocator, try parseSoftware(allocator, entry.key_ptr.*, entry.value_ptr));
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
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
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
}

fn stringSequence(allocator: Allocator, maybe: ?*const serde.yaml.Value) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    const v = maybe orelse {
        const owned = try out.toOwnedSlice(allocator);
        out.deinit(allocator);
        return owned;
    };
    if (v.* == .string) return try allocator.dupe([]const u8, &.{v.string});
    if (v.* != .sequence) return error.InvalidStringSequence;
    for (v.sequence) |item| {
        const s = stringScalar(&item) orelse return error.InvalidStringSequence;
        try out.append(allocator, try allocator.dupe(u8, s));
    }
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
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
    const v = maybe orelse {
        const owned = try out.toOwnedSlice(allocator);
        out.deinit(allocator);
        return owned;
    };
    if (v.* != .mapping) return error.InvalidEnv;
    var it = v.mapping.iterator();
    while (it.next()) |entry| {
        const raw_value = stringScalar(entry.value_ptr) orelse return error.InvalidEnv;
        try out.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, raw_value) });
    }
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
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
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendNodeText(allocator, &out, node, 0);
    const owned = try out.toOwnedSlice(allocator);
    out.deinit(allocator);
    return owned;
}

fn appendNodeText(allocator: Allocator, out: *std.ArrayList(u8), node: *const serde.yaml.Value, indent: usize) !void {
    switch (node.*) {
        .string => |s| try out.appendSlice(allocator, s),
        .integer => try out.print(allocator, "{d}", .{node.integer}),
        .float => try out.print(allocator, "{d}", .{node.float}),
        .boolean => try out.appendSlice(allocator, if (node.boolean) "true" else "false"),
        .sequence => {
            for (node.sequence) |item| {
                try indentOut(allocator, out, indent);
                try out.appendSlice(allocator, "- ");
                try appendNodeText(allocator, out, &item, indent + 2);
                try out.appendSlice(allocator, "\n");
            }
        },
        .mapping => {
            var it = node.mapping.iterator();
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
