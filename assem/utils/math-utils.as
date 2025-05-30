include '../tundra-extra.inc'

; TODO: fix numerator > denominator case, optimize (see div_floor)
macro define_div_ceil
  ; assumes numerator > denominator, denominator != 0
  ; div_ceil(numerator: u16, denominator: u16) u16
  div_ceil:
    peeki a, 6
    push a    ; count
    pushi 0   ; result

    .loop:
      peeki a, 4  ; count
      peeki b, 8  ; denominator
      sub a, b
      pokeir 4, a

      pop b
      addi b, 1
      push b

      peeki b, 10

      jlequri b, a, .loop
    
    pop a
    dropi 2
    reti 4
end macro

macro define_div_floor
  ; div_floor(numerator: u16, denominator: u16) u16
  div_floor:
    peeki a, 6  ; peek numerator into a as counter
    pushi 0     ; result

    .loop:
      peeki b, 6        ; denominator
      jgturi b, a, .end ; if denominator > counter, end

      sub a, b          ; counter -= denominator

      pop b
      addi b, 1
      push b

      jmpi .loop

    .end:
      pop a
      reti 4
end macro

macro define_div_floor_rem
  ; works like div_floor but also calculates remainder
  ; div_floor_rem(numerator: u16, denominator: u16, mod_result: *u16) u16
  div_floor_rem:
    peeki a, 8  ; peek numerator into a as counter
    pushi 0     ; result

    .loop:
      peeki b, 8        ; denominator
      jgturi b, a, .end ; if denominator > counter, end

      sub a, b          ; counter -= denominator

      pop b
      addi b, 1
      push b

      jmpi .loop

    .end:
      sub b, a
      peeki a, 6
      sto a, b

      pop a
      reti 6
end macro
