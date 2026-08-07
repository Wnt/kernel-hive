/*
 * QNX Neutrino 6.5 devi input module for the gallery-hid-pci v1 transport.
 *
 * Role: ABSOLUTE POINTER only (keyboard stays on the QEMU PS/2 / stock devi
 * kbd line, exactly like the Solaris port).  This is the QNX analogue of
 * streamhost/guest-agents/solaris-galleryhid/galleryhid.c: it attaches to the
 * gallery-hid-pci device (PCI 1b36:0015), maps BAR0 (control regs) + BAR2
 * (8 KiB ring), performs the DRIVER_READY / epoch handshake, attaches the
 * level-triggered INTA, drains 16-byte POINTER_ABS_STATE records on interrupt,
 * and injects each as an ABSOLUTE Photon pointer event.
 *
 * The injection uses the devi ABS FILTER path proven in the de-risk spike:
 * this module is a combined DEVICE+PROTOCOL module of class DEVI_CLASS_ABS; it
 * fills a `struct packet_abs` (screen-pixel x,y + button bitmap, proximity/z
 * asserted so hovering position updates move the cursor) and hands it UP to the
 * stock `abs` filter, which translates to screen coordinates and injects the
 * absolute Ph_ev_ptr event.  Load with:
 *
 *     devi-hirun galleryhid abs -c        # -c / identity calib: coords are px
 *
 * The spike framebuffer-proved this exact abs-filter path tracks absolute X AND
 * Y (four corners + centre exact, click hit-tests at the correct Y, drag) using
 * the stock devi-elo test vehicle; this module replaces the Elo serial front end
 * with the gallery-hid PCI ring.  See README.md.
 *
 * ---------------------------------------------------------------------------
 * BUILD: cross-compile with a licensed QNX 6.5 SDP toolchain plus the separate
 * Input DDK.  The clone has neither qcc nor <devi.h>.  This source therefore
 * has not been compiled or loaded; reconcile it with the DDK's shipped sample
 * module before treating it as production code.  See README.md.
 * ---------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <inttypes.h>
#include <sys/mman.h>
#include <sys/neutrino.h>
#include <hw/inout.h>
#include <hw/pci.h>

/* Input DDK framework header (not part of the base QNX 6.5 SDP). */
#include <devi.h>

/* ---- gallery-hid v1 ABI (authoritative copy of gallery-hid-proto.h) ------ */
#define GHID_PCI_VENDOR_ID       0x1b36
#define GHID_PCI_DEVICE_ID       0x0015
#define GHID_BAR0_SIZE           0x1000
#define GHID_BAR2_SIZE           0x2000

#define GHID_REG_DEVICE_MAGIC    0x000
#define GHID_REG_ABI_VERSION     0x004
#define GHID_REG_FEATURES        0x008
#define GHID_REG_STATUS          0x00c
#define GHID_REG_IRQ_STATUS      0x010
#define GHID_REG_IRQ_MASK        0x014
#define GHID_REG_IRQ_ACK         0x018
#define GHID_REG_DRIVER_READY    0x01c
#define GHID_REG_GUEST_KICK      0x020

#define GHID_DEVICE_MAGIC        0x44494847U   /* 'GHID' */
#define GHID_ABI_VERSION         0x00010000U
#define GHID_FEATURES            0x0000000fU
#define GHID_IRQ_RING            (1U << 0)
#define GHID_IRQ_RESET           (1U << 1)
#define GHID_IRQ_LINK            (1U << 2)
#define GHID_IRQ_ALL             0x00000007U

#define GHID_RING_MAGIC          0x4e494c47U   /* 'GLIN' */
#define GHID_HEADER_SIZE         0x0100
#define GHID_RECORD_SIZE         16
#define GHID_RING_ENTRIES        256
#define GHID_RING_MASK           255
#define GHID_RING_OFF_MAGIC      0x000
#define GHID_RING_OFF_MAJOR      0x004
#define GHID_RING_OFF_HDR_BYTES  0x008
#define GHID_RING_OFF_REC_BYTES  0x00a
#define GHID_RING_OFF_ENTRIES    0x00c
#define GHID_RING_OFF_FEATURES   0x010
#define GHID_RING_OFF_EPOCH      0x014
#define GHID_RING_OFF_PRODUCER   0x040
#define GHID_RING_OFF_CONSUMER   0x080
#define GHID_RING_OFF_LAST_EPOCH 0x084
#define GHID_RING_OFF_RECORDS    0x100

