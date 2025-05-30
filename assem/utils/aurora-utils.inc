include '../tundra-extra.inc'

include 'math-utils.as'
include 'terminal-utils.as'
include 'memory-utils.as'

struc inode_struct
  label .

  .flags:
    rb 1
 
  .hard_link_count:
    rw 1
 
  .filesize_upper:
    rb 1
  .filesize_lower:
    rw 1
 
  .direct_block_indices:
    rw 8
  .indirect_block_index:
    rw 1

  .reserved:
    rb 8
end struc

macro create_virtual_inode? name, address
  virtual at address
    name inode_struct
  end virtual
end macro

macro create_inode? name
  name inode_struct
end macro

macro define_read_hex_u16
  ; returns result, if 0, check if buffer[0] == 0
  ; read_hex_u16(buffer: *[5]u8) u16
  read_hex_u16:
    pushi 0  ; length counter
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

      mov b, a
      jeqpi b, char.cr, .end

      mov b, a
      jeqpi b, char.bs, .backspace
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
      mov b, a
      jeqpi b, char.cr, .end

      mov b, a
      jeqpi b, char.bs, .backspace

      push a ; unmodified character

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
      cmpi a, 0 ; do not allow '@'
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
      peeki a, 4 ; length
      subi a, 1

      cmpi a, -1
      jmpi .read_char

      pokeir 4, a

      ; erase previous character from result
      pop a
      andi a, 0xfff0
      rotri a, 4
      push a

      ; modify buffer pointer
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

      pop a
      dropi 2
      reti 2
end macro

; direct dependencies: streql
; uses creli rather than calli
macro define_find_in_dir
  assert defined streql

  local dir_entries_per_block, dir_entry_name_len, block_size

  block_size = 2048
  dir_entries_per_block = 16
  dir_entry_name_len = 126

  ; returns id of found inode, or 0xffff if not found
  ; stops at first null block index (direct or indirect)
  ; find_in_dir(
  ;     direct_block_indices: *[8]u16,
  ;     indirect_block_index: u16,
  ;     directory_data: *[BLOCK_SIZE]u8,
  ;     indirect_data: *[BLOCK_SIZE]u8,
  ;     name: [*:0]u8,
  ; ) u16
  find_in_dir:
    pushi 0   ; direct block pointer counter

    .check_direct_loop:
    	pop a
      addi a, 1 ; cmpi is leq, so add first
      push a

      cmpi a, 8
      jmpi .load_direct_loop
      jmpi .load_indirect

    .load_direct_loop:
      peeki a, 14 ; direct_block_indices

      mov b, a
      addi b, 1
      pokeir 14, b

      mov b, *a ; direct block index
      jeqi b, 0, .not_found ; check if 0, clobbers b
      mov a, *a ; direct block index

      movi b, mmio.block_index
      sto b, a

      ; read block into memory
      peeki a, 10 ; directory_data
      movi b, mmio.read_storage
      sto b, a

      push a  ; base of block in memory
      peeki a, 8
      push a  ; name to search for

      creli .search_block

      mov b, a
      jeqi b, 0xffff, .check_direct_loop

      jmpi .end	; found, inode id in a 

    .load_indirect:
      dropi 2 ; direct block pointer counter

      peeki a, 10 ; indirect_block_index
      mov b, a
      jeqi b, 0, .not_found

      movi b, mmio.block_index
      sto b, a

      peeki a, 6 ; indirect_data
      movi b, mmio.read_storage
      sto b, a

      pushi 0   ; indirect block pointer counter

    .check_indirect_loop:
      pop a ; indirect block pointer offset
      addi a, 2 ; cmpi is leq, so add first
      push a

      cmpi a, dir_entries_per_block
      jmpi .load_indirect_loop
      jmpi .not_found

    .load_indirect_loop:
      peeki a, 10 ; indirect_data
      peeki b, 2 ; indirect block pointer offset
      add a, b

      movi b, mmio.block_index
      sto b, a

      peeki a, 12 ; directory_data
      movi b, mmio.read_storage
      sto b, a

      push a ; directory_data
      peeki a, 10 ; name
      creli .search_block

      mov b, a
      jeqi b, 0xffff, .check_indirect_loop
      jmpi .end   ; found

    .not_found:
      movi a, 0xffff
    .end:
      dropi 2
      reti 10

    ; returns id of found inode, or 0xffff if not found
    ; stop at first entry with inode id of 0xffff
    ;
    ; search_block(
    ;   dir_block: *[BLOCK_SIZE],
    ;   name: [*:0]u8,
    ; ) u16
    .search_block:
      pushi 1 ; counter, starts at 1 due to cmp checking less than or equal

      .search_block.loop:
        peeki a, 8

        mov b, *a
        jeqi b, .search_block.not_found

        push a

        addi a, 2
        push a  ; dir_block[i].name

        peeki a, 8
        push a  ; name

        creli streql

        cmpi a, 0
        jmpi .search_block.continue  ; not equal
        jmpi .search_block.found  ; equal

      .search_block.continue:
        pop a ; dir_block[i].name
        addi a, dir_entry_name_len
        pokeir 8, a ; set dir_block to point to next entry

        pop a ; counter
        addi a, 1
        push a

        cmpi a, dir_entries_per_block
        jmpi .search_block.loop

      .search_block.not_found:
        ; if greater than max length, not found
        movi a, 0xffff
        jmpi .search_block.end

      .search_block.found:
        pop a

      .search_block.end:
        dropi 2
        reti 4

