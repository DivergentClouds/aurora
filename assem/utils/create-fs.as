include '../tundra-extra.inc'
include './aurora-utils.inc'

total_blocks = 0x10000
block_size = 2048
reserved_blocks = 2
max_available_blocks = total_blocks - reserved_blocks
inode_size = 32
inodes_per_block = 64
dir_entires_per_block = 16
filename_len = 126

bootblock_index = 0
superblock_index = 1

_start:
  stack_init

  pushi strings.welcome
  calli puts
  
  movi a, mmio.storage_count
  mov a, *a
  cmpi a, 0
  jmpi .no_storage_error

  .get_count:
    pushi strings.ask_inode_count
    calli puts

    pushi data.inode_count_str
    calli read_hex_u16
    push a

    jlequi a, 0x0fff, .default_count
    jeqi a, 0xffff, .default_count  ; disallow 0xffff inodes, so that invalid inode ids can exist

    pushi data.inode_count_str

    jmpi .confirm_count

    .default_count:
      dropi 2
      pushi 0x8000
      pushi data.default_inode_count_str

    .confirm_count:
      pushi strings.confirm_format_pt1
      calli puts

      calli puts  ; string was pushed earlier

      pushi strings.confirm_format_pt2
      calli puts

      pushi 0
      calli read_ync

      cmpi a, 0
      jmpi .get_count

      cmpi a, 1
      jmpi .do_format

      ; if user cancelled, exit
      jmpi .exit

  .do_format:
    calli format_storage    ; inode count is still on stack

    calli create_root

    pushi strings.finished_format
    calli puts

  .exit:
    movi a, mmio.halt
    sto a, a

  .no_storage_error:
    pushi strings.error_missing_device
    calli puts
    jmpi .exit


; create_root() void
create_root:
  movi a, mmio.block_index
  stoi a, superblock.first_inode_block

  movi a, mmio.write_storage
  stoi a, root_inode_block

  movi a, mmio.block_index
  stoi a, superblock.inode_bitmap_start

  movi a, mmio.read_storage
  stoi a, first_inode_bitmap

  movi a, first_inode_bitmap
  stoi a, 0x8000 ; 1 followed by 15 0s

  movi a, mmio.write_storage
  stoi a, first_inode_bitmap

  reti 2
  

; format(inode_count: u16) void
format_storage:
  ; write to superblock ;
  ; ------------------- ;

  movi a, superblock.total_inodes
  peeki b, 4
  sto a, b

  movi a, superblock.unallocated_inodes
  sto a, b

  movi a, superblock.inode_bitmap_start
  stoi a, reserved_blocks  ; directly after superblock

  push b   ; total inodes
  pushi inodes_per_block
  calli div_ceil
  
  push a   ; INODE_BLOCK_COUNT

  push a
  pushi 8
  calli div_ceil

  push a    ; inode_bitmap_len

  movi b, superblock.inode_bitmap_len
  sto b, a

  addi a, reserved_blocks
  movi b, superblock.data_bitmap_start
  sto b, a

  peeki a, 2

  neg a
  addi a, max_available_blocks
  push a    ; TOTAL_BLOCKS - INODE_BITMAP_LEN - RESERVED_BLOCKS
  pushi 8
  calli div_ceil ; DATA_BITMAP_LEN
  
  movi b, superblock.data_bitmap_len
  sto b, a

  pop b    ; inode_bitmap_len

  add a, b
  addi a, reserved_blocks
  movi b, superblock.first_inode_block
  sto b, a
  
  pop b     ; INODE_BLOCK_COUNT
  add a, b
  movi b, superblock.first_data_block
  sto b, a

  movi b, max_available_blocks
  sub b, a    ; TOTAL_BLOCKS - RESERVED_BLOCKS - first_data_block
  movi a, superblock.unallocated_data
  sto a, b


  ; store superblock ;
  ; ---------------- ;

  movi a, mmio.block_index
  stoi a, superblock_index
  
  movi a, mmio.write_storage
  stoi a, superblock ; store superblock

  ; initalize bitmaps ;
  ; ----------------- ;
  
  movi a, superblock.inode_bitmap_start
  movi b, mmio.block_index
  sto b, a

  movi a, superblock.inode_bitmap_len
  movi b, mmio.zero_storage
  sto b, a
  
  movi a, superblock.data_bitmap_start
  movi b, mmio.block_index
  sto b, a

  movi a, superblock.data_bitmap_len
  movi b, mmio.zero_storage
  sto b, a

  ; store bootblock ;
  ; --------------- ;

  movi a, mmio.block_index
  stoi a, bootblock_index
  
  movi a, mmio.write_storage
  stoi a, bootblock

  reti 2

define_div_ceil
define_read_ync
define_read_hex_u16
define_puts


; not executed, copied into block 0
bootblock:
  include 'bootblock.as'
  rb block_size - ($ - bootblock)

strings:
  .welcome: db 'Welcome to the AuroraFS version 0 disk formatting tool', \
              char.cr, char.lf, 0

  .ask_inode_count: db 'Enter the desired inode count in hexadecimal (1000-fffe, default 8000): ', \
                      0

  .confirm_format_pt1: db 'Format storage device 0 with 0x', 0
  .confirm_format_pt2: db ' inodes? (y/N/c): ', 0

  .finished_format: db 'Formatted storage device 0', char.cr, char.lf, 0

  .error_missing_device: db 'ERROR: no storage device attached', char.cr, char.lf

data:
  .inode_count_str: db 5 dup 0
  .default_inode_count_str: db '8000', 0

superblock:
  .magic:
    db 'AuroraFS'
  .version:
    dw 0
  
  .unallocated_data:
    rw 1
  .total_inodes:
    rw 1
  .unallocated_inodes:
    rw 1

  .inode_bitmap_start:
    rw 1
  .inode_bitmap_len:
    rw 1

  .data_bitmap_start:
    rw 1
  .data_bitmap_len:
    rw 1

  .first_inode_block:
    rw 1
  .first_data_block:
    rw 1



  rb block_size - ($ - superblock)

root_inode_block inode_struct
rb block_size - ($ - root_inode_block)

first_inode_bitmap:
  rb block_size

first_data_bitmap:
  rb block_size

root_data_block:
  .inode_id_0: dw 0
  .name_0:
    db '.', 0
    rb filename_len - ($ - .name_0)

  .inode_id_1: dw 0
  .name_1:
    db '..', 0
    rb filename_len - ($ - .name_1)
  
  .inode_id_2: dw 0xffff
  .name_2:
    db 0
    rb filename_len - ($ - .name_2)

  rb block_size - ($ - root_data_block)