#define GHID_EVENT_POINTER_ABS   0x01
#define GHID_EVENT_KEY           0x02
#define GHID_EVENT_RELEASE_ALL   0x03
#define GHID_BUTTON_COUNT        3

/* Default Photon framebuffer for the QNX tile.  Override with `-r WxH` (parm).
 * Coordinates are scaled here to pixels so the abs filter can run with `-c`
 * (identity calibration).  gallery-hid axes are normalised 0..32767. */
#define GHID_DEFAULT_W           1024
#define GHID_DEFAULT_H           768

/* ---- module private state ------------------------------------------------ */
typedef struct ghid_ctx {
    void             *pci_hdl;        /* pci_attach_device handle            */
    volatile uint8_t *bar0;           /* control regs (mmap_device_memory)   */
    volatile uint8_t *bar2;           /* 8 KiB ring                          */
    int               irq;            /* INTA vector                         */
    int               iid;            /* InterruptAttachEvent id             */
    struct sigevent   isr_event;      /* pulse/intr event                    */
    pthread_t         isr_tid;
    pthread_mutex_t   init_lock;
    pthread_cond_t    init_cv;
    int               init_done;
    int               init_rc;
    int               init_errno;
    int               thread_started;
    volatile int      running;
    uint32_t          epoch;
    uint16_t          buttons;
    int               last_x;
    int               last_y;
    int               screen_w;
    int               screen_h;
    input_module_t   *self;           /* back-pointer for the up-call        */
    unsigned long     events;
    unsigned long     ring_irqs;
} ghid_ctx_t;

static ghid_ctx_t ghid;   /* single instance (one device per tile) */

/* ---- little-endian MMIO helpers (x86 target: direct volatile access) ----- */
static inline uint32_t reg_rd(uint32_t off)
{
    return *(volatile uint32_t *)(ghid.bar0 + off);
}
static inline void reg_wr(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(ghid.bar0 + off) = v;
}
static inline uint8_t ring_rd8(uint32_t off)
{
    return *(volatile uint8_t *)(ghid.bar2 + off);
}
static inline uint16_t ring_rd16(uint32_t off)
{
    return *(volatile uint16_t *)(ghid.bar2 + off);
}
static inline uint32_t ring_rd32(uint32_t off)
{
    return *(volatile uint32_t *)(ghid.bar2 + off);
}
static inline void ring_wr32(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(ghid.bar2 + off) = v;
}

static int ghid_header_valid(void)
{
    uint32_t producer = ring_rd32(GHID_RING_OFF_PRODUCER);
    uint32_t consumer = ring_rd32(GHID_RING_OFF_CONSUMER);

    return reg_rd(GHID_REG_DEVICE_MAGIC) == GHID_DEVICE_MAGIC &&
           reg_rd(GHID_REG_ABI_VERSION) == GHID_ABI_VERSION &&
           (reg_rd(GHID_REG_FEATURES) & GHID_FEATURES) == GHID_FEATURES &&
           ring_rd32(GHID_RING_OFF_MAGIC) == GHID_RING_MAGIC &&
           ring_rd16(GHID_RING_OFF_MAJOR) == 1 &&
           ring_rd16(GHID_RING_OFF_HDR_BYTES) == GHID_HEADER_SIZE &&
           ring_rd16(GHID_RING_OFF_REC_BYTES) == GHID_RECORD_SIZE &&
           ring_rd16(GHID_RING_OFF_ENTRIES) == GHID_RING_ENTRIES &&
           (ring_rd32(GHID_RING_OFF_FEATURES) & GHID_FEATURES) ==
               GHID_FEATURES &&
           (uint32_t)(producer - consumer) <= GHID_RING_ENTRIES;
}

/* value in 0..32767 -> 0..(size-1), rounded (identical to Solaris port). */
static int ghid_map_coord(uint16_t value, int size)
{
    uint64_t scaled;
    if (size <= 1)
        return 0;
    scaled = (uint64_t)value * (uint64_t)(size - 1) + 16383U;
    return (int)(scaled / 32767U);
}

