pub const block_size = 2048;
pub const bootblock_address = 0 * block_size;
pub const superblock_address = 1 * block_size;
pub const max_executable_size = 0x8000;

/// direct block indices + indices in an indirect block
pub const max_inode_data_blocks = 8 + block_size / @sizeOf(u16);
