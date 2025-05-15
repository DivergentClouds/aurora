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
        if (try Version0.check(id, kind, superblock.*, storage)) {
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

        const offset = id - switch (kind) {
            .inode => superblock.@"0".first_inode_block,
            .data => superblock.@"0".first_data_block,
        };

        const bitmap_byte_address: u32 = bitmap_base_index * common.block_size + offset / 8;

        if (bitmap_byte_address >= bitmap_block_len * common.block_size)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(offset % 8);

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

        const offset = id - switch (kind) {
            .inode => superblock.@"0".first_inode_block,
            .data => superblock.@"0".first_data_block,
        };

        const bitmap_byte_address: u32 = bitmap_base_index * common.block_size + offset / 8;

        if (bitmap_byte_address >= bitmap_block_len * common.block_size)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(offset % 8);

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

    fn check(
        id: u16,
        kind: Kind,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !bool {
        const bitmap_base_index = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        const bitmap_block_len = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const offset = id - switch (kind) {
            .inode => superblock.@"0".first_inode_block,
            .data => superblock.@"0".first_data_block,
        };

        const bitmap_byte_address: u32 = bitmap_base_index * common.block_size + offset / 8;

        if (bitmap_byte_address >= bitmap_block_len * common.block_size)
            return error.OutOfRange;

        const bitmap_bit_offset: u3 = @intCast(offset % 8);

        try storage.seekTo(bitmap_byte_address);
        const bitmap_byte = try storage.reader().readByte();

        return bitmap_byte & (@as(u8, 1) << bitmap_bit_offset) != 0;
    }

    fn nextFree(
        kind: Kind,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !?u16 {
        const bitmap_base_index = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_start,
            .data => superblock.@"0".data_bitmap_start,
        };

        const bitmap_block_len = switch (kind) {
            .inode => superblock.@"0".inode_bitmap_len,
            .data => superblock.@"0".data_bitmap_len,
        };

        const reader = storage.reader();

        try storage.seekTo(bitmap_base_index * common.block_size);
        for (0..bitmap_block_len * common.block_size / 8) |u64_offset| {
            const u64_bitmap = try reader.readInt(u64, .big);

            if (u64_bitmap != std.math.maxInt(u64)) {
                for (0..64) |offset_in_u64| {
                    if (u64_bitmap & (@as(u8, 1) << @intCast(offset_in_u64)) != 0) {
                        return @intCast(u64_offset * 64 + offset_in_u64 + switch (kind) {
                            .inode => superblock.@"0".first_inode_block,
                            .data => superblock.@"0".first_data_block,
                        });
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
