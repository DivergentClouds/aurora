const std = @import("std");
const builtin = @import("builtin");

const wrappers = @import("wrappers.zig");
const afs = @import("aurora-fs.zig");

const Command = enum {
    change_perms,
    print_info,
    list_dir,
    delete,
    store_file,
    load_file,
    create_dir,
    format,
    help,
};

const CommandWithArgs = union(Command) {
    change_perms: struct {
        path: []const u8,
        permissions: afs.Inode.Permissions,
    },
    print_info: struct {
        path: []const u8,
    },
    list_dir: struct {
        path: []const u8,
    },
    delete: struct {
        path: []const u8,
    },
    store_file: struct {
        input_path: []const u8,
        output_path: []const u8,
        permissions: afs.Inode.Permissions,
    },
    load_file: struct {
        input_path: []const u8,
        output_path: []const u8,
    },
    create_dir: struct {
        path: []const u8,
        permissions: afs.Inode.Permissions,
    },
    format: struct {
        bootblock_path: []const u8,
        inode_count: ?u16,
    },
    help: struct {
        command: ?Command,
    },
};

pub fn main() !void {
    var DebugAllocator: std.heap.DebugAllocator(.{}) =
        if (builtin.mode == .Debug)
            .init;

    defer if (builtin.mode == .Debug)
        std.debug.assert(DebugAllocator.deinit() == .ok);

    const allocator: std.mem.Allocator =
        if (builtin.mode == .Debug)
            DebugAllocator.allocator()
        else
            std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 2) {
        try printHelp(null, std.io.getStdErr().writer());
        return error.NoCommandGiven;
    }

    // all commands but help ignore final element
    const command = try parseCommand(args[1..]);

    const storage = switch (command) {
        .help => undefined,
        else => try std.fs.cwd().createFile(args[args.len - 1], .{ .truncate = false }),
    };
    try runCommand(command, storage, allocator);
}

fn printHelp(
    topic: ?Command,
    writer: anytype,
) !void {
    var message: []const u8 =
        \\usage: {s} <command> [args...] <storage file>
        \\
        \\<storage file> is required for all commands except `help`, where it is forbidden
        \\
        \\commands:
        \\  chperms
        \\  info
        \\  list
        \\  delete
        \\  store
        \\  load
        \\  mkdir
        \\  format
        \\  help
    ;

    var explain_permissions = false;
    const permissions_message =
        \\
        \\<permissions> must a string "rwx" where any of the characters may be replaced with '-'
        \\if a character is replaced with '-' then that permission is false, otherwise it is true
        \\in order, the specified permissions are
        \\  - readable
        \\  - writable
        \\  - executable
    ;

    if (topic) |command| {
        switch (command) {
            .change_perms => {
                message =
                    \\change the permissions of a file or directory
                    \\
                    \\chperms <internal path> <permissions>
                    \\
                    \\<internal path> must exist on the filesystem
                ;
                explain_permissions = true;
            },
            .print_info => {
                message =
                    \\print information about a file or directory
                    \\
                    \\info <internal path>
                    \\
                    \\<internal path> must exist on the filesystem
                ;
            },
            .list_dir => {
                message =
                    \\list the contents of a directory
                    \\
                    \\list <internal path>
                    \\
                    \\<internal path> must exist on the filesystem
                ;
            },
            .delete => {
                message =
                    \\delete a file or empty directory
                    \\
                    \\delete <internal path>
                    \\
                    \\<internal path> must exist on the filesystem
                ;
            },
            .store_file => {
                message =
                    \\store an external file to the filesystem
                    \\also creates parent directories as needed
                    \\created directories have the same permissions as their parent
                    \\
                    \\store <external path> <internal path> <permissions>
                    \\
                    \\<external path> must exist on the host filesystem
                    \\
                    \\<internal path> does not have to exist on the filesystem
                ;

                explain_permissions = true;
            },
            .load_file => {
                message =
                    \\load an internal file and write it to an external file
                    \\
                    \\load <internal path> <external path>
                    \\
                    \\<internal path> must exist on the filesystem
                    \\
                    \\<external path> does not have to exist on the host filesystem
                ;
            },
            .create_dir => {
                message =
                    \\create a directory
                    \\also creates parent directories as needed
                    \\all created directories have the specified permissions
                    \\
                    \\mkdir <internal path> <permissions>
                    \\
                    \\<internal path> does not have to exist on the filesystem
                ;

                explain_permissions = true;
            },
            .format => {
                message =
                    \\format the filesystem with the given number of inodes and the given bootblock
                    \\if the number of inodes is not specified a default value is used
                    \\
                    \\format <external bootblock path> [inode count]
                    \\
                    \\<external bootblock path] must exist on the host filesystem
                ;
            },
            .help => {
                message =
                    \\print the help entry for the given command
                    \\if no command is given, print a list of all commands
                    \\
                    \\help [command]
                ;
            },
        }
    }

    try writer.print(
        "{s}{s}\n",
        .{
            message,
            if (explain_permissions)
                permissions_message
            else
                "",
        },
    );
}

