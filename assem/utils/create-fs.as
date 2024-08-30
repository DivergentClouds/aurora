include '../tundra-extra.inc'


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

    cmpi a, 0x0fff
    jmpi .default_count 

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
      calli read_ynx

      jeqpi a, 1, .start_format
      jeqpi a, 0, .get_count

      ; if user cancelled, exit
      jmpi .exit

  .start_format:
    ; TODO


  .exit:
    halt

  .no_storage_error:
    pushi strings.error_missing_device
    calli puts
    jmpi .exit


; const Ynx = enum {no = 0, yes = 1, cancel = 2}
;
; read_ynx(default: Ynx) Ynx
read_ynx:
  pushi 0
  peeki a, 6
  push a

  .read_char:
    movi a, mmio.read_char
    mov a, *a
    cmpi a, -1
    jmpi .read_char

    cmpi a, '~'
    jmpi .read_char

    jeqpi a, char.bs, .backspace

    movi b, mmio.write_char
    sto b, a
    
    jeqpi a, char.cr, .enter

    peeki b, 4
    addi b, 1
    pokeir 4, b

    andi a, 0xdf ; make case insensitive
    jeqpi a, 'Y', .yes
    jeqpi a, 'N', .no
    jeqpi a, 'X', .cancel

    peeki b, 8
    pokeir 2, b

    jmpi .read_char

    .yes:
      pokei 2, 1
      jmpi .read_char

    .no:
      pokei 2, 0
      jmpi .read_char

    .cancel:
      pokei 2, 2
      jmpi .read_char

    .backspace:
      peeki b, 4

      cmpi b, 0
      jmpi .read_char

      subi b, 1
      pokeir 4, b

      movi b, mmio.write_char
      sto b, a

      jmpi .read_char


  .enter:
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
  pushi -1  ; length counter (effectively starts at 0 due to next_char)
  pushi 0;  ; result

  .next_char:
    peeki a, 4
    addi a, 1
    pokeir 4, a
    cmpi a, 3   ; is length counter <= 3
    jmpi .inc_buffer

  .wait_for_confirm:
    movi a, mmio.read_char
    mov a, *a
    jeqpi a, char.cr, .end
    jeqpi a, char.bs, .backspace
    jmpi .wait_for_confirm

  .inc_buffer:
    peeki a, 8
    addi a, 1
    pokeir 8, a

  .read_char:
    movi a, mmio.read_char
    mov a, *a

    cmpi a, -1
    jmpi .read_char   ; loop if no character was read

    cmpi a, '~'       ; no valid characters > '~'
    jmpi .parse_char
    jmpi .read_char

  .parse_char:
    jeqpi a, char.cr, .end
    jeqpi a, char.bs, .backspace

    cmpi a, '0' - 1
    jmpi .read_char

    cmpi a, '9'
    jmpi .digit

    andi a, 0x1f
    cmpi a, 0x0f
    jmpi .put_hex

    jmpi .read_char

  .digit:
    andi a, 0x1f

  .put_hex:
    movi b, mmio.write_char
    sto b, a

    peeki b, 2
    rotli b, 4
    or b, a
    pokeir 2, b

  .backspace:
    peeki a, 4
    subi a, 1

    cmpi a, -1
    jmpi .next_char

    pokeir 4, a
    peeki a, 8
    subi a, 1
    pokeir 8, a

    movi a, mmio.write_char
    stoi a, char.bs

    jmpi .next_char

  .end:
    movi b, mmio.write_char
    stoi b, char.cr
    stoi b, char.lf

    peeki a, 2
    dropi 4
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


strings:
  .welcome: db 'Welcome to the TundraFS version 0 disk formatting tool', \
              char.cr, char.lf, 0

  .ask_inode_count: db 'Enter the desired inode count in hexadecimal (1000-ffff, default 8000): ', \
                      0

  .confirm_format_pt1: db 'Format storage device 0 with ', 0
  .confirm_format_pt2: db ' inodes? (y/N/x): ', 0

  .finished_format: db 'Formatted storage device 0', char.cr, char.lf, 0

  .error_missing_device: db 'ERROR: no storage device attached', char.cr, char.lf

data:
  .inode_count_str: db 5 dup 0
  .default_inode_count_str: db '8000', 0
