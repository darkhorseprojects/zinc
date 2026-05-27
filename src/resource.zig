const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const RefKind = enum { file, data, http, prompt, session };

pub const ResourceRef = struct {
    kind: RefKind,
    value: []u8,
    base_dir: ?[]u8 = null,

    pub fn deinit(self: ResourceRef, allocator: Allocator) void {
        allocator.free(self.value);
        if (self.base_dir) |dir| allocator.free(dir);
    }

    pub fn display(self: ResourceRef) []const u8 {
        return self.value;
    }
};

pub const ResourceValue = union(enum) {
    text: []u8,
    bytes: Bytes,
    image: Image,
    file: File,

    pub const Bytes = struct { data: []u8, mime: []u8 };
    pub const Image = struct { url: []u8, mime: []u8 };
    pub const File = struct { path: []u8, mime: []u8 };

    pub fn deinit(self: ResourceValue, allocator: Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .bytes => |bytes| {
                allocator.free(bytes.data);
                allocator.free(bytes.mime);
            },
            .image => |image| {
                allocator.free(image.url);
                allocator.free(image.mime);
            },
            .file => |file| {
                allocator.free(file.path);
                allocator.free(file.mime);
            },
        }
    }
};

pub const ModelPart = union(enum) {
    text: []u8,
    image_url: []u8,

    pub fn deinit(self: ModelPart, allocator: Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .image_url => |url| allocator.free(url),
        }
    }
};

pub fn parseRef(allocator: Allocator, raw: []const u8, base_dir: ?[]const u8) !ResourceRef {
    const kind: RefKind = if (std.mem.startsWith(u8, raw, "data:")) .data else if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) .http else if (std.mem.startsWith(u8, raw, "prompt:")) .prompt else if (std.mem.startsWith(u8, raw, "session:") or std.mem.startsWith(u8, raw, "sessions:")) .session else .file;
    return .{
        .kind = kind,
        .value = try allocator.dupe(u8, raw),
        .base_dir = if (base_dir) |dir| try allocator.dupe(u8, dir) else null,
    };
}

pub fn resolveFilePath(allocator: Allocator, ref: ResourceRef) ![]u8 {
    if (ref.kind != .file) return allocator.dupe(u8, ref.value);
    if (std.fs.path.isAbsolute(ref.value)) return allocator.dupe(u8, ref.value);
    return std.fs.path.join(allocator, &.{ ref.base_dir orelse ".", ref.value });
}

pub fn refToImagePart(allocator: Allocator, ref: ResourceRef, mime_hint: ?[]const u8) !ModelPart {
    switch (ref.kind) {
        .data, .http => return .{ .image_url = try allocator.dupe(u8, ref.value) },
        .file => {
            const path = try resolveFilePath(allocator, ref);
            defer allocator.free(path);
            return .{ .image_url = try imageDataUrl(allocator, path, mime_hint orelse mimeFromPath(path)) };
        },
        .prompt, .session => return error.ResourceCannotBecomeImage,
    }
}

pub fn imageDataUrl(allocator: Allocator, path: []const u8, mime: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "data:") or std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return allocator.dupe(u8, path);
    const bytes = try files.readLimited(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const prefix = try std.fmt.allocPrint(allocator, "data:{s};base64,", .{mime});
    defer allocator.free(prefix);
    const out = try allocator.alloc(u8, prefix.len + encoded_len);
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len..], bytes);
    return out;
}

pub fn mimeFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "application/octet-stream";
}

test "resource refs keep source separate from model parts" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var ref = try parseRef(allocator, "./shot.png", "/tmp/zinc");
    defer ref.deinit(allocator);
    try testing.expectEqual(RefKind.file, ref.kind);
    const path = try resolveFilePath(allocator, ref);
    defer allocator.free(path);
    try testing.expectEqualStrings("/tmp/zinc/./shot.png", path);
    try testing.expectEqualStrings("image/png", mimeFromPath(path));
}