end macro

; direct dependencies: div_floor_rem
; uses creli rather than calli
macro define_load_inode
  assert defined div_floor_rem

  local first_inode_block_offset, inodes_per_block, superblock_index

  first_inode_block_offset = 26
  inodes_per_block = 64
  superblock_index = 1

  ; can also return 0xffff if failed
  ; load_inode(
  ;   inode_id: u16,
  ;   destination_block: *[BLOCK_SIZE]u8
  ; ) *Inode
  load_inode:
    peeki a, 6
    jeqi a, 0xffff, .failure

    ; load superblock
    movi a, mmio.block_index
    stoi a, 1
    movi a, mmio.read_storage
    peeki b, 4  ; destination_block
    sto a, b

    addi b, first_inode_block_offset ; offset into destination_block
    mov b, *b
    push b ; first inode block index

    peeki a, 8  ; inode_id
    push a
    pushi inodes_per_block
    movreli a, .inode_id_offset
    push a
    creli div_floor_rem

    pop b ; first inode block index
    add b, a ; find the correct inode_block

    movi a, mmio.block_index
    sto a, b
    movi a, mmio.read_storage
    peeki b, 4  ; destination_block
    sto a, b

    movreli a, .inode_id_offset
    mov a, *a
    rotli a, 5  ; equivalent to a shift because 0 <= a < 64, so no wrapping occurs
    add a, b  ; pointer to Inode

    .end:
      reti 4

    .failure:
      movi a, 0xffff
      jmpi .end

    .inode_id_offset:
      rw 1
end macro

macro define_load_file_direct
  local block_size

  block_size = 2048

  ; loads up to 8 blocks into memory, returns the number of blocks loaded
  ; load_file_direct(
  ;   direct_block_indices: *[8]u8,
  ;   destination: u16
  ; ) u16
  load_file_direct:
    pushi 0

    .loop:
      peeki a, 8
      mov a, *a

      jeqi a, 0, .end

      movi a, mmio.read_storage
      peeki b, 6
      sto a, b

      peeki a, 8
      addi a, 2
      pokeir 8, a

      peeki b, 6
      addi b, block_size
      pokeir 6, b

      peeki a, 2
      addi a, 1
      pokeir 2, a
      cmpi a, 7
      jmpi .loop

    .end:
      pop a
      reti 4
end macro
