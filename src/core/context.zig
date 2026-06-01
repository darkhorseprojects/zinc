const std = @import("std");
const config = @import("../runtime/config.zig");
const graph = @import("graph.zig");
const sessions = @import("../runtime/session.zig");
const uri = @import("../runtime/uri.zig");

const Allocator = std.mem.Allocator;

pub const BoundInput = struct {
    id: []u8,
    kind: graph.InputKind,
    value: []u8,
    mime: []u8,

    pub fn deinit(self: BoundInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.mime);
    }
};

pub const ResolvedValue = struct {
    text: []u8,

    pub fn deinit(self: ResolvedValue, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub const ExecutionKind = enum { interactive, graph_run, maintenance };

pub const ExecutionFrame = struct {
    kind: ExecutionKind,
    entry: []const u8,

    pub fn interactive(entry: []const u8) ExecutionFrame {
        return .{ .kind = .interactive, .entry = entry };
    }

    pub fn child(_: ExecutionFrame, entry: []const u8) ExecutionFrame {
        return .{ .kind = .graph_run, .entry = entry };
    }

    pub fn maintenance(entry: []const u8) ExecutionFrame {
        return .{ .kind = .maintenance, .entry = entry };
    }

    pub fn isInteractiveEntry(self: ExecutionFrame, id: []const u8) bool {
        return self.kind == .interactive and std.mem.eql(u8, id, self.entry);
    }
};

pub const RuntimeReadContext = struct {
    context: uri.Context,
    inputs: []uri.Input,

    pub fn deinit(self: RuntimeReadContext, allocator: Allocator) void {
        allocator.free(self.inputs);
    }
};

pub const BashAllowance = struct {
    head: []u8,
    remaining: usize,

    pub fn deinit(self: BashAllowance, allocator: Allocator) void {
        allocator.free(self.head);
    }
};

pub const BashAllowances = std.ArrayList(BashAllowance);

pub const RunContext = struct {
    allocator: Allocator,
    io: std.Io,
    home: []const u8,
    profile: *const config.RuntimeProfile,
    graph_path: []const u8,
    graph: *const graph.Graph,
    session: sessions.Session,
    log: *sessions.Log,
    inputs: []const BoundInput,
    frame: ExecutionFrame,
    bash_allowances: *BashAllowances,
};
