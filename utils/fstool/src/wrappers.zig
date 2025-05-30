const std = @import("std");
const afs = @import("aurora-fs.zig");

pub fn changePerms(
    storage: std.fs.File,
    path: []const u8,
    permissions: afs.Inode.Permissions,
    allocator: std.mem.Allocator,
) !void {
    var superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);

    var inode = try root.openInodePath(path, superblock, storage, allocator);
    inode.setPermissions(permissions);
    try inode.write(superblock, storage);
}

pub fn printInfo(
    storage: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);

    const inode = try root.openInodePath(path, superblock, storage, allocator);

    const stdout = std.io.getStdOut().writer();

    try stdout.print("{}\n", .{inode});
}

pub fn listDir(
    storage: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);

    var entry_block_buffer: [afs.common.block_size]u8 = @splat(0);
    var indirect_block_buffer: [afs.common.block_size]u8 = @splat(0);

    const dir = try root.openDirPath(path, superblock, storage, allocator);

    var entry_iterator = try dir.entryIterator(&entry_block_buffer, &indirect_block_buffer, storage);

    const stdout = std.io.getStdOut().writer();
    while (try entry_iterator.next()) |entry| {
        try stdout.print("{}\n", .{entry});
    }
}

pub fn delete(
    storage: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);

    const inode = try root.openInodePath(path, superblock, storage, allocator);

    switch (inode.kind()) {
        .directory => try deleteDir(storage, path, allocator, &superblock, root),
        .file => try deleteDir(storage, path, allocator, &superblock, root),
        .symlink => return error.SymlinksNotImplimented,
        _ => return error.UnknownInodeKind,
    }
}

/// may only delete empty directories
fn deleteDir(
    storage: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
    superblock: *afs.SuperBlock,
    root: afs.Dir,
) !void {
    const end_index = if (path[path.len - 1] == '/')
        path.len - 1
    else
        path.len;

    const parent_dir_path_index = std.mem.lastIndexOfScalar(u8, path[0..end_index], '/') orelse 0;

    const parent_dir_path = path[0..parent_dir_path_index];
    const dir_name = path[parent_dir_path_index..];
    const dir_name_z = try allocator.dupeZ(u8, dir_name);

    var parent_dir = try root.openDirPath(parent_dir_path, superblock.*, storage, allocator);
    try parent_dir.deleteDir(dir_name_z, superblock, storage);
}

fn deleteFile(
    storage: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
    superblock: *afs.SuperBlock,
    root: afs.Dir,
) !void {
    const parent_dir_path_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;

    const parent_dir_path = path[0..parent_dir_path_index];
    const file_name = path[parent_dir_path_index..];

    const file_name_z = try allocator.dupeZ(u8, file_name);
    defer allocator.free(file_name_z);

    var parent_dir = try root.openDirPath(parent_dir_path, superblock.*, storage, allocator);

    try parent_dir.deleteFile(file_name_z, superblock, storage);
}

/// creates directories as needed, copying the permissions of the previous directory
pub fn storeFile(
    storage: std.fs.File,
    input_path: []const u8,
    output_path: []const u8,
    file_permissions: afs.Inode.Permissions,
    allocator: std.mem.Allocator,
) !void {
    var superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    var dir = try afs.Dir.root(superblock, storage);

    var path_tokens = std.mem.tokenizeScalar(u8, output_path, '/');
    const output_name: []const u8 = while (path_tokens.next()) |subpath| {
        if (path_tokens.peek() == null)
            break subpath;

        const subpath_z = try allocator.dupeZ(u8, subpath);
        defer allocator.free(subpath_z);

        const dir_permissions = dir.inode().getPermissions();

        dir = try dir.openDir(subpath_z, superblock, storage) orelse
            try dir.createDir(
                subpath_z,
                dir_permissions,
                &superblock,
                storage,
            );
    } else unreachable; // path_tokens.peek() will eventually result in null and cause the loop to break

    const output_name_z = try allocator.dupeZ(u8, output_name);
    defer allocator.free(output_name_z);

    if (try dir.openFile(output_name_z, superblock, storage) != null) {
        try dir.deleteFile(output_name_z, &superblock, storage);
    }

    var output_file = try dir.createFile(
        output_name_z,
        file_permissions,
        &superblock,
        storage,
    );

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const input_file_contents = try input_file.readToEndAlloc(allocator, std.math.maxInt(u27));
    defer allocator.free(input_file_contents);

    try output_file.write(input_file_contents, &superblock, storage);
}

