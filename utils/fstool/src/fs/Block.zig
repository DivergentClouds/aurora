const std = @import("std");
const common = @import("common.zig");
const Block = @This();

contents: *[common.block_size]u8,

pub fn read(
    contents: *[common.block_size]u8,
    block_index: u16,
    storage: std.fs.File,
) !Block {
    try storage.seekTo(block_index * common.block_size);

    const reader = storage.reader();

    _ = try reader.readAll(contents);

    return Block{ .contents = contents };
}

pub fn write(
    block: Block,
    block_index: u16,
    storage: std.fs.File,
) !void {
    try storage.seekTo(block_index * common.block_size);

    const writer = storage.writer();

    try writer.writeAll(block.contents);
}

pub fn new(contents: *[common.block_size]u8) !Block {
    @memset(contents, 0);

    return Block{ .contents = contents };
}
