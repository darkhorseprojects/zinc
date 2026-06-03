const std = @import("std");
const config = @import("../config/mod.zig");
const graph = @import("mod.zig");
const sessions = @import("../session/mod.zig");
const uri = @import("../io/uri.zig");

const Allocator = std.mem.Allocator;

pub const BoundInput = struct {
    id: []u8,
    kind: graph.InputKind,
    value: []u8,
    content_type: []u8,

    pub fn deinit(self: BoundInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.content_type);
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
    target: []const u8,

    pub fn interactive(target: []const u8) ExecutionFrame {
        return .{ .kind = .interactive, .target = target };
    }

    pub fn child(_: ExecutionFrame, target: []const u8) ExecutionFrame {
        return .{ .kind = .graph_run, .target = target };
    }

    pub fn maintenance(target: []const u8) ExecutionFrame {
        return .{ .kind = .maintenance, .target = target };
    }

    pub fn isInteractiveTarget(self: ExecutionFrame, id: []const u8) bool {
        return self.kind == .interactive and std.mem.eql(u8, id, self.target);
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
