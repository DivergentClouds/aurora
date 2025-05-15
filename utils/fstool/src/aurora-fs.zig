const std = @import("std");

pub const SuperBlock = @import("fs/SuperBlock.zig").SuperBlock;
pub const Inode = @import("fs/Inode.zig").Inode;
pub const Dir = @import("fs/Dir.zig").Dir;
pub const File = @import("fs/File.zig").File;
pub const Block = @import("fs/Block.zig");
pub const common = @import("fs/common.zig");
pub const bitmap = @import("fs/bitmap.zig");

test "check for compile errors" {
    std.testing.refAllDeclsRecursive(@This());
}
