const std = @import("std");

const SuperBlock = @import("SuperBlock.zig").SuperBlock;
const Inode = @import("Inode.zig").Inode;
const File = @import("File.zig").File;
const Block = @import("Block.zig");
const common = @import("common.zig");
const bitmap = @import("bitmap.zig");

pub const Dir = union(enum) {
    @"0": Version0,

    const Version0 = struct {
        inode: Inode,

        fn nextFreeEntryAddress(
            dir: Version0,
            storage: std.fs.File,
        ) !?u27 {
            const dir_inode_version = dir.inode.@"0";

            var entries: [common.block_size]u8 = undefined;

            var indirect_indices: [common.block_size]u8 = undefined;

            for (dir_inode_version.direct_block_indices) |direct_index| {
                if (direct_index == 0) {
                    return null;
                }

                _ = try Block.read(&entries, direct_index, storage);

                for (0..Entry.Version0.entries_per_block) |entry_id| {
                    const entry = try Entry.init(
                        0,
                        entries[entry_id * Entry.Version0.entry_size .. (entry_id + 1) * Entry.Version0.entry_size],
                    );

                    if (entry.@"0".inode_id == 0xffff) {
                        return @intCast(direct_index + entry_id * Entry.Version0.entry_size);
                    }
                }
            }

            if (dir_inode_version.indirect_block_index == 0) {
                return null;
            }

            _ = try Block.read(&indirect_indices, dir_inode_version.indirect_block_index, storage);

            var i: usize = 0;
            while (i < common.block_size) : (i += 2) {
                const direct_index: u16 = std.mem.readInt(u16, indirect_indices[i .. i + 2][0..2], .little);

                if (direct_index == 0) {
                    return null;
                }

                _ = try Block.read(&entries, direct_index, storage);

                for (0..Entry.Version0.entries_per_block) |entry_id| {
                    const entry = try Entry.init(
                        0,
                        entries[entry_id * Entry.Version0.entry_size .. (entry_id + 1) * Entry.Version0.entry_size],
                    );

                    if (entry.@"0".inode_id == 0xffff) {
                        return @intCast(direct_index + entry_id * Entry.Version0.entry_size);
                    }
                }
            }

            return null;
        }

        fn findEntryAddress(
            dir: Version0,
            name: [:0]const u8,
            storage: std.fs.File,
        ) !?u27 {
            if (name.len >= Entry.Version0.name_len) {
                return error.NameTooLong;
            }

            const dir_inode_version = dir.inode.@"0";

            var entries: [common.block_size]u8 = undefined;

            var indirect_indices: [common.block_size]u8 = undefined;

            for (dir_inode_version.direct_block_indices) |direct_index| {
                if (direct_index == 0) {
                    return null;
                }

                _ = try Block.read(&entries, direct_index, storage);

                for (0..Entry.Version0.entries_per_block) |entry_id| {
                    const entry = try Entry.init(
                        0,
                        entries[entry_id * Entry.Version0.entry_size .. (entry_id + 1) * Entry.Version0.entry_size],
                    );

                    if (entry.@"0".inode_id == 0xffff) {
                        return null;
                    }

                    if (entry.eql(name)) {
                        return @intCast(direct_index + entry_id * Entry.Version0.entry_size);
                    }
                }
            }

            if (dir_inode_version.indirect_block_index == 0) {
                return null;
            }

            _ = try Block.read(&indirect_indices, dir_inode_version.indirect_block_index, storage);

            var i: usize = 0;
            while (i < common.block_size) : (i += 2) {
                const direct_index: u16 = std.mem.readInt(u16, indirect_indices[i .. i + 2][0..2], .little);

                if (direct_index == 0) {
                    return null;
                }

                _ = try Block.read(&entries, direct_index, storage);

                for (0..Entry.Version0.entries_per_block) |entry_id| {
                    const entry = try Entry.init(
                        0,
                        entries[entry_id * Entry.Version0.entry_size .. (entry_id + 1) * Entry.Version0.entry_size],
                    );

                    if (entry.@"0".inode_id == 0xffff) {
                        return null;
                    }

                    if (entry.eql(name)) {
                        return @intCast(direct_index + entry_id * Entry.Version0.entry_size);
                    }
                }
            }

            return null;
        }

        fn inodeIdFromEntryAddress(
            storage: std.fs.File,
            entry_address: u27,
        ) !u16 {
            var entry_contents: [Entry.Version0.entry_size]u8 = undefined;
            const entry = try Entry.read(0, &entry_contents, storage, entry_address);

            return entry.@"0".inode_id;
        }

        fn findId(
            dir: Version0,
            name: [:0]const u8,
            storage: std.fs.File,
        ) !?u16 {
            const entry_address = try dir.findEntryAddress(
                name,
                storage,
            ) orelse return null;

            return try inodeIdFromEntryAddress(storage, entry_address);
        }

        fn find(
            dir: Version0,
            name: [:0]const u8,
            superblock: SuperBlock,
            storage: std.fs.File,
        ) !?Inode {
            const id = try dir.findId(
                name,
                storage,
            ) orelse return null;

            return try Inode.read(
                0, // version
                id,
                superblock,
                storage,
            );
        }

        fn deleteFile(
            dir: Version0,
            name: [:0]const u8,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !void {
            const entry_address = try dir.findEntryAddress(
                name,
                storage,
            ) orelse return error.FileNotFound;

            var entry_contents: [Entry.Version0.entry_size]u8 = undefined;
            var entry = try Entry.read(0, &entry_contents, storage, entry_address);

            var file_inode = try Inode.read(
                0, // version
                entry.@"0".inode_id,
                superblock.*,
                storage,
            );

            if (file_inode.@"0".kind != .file) {
                return error.NotAfFile;
            }

            entry.@"0".name[0] = 0;
            try entry.write(storage, entry_address);

            if (file_inode.@"0".hard_link_count > 1) {
                file_inode.@"0".hard_link_count -= 1;

                try file_inode.write(superblock.*, storage);
            } else {
                try file_inode.free(superblock, storage);
            }
        }

        fn deleteDir(
            dir: Version0,
            name: [:0]const u8,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !void {
            var child_dir = try Dir.openDir(.{ .@"0" = dir }, name, superblock.*, storage) orelse
                error.DirectoryNotFound;

            if (!try child_dir.isEmpty(storage))
                return error.DirectoryNotEmpty;

            const entry_address = try dir.findEntryAddress(
                name,
                storage,
            ) orelse unreachable; // we already made sure the directory exists

            var entry_contents: [Entry.Version0.entry_size]u8 = undefined;
            var entry = try Entry.read(0, &entry_contents, storage, entry_address);

            var dir_inode = try Inode.read(
                0, // version
                entry.@"0".inode_id,
                superblock.*,
                storage,
            );

            entry.@"0".name[0] = 0;
            try entry.write(storage, entry_address);

            if (dir_inode.@"0".hard_link_count > 1) {
                dir_inode.@"0".hard_link_count -= 1;

                try dir_inode.write(superblock.*, storage);
            } else {
                try dir_inode.free(superblock, storage);
            }
        }

        fn createHardLink(
            dir: *Version0,
            name: [:0]const u8,
            inode_to_link: *Inode,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !void {
            if (try dir.findEntryAddress(name, storage) != null) {
                return error.FileAlreadyExists;
            }

            if (name.len > Entry.Version0.name_len) {
                return error.NameTooLong;
            }

            if (std.mem.indexOfScalar(u8, name, '/') != null or
                std.mem.indexOfScalar(u8, name, ':') != null)
            {
                return error.InvalidName;
            }

            if (inode_to_link.@"0".hard_link_count == 0xffff) {
                return error.TooManyHardLinksToInode;
            }

            var name_memory: [126]u8 = @splat(0);
            @memcpy(name_memory[0..name.len], name);

            const next_address = try dir.nextFreeEntryAddress(storage) orelse
                try dir.inode.extendData(superblock, storage) * common.block_size;

            inode_to_link.@"0".hard_link_count += 1;

            const entry: Entry = .{
                .@"0" = .{
                    .inode_id = inode_to_link.@"0".id,
                    .name = &name_memory,
                },
            };

            try entry.write(storage, next_address);
        }

        fn createFile(
            dir: *Version0,
            name: [:0]const u8,
            permissions: Inode.Permissions,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !File {
            if (try dir.findEntryAddress(name, storage) != null) {
                return error.FileAlreadyExists;
            }

            const inode_id = try bitmap.nextFree(0, .inode, superblock.*, storage) orelse
                return error.NoFreeInodes;

            var file_inode: Inode = .{
                .@"0" = .{
                    .valid = true,
                    .kind = .file,
                    .readable = permissions.readable orelse true,
                    .writeable = permissions.writable orelse true,
                    .executable = permissions.executable orelse false,
                    .hard_link_count = 0, // incremented in createHardLink
                    .file_size_upper = 0,
                    .file_size_lower = 0,
                    .direct_block_indices = @splat(0),
                    .indirect_block_index = 0,

                    .id = inode_id,
                },
            };

            try dir.createHardLink(
                name,
                &file_inode,
                superblock,
                storage,
            );

            try file_inode.write(
                superblock.*,
                storage,
            );

            return .{ .@"0" = .{ .inode = file_inode } };
        }

        fn createDir(
            dir: *Version0,
            name: [:0]const u8,
            permissions: Inode.Permissions,
            superblock: *SuperBlock,
            storage: std.fs.File,
        ) !Dir {
            if (try dir.findEntryAddress(name, storage) != null) {
                return error.FileAlreadyExists;
            }

            const inode_id = try bitmap.nextFree(0, .inode, superblock.*, storage) orelse
                return error.NoFreeInodes;

            var dir_inode: Inode = .{
                .@"0" = .{
                    .valid = true,
                    .kind = .directory,
                    .readable = permissions.readable orelse true,
                    .writeable = permissions.writable orelse true,
                    .executable = permissions.executable orelse true,
                    .hard_link_count = 0, // incremented in createHardLink
                    .file_size_upper = 0,
                    .file_size_lower = 0,
                    .direct_block_indices = @splat(0),
                    .indirect_block_index = 0,

                    .id = inode_id,
                },
            };

            try dir.createHardLink(
                name,
                &dir_inode,
                superblock,
                storage,
            );

            var sub_dir: Dir = .{
                .@"0" = .{ .inode = dir_inode },
            };

            try sub_dir.@"0".createHardLink(".", &dir_inode, superblock, storage);
            try sub_dir.@"0".createHardLink("..", &dir_inode, superblock, storage);

            try dir_inode.write(
                superblock.*,
                storage,
            );

            return .{ .@"0" = .{ .inode = dir_inode } };
        }

        fn isEmpty(dir: Version0, storage: std.fs.File) bool {
            var entry_block_buffer: [common.block_size]u8 = undefined;
            var indirect_block_buffer: [common.block_size]u8 = undefined;

            var dir_iterator = try dir.entryIterator(&entry_block_buffer, &indirect_block_buffer, storage);

            while (try dir_iterator.next()) |entry| {
                if (!entry.eql("..") and !entry.eql("."))
                    return false;
            }

            return true;
        }
    };

    /// Open a subdirectory from a directory.
    /// To open a directory by path see `openDirPath`.
    /// returns null if nothing of that name exists in `dir`.
    pub fn openDir(
        dir: Dir,
        name: [:0]const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !?Dir {
        switch (dir) {
            inline else => |dir_version| {
                const found_inode: Inode = try dir_version.find(
                    name,
                    superblock,
                    storage,
                ) orelse return null;

                switch (found_inode) {
                    inline else => |inode_version| {
                        if (inode_version.kind != .directory)
                            return error.NotADirectory;
                    },
                }

                return @unionInit(
                    Dir,
                    @tagName(dir),
                    .{ .inode = found_inode },
                );
            },
        }
    }

    /// Open a file from a directory.
    /// returns null if nothing of that name exists in `dir`.
    pub fn openFile(
        dir: Dir,
        name: [:0]const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !?File {
        switch (dir) {
            inline else => |dir_version| {
                const found_inode: Inode = try dir_version.find(
                    name,
                    superblock,
                    storage,
                ) orelse return null;

                switch (found_inode) {
                    inline else => |inode_version| {
                        // TODO: handle symlinks
                        if (inode_version.kind != .file)
                            return error.NotAFile;
                    },
                }

                return switch (superblock.version()) {
                    0 => File{ .@"0" = .{ .inode = found_inode } },
                    else => return error.UnsupportedVersion,
                };
            },
        }
    }

    /// Open an inode from a directory.
    /// To open an inode by path see `openInodePath`.
    /// returns null if nothing of that name exists in `dir`.
    pub fn openInode(
        dir: Dir,
        name: [:0]const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !?Inode {
        switch (dir) {
            inline else => |dir_version| {
                return try dir_version.find(
                    name,
                    superblock,
                    storage,
                );
            },
        }
    }

    /// Open the directory at the given path, starting from `dir`.
    pub fn openDirPath(
        dir: Dir,
        path: []const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
        allocator: std.mem.Allocator,
    ) !Dir {
        var current_dir = dir;

        var path_iterator = std.mem.tokenizeScalar(u8, path, '/');
        while (path_iterator.next()) |subpath| {
            const subpath_z = try allocator.dupeZ(u8, subpath);
            defer allocator.free(subpath_z);

            current_dir = try current_dir.openDir(subpath_z, superblock, storage) orelse
                return error.DirectoryNotFound;
        }

        return current_dir;
    }

    /// Open the file at the given path, starting from `dir`.
    pub fn openFilePath(
        dir: Dir,
        path: []const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
        allocator: std.mem.Allocator,
    ) !File {
        const filename_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;

        const dir_path = path[0..filename_index];
        const filename = path[filename_index..];

        const parent_dir = try dir.openDirPath(
            dir_path,
            superblock,
            storage,
            allocator,
        );

        const filename_z = try allocator.dupeZ(u8, filename);
        defer allocator.free(filename_z);

        return try parent_dir.openFile(
            filename_z,
            superblock,
            storage,
        ) orelse return error.FileNotFound;
    }

    /// Open the file at the given path, starting from `dir`.
    pub fn openInodePath(
        dir: Dir,
        path: []const u8,
        superblock: SuperBlock,
        storage: std.fs.File,
        allocator: std.mem.Allocator,
    ) !Inode {
        const end_index = if (path[path.len - 1] == '/')
            path.len - 1
        else
            path.len;

        const parent_dir_path_index = std.mem.lastIndexOfScalar(u8, path[0..end_index], '/') orelse 0;

        const parent_dir_path = path[0..parent_dir_path_index];
        const name = path[parent_dir_path_index..];

        const name_z = allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        var parent_dir = try dir.openDirPath(parent_dir_path, superblock, storage, allocator);
        return try parent_dir.openInode(name_z, superblock, storage) orelse
            return error.InodeNotFound;
    }

    // Open the root directory
    pub fn root(
        superblock: SuperBlock,
        storage: std.fs.File,
    ) !Dir {
        const version = superblock.version();
        switch (version) {
            0 => return Dir{
                .@"0" = .{
                    .inode = try Inode.read(
                        version,
                        0,
                        superblock,
                        storage,
                    ),
                },
            },
            else => return error.UnsupportedVersion,
        }
    }

    pub fn deleteFile(
        dir: Dir,
        name: [:0]const u8,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (dir) {
            inline else => |dir_version| {
                try dir_version.deleteFile(name, superblock, storage);
            },
        }
    }

    /// directory must be empty
    pub fn deleteDir(
        dir: Dir,
        name: [:0]const u8,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (dir) {
            inline else => |dir_version| {
                try dir_version.deleteDir(name, superblock, storage);
            },
        }
    }

    pub fn createHardLink(
        dir: *Dir,
        name: [:0]const u8,
        inode_to_link: *Inode,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !void {
        switch (dir.*) {
            inline else => |*dir_version| try dir_version.createHardLink(
                name,
                inode_to_link,
                superblock,
                storage,
            ),
        }
    }

    pub fn createFile(
        dir: *Dir,
        name: [:0]const u8,
        permissions: Inode.Permissions,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !File {
        switch (dir.*) {
            inline else => |*dir_version| {
                return try dir_version.createFile(
                    name,
                    permissions,
                    superblock,
                    storage,
                );
            },
        }
    }

    pub fn createDir(
        dir: *Dir,
        name: [:0]const u8,
        permissions: Inode.Permissions,
        superblock: *SuperBlock,
        storage: std.fs.File,
    ) !Dir {
        switch (dir.*) {
            inline else => |*dir_version| {
                return try dir_version.createDir(
                    name,
                    permissions,
                    superblock,
                    storage,
                );
            },
        }
    }

    pub fn inode(dir: Dir) Inode {
        return switch (dir) {
            inline else => |dir_version| dir_version.inode,
        };
    }

    pub fn entryIterator(
        dir: Dir,
        entry_block_buffer: *[common.block_size]u8,
        indirect_block_buffer: *[common.block_size]u8,
        storage: std.fs.File,
    ) !EntryIterator {
        return switch (dir) {
            .@"0" => |dir_version| try EntryIterator.Version0.init(
                dir_version,
                entry_block_buffer,
                indirect_block_buffer,
                storage,
            ),
        };
    }

    pub const EntryIterator = union(enum) {
        @"0": EntryIterator.Version0,

        const Version0 = struct {
            dir: Dir.Version0,
            index: usize,
            entries_block: ?Block,
            entry_index_in_block: std.math.IntFittingRange(0, Entry.Version0.entries_per_block - 1),
            block_index_iterator: Inode.BlockIndexIterator,
            storage: std.fs.File,

            fn init(
                dir: Dir.Version0,
                entry_block_buffer: *[common.block_size]u8,
                indirect_block_buffer: *[common.block_size]u8,
                storage: std.fs.File,
            ) !EntryIterator {
                const first_entry_block_index = dir.inode.@"0".direct_block_indices[0];
                const entries_block: ?Block = if (first_entry_block_index == 0)
                    null
                else
                    try Block.read(
                        entry_block_buffer,
                        first_entry_block_index.direct_block_indices[0],
                        storage,
                    );

                return .{
                    .@"0" = EntryIterator.Version0{
                        .dir = dir,
                        .index = 0,
                        .entries_block = entries_block,
                        .entry_index_in_block = 0,
                        .block_index_iterator = try dir.inode.blockIndexIterator(indirect_block_buffer, storage),
                        .storage = storage,
                    },
                };
            }

            fn next(iterator: *EntryIterator.Version0) !?Entry {
                const entry = iterator.peek();

                if (entry != null) {
                    if (iterator.entry_index_in_block >= Entry.Version0.entries_per_block) {
                        try Block.read(
                            iterator.entries_block.?.contents,
                            iterator.block_index_iterator.next() orelse
                                return null,
                            iterator.storage,
                        );

                        iterator.entry_index_in_block = 0;
                    } else {
                        iterator.index += 1;
                        iterator.entry_index_in_block += 1;
                    }
                }

                return entry;
            }

            fn peek(iterator: *EntryIterator.Version0) ?Entry {
                const entry_block = iterator.entries_block orelse
                    return null;

                const entry_memory = entry_block.contents[iterator.entry_index_in_block *
                    Entry.Version0.entry_size .. (iterator.entry_index_in_block + 1) *
                    Entry.Version0.entry_size];

                const entry = Entry.Version0.init(entry_memory) catch |err| switch (err) {
                    error.UnsupportedVersion => unreachable,
                };

                if (entry.@"0".inode_id == 0xffff)
                    return null;

                return entry;
            }

            fn reset(iterator: *EntryIterator.Version0) !void {
                iterator.index = 0;
                iterator.entry_index_in_block = 0;
                iterator.block_index_iterator.reset();

                const entries_block = iterator.entries_block orelse
                    return;

                try Block.read(
                    entries_block.contents,
                    iterator.block_index_iterator.peek() orelse return,
                    iterator.storage,
                );
            }
        };

        fn init(
            dir: Dir,
            entry_block_buffer: *[common.block_size]u8,
            indirect_block_buffer: *[common.block_size]u8,
            storage: std.fs.File,
        ) !EntryIterator {
            switch (dir) {
                .@"0" => EntryIterator.Version0.init(dir, entry_block_buffer, indirect_block_buffer, storage),
            }
        }

        pub fn next(iterator: *EntryIterator) !?Entry {
            return switch (iterator) {
                inline else => |iterator_version| try iterator_version.next(),
            };
        }
        pub fn peek(iterator: *EntryIterator) !?Entry {
            return switch (iterator) {
                inline else => |iterator_version| try iterator_version.peek(),
            };
        }
        pub fn reset(iterator: *EntryIterator) void {
            return switch (iterator) {
                inline else => |iterator_version| iterator_version.reset(),
            };
        }
    };

    pub const Entry = union(enum) {
        @"0": Entry.Version0,
        const Version0 = struct {
            inode_id: u16,
            name: *[entry_size]u8,

            const entry_size = 128;
            const name_len = entry_size - @sizeOf(Inode.Id);
            /// 16
            const entries_per_block = common.block_size / entry_size;

            fn init(
                /// this is a slice because it is better to error when given the wrong size than to
                /// silently truncate it in `Entry.init` when calling this function
                contents: []u8,
            ) !Entry {
                if (contents.len != entry_size)
                    return error.InvalidEntryBufferSize;

                return .{
                    .@"0" = .{
                        .inode_id = std.mem.readInt(u16, contents[0..2], .little),
                        .name = contents[2..128],
                    },
                };
            }

            fn read(
                /// this is a slice because it is better to error when given the wrong size than to
                /// silently truncate it in `Entry.init` when calling this function
                contents_buffer: []u8,
                storage: std.fs.File,
                storage_address: u27,
            ) !Entry {
                if (contents_buffer.len != entry_size)
                    return error.InvalidEntryBufferSize;

                try storage.seekTo(storage_address);

                const reader = storage.reader();
                _ = try reader.readAll(contents_buffer);

                return .{
                    .@"0" = .{
                        .inode_id = std.mem.readInt(u16, contents_buffer[0..2], .little),
                        .name = contents_buffer[2..128],
                    },
                };
            }

            fn write(
                entry: Entry.Version0,
                storage: std.fs.File,
                storage_address: u27,
            ) !void {
                try storage.seekTo(storage_address);

                const writer = storage.writer();

                try writer.writeInt(u16, entry.inode_id, .little);
                try writer.writeAll(entry.name);
            }

            /// returns true if `entry` marks the end of that entry block
            fn isEnd(entry: Entry.Version0) bool {
                return entry.inode_id != 0xffff;
            }

            /// asserts that `name.len` <= 126.
            fn eql(entry: Entry.Version0, name: [:0]const u8) bool {
                std.debug.assert(name.len <= name_len);

                for (name, 0..) |char, i| {
                    if (entry.name[i] != char)
                        return false;
                }

                return true;
            }

            pub fn format(
                entry: Entry.Version0,
                _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                const len = std.mem.indexOfScalar(u8, entry.name, 0) orelse Entry.Version0.name_len;
                try writer.writeAll(entry.name[0..len]);
            }
        };

        pub fn init(
            version: u16,
            contents: []u8, // this is a slice, because entry_size may change in future versions
        ) !Entry {
            return switch (version) {
                0 => try Entry.Version0.init(contents),
                else => return error.UnsupportedVersion,
            };
        }

        pub fn read(
            version: u16,
            contents_buffer: []u8, // this is a slice, because entry_size may change in future versions
            storage: std.fs.File,
            storage_address: u27,
        ) !Entry {
            return switch (version) {
                0 => try Entry.Version0.read(contents_buffer, storage, storage_address),
                else => return error.UnsupportedVersion,
            };
        }

        pub fn write(
            entry: Entry,
            storage: std.fs.File,
            storage_address: u27,
        ) !void {
            switch (entry) {
                inline else => |entry_version| try entry_version.write(
                    storage,
                    storage_address,
                ),
            }
        }

        pub fn isEnd(entry: Entry) bool {
            return switch (entry) {
                inline else => |entry_version| entry_version.isEnd(),
            };
        }
        pub fn eql(entry: Entry, name: [:0]const u8) bool {
            return switch (entry) {
                inline else => |entry_version| entry_version.eql(name),
            };
        }

        pub fn format(
            entry: Entry,
            _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (entry) {
                inline else => |entry_version| try writer.print(
                    "{}",
                    .{entry_version},
                ),
            }
        }
    };
};
