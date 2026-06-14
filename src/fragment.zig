const std = @import("std");
const substrate = @import("substrate.zig");

pub fn head(target: []const u8, request: []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(target);
    h.update("\x00");
    h.update(request);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn fragment(target: []const u8, request: []const u8, result: []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(target);
    h.update("\x00");
    h.update(request);
    h.update("\x00");
    h.update(result);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn headFragment(store: *substrate.Store, head_hex: []const u8) !?substrate.Fragment {
    const row = (try store.getHead(head_hex)) orelse return null;
    defer store.freeHead(row);
    return try store.getFragment(row.fragment);
}

pub fn put(store: *substrate.Store, target: []const u8, request: []const u8, result: []const u8, time: i64) ![64]u8 {
    const fragment_hex = fragment(target, request, result);
    try store.putFragment(.{ .fragment = &fragment_hex, .target = target, .request = request, .result = result, .time = time });
    return fragment_hex;
}

pub fn putHead(store: *substrate.Store, target: []const u8, request: []const u8, fragment_hex: []const u8) ![64]u8 {
    const head_hex = head(target, request);
    try store.putHead(.{ .head = &head_hex, .fragment = fragment_hex });
    return head_hex;
}

pub fn putAndHead(store: *substrate.Store, target: []const u8, request: []const u8, result: []const u8, time: i64) !struct { fragment: [64]u8, head: [64]u8 } {
    const fragment_hex = try put(store, target, request, result, time);
    const head_hex = try putHead(store, target, request, &fragment_hex);
    return .{ .fragment = fragment_hex, .head = head_hex };
}

pub fn payloadHash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
