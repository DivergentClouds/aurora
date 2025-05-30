include '../tundra-extra.inc'
include './aurora-utils.inc'

; write the contents of disk 1 to `/boot/kernel` on disk 0
; checks to make sure a valid file system is present on disk 0

_start:
  stack_init

  pushi strings.welcome
  calli puts

  movi a, mmio.storage_count
  mov a, *a
  cmpi a, 1
  jmpi .missing_storage_error

  .get_length:
    pushi strings.ask_length
    calli puts

    pushi data.length_str
    calli read_hex_u16

    cmpi a, 0
    jmpi .get_length
    
    cmpi a, 0x4000
    jmpi .confirm_length

    jmpi .get_length

  .confirm_length:
    push a

    pushi strings.confirm
    calli puts

    pushi 0
    calli read_ync

    cmpi a, 0
    jmpi .get_length

    cmpi a, 1
    calli write_kernel ; length is still on stack

    jmpi .exit

  .exit:
    halt

  .missing_storage_error:
    pushi strings.error_missing_storage
    calli puts

    jmpi .exit

  .bad_filesystem_error:
    pushi strings.error_bad_filesystem
    calli puts

    jmpi .exit

; returns 0 if there is an issue with the filesystem
; the issue can be either a bad superblock or too few free data blocks
; write_kernel(length: usize) bool
write_kernel:
  reti 2

; returns 0 if superblock is invalid
; verify_superblock(superblock_address: usize) bool
verify_superblock:
  reti 2

; free_previous_kernel(
free_previous_kernel:
  reti 4

define_div_ceil
define_read_hex_u16
define_read_ync
define_puts

strings:
  .welcome: db 'Welcome to the kernel writing tool for Aurora', char.cr, char.lf, 0

  .ask_length: db 'How many bytes long is the kernel in hexadecimal? (1-4000): ', 0

  .confirm: db 'Write the contents of storage device 1 to storage device 0 as the kernel? (y/N/c): ', 0

  .finished: db 'Finished writing kernel', char.cr, char.lf, 0

  .error_missing_storage: db 'ERROR: too few storage devices attached', char.cr, char.lf, 0

  .error_bad_filesystem: db 'ERROR: invalid file system state', char.cr, char.lf, 0

data:
  .length_str: db 5 dup 0

