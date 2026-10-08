OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { SRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8K }
__stack_top = 0x80001fc0;
SECTIONS {
  /DISCARD/ : { *(.note*) *(.comment) *(.riscv.attributes) }
  .text : { *(.text.init) *(.text .text.*) } > SRAM
  .rodata : { . = ALIGN(4); *(.rodata .rodata.*) } > SRAM
  .data : { . = ALIGN(4); *(.data .data.*) } > SRAM
  .bss : {
    . = ALIGN(4); _bss_start = .;
    *(.bss .bss.*) *(COMMON)
    . = ALIGN(4); _bss_end = .;
  } > SRAM
  ASSERT(_bss_end <= 0x80001bc0, "Program overlaps 1KB stack reservation")
}