/// read contents of the file at `input_path` in `storage` into the file
/// `output_path` on the host disk
pub fn loadFile(
    storage: std.fs.File,
    input_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);

    const input_file = try root.openFilePath(input_path, superblock, storage, allocator);
    const file_contents = try input_file.read(storage, allocator);

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    try output_file.writeAll(file_contents);
}

pub fn createDir(
    storage: std.fs.File,
    path: []const u8,
    permissions: afs.Inode.Permissions,
    allocator: std.mem.Allocator,
) !void {
    var superblock = try afs.SuperBlock.read(storage);
    try superblock.verify();

    const root = try afs.Dir.root(superblock, storage);
    _ = try root.createDirPath(path, permissions, &superblock, storage, allocator);
}

pub fn format(
    storage: std.fs.File,
    inode_count: ?u16,
    bootblock_name: []const u8,
) !void {
    const reserved_blocks = 2;
    const total_blocks = 0x10000;

    const default_inode_count = 0x8000;
    const inode_bitmap_start = reserved_blocks;

    var bootblock: [afs.common.block_size]u8 = @splat(0);

    const bootblock_file = try std.fs.cwd().openFile(bootblock_name, .{});
    defer bootblock_file.close();

    _ = try bootblock_file.reader().readAll(&bootblock);

    const total_inodes = if (inode_count) |count|
        if (count == 0xffff)
            return error.InvalidInodeCount
        else
            count
    else
        default_inode_count;

    const inode_block_count = try std.math.divCeil(u16, total_inodes, afs.common.block_size);
    const inode_bitmap_len = try std.math.divCeil(u16, inode_block_count, 8);

    const data_bitmap_len = try std.math.divCeil(u16, total_blocks - inode_bitmap_start - inode_bitmap_len, 8);

    const first_inode_block = inode_bitmap_len + data_bitmap_len + reserved_blocks;
    const first_data_block = first_inode_block + inode_block_count;

    const unallocated_data = total_blocks - reserved_blocks - first_data_block;

    var superblock: afs.SuperBlock = .{
        .@"0" = .{
            .magic = "AuroraFS".*,
            .version = 0,

            .unallocated_data = unallocated_data,
            .total_inodes = total_inodes,
            .unallocated_inodes = total_inodes,

            .inode_bitmap_start = inode_bitmap_start,
            .inode_bitmap_len = inode_bitmap_len,

            .data_bitmap_start = inode_bitmap_start + inode_bitmap_len,
            .data_bitmap_len = data_bitmap_len,

            .first_inode_block = first_inode_block,
            .first_data_block = first_data_block,
        },
    };

    try superblock.verify();
    try superblock.write(storage);

    try storage.seekTo(afs.common.bootblock_address);
    try storage.writeAll(&bootblock);

    // create root directory
    var root_inode: afs.Inode = .{
        .@"0" = .{
            .valid = true,
            .kind = .directory,
            .readable = true,
            .writeable = true,
            .executable = true,

            .hard_link_count = 0, // will be incremented

            .file_size_upper = 0,
            .file_size_lower = 0,

            .direct_block_indices = @splat(0),
            .indirect_block_index = 0,

            .id = 0,
        },
    };

    try afs.bitmap.allocate(0, 0, .inode, &superblock, storage);

    try root_inode.write(superblock, storage);

    var root: afs.Dir = .{
        .@"0" = .{
            .inode = root_inode,
        },
    };

    try root.createHardLink(".", &root_inode, &superblock, storage);
    try root.createHardLink("..", &root_inode, &superblock, storage);

    try superblock.write(storage);
    try root_inode.write(superblock, storage);
}
