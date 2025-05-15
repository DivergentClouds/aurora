const std = @import("std");

const common = @import("common.zig");

pub const SuperBlock = union(enum) {
    @"0": Version0,

    const Version0 = struct {
        /// must equal "AuroraFS"
        magic: [8]u8,
        version: u16,

        /// number of data blocks still unallocated
        unallocated_data: u16,
        /// total number of reserved inodes, must be in the range 0x1000-0xfffe
        total_inodes: u16,
        /// number of inodes still unallocated
        unallocated_inodes: u16,

        /// block ptr to start of used inode bitmap
        /// inode_bitmap must be INODE_BITMAP_LEN blocks long
        inode_bitmap_start: u16,
        /// ceil(INODE_BLOCK_COUNT / 8)
        inode_bitmap_len: u16,

        /// block ptr to start of used data block bitmap
        /// must be directly after end of inode_bitmap
        /// data_bitmap must be DATA_BITMAP_LEN blocks long
        data_bitmap_start: u16,
        /// ceil((TOTAL_BLOCKS - RESERVED_BLOCKS - inode_bitmap_len) / 8)
        data_bitmap_len: u16,

        /// INODE_BITMAP_LEN + DATA_BITMAP_LEN + RESERVED_BLOCKS
        first_inode_block: u16,
        /// first_inode_block + INODE_BLOCK_COUNT
        first_data_block: u16,

        fn read(
            magic: []const u8,
            storage: std.fs.File,
        ) !SuperBlock {
            const reader = storage.reader();

            var superblock: SuperBlock = .{
                .@"0" = .{
                    .magic = undefined,
                    .version = 0,

                    .unallocated_data = try reader.readInt(u16, .little),
                    .total_inodes = try reader.readInt(u16, .little),
                    .unallocated_inodes = try reader.readInt(u16, .little),

                    .inode_bitmap_start = try reader.readInt(u16, .little),
                    .inode_bitmap_len = try reader.readInt(u16, .little),

                    .data_bitmap_start = try reader.readInt(u16, .little),
                    .data_bitmap_len = try reader.readInt(u16, .little),

                    .first_inode_block = try reader.readInt(u16, .little),
                    .first_data_block = try reader.readInt(u16, .little),
                },
            };

            for (magic, &superblock.@"0".magic) |src, *dest| {
                dest.* = src;
            }

            return superblock;
        }

        fn write(superblock: Version0, storage: std.fs.File) !void {
            const writer = storage.writer();

            try storage.seekTo(common.superblock_address);

            try writer.writeAll(&superblock.magic);
            try writer.writeInt(u16, superblock.version, .little);
            try writer.writeInt(u16, superblock.unallocated_data, .little);
            try writer.writeInt(u16, superblock.total_inodes, .little);
            try writer.writeInt(u16, superblock.unallocated_inodes, .little);
            try writer.writeInt(u16, superblock.inode_bitmap_start, .little);
            try writer.writeInt(u16, superblock.inode_bitmap_len, .little);
            try writer.writeInt(u16, superblock.data_bitmap_start, .little);
            try writer.writeInt(u16, superblock.data_bitmap_len, .little);
            try writer.writeInt(u16, superblock.first_inode_block, .little);
            try writer.writeInt(u16, superblock.first_data_block, .little);
        }
    };

    pub fn read(storage: std.fs.File) !SuperBlock {
        const reader = storage.reader();

        try storage.seekTo(common.superblock_address);

        var magic: [8]u8 = undefined;
        _ = try reader.readAll(&magic);

        const superblock_version = try reader.readInt(u16, .little);

        return switch (superblock_version) {
            0 => try Version0.read(&magic, storage),
            else => error.UnsupportedVersion,
        };
    }

    pub fn write(superblock: SuperBlock, storage: std.fs.File) !void {
        switch (superblock) {
            inline else => |superblock_version| try superblock_version.write(storage),
        }
    }

    pub fn verify(superblock: SuperBlock) !void {
        const magic = "AuroraFS";

        switch (superblock) {
            inline else => |superblock_version| {
                if (!std.mem.eql(u8, superblock_version.magic, magic))
                    return error.InvalidSuperblock;
            },
        }
    }

    pub fn version(superblock: SuperBlock) u16 {
        switch (superblock) {
            .@"0" => return 0,
        }
    }
};
