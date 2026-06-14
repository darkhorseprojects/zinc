const std = @import("std");
const substrate = @import("substrate.zig");

pub fn choice(target: []const u8, request: []const u8) [64]u8 {
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

pub fn chosen(store: *substrate.Store, choice_hex: []const u8) !?substrate.Fragment {
    const row = (try store.getChoice(choice_hex)) orelse return null;
    defer store.freeChoice(row);
    return try store.getFragment(row.fragment);
}

pub fn put(store: *substrate.Store, target: []const u8, request: []const u8, result: []const u8, time: i64) ![64]u8 {
    const fragment_hex = fragment(target, request, result);
    try store.putFragment(.{ .fragment = &fragment_hex, .target = target, .request = request, .result = result, .time = time });
    return fragment_hex;
}

pub fn choose(store: *substrate.Store, target: []const u8, request: []const u8, fragment_hex: []const u8) ![64]u8 {
    const choice_hex = choice(target, request);
    try store.putChoice(.{ .choice = &choice_hex, .fragment = fragment_hex });
    return choice_hex;
}

pub fn putAndChoose(store: *substrate.Store, target: []const u8, request: []const u8, result: []const u8, time: i64) !struct { fragment: [64]u8, choice: [64]u8 } {
    const fragment_hex = try put(store, target, request, result, time);
    const choice_hex = try choose(store, target, request, &fragment_hex);
    return .{ .fragment = fragment_hex, .choice = choice_hex };
}

pub fn payloadHash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
