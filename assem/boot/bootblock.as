namespace bootblock
include '../tundra-extra.inc'
include '../utils/aurora-utils.inc'

; loaded in at 0xc000 (kernel_base + kernel_max_size)

block_size = 2048
max_size = 0x3800 ; leave plenty of room for the stack
inode_size = 32

bootblock_index = 0
superblock_index = 1
version = 0

kernel_max_size = 0x4000
kernel_base = 0x8000 ; subject to change


; needed because this file is included in create-fs.as
start:
; setup
stack_init


; load superblock ;
; --------------- ; 

movi a, mmio.block_index
stoi a, superblock_index

movi a, mmio.read_storage
movreli b, superblock
sto a, b

; verify superblock ;
; ----------------- ;

; magic check

movreli a, superblock.magic
push a
movreli a, strings.magic
push a
creli streql

cmpi a, 0
jmpi superblock_magic_error

; version check

movreli b, superblock.version
mov b, *b
jnei b, version, superblock_version_error


; load `/` ;
; -------- ;

movreli a, superblock.first_inode_block
movi b, mmio.block_index
sto b, *a

movi a, mmio.read_storage
movreli b, inode_block
sto a, b

movreli a, inode_block.flags
mov a, *a
andi a, 0xf0              ; we are only looking at the upper nybble of the flags byte
jeqpi a, 0x80, load_boot  ; jump if valid flag is set and kind is directory
jmpi root_not_found_error ; otherwise, error

; find `/boot` ;
; ------------ ;

load_boot:

; since `/` is inode 0, we know it is at the start of the block
movreli a, inode_block.direct_block_indices
push a

movreli a, inode_block.indirect_block_index
push a

; do not use movreli as `directory` is not relative to program base
pushi directory.contents
pushi directory.indirect_block_indices

movreli a, strings.boot_dir_name
push a

creli find_in_dir

mov b, a  ; do not clobber find_in_dir result
jeqi b, 0xffff, boot_not_found_error

; load `/boot` ;
; ------------ ;

push a  ; inode id

movreli a, inode_block
push a

creli load_inode

; find `/boot/kernel` ;
; ------------------- ;

mov b, a  ; a is boot directory inode pointer
addi b, inode_offsets.direct_block_indices
push b

mov b, a  ; a is boot directory inode pointer
addi b, inode_offsets.indirect_block_index

; do not use movreli as `directory` is not relative to program base
pushi directory.contents
pushi directory.indirect_block_indices

movreli a, strings.kernel_file_name
push a

creli find_in_dir

; load kernel ;
; ----------- ;

mov b, a  ; a is `/boot/kernel` inode pointer
addi b, inode_offsets.filesize_upper
movb b, *b
jnei b, 0, kernel_too_large_error

mov b, a  ; a is `/boot/kernel` inode pointer
addi b, inode_offsets.filesize_lower
mov b, *b
jgtui b, kernel_max_size - 1, kernel_too_large_error

addi a, inode_offsets.direct_block_indices
push a
pushi kernel_base

creli load_file_direct



; set up for kernel ;
; ----------------- ;

; NOTE: kernel must set up interrupt address

movi a, mmio.boundary_address
stoi a, kernel_base

; jump into kernel ;
; ---------------- ;

jabsi kernel_base


superblock_magic_error:
  movreli a, strings.magic_error
  jmpi error

superblock_version_error:
  movreli a, strings.version_error
  jmpi error

root_not_found_error:
  movreli a, strings.no_root_error
  jmpi error

boot_not_found_error:
  movreli a, strings.no_boot_error
  jmpi error

kernel_not_found_error:
  movreli a, strings.no_kernel_error
  jmpi error

kernel_too_large_error:
  movreli a, strings.large_kernel_error
  jmpi error

error:
  push a
  creli puts
  movi a, mmio.halt
  sto a, a


strings:
  .magic_error:
    db 'ERROR: filesystem invalid magic', char.cr, char.lf, 0
  .version_error:
    db 'ERROR: filesystem version mismatch', char.cr, char.lf, 0
  .no_root_error:
    db 'ERROR: root directory not found', char.cr, char.lf, 0
  .no_boot_error:
    db 'ERROR: boot directory not found', char.cr, char.lf, 0
  .no_kernel_error:
    db 'ERROR: kernel not found', char.cr, char.lf, 0
  .large_kernel_error:
    db 'ERROR: kernel too large', char.cr, char.lf, 0

  .magic:
    db 'AuroraFS', 0
  .kernel_file_name:
    db 'kernel', 0
  .boot_dir_name:
    db 'boot', 0

define_puts
define_streql
define_div_floor_rem
define_find_in_dir
define_load_inode
define_load_file_direct

; make sure bootblock fits in a block
assert $ - start < block_size

virtual
  superblock:
    .magic:
      rb 8
    .version:
      rw 1
    
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


  rb $ - superblock + block_size

  inode_block inode_struct
  rb $ - inode_block + block_size ; reserve rest of block
  
  assert $ - start < max_size
end virtual


virtual at 0
  directory:
  .contents:
    rb block_size

  .indirect_block_indices:
    rb block_size
end virtual

; use as constants, not addresses
create_virtual_inode inode_offsets, 0

end namespace
