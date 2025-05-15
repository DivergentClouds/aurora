const std = @import("std");

const Inode = @import("Inode.zig").Inode;
const SuperBlock = @import("SuperBlock.zig").SuperBlock;
const Block = @import("Block.zig");
const common = @import("common.zig");

pub const File = union(enum) {
    @"0": Version0,

    const Version0 = struct {
        inode: Inode,

        fn read(
            file: Version0,
            storage: std.fs.File,
            allocator: std.mem.Allocator,
        ) ![]const u8 {
            var contents: std.ArrayList(u8) = .init(allocator);
            errdefer contents.deinit();

            var indirect_contents: [common.block_size]u8 = @splat(0);
            var index_iterator = try file.inode.blockIndexIterator(
                &indirect_contents,
                storage,
            );

            const file_size_extra = file.inode.@"0".file_size_lower % common.block_size;

            while (index_iterator.next()) |block_index| {
                try storage.seekTo(block_index * common.block_size);

                const read_size = if (index_iterator.peek() == null)
                    file_size_extra
                else
                    common.block_size;

                try contents.ensureUnusedCapacity(read_size);
                try storage.reader().readAllArrayList(&contents, read_size);
            }

            return try contents.toOwnedSlice();
        }

        fn write(
            file: *Version0,
            contents: []const u8,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !void {
            if (contents.len > common.max_executable_size and
                file.inode.@"0".executable and
                file.inode.@"0".kind == .file)
            {
                return error.ExecutableFileTooLarge;
            }

            const file_len: u24 = (@as(u24, file.inode.@"0".file_size_upper) << 16) +
                file.inode.@"0".file_size_lower;

            const blocks_owned = file_len / common.block_size;
            const blocks_needed = contents.len / common.block_size;

            if (blocks_needed > superblock.@"0".unallocated_data) {
                return error.NotEnoughStorage;
            }

            if (blocks_needed > common.max_inode_data_blocks) {
                return error.ContentsTooLarge;
            }

            if (blocks_needed > blocks_owned) {
                for (0..blocks_needed - blocks_owned) |_| {
                    _ = try file.inode.extendData(superblock, storage);
                }
            }

            var indirect_contents: [common.block_size]u8 = undefined;
            var indirect_block = try Block.new(&indirect_contents);

            var index_iterator = try file.inode.blockIndexIterator(
                &indirect_contents,
                storage,
            );

            var index: usize = 0;
            while (index_iterator.next()) |block_index| {
                try storage.seekTo(block_index * common.block_size);

                const remaining = contents.len - index * common.block_size;
                const slice_end = if (remaining < common.block_size)
                    contents.len
                else
                    (index + 1) * common.block_size;

                try storage.writer().writeAll(contents[index * common.block_size .. slice_end]);

                index += 1;

                if (remaining <= common.block_size)
                    break; // last part of file is already written
            }

            if (index < 8) {
                file.inode.@"0".direct_block_indices[index] = 0;
            } else if (index == 8) {
                file.inode.@"0".indirect_block_index = 0;
            } else {
                indirect_contents[index - 8] = 0;
                try indirect_block.write(file.inode.@"0".indirect_block_index, storage);
            }

            file.inode.@"0".file_size_upper = @intCast(contents.len >> 16);
            file.inode.@"0".file_size_lower = @truncate(contents.len);

            try file.inode.write(superblock.*, storage);
        }
    };

    pub fn read(
        file: File,
        storage: std.fs.File,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        return switch (file) {
            inline else => |file_version| try file_version.read(
                storage,
                allocator,
            ),
        };
    }

    pub fn write(
        file: *File,
        contents: []const u8,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (file.*) {
            inline else => |*file_version| try file_version.write(
                contents,
                superblock,
                storage,
            ),
        }
    }

    pub fn inode(file: File) Inode {
        return switch (file) {
            inline else => |file_version| file_version.inode,
        };
    }
};
