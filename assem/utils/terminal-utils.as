include '../tundra-extra.inc'

macro define_puts
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
      reti 2
end macro

macro define_read_ync
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
      mov b, a
      jeqpi b, char.bs, .backspace

      movi b, mmio.write_char
      sto b, a

      mov b, a
      jeqpi b, char.cr, .enter

      peeki b, 4
      addi b, 1
      pokeir 4, b

      andi a, 0xdf ; make case insensitive

      mov b, a
      jeqpi b, 'Y', .yes

      mov b, a
      jeqpi b, 'N', .no

      mov b, a
      jeqpi b, 'C', .cancel

      peeki b, 8
      dropi 2
      push b

      jmpi .read_char

      .yes:
        dropi 2
        pushi 1
        jmpi .read_char

      .no:
        dropi 2
        pushi 0
        jmpi .read_char

      .cancel:
        dropi 2
        pushi 2
        jmpi .read_char

      .backspace:
        peeki b, 4

        cmpi b, 0
        jmpi .read_char

        subi b, 1
        pokeir 4, b

        movi b, mmio.write_char
        stoi b, char.bs

        jmpi .read_char

    .enter:
      movi b, mmio.write_char
      stoi b, char.lf

      peeki b, 4
      jeqi b, 1, .end

      ; otherwise, set to default
      peeki b, 8
      dropi 2
      push b

    .end:
      pop a
      dropi 2
      reti 2
end macro

