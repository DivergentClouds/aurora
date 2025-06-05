const std = @import("std");
const common = @import("common.zig");
const Block = @This();

contents: *[common.block_size]u8,

pub fn read(
    buffer: *[common.block_size]u8,
    block_index: u16,
    storage: std.fs.File,
) !Block {
    try storage.seekTo(@as(usize, block_index) * common.block_size);

    const reader = storage.reader();

    _ = try reader.readAll(buffer);

    return Block{ .contents = buffer };
}

pub fn write(
    block: Block,
    block_index: u16,
    storage: std.fs.File,
) !void {
    try storage.seekTo(@as(usize, block_index) * common.block_size);

    const writer = storage.writer();

    try writer.writeAll(block.contents);
}

pub fn new(buffer: *[common.block_size]u8) !Block {
    @memset(buffer, 0);

    return Block{ .contents = buffer };
}
