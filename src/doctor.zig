const std = @import("std");
const config = @import("config/mod.zig");
const layout = @import("io/layout.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !void {
    std.debug.print("Zinc\n  version: 0.4.11\n\n", .{});

    const model_id = config.resolveConfiguredModelId(allocator, io, layout_ctx) catch |err| switch (err) {
        error.ModelNotConfigured => return printUnconfigured(),
        else => return err,
    };
    defer allocator.free(model_id);
    const profile = config.loadRuntimeProfile(allocator, io, layout_ctx, model_id) catch |err| switch (err) {
        error.ModelNotConfigured, error.UnknownModel => return printUnconfigured(),
        else => return err,
    };
    defer profile.deinit(allocator);

    std.debug.print("Model endpoint\n  model id: {s}\n  model: {s}\n  base URL: {s}\n  context window: {d}\n  chars/token estimate: {d}\n", .{ profile.provider.id, profile.provider.model, profile.provider.base_url, profile.model.context_window, profile.model.chars_per_token });
    if (profile.provider.api_key_env) |name| {
        std.debug.print("  API key env: {s} ({s})\n", .{ name, if (config.envPresent(name)) "set" else "missing" });
    }
    if (profile.model.reasoning.enabled) std.debug.print("  reasoning effort: {s}\n", .{profile.model.reasoning.effort}) else std.debug.print("  reasoning: disabled\n", .{});

    const reachable = try endpointReachable(allocator, io, profile.provider.base_url);
    std.debug.print("  endpoint: {s}\n", .{if (reachable) "reachable" else "not reachable"});
    if (!reachable) std.debug.print("\nFix: start an OpenAI-compatible endpoint, or set models.{s}.base_url in your Zinc config.\n", .{profile.provider.id});
}

fn printUnconfigured() void {
    std.debug.print(
        \\Model endpoint
        \\  not configured
        \\
        \\Add `default_model` and a matching `models.<id>` entry in your Zinc config.
        \\Zinc calls OpenAI-compatible Chat Completions endpoints; it does not ship or manage a model server.
        \\
    , .{});
}

fn endpointReachable(allocator: Allocator, io: std.Io, base_url: []const u8) !bool {
    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{base_url});
    defer allocator.free(url);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = client.fetch(.{ .location = .{ .url = url }, .method = .GET }) catch return false;
    return @intFromEnum(result.status) >= 200 and @intFromEnum(result.status) < 500;
}
