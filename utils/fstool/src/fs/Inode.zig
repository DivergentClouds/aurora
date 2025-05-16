const std = @import("std");

const SuperBlock = @import("SuperBlock.zig").SuperBlock;
const Block = @import("Block.zig");
const bitmap = @import("bitmap.zig");
const common = @import("common.zig");

pub const Inode = union(enum) {
    @"0": Version0,

    pub const Id = u16;

    const Version0 = struct {
        valid: bool,
        kind: Version0.Kind,
        readable: bool,
        writeable: bool,
        executable: bool, // for a directory, this means it can be entered

        hard_link_count: u16, // number of hard links associated with this inode, on 0, free

        // if a regular file is executable, it has a maximum file size of 0x8000
        // ignored for directories
        file_size_upper: u8, // upper 8 bits of file size in bytes
        file_size_lower: u16, // lower 16 bits of file size in bytes

        // if a null block index exists, all subsequent block index entries are invalid
        direct_block_indices: [8]u16, // points to a data block, 0 if no block is associated
        indirect_block_index: u16, // points to a block of direct block indices, 0 if no block is associated

        id: Id, // not written to storage

        const Kind = enum(u3) {
            directory,
            file,
            symlink,
            _,
        };

        const inode_size = 32;
        const inodes_per_block = common.block_size / inode_size;

        fn read(
            inode_id: Id,
            superblock: SuperBlock,
            storage: std.fs.File,
        ) !Inode {
            const reader = storage.reader();

            try storage.seekTo(Version0.idToAddress(inode_id, superblock));

            var inode: Inode = .{ .@"0" = undefined };

            const flags = try reader.readByte();
            inode.@"0".valid = @as(u1, @intCast(flags >> 7)) == 1;
            inode.@"0".kind = @enumFromInt(@as(u3, @truncate(flags >> 4)));
            inode.@"0".readable = @as(u1, @truncate(flags >> 2)) == 1;
            inode.@"0".writeable = @as(u1, @truncate(flags >> 1)) == 1;
            inode.@"0".executable = @as(u1, @truncate(flags)) == 1;

            inode.@"0".hard_link_count = try reader.readInt(u16, .little);

            inode.@"0".file_size_upper = try reader.readByte();
            inode.@"0".file_size_lower = try reader.readInt(u16, .little);

            for (0..8) |i| {
                inode.@"0".direct_block_indices[i] = try reader.readInt(u16, .little);
            }
            inode.@"0".indirect_block_index = try reader.readInt(u16, .little);

            inode.@"0".id = inode_id;

            return inode;
        }

        fn write(
            inode: Version0,
            superblock: SuperBlock,
            storage: std.fs.File,
        ) !void {
            const inode_address = Version0.idToAddress(inode.id, superblock);

            const writer = storage.writer();

            try storage.seekTo(inode_address);

            const flags: u8 = @as(u8, @intFromBool(inode.valid)) << 7 |
                @as(u8, @intFromEnum(inode.kind)) << 4 |
                @as(u8, @intFromBool(inode.readable)) << 2 |
                @as(u8, @intFromBool(inode.writeable)) << 1 |
                @intFromBool(inode.executable);

            try writer.writeByte(flags);
            try writer.writeInt(u16, inode.hard_link_count, .little);

            try writer.writeByte(inode.file_size_upper);
            try writer.writeInt(u16, inode.file_size_lower, .little);

            for (0..8) |i| {
                try writer.writeInt(u16, inode.direct_block_indices[i], .little);
            }

            try writer.writeInt(u16, inode.indirect_block_index, .little);
        }

        fn idToAddress(
            inode_id: Id,
            superblock: SuperBlock,
        ) u27 {
            const block_offset = inode_id / inodes_per_block;
            const block_index = superblock.@"0".first_inode_block + block_offset;
            const offset_in_block = (inode_id % inodes_per_block) * inode_size;

            return block_index * common.block_size + offset_in_block;
        }

        fn addressToId(
            block_address: u27,
            superblock: SuperBlock,
        ) u16 {
            const offset_in_block = block_address % common.block_size;
            const block_index = block_address / common.block_size;
            const block_offset = block_index - superblock.@"0".first_inode_block;

            return @intCast(block_offset * inodes_per_block + offset_in_block / inode_size);
        }

        fn free(
            inode: Version0,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !void {
            try bitmap.free(0, inode.id, .inode, superblock, storage);

            var indirect_block_contents: [common.block_size]u8 = undefined;

            // reconstruct Inode from Version0 to access blockIndexIterator
            var index_iterator = try (Inode{ .@"0" = inode }).blockIndexIterator(&indirect_block_contents, storage);

            var index_number: usize = 0;
            while (index_iterator.next()) |block_index| {
                index_number += 1;

                try bitmap.free(0, block_index, .data, superblock, storage);
            }

            if (index_number > 8) {
                index_number += 1;

                try bitmap.free(0, inode.indirect_block_index, .data, superblock, storage);
            }

            superblock.@"0".unallocated_inodes += 1;
            superblock.@"0".unallocated_data += @intCast(index_number);

            try superblock.write(storage);

            var copied_inode = inode;
            copied_inode.valid = false;
            try copied_inode.write(superblock.*, storage);
        }

        /// adds a new block to a directory for entries
        /// returns index of new block
        fn extendData(
            inode: *Version0,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !u16 {
            const file_len: u24 = (@as(u24, inode.file_size_upper) << 16) +
                inode.file_size_lower;

            if (file_len +| common.block_size > common.max_executable_size) {
                return error.ExecutableFileTooLarge;
            }

            var free_block_index = try bitmap.nextFree(0, .data, superblock.*, storage) orelse
                return error.NoFreeDataBlocks;

            var contents: [common.block_size]u8 = @splat(0);
            var indirect_indices: [common.block_size]u8 = undefined;

            for (inode.direct_block_indices, 0..) |direct_index, index_number| {
                if (direct_index == 0) {
                    try bitmap.allocate(0, free_block_index, .data, superblock, storage);

                    const block = try Block.new(&contents);
                    try block.write(free_block_index, storage);

                    inode.direct_block_indices[index_number] = free_block_index;
                    try inode.write(superblock.*, storage);

                    return free_block_index;
                }
            }

            if (inode.indirect_block_index == 0) {
                try bitmap.allocate(0, free_block_index, .data, superblock, storage);

                inode.indirect_block_index = free_block_index;
                try inode.write(superblock.*, storage);

                const block = try Block.new(&contents);
                try block.write(free_block_index, storage);

                free_block_index = try bitmap.nextFree(0, .data, superblock.*, storage) orelse
                    return error.NoFreeDataBlocks;
            }

            var indirect_block = try Block.read(&indirect_indices, inode.indirect_block_index, storage);

            var i: usize = 0;
            while (i < common.block_size) : (i += 2) {
                const direct_index: u16 = std.mem.readInt(u16, indirect_indices[i .. i + 2][0..2], .little);

                if (direct_index == 0) {
                    try bitmap.allocate(0, free_block_index, .data, superblock, storage);

                    const block = try Block.new(&contents);
                    try block.write(free_block_index, storage);

                    std.mem.writeInt(u16, indirect_block.contents[i .. i + 2][0..2], free_block_index, .little);
                    try indirect_block.write(inode.indirect_block_index, storage);

                    return free_block_index;
                }
            }

            return error.NoFreeBlocksInInode;
        }

        fn getPermissions(inode: Version0) Permissions {
            return .{
                .readable = inode.readable,
                .writable = inode.writeable,
                .executable = inode.executable,
            };
        }

        fn setPermissions(inode: *Version0, permissions: Permissions) void {
            inode.readable = permissions.readable orelse inode.readable;
            inode.writeable = permissions.readable orelse inode.writeable;
            inode.executable = permissions.readable orelse inode.executable;
        }

        fn fileSize(inode: Version0) u24 {
            return (@as(u24, inode.file_size_upper) << 16) |
                inode.file_size_lower;
        }

        pub fn format(
            inode: Version0,
            _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print(
                \\inode id: {x:0>4}
                \\kind: {s}
                \\permissions: {}
                \\hard link count: {d}
            ,
                .{
                    inode.id,
                    @tagName(inode.kind),
                    inode.getPermissions(),
                    inode.hard_link_count,
                },
            );

            if (inode.kind == .file) {
                try writer.print(
                    \\file size: {x:0>6}
                ,
                    .{
                        inode.fileSize(),
                    },
                );
            }
        }
    };

    pub const Permissions = struct {
        readable: ?bool = null,
        writable: ?bool = null,
        executable: ?bool = null,

        pub fn format(
            permissions: Permissions,
            _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print(
                "{c}{c}{c}",
                .{
                    if (permissions.readable orelse false)
                        'r'
                    else
                        '-',

                    if (permissions.writable orelse false)
                        'w'
                    else
                        '-',

                    if (permissions.executable orelse false)
                        'x'
                    else
                        '-',
                },
            );
        }
    };

    pub fn read(
        version: u16,
        inode_id: Id,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !Inode {
        return switch (version) {
            0 => try Inode.Version0.read(inode_id, superblock, storage),
            else => error.UnsupportedVersion,
        };
    }

    pub fn write(
        inode: Inode,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (inode) {
            inline else => |inode_version| try inode_version.write(
                superblock,
                storage,
            ),
        }
    }

    pub fn blockIndexIterator(
        inode: Inode,
        indirect_block_contents: *[common.block_size]u8,
        storage: std.fs.File,
    ) !BlockIndexIterator {
        return switch (inode) {
            // can't be `inline else` because `Inode.Version0` is different from `BlockIndexIterator.Version0`
            // maybe an explicit tag type would allow use of `inline else`?
            .@"0" => |inode_version| try BlockIndexIterator.Version0.init(
                inode_version,
                indirect_block_contents,
                storage,
            ),
        };
    }

    pub fn idToAddress(inode_id: Id, superblock: SuperBlock) !u27 {
        return switch (superblock.version()) {
            0 => Version0.idToAddress(inode_id, superblock),
            else => return error.UnsupportedVersion,
        };
    }

    pub fn addressToId(block_address: u27, superblock: SuperBlock) !u16 {
        return switch (superblock.version()) {
            0 => Version0.addressToId(block_address, superblock),
            else => return error.UnsupportedVersion,
        };
    }

    pub fn free(
        inode: Inode,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (inode) {
            inline else => |inode_version| try inode_version.free(
                superblock,
                storage,
            ),
        }
    }
    /// adds a new data block to an inode
    /// returns index of new block
    pub fn extendData(
        inode: *Inode,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !u16 {
        return switch (inode.*) {
            inline else => |*inode_version| try inode_version.extendData(
                superblock,
                storage,
            ),
        };
    }

    pub fn getPermissions(inode: Inode) Permissions {
        return switch (inode) {
            inline else => |inode_version| inode_version.getPermissions(),
        };
    }

    pub fn setPermissions(inode: *Inode, permissions: Permissions) void {
        return switch (inode.*) {
            inline else => |*inode_version| inode_version.setPermissions(
                permissions,
            ),
        };
    }

    pub fn id(inode: Inode) u16 {
        return switch (inode) {
            inline else => |inode_version| inode_version.id,
        };
    }

    pub fn address(inode: Inode) u27 {
        return switch (inode) {
            .@"0" => idToAddress(0, inode.id()) catch |err| switch (err) {
                error.UnsupportedVersion => unreachable,
            },
        };
    }

    pub fn Kind(inode: Inode) type {
        return switch (inode) {
            inline else => |inode_version| inode_version.Kind,
        };
    }

    pub fn kind(inode: Inode) Kind(inode) {
        return switch (inode) {
            inline else => |inode_version| inode_version.kind,
        };
    }
    pub fn format(
        inode: Inode,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (inode) {
            inline else => |inode_version| try writer.print(
                "{}",
                .{inode_version},
            ),
        }
    }

    pub const BlockIndexIterator = union(enum) {
        @"0": BlockIndexIterator.Version0,

        const Version0 = struct {
            inode: Inode.Version0,
            index: usize,

            /// null if inode.indirect_block_index == 0
            indirect_block: ?Block,

            fn init(
                inode: Inode.Version0,
                indirect_block_contents: *[common.block_size]u8,
                storage: std.fs.File,
            ) !BlockIndexIterator {
                const indirect_exists = inode.indirect_block_index != 0;

                const indirect_block = if (indirect_exists)
                    try Block.read(
                        indirect_block_contents,
                        inode.indirect_block_index,
                        storage,
                    )
                else
                    null;

                return .{
                    .@"0" = BlockIndexIterator.Version0{
                        .inode = inode,
                        .index = 0,
                        .indirect_block = indirect_block,
                    },
                };
            }

            fn next(iterator: *BlockIndexIterator.Version0) ?u16 {
                const peeked = iterator.peek();

                if (peeked != null) {
                    iterator.index += 1;
                }

                return peeked;
            }

            fn peek(iterator: *BlockIndexIterator.Version0) ?u16 {
                if (iterator.index < 8) {
                    const value = iterator.inode.direct_block_indices[iterator.index];

                    if (value == 0) return null;

                    return value;
                } else {
                    const indirect_block = iterator.indirect_block orelse
                        return null;

                    const adjusted_index = (iterator.index - 8) * 2;

                    const value = std.mem.readInt(
                        u16,
                        indirect_block.contents[adjusted_index .. adjusted_index + 2][0..2],
                        .little,
                    );

                    if (value == 0) return null;

                    return value;
                }
            }

            fn reset(iterator: *BlockIndexIterator.Version0) void {
                iterator.index = 0;
            }

            fn seekBy(iterator: *BlockIndexIterator.Version0, count: isize) bool {
                if (count < 0) {
                    iterator.index -|= @as(usize, @bitCast(count));
                } else {
                    for (0..@intCast(count)) |i| {
                        if (i > common.max_inode_data_blocks)
                            return false;

                        if (iterator.next() == null)
                            return false;
                    }
                }

                if (iterator.peek()) |_| {
                    return true;
                } else {
                    return false;
                }
            }

            fn seekTo(iterator: *BlockIndexIterator.Version0, index: usize) bool {
                iterator.reset();

                // 0xffff is more blocks than can be allocated anyways
                if (index > common.max_inode_data_blocks) {
                    _ = iterator.seekBy(common.max_inode_data_blocks + 1); // seek to end
                    return false;
                }

                return iterator.seekBy(@intCast(index)); // in range, as per above if statement
            }
        };

        pub fn next(iterator: *BlockIndexIterator) ?u16 {
            switch (iterator.*) {
                inline else => |*iterator_version| {
                    return iterator_version.next();
                },
            }
        }

        pub fn peek(iterator: *BlockIndexIterator) ?u16 {
            switch (iterator.*) {
                inline else => |*iterator_version| {
                    return iterator_version.peek();
                },
            }
        }

        pub fn reset(iterator: *BlockIndexIterator) void {
            switch (iterator.*) {
                inline else => |*iterator_version| {
                    return iterator_version.reset();
                },
            }
        }

        // returns false if no items left, true otherwise
        pub fn seekBy(iterator: *BlockIndexIterator, count: isize) bool {
            switch (iterator.*) {
                inline else => |*iterator_version| {
                    return iterator_version.seekBy(count);
                },
            }
        }
        // returns false if no items left, true otherwise
        pub fn seekTo(iterator: *BlockIndexIterator, index: usize) bool {
            switch (iterator.*) {
                inline else => |*iterator_version| {
                    return iterator_version.seekTo(index);
                },
            }
        }
    };
};