/*
 * Hand one absolute sample UP to the `abs` filter.
 *
 * The devi protocol->filter hand-off: fill a `struct packet_abs` (buttons, x, y,
 * pressure/z, timestamp) and pass it to the up module's input entry.  On QNX 6.5
 * the documented primitive is the up module's `input` callback. packet_abs carries a
 * proximity/pressure field: we assert it on every sample so the filter treats
 * each position update as a live coordinate and moves the cursor even while
 * hovering (buttons==0) — gallery-hid streams hovering absolute position, unlike
 * a contact-only touch panel.  Framebuffer-verified: status=3 (stream, no
 * button) moves the Photon cursor with the abs filter.
 */
static void ghid_send_abs(int px, int py, uint16_t buttons)
{
    struct packet_abs pkt;
    input_module_t *up = ghid.self ? ghid.self->up : NULL;

    if (up == NULL)
        return;

    memset(&pkt, 0, sizeof(pkt));
    pkt.buttons = buttons & ((1U << GHID_BUTTON_COUNT) - 1);
    pkt.x       = (unsigned short)px;
    pkt.y       = (unsigned short)py;
    pkt.z       = 1;                 /* proximity/pressure asserted (hover)   */
    pkt.timestamp = clk_get();

    /* Pass the packet up to the abs filter's input handler. */
    (*up->input)(up, 1, &pkt);
    ghid.last_x = px;
    ghid.last_y = py;
    ghid.events++;
}

/* Drain all ready ring records and inject them.  Mirrors the Solaris ISR. */
static void ghid_drain_ring(void)
{
    uint8_t  rec[GHID_RECORD_SIZE];
    uint32_t producer, consumer, avail, off, i, j, drained = 0;

    do {
        producer = ring_rd32(GHID_RING_OFF_PRODUCER);
        consumer = ring_rd32(GHID_RING_OFF_CONSUMER);
        avail = producer - consumer;
        if (avail > GHID_RING_ENTRIES) {         /* corrupt: resync */
            ring_wr32(GHID_RING_OFF_CONSUMER, producer);
            break;
        }
        if (avail > GHID_RING_ENTRIES - drained)
            avail = GHID_RING_ENTRIES - drained;

        for (i = 0; i < avail; i++) {
            off = GHID_RING_OFF_RECORDS +
                  ((consumer & GHID_RING_MASK) * GHID_RECORD_SIZE);
            for (j = 0; j < GHID_RECORD_SIZE; j++)
                rec[j] = ring_rd8(off + j);

            if (rec[0] == GHID_EVENT_POINTER_ABS) {
                uint16_t rx = (uint16_t)(rec[4] | (rec[5] << 8));
                uint16_t ry = (uint16_t)(rec[6] | (rec[7] << 8));
                uint16_t bt = (uint16_t)(rec[8] | (rec[9] << 8));
                if (rx <= 32767 && ry <= 32767) {
                    ghid.buttons = bt;
                    ghid_send_abs(ghid_map_coord(rx, ghid.screen_w),
                                  ghid_map_coord(ry, ghid.screen_h), bt);
                }
            } else if (rec[0] == GHID_EVENT_RELEASE_ALL) {
                if (ghid.buttons) {
                    ghid.buttons = 0;
                    /* Re-send the last position with all buttons up. */
                    ghid_send_abs(ghid.last_x, ghid.last_y, 0);
                }
            }
            consumer++;
        }
        drained += avail;
        ring_wr32(GHID_RING_OFF_CONSUMER, consumer);
        reg_wr(GHID_REG_GUEST_KICK, 1);
        reg_wr(GHID_REG_IRQ_ACK, GHID_IRQ_RING);
    } while (ring_rd32(GHID_RING_OFF_PRODUCER) != consumer &&
             drained < GHID_RING_ENTRIES);
}

/* Backend hello / reset: re-arm the ring at the current producer + epoch. */
static void ghid_rearm(void)
{
    uint32_t epoch, producer;

    reg_wr(GHID_REG_IRQ_MASK, 0);
    if (!ghid_header_valid())
        return;
    epoch    = ring_rd32(GHID_RING_OFF_EPOCH);
    producer = ring_rd32(GHID_RING_OFF_PRODUCER);
    if (epoch == 0)
        return;
    ghid.epoch   = epoch;
    ghid.buttons = 0;
    ring_wr32(GHID_RING_OFF_CONSUMER, producer);
    ring_wr32(GHID_RING_OFF_LAST_EPOCH, epoch);
    reg_wr(GHID_REG_DRIVER_READY, epoch);
    reg_wr(GHID_REG_IRQ_ACK, GHID_IRQ_ALL);
    reg_wr(GHID_REG_IRQ_MASK, GHID_IRQ_ALL);
}

