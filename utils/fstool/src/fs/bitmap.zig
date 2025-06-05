const std = @import("std");

const SuperBlock = @import("SuperBlock.zig").SuperBlock;
const common = @import("common.zig");

const Version0 = struct {
    fn free(
        id: u16,
        kind: Kind,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        if (!try Version0.check(id, kind, superblock.*, storage)) {
            return error.AlreadyAllocated;
        }

        const bitmap_base_index = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        const bitmap_block_len = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const bitmap_byte_address = bitmap_base_index * common.block_size + id / 8;
        const bitmap_end_address = (bitmap_base_index + bitmap_block_len) * common.block_size;

        if (bitmap_byte_address >= bitmap_end_address)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(id % 8);

        try storage.seekTo(bitmap_byte_address);
        var bitmap_byte = try storage.reader().readByte();

        bitmap_byte &= ~(@as(u8, 1) << bitmap_bit_offset);
        try storage.seekTo(bitmap_byte_address);
        try storage.writer().writeByte(bitmap_byte);

        switch (kind) {
            .inode => superblock.@"0".unallocated_inodes += 1,
            .data => superblock.@"0".unallocated_data += 1,
        }
    }

    /// allocate a new block in the relevant bitmap
    fn allocate(
        id: u16,
        kind: Kind,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        if (try Version0.check(id, kind, superblock.*, storage)) {
            return error.AlreadyAllocated;
        }

        const bitmap_base_index: usize = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        const bitmap_block_len: usize = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const bitmap_byte_address = bitmap_base_index * common.block_size + id / 8;
        const bitmap_end_address = (bitmap_base_index + bitmap_block_len) * common.block_size;

        if (bitmap_byte_address >= bitmap_end_address)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(id % 8);

        try storage.seekTo(bitmap_byte_address);
        var bitmap_byte = try storage.reader().readByte();

        bitmap_byte |= @as(u8, 1) << bitmap_bit_offset;
        try storage.seekTo(bitmap_byte_address);
        try storage.writer().writeByte(bitmap_byte);

        switch (kind) {
            .inode => superblock.@"0".unallocated_inodes -= 1,
            .data => superblock.@"0".unallocated_data -= 1,
        }
    }

    /// returns true if the inode is already allocated
    fn check(
        id: u16,
        kind: Kind,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !bool {
        // promote to u32 for later arithmetic
        const bitmap_base_index: u32 = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        // promote to u32 for later arithmetic
        const bitmap_block_len: u32 = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const bitmap_byte_address = bitmap_base_index * common.block_size + id / 8;
        const bitmap_end_address = (bitmap_base_index + bitmap_block_len) * common.block_size;

        if (bitmap_byte_address >= bitmap_end_address)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(id % 8);

        try storage.seekTo(bitmap_byte_address);
        const bitmap_byte = try storage.reader().readByte();

        return bitmap_byte & (@as(u8, 1) << bitmap_bit_offset) != 0;
    }

    /// returns the next id of the free data block or inode
    fn nextFree(
        kind: Kind,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !?u16 {
        const bitmap_base_index: u32 = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        const bitmap_block_len: u32 = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const reader = storage.reader();

        try storage.seekTo(bitmap_base_index * common.block_size);
        for (0..bitmap_block_len * common.block_size) |u8_offset| {
            const u8_bitmap = try reader.readByte();

            if (u8_bitmap != 0xff) { // don't check each bit when there are no free bits
                for (0..8) |offset_in_u8| {
                    if (u8_bitmap & (@as(u64, 1) << @intCast(offset_in_u8)) == 0) {
                        return @intCast(u8_offset * 8 + offset_in_u8);
                    }
                }
            }
        }

        return null;
    }
};

pub const Kind = enum {
    inode,
    data,
};

pub fn free(
    version: u16,
    id: u16,
    kind: Kind,
    superblock: *SuperBlock,
    storage: std.fs.File,
) !void {
    switch (version) {
        0 => try Version0.free(
            id,
            kind,
            superblock,
            storage,
        ),
        else => return error.UnsupportedVersion,
    }
}

pub fn allocate(
    version: u16,
    id: u16,
    kind: Kind,
    superblock: *SuperBlock,
    storage: std.fs.File,
) !void {
    switch (version) {
        0 => try Version0.allocate(
            id,
            kind,
            superblock,
            storage,
        ),
        else => return error.UnsupportedVersion,
    }
}

/// check if an inode id is allocated
pub fn check(
    version: u16,
    id: u16,
    kind: Kind,
    superblock: SuperBlock,
    storage: std.fs.File,
) !bool {
    return switch (version) {
        0 => try Version0.check(
            id,
            kind,
            superblock,
            storage,
        ),
        else => return error.UnsupportedVersion,
    };
}

pub fn nextFree(
    version: u16,
    kind: Kind,
    superblock: SuperBlock,
    storage: std.fs.File,
) !?u16 {
    return switch (version) {
        0 => try Version0.nextFree(
            kind,
            superblock,
            storage,
        ),
        else => return error.UnsupportedVersion,
    };
}
