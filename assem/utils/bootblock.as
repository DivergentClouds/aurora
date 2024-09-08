namespace bootblock
include '../tundra-extra.inc'

; loaded in at 0xf000
org 0xf000

block_size = 2048
max_size = 0xfee

bootblock_index = 0
superblock_index = 1
version = 0

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
stoi a, superblock


; verify superblock ;
; ----------------- ;

movi a, superblock


; magic check

pushi superblock.magic
calli check_magic
cmpi a, 0
jmpi superblock_magic_error

; version check

movi b, superblock.version
jnei b, version, superblock_version_error


; verify kernel exists ;
; -------------------- ;

movi a, superblock.first_inode_block
movi b, mmio.block_index
sto b, *a

movi a, mmio.read_storage
stoi a, kernel_inode_block

movi a, kernel_inode_block.flags
movb a, *a
rotri a, 7
andi a, 1
cmpi a, 0   ; if kernel is invalid
jmpi kernel_not_found_error ; then error


; set up for kernel ;
; ----------------- ;

movi a, mmio.boundary_address
stoi a, kernel_base

; let kernel set interrupt address


; load kernel ;
; ----------- ;
  pushi kernel_inode_block.direct_block_ptrs
  calli load_kernel_direct

  ; kernel can be at most 0x4000 bytes

; jump into kernel ;
; ---------------- ;
  jmpi kernel_base



superblock_magic_error:
  pushi strings.magic_error
  jmpi error

superblock_version_error:
  pushi strings.version_error
  jmpi error

kernel_not_found_error:
  pushi strings.no_kernel_error
  jmpi error

error:
  calli puts
  halt

strings:
  .magic_error:
    db 'ERROR: filesystem invalid magic', char.cr, char.lf, 0
  .version_error:
    db 'ERROR: filesystem version mismatch', char.cr, char.lf, 0
 .no_kernel_error:
    db 'ERROR: kernel not found', char.cr, char.lf, 0

; puts(str: [*:0]u8) void
puts:
  .loop:
    peeki b, 4

    movb b, *b

    cmpi b, 0
    jmpi .end

    movi a, mmio.write_char
    sto a, b

    ; str is 4 bytes deep in the stack
    movi a, 4
    peek b, a
    addi b, 1
    poke a, b
    jmpi .loop

  .end:
  reti b, 2

; load_kernel_direct(direct_block_ptrs: *[8]u8) void
load_kernel_direct:
  pushi kernel_base   ; location to read to
  pushi 0

  .loop:
    peeki a, 8
    mov a, *a

    jeqi a, 0, .end

    movi a, mmio.read_storage
    stoi a, 1

    peeki a, 8
    addi a, 2
    pokeir 8, a

    peeki b, 4
    addi b, block_size
    pokeir 4, b

    peeki a, 2
    addi a, 1
    pokeir 2, a
    cmpi a, 7
    jmpi .loop

  .end:
    dropi 2
    reti b, 2


; check_magic(ptr: *[8]) bool
check_magic:
  pushi 0   ; array index

  .loop:
    peeki a, 6
    peeki b, 2
    add a, b
    movb a, *a

    push a

    movi a, data.magic
    peeki b, 4
    add a, b
    movb a, *a

    pop b

    jneri a, b, .fail

    peeki a, 2
    cmpi a, 7   ; is index <= 7
    jmpi .loop  ; if so, jump to .loop

  .success:
    movi a, 1
    jmpi .end

  .fail:
    movi a, 0

  .end:
    dropi 2
    reti b, 2


data:
  .magic = 'TundraFS'



virtual
  kernel_inode_block:

    .flags:
      rb 1
    
    .hard_link_count:
      rw 1
    .used_block_count:
      rw 1
    
    .filesize_upper:
      rb 1
    .filesize_lower:
      rw 1
    
    .direct_block_ptrs:
      rw 8
    .indirect_block_ptr:
      rw 1

    .reserved:
      rb 6

  rb $ - superblock + block_size
  assert $ - start < max_size
end virtual

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
  assert $ - start < max_size
end virtual
end namespace