/* Dedicated interrupt-handler thread: InterruptWait -> drain -> unmask.
 * (A private thread avoids relying on devi's pulse-registration internals;
 * it only touches module->up via ghid_send_abs, which the framework allows.) */
static void *ghid_isr_thread(void *arg)
{
    (void)arg;
    /* QNX requires the InterruptWait thread itself to attach the event. */
    ghid.init_rc = -1;
    if (ThreadCtl(_NTO_TCTL_IO, 0) == 0) {
        SIGEV_INTR_INIT(&ghid.isr_event);
        ghid.iid = InterruptAttachEvent(ghid.irq, &ghid.isr_event,
                    _NTO_INTR_FLAGS_TRK_MSK | _NTO_INTR_FLAGS_END);
        if (ghid.iid != -1) {
            ghid_rearm();
            ghid.init_rc = 0;
        }
    }
    if (ghid.init_rc != 0)
        ghid.init_errno = errno;

    pthread_mutex_lock(&ghid.init_lock);
    ghid.init_done = 1;
    pthread_cond_signal(&ghid.init_cv);
    pthread_mutex_unlock(&ghid.init_lock);

    if (ghid.init_rc != 0)
        return NULL;

    while (ghid.running) {
        uint32_t status, handled;
        if (InterruptWait(0, NULL) == -1)
            continue;
        status  = reg_rd(GHID_REG_IRQ_STATUS);
        handled = status & reg_rd(GHID_REG_IRQ_MASK) & GHID_IRQ_ALL;
        if (handled & (GHID_IRQ_RESET | GHID_IRQ_LINK)) {
            ghid_rearm();
        } else if (handled & GHID_IRQ_RING) {
            ghid.ring_irqs++;
            ghid_drain_ring();
        }
        reg_wr(GHID_REG_IRQ_ACK, handled & ~GHID_IRQ_RING);
        (void)reg_rd(GHID_REG_IRQ_STATUS);   /* flush posted writes */
        InterruptUnmask(ghid.irq, ghid.iid);
    }
    return NULL;
}

/* ---- PCI attach + BAR map ------------------------------------------------- */
static int ghid_hw_attach(void)
{
    struct pci_dev_info info;
    void *hdl;
    uint64_t bar0_base, bar2_base;
    unsigned flags;

    if (pci_attach(0) < 0) {
        fprintf(stderr, "galleryhid: pci_attach failed: %s\n", strerror(errno));
        return -1;
    }
    memset(&info, 0, sizeof(info));
    info.VendorId = GHID_PCI_VENDOR_ID;
    info.DeviceId = GHID_PCI_DEVICE_ID;
    hdl = pci_attach_device(NULL, PCI_SEARCH_VENDEV | PCI_INIT_ALL |
                            PCI_MASTER_ENABLE,
                            0, &info);
    if (hdl == NULL) {
        fprintf(stderr, "galleryhid: gallery-hid-pci (1b36:0015) not found\n");
        return -1;
    }
    ghid.pci_hdl = hdl;

    /* BAR0 = CpuBaseAddress[0] (mem), BAR2 = CpuBaseAddress[2]. */
    bar0_base = PCI_MEM_ADDR(info.CpuBaseAddress[0]);
    bar2_base = PCI_MEM_ADDR(info.CpuBaseAddress[2]);
    ghid.irq  = info.Irq;

    flags = PROT_READ | PROT_WRITE | PROT_NOCACHE;
    ghid.bar0 = mmap_device_memory(NULL, GHID_BAR0_SIZE, flags, 0, bar0_base);
    ghid.bar2 = mmap_device_memory(NULL, GHID_BAR2_SIZE, flags, 0, bar2_base);
    if (ghid.bar0 == MAP_FAILED || ghid.bar2 == MAP_FAILED) {
        fprintf(stderr, "galleryhid: mmap_device_memory failed: %s\n",
                strerror(errno));
        return -1;
    }

    reg_wr(GHID_REG_IRQ_MASK, 0);
    if (!ghid_header_valid()) {
        fprintf(stderr, "galleryhid: ABI validation failed "
                "(magic=0x%x abi=0x%x ring=0x%x)\n",
                reg_rd(GHID_REG_DEVICE_MAGIC), reg_rd(GHID_REG_ABI_VERSION),
                ring_rd32(GHID_RING_OFF_MAGIC));
        return -1;
    }

    /* Validate the live epoch before the interrupt thread attaches and arms. */
    ghid.epoch = ring_rd32(GHID_RING_OFF_EPOCH);
    if (ghid.epoch == 0) {
        fprintf(stderr, "galleryhid: zero epoch, backend not connected\n");
        return -1;
    }
    ghid.iid = -1;
    pthread_mutex_init(&ghid.init_lock, NULL);
    pthread_cond_init(&ghid.init_cv, NULL);
    ghid.init_done = 0;
    ghid.init_rc = -1;
    ghid.init_errno = 0;
    ghid.running = 1;
    if (pthread_create(&ghid.isr_tid, NULL, ghid_isr_thread, NULL) != 0) {
        fprintf(stderr, "galleryhid: pthread_create(isr) failed\n");
        ghid.running = 0;
        return -1;
    }
    ghid.thread_started = 1;
    pthread_mutex_lock(&ghid.init_lock);
    while (!ghid.init_done)
        pthread_cond_wait(&ghid.init_cv, &ghid.init_lock);
    pthread_mutex_unlock(&ghid.init_lock);
    if (ghid.init_rc != 0) {
        fprintf(stderr, "galleryhid: InterruptAttachEvent(%d) failed: %s\n",
                ghid.irq, strerror(ghid.init_errno));
        ghid.running = 0;
        pthread_join(ghid.isr_tid, NULL);
        ghid.thread_started = 0;
        return -1;
    }
    fprintf(stderr, "galleryhid: attached irq=%d epoch=%u res=%dx%d\n",
            ghid.irq, ghid.epoch, ghid.screen_w, ghid.screen_h);
    return 0;
}

