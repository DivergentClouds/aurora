include '../tundra-extra.inc'

macro define_streql
  ; streql(str1: [*:0], str2: [*:0]) bool
  streql:
    .check:
      peeki a, 4
      movb a, *a

      peeki b, 6
      movb b, *b

      jeqpri a, b, .char_eql
      jmpi .not_equal

      .char_eql:
        jeqpi b, 0, .equal   ; str1[i] == str2[i], both are positive or 0

        movi b, 4
        peek a, b
        addi a, 1
        poke b, a

        movi b, 6
        peek a, b
        addi a, 1
        poke b, a

        jmpi .check

    .not_equal:
      movi a, 0
      jmpi .exit

    .equal:
      movi a, 1
    .exit:
      reti 4
end macro