fn runCommand(
    command: CommandWithArgs,
    storage: std.fs.File,
    allocator: std.mem.Allocator,
) !void {
    switch (command) {
        .change_perms => |args| try wrappers.changePerms(
            storage,
            args.path,
            args.permissions,
            allocator,
        ),
        .print_info => |args| try wrappers.printInfo(
            storage,
            args.path,
            allocator,
        ),
        .list_dir => |args| try wrappers.listDir(
            storage,
            args.path,
            allocator,
        ),
        .delete => |args| try wrappers.delete(
            storage,
            args.path,
            allocator,
        ),
        .store_file => |args| try wrappers.storeFile(
            storage,
            args.input_path,
            args.output_path,
            args.permissions,
            allocator,
        ),
        .load_file => |args| try wrappers.loadFile(
            storage,
            args.input_path,
            args.output_path,
            allocator,
        ),
        .create_dir => |args| try wrappers.createDir(
            storage,
            args.path,
            args.permissions,
            allocator,
        ),
        .format => |args| try wrappers.format(
            storage,
            args.inode_count,
            args.bootblock_path,
        ),
        .help => |args| try printHelp(
            args.command,
            std.io.getStdOut().writer(),
        ),
    }
}

/// asserts that strings.len != 0
fn parseCommand(
    strings: []const []const u8,
) !CommandWithArgs {
    std.debug.assert(strings.len != 0);

    const command = try getCommand(strings[0]);

    const args_len: usize = switch (command) {
        .help => strings.len,
        else => strings.len - 1,
    };

    switch (command) {
        .change_perms => {
            if (args_len != 2)
                return error.BadArgCount;

            return .{
                .change_perms = .{
                    .path = strings[1],
                    .permissions = try parsePermissions(strings[2]),
                },
            };
        },
        .print_info => {
            if (args_len != 1)
                return error.BadArgCount;

            return .{
                .print_info = .{
                    .path = strings[1],
                },
            };
        },
        .list_dir => {
            if (args_len != 1)
                return error.BadArgCount;

            return .{
                .list_dir = .{
                    .path = strings[1],
                },
            };
        },
        .delete => {
            if (args_len > 1)
                return error.BadArgCount;

            return .{
                .delete = .{
                    .path = strings[1],
                },
            };
        },
        .store_file => {
            if (args_len != 3)
                return error.BadArgCount;

            return .{
                .store_file = .{
                    .input_path = strings[1],
                    .output_path = strings[2],
                    .permissions = try parsePermissions(strings[3]),
                },
            };
        },
        .load_file => {
            if (args_len != 2)
                return error.BadArgCount;

            return .{
                .load_file = .{
                    .input_path = strings[1],
                    .output_path = strings[2],
                },
            };
        },
        .create_dir => {
            if (args_len != 2)
                return error.BadArgCount;

            return .{
                .create_dir = .{
                    .path = strings[1],
                    .permissions = try parsePermissions(strings[2]),
                },
            };
        },
        .format => {
            if (args_len > 2 or args_len < 1)
                return error.BadArgCount;

            return .{
                .format = .{
                    .bootblock_path = strings[1],

                    .inode_count = if (args_len < 3)
                        null
                    else
                        try std.fmt.parseInt(u16, strings[2], 0),
                },
            };
        },
        .help => {
            if (args_len > 2)
                return error.BadArgCount;

            return .{
                .help = .{
                    .command = if (args_len == 0)
                        null
                    else
                        try getCommand(strings[1]),
                },
            };
        },
    }
}

fn parsePermissions(permissions_string: []const u8) !afs.Inode.Permissions {
    if (permissions_string.len != 3)
        return error.InvalidPermssionStringLength;

    const readable = if (permissions_string[0] == 'r')
        true
    else if (permissions_string[0] == '-')
        false
    else
        return error.InvalidPermssionString;

    const writeable = if (permissions_string[1] == 'w')
        true
    else if (permissions_string[1] == '-')
        false
    else
        return error.InvalidPermssionString;

    const executable = if (permissions_string[2] == 'x')
        true
    else if (permissions_string[2] == '-')
        false
    else
        return error.InvalidPermssionString;

    return afs.Inode.Permissions{
        .readable = readable,
        .writable = writeable,
        .executable = executable,
    };
}

fn getCommand(command_string: []const u8) error{UnknownCommand}!Command {
    return if (std.mem.eql(u8, command_string, "chperms"))
        .change_perms
    else if (std.mem.eql(u8, command_string, "info"))
        .print_info
    else if (std.mem.eql(u8, command_string, "list"))
        .list_dir
    else if (std.mem.eql(u8, command_string, "delete"))
        .delete
    else if (std.mem.eql(u8, command_string, "store"))
        .store_file
    else if (std.mem.eql(u8, command_string, "load"))
        .load_file
    else if (std.mem.eql(u8, command_string, "mkdir"))
        .create_dir
    else if (std.mem.eql(u8, command_string, "format"))
        .format
    else if (std.mem.eql(u8, command_string, "help"))
        .help
    else
        error.UnknownCommand;
}