/* ================= devi module glue ======================================= */

static int ghid_parm(input_module_t *module, int opt, char *arg)
{
    /* Accept "-r WxH" to override the framebuffer size (coords are scaled to
     * pixels here so the abs filter runs with -c / identity calibration). */
    (void)module;
    if (opt == 'r' && arg != NULL) {
        int w, h;
        if (sscanf(arg, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
            ghid.screen_w = w;
            ghid.screen_h = h;
        }
    }
    return 0;
}

static int ghid_init(input_module_t *module)
{
    ghid.self = module;
    if (ghid.screen_w == 0) ghid.screen_w = GHID_DEFAULT_W;
    if (ghid.screen_h == 0) ghid.screen_h = GHID_DEFAULT_H;
    ThreadCtl(_NTO_TCTL_IO, 0);
    return ghid_hw_attach();
}

static int ghid_reset(input_module_t *module)
{
    (void)module;
    ghid_rearm();
    return 0;
}

static int ghid_shutdown(input_module_t *module, int delay)
{
    (void)module; (void)delay;
    ghid.running = 0;
    if (ghid.bar0 != NULL && ghid.bar0 != MAP_FAILED)
        reg_wr(GHID_REG_IRQ_MASK, 0);
    if (ghid.iid != -1)
        InterruptDetach(ghid.iid);
    if (ghid.thread_started) {
        pthread_cancel(ghid.isr_tid); /* InterruptWait is a cancellation point */
        pthread_join(ghid.isr_tid, NULL);
        ghid.thread_started = 0;
    }
    return 0;
}

/*
 * The field names and callback signatures below follow the published QNX 6.5
 * Input DDK documentation.  Confirm the exported symbol convention and build
 * flags against the DDK's sample module before loading this unbuilt source.
 */
input_module_t input_module = {
    .up       = NULL,
    .down     = NULL,
    .line     = NULL,
    .flags    = 0,
    .type     = DEVI_CLASS_ABS | DEVI_MODULE_TYPE_DEVICE |
                DEVI_MODULE_TYPE_PROTO,
    .name     = "galleryhid",
    .date     = __DATE__,
    .args     = "r:",
    .data     = NULL,
    .init     = ghid_init,
    .reset    = ghid_reset,
    .input    = NULL,
    .output   = NULL,
    .pulse    = NULL,       /* private InterruptWait thread */
    .parm     = ghid_parm,
    .devctrl  = NULL,
    .shutdown = ghid_shutdown,
};
