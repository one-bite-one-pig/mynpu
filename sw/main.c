#include "model_data.h"
#define NPU ((volatile unsigned int *)0x70000000u)
#define SRAM ((volatile unsigned int *)0x70004000u)
#define MAIL ((volatile unsigned int *)0x80001fc0u)
static volatile unsigned int irq_count;

static void barrier(void) { __asm__ volatile ("fence iorw, iorw" ::: "memory"); }
static void fail(unsigned int code) {
    MAIL[1] = code;
    barrier(); MAIL[0] = 0xdeadbeefu;
    for (;;) __asm__ volatile ("nop");
}

void __attribute__((interrupt("machine"), aligned(256))) npu_handler(void) {
    unsigned int cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x80000010u) fail(0x100u + cause);
    NPU[0] = 4u; /* clear DONE and disable interrupt */
    barrier();
    ++irq_count;
}

static void load_input(void) {
    for (unsigned int i=0; i<sizeof(model_input)/4; ++i)
        SRAM[INPUT_BASE/4+i] = model_input[i];
    barrier();
}

static void check_output(unsigned int run) {
    unsigned int best=0, bestval=0;
    for (unsigned int i=0; i<10; ++i) {
        unsigned int word = SRAM[OUTPUT_BASE/4+i/4];
        unsigned int q = (word >> ((i%4)*8)) & 255u;
        MAIL[4+i] = q;
        if (q != integer_output[i]) fail(0x200u + run*16u+i);
        int delta = (int)q-(int)pytorch_output[i];
        if (delta < -1 || delta > 1) fail(0x300u+run*16u+i);
        if (i==0 || q>bestval) { best=i; bestval=q; }
    }
    if (best != 2u) fail(0x400u+run);
    MAIL[2] = best;
    MAIL[3] = NPU[6];
}

int main(void) {
    MAIL[0] = 0x12345678u;
    for (unsigned int i=0; i<sizeof(model_params)/4; ++i) SRAM[i]=model_params[i];
    for (unsigned int i=0; i<sizeof(model_desc)/4; ++i) SRAM[DESC_BASE/4+i]=model_desc[i];
    barrier();
    NPU[4]=DESC_BASE; NPU[5]=6u;
    load_input();
    NPU[0]=5u; /* clear previous state + start, no IRQ */
    unsigned int limit=200000u, status=0;
    while (limit--) { status=NPU[1]; if (status & 6u) break; }
    if (!(status & 2u) || (status & 4u)) fail(1u);
    check_output(0u);
    NPU[0]=4u;
    if (NPU[1] & 2u) fail(2u);

    /* A second run tests rewritten input and an actual CPU interrupt handler. */
    load_input();
    unsigned int handler=(unsigned int)npu_handler;
    __asm__ volatile ("csrw mtvec, %0" :: "r"(handler));
    unsigned int irqmask=1u<<16;
    __asm__ volatile ("csrw mie, %0" :: "r"(irqmask));
    __asm__ volatile ("csrsi mstatus, 8");
    NPU[0]=3u;
    limit=200000u;
    while (limit-- && irq_count==0u) { __asm__ volatile ("nop"); }
    if (irq_count != 1u) fail(3u);
    check_output(1u);
    if (NPU[1] & 2u) fail(4u);
    __asm__ volatile ("csrci mstatus, 8");
    MAIL[14]=irq_count;
    barrier(); MAIL[0]=0xc0dec0deu;
    for (;;) __asm__ volatile ("nop");
}
