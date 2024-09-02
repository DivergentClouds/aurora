include '../tundra-extra.inc'

total_blocks = 0x10000
block_size = 2048
reserved_blocks = 2
max_available_blocks = total_blocks - reserved_blocks
inodes_per_block = 64
dir_entires_per_block = 16

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

    jlequi a, 0x0fff, .default_count

    push a
    pushi data.inode_count_str

    jmpi .confirm_count

    .default_count:
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

      push a
      jeqpi a, 1, .do_format
      pop a
      jeqpi a, 0, .get_count

      ; if user cancelled, exit
      jmpi .exit

  .do_format:
    calli format_storage    ; inode count is still on stack


  .exit:
    halt

  .no_storage_error:
    pushi strings.error_missing_device
    calli puts
    jmpi .exit


; format(inode_count: usize) void
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

  movi a, mmio.access_address
  stoi a, superblock

  movi a, mmio.block_index
  stoi a, 1   ; superblock location, 0 is boot block
  
  movi a, mmio.write_storage
  stoi a, 1   ; write 1 block

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

  ; TODO

  reti b, 2

; assumes numerator > denominator
; get_inode_block_count(numer: usize, denom: usize) usize
div_ceil:
  peeki a, 6
  push a    ; count
  pushi 0   ; result

  .loop:
    peeki a, 4
    peeki b, 8  ; denominator
    sub a, b
    pokeir 4, a

    peeki b, 2
    addi b, 1
    pokeir 2, b

    peeki b, 10

    jlequri b, a, .loop
  
  pop a
  dropi 2
  reti b, 2


; Ync = enum { 0 = no, 1 = yes, 2 = cancel }
; read_ync(default: Ync) Ync
read_ync:
  pushi 0
  peeki a, 6
  push a

  .read_char:
    movi a, mmio.read_char
    mov a, *a
    cmpi a, -1
    jmpi .read_char

    cmpi a, '~'
    jmpi .parse_char
    jmpi .read_char

  .parse_char:
    push a
    jeqpi a, char.bs, .backspace
    pop a

    movi b, mmio.write_char
    sto b, a
    
    push a
    jeqpi a, char.cr, .enter
    pop a

    peeki b, 4
    addi b, 1
    pokeir 4, b

    andi a, 0xdf ; make case insensitive

    push a
    jeqpi a, 'Y', .yes
    pop a

    push a
    jeqpi a, 'N', .no
    pop a

    push a
    jeqpi a, 'C', .cancel
    pop a
 
    peeki b, 8
    pokeir 2, b

    jmpi .read_char

    .yes:
      dropi 2
      pokei 2, 1
      jmpi .read_char

    .no:
      dropi 2
      pokei 2, 0
      jmpi .read_char

    .cancel:
      dropi 2
      pokei 2, 2
      jmpi .read_char

    .backspace:
      dropi 2
      peeki b, 4

      cmpi b, 0
      jmpi .read_char

      subi b, 1
      pokeir 4, b

      movi b, mmio.write_char
      stoi b, char.bs

      jmpi .read_char

  .enter:
    dropi 2
    movi b, mmio.write_char
    stoi b, char.lf

    peeki b, 4
    jeqi b, 1, .end

    ; otherwise, set to default
    peeki b, 8
    pokeir 2, b

  .end:
    pop a
    dropi 2
    reti b, 2

; returns result, if 0, check if buffer[0] == 0
; read_hex_u16(buffer: *[5]u8) bool
read_hex_u16:
  pushi 0  ; length counter (effectively starts at 0 due to next_char)
  pushi 0  ; result

  jmpi .read_char

  .next_char:
    peeki a, 4
    addi a, 1
    pokeir 4, a
    cmpi a, 3   ; is length counter <= 3
    jmpi .read_char

  .wait_for_confirm:
    movi a, mmio.read_char
    mov a, *a
    cmpi a, -1
    jmpi .wait_for_confirm

    push a
    jeqpi a, char.cr, .end
    pop a
    jeqpi a, char.bs, .backspace
    jmpi .wait_for_confirm

  .drop_top:
    dropi 2
  .read_char:
    movi a, mmio.read_char
    mov a, *a

    cmpi a, -1
    jmpi .read_char   ; loop if no character was read

    cmpi a, '~'       ; no valid characters > '~'
    jmpi .parse_char
    jmpi .read_char

  .parse_char:
    push a
    jeqpi a, char.cr, .end

    pop a
    push a
    jeqpi a, char.bs, .backspace

    pop a
    push a

    cmpi a, '0' - 1
    jmpi .drop_top

    cmpi a, '9'
    jmpi .digit


    andi a, 0x1f
    cmpi a, 0x06
    jmpi .hex

    jmpi .drop_top

  .digit:
    subi a, '0'
    jmpi .put_hex

  .hex:
    cmpi a, 0
    jmpi .drop_top
    addi a, 9

  .put_hex:
    peeki b, 4
    rotli b, 4
    or b, a
    pokeir 4, b

    pop a   ; character typed
    movi b, mmio.write_char
    sto b, a

    peeki b, 8
    sto b, a
    addi b, 1
    pokeir 8, b

    jmpi .next_char

  .backspace:
    dropi 2
    peeki a, 4
    subi a, 1

    cmpi a, -1
    jmpi .read_char

    pokeir 4, a


    peeki a, 8
    subi a, 1
    pokeir 8, a

    movi a, mmio.write_char
    stoi a, char.bs

    jmpi .read_char

  .end:
    movi b, mmio.write_char
    stoi b, char.cr
    stoi b, char.lf

    dropi 2
    pop a
    dropi 2
    reti b, 2


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


; not executed, copied into block 0
bootblock:
  
  rb superblock - $ + block_size

strings:
  .welcome: db 'Welcome to the TundraFS version 0 disk formatting tool', \
              char.cr, char.lf, 0

  .ask_inode_count: db 'Enter the desired inode count in hexadecimal (1000-ffff, default 8000): ', \
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
    db 'TundraFS'
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



  rb superblock - $ + block_size

