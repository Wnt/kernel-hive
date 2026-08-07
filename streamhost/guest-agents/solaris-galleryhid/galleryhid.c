/*
 * Solaris 10 VUID pointer driver for the gallery-hid-pci v1 transport.
 *
 * The proven diagnostic BAR2/INTA drain is retained.  Pointer-state records
 * are additionally translated to Solaris Firm_event records and delivered
 * through a direct STREAMS mouse minor for Xorg's VUID mouse backend.
 */

#include <sys/types.h>
#include <sys/conf.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/ddi_intr.h>
#include <sys/pci.h>
#include <sys/stream.h>
#include <sys/stropts.h>
#include <sys/strsun.h>
#include <sys/vuid_event.h>
#include <sys/vuid_wheel.h>
#include <sys/msio.h>
#include <sys/time.h>
#include <sys/modctl.h>
#include <sys/stat.h>
#include <sys/cmn_err.h>
#include <sys/atomic.h>
#include <sys/errno.h>
#include <sys/systm.h>

#define GHID_NAME                       "galleryhid"

/* gallery-hid-proto.h v1 constants (the QEMU header is authoritative). */
#define GHID_BAR0_SIZE                  0x1000
#define GHID_BAR2_SIZE                  0x2000
#define GHID_REG_DEVICE_MAGIC           0x000
#define GHID_REG_ABI_VERSION            0x004
#define GHID_REG_FEATURES               0x008
#define GHID_REG_STATUS                 0x00c
#define GHID_REG_IRQ_STATUS             0x010
#define GHID_REG_IRQ_MASK               0x014
#define GHID_REG_IRQ_ACK                0x018
#define GHID_REG_DRIVER_READY           0x01c
#define GHID_REG_GUEST_KICK             0x020
#define GHID_DEVICE_MAGIC               0x44494847U
#define GHID_ABI_VERSION                0x00010000U
#define GHID_FEATURES                   0x0000000fU
#define GHID_IRQ_RING                   (1U << 0)
#define GHID_IRQ_RESET                  (1U << 1)
#define GHID_IRQ_LINK                   (1U << 2)
#define GHID_IRQ_ALL                    0x00000007U
#define GHID_RING_MAGIC                 0x4e494c47U
#define GHID_HEADER_SIZE                0x0100
#define GHID_RECORD_SIZE                16
#define GHID_RING_ENTRIES               256
#define GHID_RING_MASK                  255
#define GHID_RING_OFF_MAGIC             0x000
#define GHID_RING_OFF_MAJOR             0x004
#define GHID_RING_OFF_MINOR             0x006
#define GHID_RING_OFF_HDR_BYTES         0x008
#define GHID_RING_OFF_REC_BYTES         0x00a
#define GHID_RING_OFF_ENTRIES           0x00c
#define GHID_RING_OFF_FEATURES          0x010
#define GHID_RING_OFF_EPOCH             0x014
#define GHID_RING_OFF_PRODUCER          0x040
#define GHID_RING_OFF_CONSUMER          0x080
#define GHID_RING_OFF_LAST_EPOCH        0x084
#define GHID_RING_OFF_RECORDS           0x100
#define GHID_EVENT_POINTER_ABS          0x01
#define GHID_EVENT_KEY                  0x02
#define GHID_EVENT_RELEASE_ALL          0x03
#define GHID_BUTTON_COUNT               3
#define GHID_MAX_VUID_EVENTS            6
#define GHID_IOC_GETSTRUCT              1
#define GHID_IOC_GETRESULT              2

#ifndef GHID_DEBUG_LOG
#define GHID_DEBUG_LOG                  0
#endif

typedef struct ghid_iocstate {
        uint_t                  stage;
        caddr_t                 user_addr;
} ghid_iocstate_t;

typedef struct ghid_state {
        dev_info_t              *dip;
        int                     instance;
        caddr_t                 bar0;
        caddr_t                 bar2;
        ddi_acc_handle_t        bar0_handle;
        ddi_acc_handle_t        bar2_handle;
        ddi_acc_handle_t        pci_handle;
        uint16_t                saved_pci_command;
        ddi_intr_handle_t       intr_handle;
        boolean_t               intr_added;
        boolean_t               intr_enabled;
        kmutex_t                lock;
        boolean_t               lock_init;
        queue_t                 *readq;
        int                     vuid_format;
        short                   vuid_addr;
        int                     screen_width;
        int                     screen_height;
        uint16_t                buttons;
        uint32_t                wheel_state;
        boolean_t               abs_type_sent;
        uint32_t                epoch;
        uint16_t                last_sequence;
        boolean_t               have_sequence;
        unsigned long           isr_count;
        unsigned long           ring_irq_count;
        unsigned long           event_count;
        unsigned long           invalid_count;
        unsigned long           sequence_faults;
        unsigned long           vuid_event_count;
        unsigned long           vuid_drop_count;
} ghid_state_t;

static ghid_state_t *ghid_device;

static uint_t ghid_intr(caddr_t, caddr_t);
static int ghid_attach(dev_info_t *, ddi_attach_cmd_t);
static int ghid_detach(dev_info_t *, ddi_detach_cmd_t);
static int ghid_getinfo(dev_info_t *, ddi_info_cmd_t, void *, void **);
static void ghid_ioctl(queue_t *, mblk_t *);
static void ghid_iocdata(queue_t *, mblk_t *);
static void ghid_emit_pointer_locked(ghid_state_t *, const uint8_t *);
static void ghid_emit_release_locked(ghid_state_t *);

static int
ghid_open(queue_t *rq, dev_t *devp, int oflag, int sflag, cred_t *credp)
{
        ghid_state_t *state = ghid_device;

        (void)devp;
        (void)oflag;
        (void)credp;
        if (sflag != 0 || state == NULL)
                return (ENXIO);
        if (rq->q_ptr != NULL)
                return (0);
        mutex_enter(&state->lock);
        if (state->readq != NULL) {
                mutex_exit(&state->lock);
                return (EBUSY);
        }
        rq->q_ptr = state;
        WR(rq)->q_ptr = state;
        state->readq = rq;
        state->vuid_format = VUID_FIRM_EVENT;
        state->vuid_addr = VKEY_FIRST;
        state->buttons = 0;
        state->wheel_state = VUID_WHEEL_STATE_ENABLED;
        state->abs_type_sent = B_FALSE;
        mutex_exit(&state->lock);
        qprocson(rq);
        cmn_err(CE_NOTE, "galleryhid%d: mouse open resolution=%dx%d",
            state->instance, state->screen_width, state->screen_height);
        return (0);
}

static int
ghid_close(queue_t *rq, int flag, cred_t *credp)
{
        ghid_state_t *state = (ghid_state_t *)rq->q_ptr;

        (void)flag;
        (void)credp;
        mutex_enter(&state->lock);
        if (state->readq == rq)
                state->readq = NULL;
        state->buttons = 0;
        mutex_exit(&state->lock);
        qprocsoff(rq);
        rq->q_ptr = NULL;
        WR(rq)->q_ptr = NULL;
        return (0);
}

static int
ghid_wput(queue_t *wq, mblk_t *mp)
{
        switch (mp->b_datap->db_type) {
        case M_FLUSH:
                if (*mp->b_rptr & FLUSHW)
                        flushq(wq, FLUSHDATA);
                if (*mp->b_rptr & FLUSHR) {
                        flushq(RD(wq), FLUSHDATA);
                        *mp->b_rptr &= ~FLUSHW;
                        qreply(wq, mp);
                        return (0);
                }
                freemsg(mp);
                return (0);
        case M_IOCTL:
                ghid_ioctl(wq, mp);
                return (0);
        case M_IOCDATA:
                ghid_iocdata(wq, mp);
                return (0);
        default:
                freemsg(mp);
                return (0);
        }
}

static void
ghid_firm_event(mblk_t *mp, ushort_t id, uchar_t pair_type, uchar_t pair,
    int value, const timespec_t *now)
{
        Firm_event *event = (Firm_event *)mp->b_wptr;

        event->id = id;
        event->pair_type = pair_type;
        event->pair = pair;
        event->value = value;
        event->time.tv_sec = (time32_t)now->tv_sec;
        event->time.tv_usec = (int32_t)(now->tv_nsec / 1000);
        mp->b_wptr += sizeof (*event);
}

static void
ghid_emit_abs_type_locked(ghid_state_t *state)
{
        mblk_t *mp;
        timespec_t now;

        if (state->readq == NULL || state->abs_type_sent)
                return;
        mp = allocb(sizeof (Firm_event), BPRI_HI);
        if (mp == NULL) {
                state->vuid_drop_count++;
                return;
        }
        gethrestime(&now);
        ghid_firm_event(mp, MOUSE_TYPE_ABSOLUTE, FE_PAIR_NONE, 0, 0, &now);
        state->abs_type_sent = B_TRUE;
        state->vuid_event_count++;
        putnext(state->readq, mp);
}

static int
ghid_map_coordinate(uint16_t value, int size)
{
        uint64_t scaled;

        if (size <= 1)
                return (0);
        scaled = (uint64_t)value * (uint64_t)(size - 1) + 16383U;
        return ((int)(scaled / 32767U));
}

static void
ghid_emit_pointer_locked(ghid_state_t *state, const uint8_t *record)
{
        static const ushort_t button_ids[GHID_BUTTON_COUNT] = {
                MS_LEFT, MS_MIDDLE, MS_RIGHT
        };
        mblk_t *mp;
        timespec_t now;
        uint16_t x;
        uint16_t y;
        uint16_t buttons;
        uint16_t changed;
        int wheel;
        int i;
        int count;

        if (state->readq == NULL || state->vuid_format != VUID_FIRM_EVENT ||
            state->screen_width <= 0 || state->screen_height <= 0)
                return;
        x = (uint16_t)(record[4] | (record[5] << 8));
        y = (uint16_t)(record[6] | (record[7] << 8));
        buttons = (uint16_t)(record[8] | (record[9] << 8));
        buttons &= (1U << GHID_BUTTON_COUNT) - 1;
        changed = (state->buttons ^ buttons) &
            ((1U << GHID_BUTTON_COUNT) - 1);
        wheel = (int)(int8_t)record[10];
        count = 2;
        for (i = 0; i < GHID_BUTTON_COUNT; i++) {
                if (changed & (1U << i))
                        count++;
        }
        if (wheel != 0 &&
            (state->wheel_state & VUID_WHEEL_STATE_ENABLED) != 0)
                count++;
        mp = allocb(count * sizeof (Firm_event), BPRI_HI);
        if (mp == NULL) {
                state->vuid_drop_count++;
                return;
        }
        gethrestime(&now);
        ghid_firm_event(mp, LOC_X_ABSOLUTE, FE_PAIR_DELTA,
            vuid_id_offset(LOC_X_DELTA),
            ghid_map_coordinate(x, state->screen_width), &now);
        ghid_firm_event(mp, LOC_Y_ABSOLUTE, FE_PAIR_DELTA,
            vuid_id_offset(LOC_Y_DELTA),
            ghid_map_coordinate(y, state->screen_height), &now);
        for (i = 0; i < GHID_BUTTON_COUNT; i++) {
                if (changed & (1U << i)) {
                        ghid_firm_event(mp,
                            vuid_id_addr(state->vuid_addr) |
                            vuid_id_offset(button_ids[i]), FE_PAIR_NONE, 0,
                            (buttons & (1U << i)) ? VKEY_DOWN : VKEY_UP,
                            &now);
                }
        }
        if (wheel != 0 &&
            (state->wheel_state & VUID_WHEEL_STATE_ENABLED) != 0) {
                ghid_firm_event(mp, vuid_first(VUID_WHEEL), FE_PAIR_NONE,
                    0, wheel, &now);
        }
        state->buttons = buttons;
        state->vuid_event_count += count;
        putnext(state->readq, mp);
}

static void
ghid_emit_release_locked(ghid_state_t *state)
{
        static const ushort_t button_ids[GHID_BUTTON_COUNT] = {
                MS_LEFT, MS_MIDDLE, MS_RIGHT
        };
        mblk_t *mp;
        timespec_t now;
        int i;
        int count = 0;

        if (state->readq == NULL || state->vuid_format != VUID_FIRM_EVENT ||
            state->buttons == 0)
                return;
        for (i = 0; i < GHID_BUTTON_COUNT; i++) {
                if (state->buttons & (1U << i))
                        count++;
        }
        mp = allocb(count * sizeof (Firm_event), BPRI_HI);
        if (mp == NULL) {
                state->vuid_drop_count++;
                return;
        }
        gethrestime(&now);
        for (i = 0; i < GHID_BUTTON_COUNT; i++) {
                if (state->buttons & (1U << i)) {
                        ghid_firm_event(mp,
                            vuid_id_addr(state->vuid_addr) |
                            vuid_id_offset(button_ids[i]), FE_PAIR_NONE, 0,
                            VKEY_UP, &now);
                }
        }
        state->buttons = 0;
        state->vuid_event_count += count;
        putnext(state->readq, mp);
}

static void
ghid_ioc_ack(queue_t *wq, mblk_t *mp)
{
        struct iocblk *iocp = (struct iocblk *)mp->b_rptr;

        if (mp->b_cont != NULL) {
                freemsg(mp->b_cont);
                mp->b_cont = NULL;
        }
        iocp->ioc_count = 0;
        iocp->ioc_error = 0;
        iocp->ioc_rval = 0;
        mp->b_datap->db_type = M_IOCACK;
        mp->b_wptr = mp->b_rptr + sizeof (struct iocblk);
        qreply(wq, mp);
}

static void
ghid_ioc_error(queue_t *wq, mblk_t *mp, int error)
{
        struct iocblk *iocp = (struct iocblk *)mp->b_rptr;
        struct copyresp *resp = (struct copyresp *)mp->b_rptr;

        if (mp->b_datap->db_type == M_IOCDATA && resp->cp_private != NULL) {
                freemsg(resp->cp_private);
                resp->cp_private = NULL;
        }
        if (mp->b_cont != NULL) {
                freemsg(mp->b_cont);
                mp->b_cont = NULL;
        }
        iocp->ioc_count = 0;
        iocp->ioc_error = error;
        iocp->ioc_rval = -1;
        mp->b_datap->db_type = M_IOCNAK;
        mp->b_wptr = mp->b_rptr + sizeof (struct iocblk);
        qreply(wq, mp);
}

static int
ghid_reply_int(queue_t *wq, mblk_t *mp, int value)
{
        mblk_t *data = allocb(sizeof (int), BPRI_HI);

        if (data == NULL)
                return (ENOMEM);
        *(int *)data->b_wptr = value;
        data->b_wptr += sizeof (int);
        if (mp->b_cont != NULL)
                freemsg(mp->b_cont);
        mp->b_cont = data;
        miocack(wq, mp, sizeof (int), 0);
        return (0);
}

static caddr_t
ghid_transparent_addr(mblk_t *mp)
{
        if (mp->b_cont == NULL ||
            (size_t)MBLKL(mp->b_cont) < sizeof (caddr_t))
                return (NULL);
        return (*(caddr_t *)mp->b_cont->b_rptr);
}

static int
ghid_copyin(queue_t *wq, mblk_t *mp, size_t size)
{
        ghid_iocstate_t *iocstate;
        mblk_t *private;
        caddr_t addr = ghid_transparent_addr(mp);

        if (addr == NULL)
                return (EINVAL);
        private = allocb(sizeof (*iocstate), BPRI_HI);
        if (private == NULL)
                return (ENOMEM);
        iocstate = (ghid_iocstate_t *)private->b_wptr;
        iocstate->stage = GHID_IOC_GETSTRUCT;
        iocstate->user_addr = addr;
        private->b_wptr += sizeof (*iocstate);
        freemsg(mp->b_cont);
        mp->b_cont = NULL;
        mcopyin(mp, private, size, addr);
        qreply(wq, mp);
        return (0);
}

static int
ghid_copyout_int(queue_t *wq, mblk_t *mp, int value)
{
        mblk_t *data;
        caddr_t addr = ghid_transparent_addr(mp);

        if (addr == NULL)
                return (EINVAL);
        data = allocb(sizeof (int), BPRI_HI);
        if (data == NULL)
                return (ENOMEM);
        *(int *)data->b_wptr = value;
        data->b_wptr += sizeof (int);
        freemsg(mp->b_cont);
        mp->b_cont = NULL;
        mcopyout(mp, NULL, sizeof (int), addr, data);
        qreply(wq, mp);
        return (0);
}

static int
ghid_copyout_result(queue_t *wq, mblk_t *mp, size_t size)
{
        struct copyresp *resp = (struct copyresp *)mp->b_rptr;
        ghid_iocstate_t *iocstate;
        mblk_t *private = resp->cp_private;

        if (private == NULL || mp->b_cont == NULL ||
            (size_t)MBLKL(private) < sizeof (*iocstate) ||
            (size_t)MBLKL(mp->b_cont) < size)
                return (EINVAL);
        iocstate = (ghid_iocstate_t *)private->b_rptr;
        iocstate->stage = GHID_IOC_GETRESULT;
        mcopyout(mp, private, size, iocstate->user_addr, mp->b_cont);
        qreply(wq, mp);
        return (0);
}

static int
ghid_wheel_info(wheel_info *info)
{
        if (info->vers != VUID_WHEEL_INFO_VERS || info->id != 0)
                return (EINVAL);
        info->format = VUID_WHEEL_FORMAT_VERTICAL;
        return (0);
}

static int
ghid_wheel_state(ghid_state_t *state, wheel_state *wheel, boolean_t set)
{
        if (wheel->vers != VUID_WHEEL_STATE_VERS || wheel->id != 0)
                return (EINVAL);
        mutex_enter(&state->lock);
        if (set)
                state->wheel_state = wheel->stateflags &
                    VUID_WHEEL_STATE_ENABLED;
        else
                wheel->stateflags = state->wheel_state;
        mutex_exit(&state->lock);
        return (0);
}

static int
ghid_resolution(ghid_state_t *state, Ms_screen_resolution *resolution)
{
        if (resolution->width <= 0 || resolution->height <= 0 ||
            resolution->width > 32768 || resolution->height > 32768)
                return (EINVAL);
        mutex_enter(&state->lock);
        state->screen_width = resolution->width;
        state->screen_height = resolution->height;
        ghid_emit_abs_type_locked(state);
        mutex_exit(&state->lock);
        cmn_err(CE_NOTE, "galleryhid%d: MSIOSRESOLUTION width=%d height=%d",
            state->instance, resolution->width, resolution->height);
        return (0);
}

static void
ghid_ioctl(queue_t *wq, mblk_t *mp)
{
        ghid_state_t *state = (ghid_state_t *)wq->q_ptr;
        struct iocblk *iocp = (struct iocblk *)mp->b_rptr;
        Vuid_addr_probe *probe;
        int *format;
        int error = 0;

        if (state == NULL) {
                miocnak(wq, mp, 0, ENXIO);
                return;
        }
        switch (iocp->ioc_cmd) {
        case VUIDSFORMAT:
                error = miocpullup(mp, sizeof (int));
                if (error == 0) {
                        format = (int *)mp->b_cont->b_rptr;
                        if (*format != VUID_FIRM_EVENT)
                                error = EINVAL;
                        else {
                                mutex_enter(&state->lock);
                                state->vuid_format = *format;
                                mutex_exit(&state->lock);
                        }
                }
                break;
        case VUIDGFORMAT:
                error = ghid_reply_int(wq, mp, VUID_FIRM_EVENT);
                if (error == 0)
                        return;
                break;
        case VUIDSADDR:
        case VUIDGADDR:
                error = miocpullup(mp, sizeof (*probe));
                if (error != 0)
                        break;
                probe = (Vuid_addr_probe *)mp->b_cont->b_rptr;
                if (probe->base != VKEY_FIRST) {
                        error = ENODEV;
                        break;
                }
                mutex_enter(&state->lock);
                if (iocp->ioc_cmd == VUIDSADDR)
                        state->vuid_addr = probe->data.next;
                else
                        probe->data.current = state->vuid_addr;
                mutex_exit(&state->lock);
                break;
        case MSIOBUTTONS:
                error = ghid_reply_int(wq, mp, GHID_BUTTON_COUNT);
                if (error == 0)
                        return;
                break;
        case VUIDGWHEELCOUNT:
                if (iocp->ioc_count == TRANSPARENT) {
                        error = ghid_copyout_int(wq, mp, 1);
                        if (error == 0)
                                return;
                } else {
                        error = ghid_reply_int(wq, mp, 1);
                        if (error == 0)
                                return;
                }
                break;
        case VUIDGWHEELINFO:
        case VUIDGWHEELSTATE:
        case VUIDSWHEELSTATE:
        case MSIOSRESOLUTION:
                if (iocp->ioc_count == TRANSPARENT) {
                        if (iocp->ioc_cmd == VUIDGWHEELINFO)
                                error = ghid_copyin(wq, mp,
                                    sizeof (wheel_info));
                        else if (iocp->ioc_cmd == MSIOSRESOLUTION)
                                error = ghid_copyin(wq, mp,
                                    sizeof (Ms_screen_resolution));
                        else
                                error = ghid_copyin(wq, mp,
                                    sizeof (wheel_state));
                        if (error == 0)
                                return;
                        break;
                }
                if (iocp->ioc_cmd == VUIDGWHEELINFO) {
                        error = miocpullup(mp, sizeof (wheel_info));
                        if (error == 0)
                                error = ghid_wheel_info((wheel_info *)
                                    mp->b_cont->b_rptr);
                } else if (iocp->ioc_cmd == MSIOSRESOLUTION) {
                        error = miocpullup(mp,
                            sizeof (Ms_screen_resolution));
                        if (error == 0)
                                error = ghid_resolution(state,
                                    (Ms_screen_resolution *)
                                    mp->b_cont->b_rptr);
                } else {
                        error = miocpullup(mp, sizeof (wheel_state));
                        if (error == 0)
                                error = ghid_wheel_state(state,
                                    (wheel_state *)mp->b_cont->b_rptr,
                                    iocp->ioc_cmd == VUIDSWHEELSTATE);
                }
                break;
        default:
                miocnak(wq, mp, 0, ENOTTY);
                return;
        }
        if (error != 0)
                miocnak(wq, mp, 0, error);
        else
                miocack(wq, mp, iocp->ioc_cmd == VUIDGADDR ?
                    sizeof (Vuid_addr_probe) : 0, 0);
}

static void
ghid_iocdata(queue_t *wq, mblk_t *mp)
{
        ghid_state_t *state = (ghid_state_t *)wq->q_ptr;
        struct copyresp *resp = (struct copyresp *)mp->b_rptr;
        ghid_iocstate_t *iocstate;
        int error = 0;

        if (state == NULL || resp->cp_rval != NULL) {
                ghid_ioc_error(wq, mp, state == NULL ? ENXIO : EFAULT);
                return;
        }
        if (resp->cp_cmd == VUIDGWHEELCOUNT) {
                ghid_ioc_ack(wq, mp);
                return;
        }
        if (resp->cp_private == NULL ||
            (size_t)MBLKL(resp->cp_private) < sizeof (*iocstate)) {
                ghid_ioc_error(wq, mp, EINVAL);
                return;
        }
        iocstate = (ghid_iocstate_t *)resp->cp_private->b_rptr;
        if (iocstate->stage == GHID_IOC_GETRESULT) {
                freemsg(resp->cp_private);
                resp->cp_private = NULL;
                ghid_ioc_ack(wq, mp);
                return;
        }
        if (iocstate->stage != GHID_IOC_GETSTRUCT || mp->b_cont == NULL) {
                ghid_ioc_error(wq, mp, EINVAL);
                return;
        }
        switch (resp->cp_cmd) {
        case VUIDGWHEELINFO:
                if ((size_t)MBLKL(mp->b_cont) < sizeof (wheel_info))
                        error = EINVAL;
                else
                        error = ghid_wheel_info((wheel_info *)
                            mp->b_cont->b_rptr);
                if (error == 0) {
                        error = ghid_copyout_result(wq, mp,
                            sizeof (wheel_info));
                        if (error == 0)
                                return;
                }
                break;
        case VUIDGWHEELSTATE:
                if ((size_t)MBLKL(mp->b_cont) < sizeof (wheel_state))
                        error = EINVAL;
                else
                        error = ghid_wheel_state(state, (wheel_state *)
                            mp->b_cont->b_rptr, B_FALSE);
                if (error == 0) {
                        error = ghid_copyout_result(wq, mp,
                            sizeof (wheel_state));
                        if (error == 0)
                                return;
                }
                break;
        case VUIDSWHEELSTATE:
                if ((size_t)MBLKL(mp->b_cont) < sizeof (wheel_state))
                        error = EINVAL;
                else
                        error = ghid_wheel_state(state, (wheel_state *)
                            mp->b_cont->b_rptr, B_TRUE);
                if (error == 0) {
                        freemsg(resp->cp_private);
                        resp->cp_private = NULL;
                        ghid_ioc_ack(wq, mp);
                        return;
                }
                break;
        case MSIOSRESOLUTION:
                if ((size_t)MBLKL(mp->b_cont) <
                    sizeof (Ms_screen_resolution))
                        error = EINVAL;
                else
                        error = ghid_resolution(state,
                            (Ms_screen_resolution *)mp->b_cont->b_rptr);
                if (error == 0) {
                        freemsg(resp->cp_private);
                        resp->cp_private = NULL;
                        ghid_ioc_ack(wq, mp);
                        return;
                }
                break;
        default:
                error = EINVAL;
                break;
        }
        ghid_ioc_error(wq, mp, error == 0 ? EINVAL : error);
}

static struct module_info ghid_minfo = {
        0x4748, GHID_NAME, 0, INFPSZ, 2048, 128
};

static struct qinit ghid_rinit = {
        NULL, NULL, ghid_open, ghid_close, NULL, &ghid_minfo, NULL,
        NULL, NULL, STRUIOT_DONTCARE
};

static struct qinit ghid_winit = {
        ghid_wput, NULL, NULL, NULL, NULL, &ghid_minfo, NULL,
        NULL, NULL, STRUIOT_DONTCARE
};

static struct streamtab ghid_streamtab = {
        &ghid_rinit, &ghid_winit, NULL, NULL
};

DDI_DEFINE_STREAM_OPS(ghid_dev_ops, nulldev, nulldev, ghid_attach,
    ghid_detach, nodev, ghid_getinfo, D_MP, &ghid_streamtab);

static struct modldrv modldrv = {
        &mod_driverops, "gallery-hid v1 VUID pointer driver", &ghid_dev_ops
};

static struct modlinkage modlinkage = {
        MODREV_1, &modldrv, NULL
};

int
_init(void)
{
        return (mod_install(&modlinkage));
}

int
_fini(void)
{
        return (mod_remove(&modlinkage));
}

int
_info(struct modinfo *modinfop)
{
        return (mod_info(&modlinkage, modinfop));
}

static uint8_t
ghid_ring_get8(ghid_state_t *state, uint32_t offset)
{
        return (ddi_get8(state->bar2_handle,
            (uint8_t *)(state->bar2 + offset)));
}

static uint16_t
ghid_ring_get16(ghid_state_t *state, uint32_t offset)
{
        return (ddi_get16(state->bar2_handle,
            (uint16_t *)(state->bar2 + offset)));
}

static uint32_t
ghid_ring_get32(ghid_state_t *state, uint32_t offset)
{
        return (ddi_get32(state->bar2_handle,
            (uint32_t *)(state->bar2 + offset)));
}

static void
ghid_ring_put32(ghid_state_t *state, uint32_t offset, uint32_t value)
{
        ddi_put32(state->bar2_handle, (uint32_t *)(state->bar2 + offset),
            value);
}

static uint32_t
ghid_reg_get32(ghid_state_t *state, uint32_t offset)
{
        return (ddi_get32(state->bar0_handle,
            (uint32_t *)(state->bar0 + offset)));
}

static void
ghid_reg_put32(ghid_state_t *state, uint32_t offset, uint32_t value)
{
        ddi_put32(state->bar0_handle, (uint32_t *)(state->bar0 + offset),
            value);
}

static boolean_t
ghid_header_valid(ghid_state_t *state)
{
        uint32_t producer = ghid_ring_get32(state, GHID_RING_OFF_PRODUCER);
        uint32_t consumer = ghid_ring_get32(state, GHID_RING_OFF_CONSUMER);

        return (ghid_reg_get32(state, GHID_REG_DEVICE_MAGIC) ==
            GHID_DEVICE_MAGIC &&
            ghid_reg_get32(state, GHID_REG_ABI_VERSION) ==
            GHID_ABI_VERSION &&
            (ghid_reg_get32(state, GHID_REG_FEATURES) & GHID_FEATURES) ==
            GHID_FEATURES &&
            ghid_ring_get32(state, GHID_RING_OFF_MAGIC) == GHID_RING_MAGIC &&
            ghid_ring_get16(state, GHID_RING_OFF_MAJOR) == 1 &&
            ghid_ring_get16(state, GHID_RING_OFF_HDR_BYTES) ==
            GHID_HEADER_SIZE &&
            ghid_ring_get16(state, GHID_RING_OFF_REC_BYTES) ==
            GHID_RECORD_SIZE &&
            ghid_ring_get16(state, GHID_RING_OFF_ENTRIES) ==
            GHID_RING_ENTRIES &&
            (ghid_ring_get32(state, GHID_RING_OFF_FEATURES) &
            GHID_FEATURES) == GHID_FEATURES &&
            producer - consumer <= GHID_RING_ENTRIES);
}

static boolean_t
ghid_record_valid(const uint8_t record[GHID_RECORD_SIZE])
{
        uint16_t value16;
        uint32_t value32;

        switch (record[0]) {
        case GHID_EVENT_POINTER_ABS:
                value16 = (uint16_t)(record[4] | (record[5] << 8));
                if (record[1] != 0 || value16 > 32767)
                        return (B_FALSE);
                value16 = (uint16_t)(record[6] | (record[7] << 8));
                if (value16 > 32767)
                        return (B_FALSE);
                value16 = (uint16_t)(record[8] | (record[9] << 8));
                return ((value16 & ~0x1fU) == 0);
        case GHID_EVENT_KEY:
                value16 = (uint16_t)(record[4] | (record[5] << 8));
                value32 = (uint32_t)record[8] |
                    ((uint32_t)record[9] << 8) |
                    ((uint32_t)record[10] << 16) |
                    ((uint32_t)record[11] << 24);
                return ((record[1] & ~0x03U) == 0 &&
                    (value16 <= 0x007f ||
                    ((value16 & 0xff00) == 0xe000 &&
                    (value16 & 0xff) <= 0x7f) || value16 == 0xe145) &&
                    value32 == 0);
        case GHID_EVENT_RELEASE_ALL:
                value32 = (uint32_t)record[4] |
                    ((uint32_t)record[5] << 8) |
                    ((uint32_t)record[6] << 16) |
                    ((uint32_t)record[7] << 24) |
                    (uint32_t)record[8] |
                    ((uint32_t)record[9] << 8) |
                    ((uint32_t)record[10] << 16) |
                    ((uint32_t)record[11] << 24);
                return ((record[1] & ~0x07U) == 0 && value32 == 0);
        default:
                return (B_FALSE);
        }
}

static void
ghid_log_record(ghid_state_t *state, const uint8_t record[GHID_RECORD_SIZE],
    uint32_t producer, uint32_t consumer)
{
        uint16_t sequence = (uint16_t)(record[2] | (record[3] << 8));
#if GHID_DEBUG_LOG
        uint16_t a = (uint16_t)(record[4] | (record[5] << 8));
        uint16_t b = (uint16_t)(record[6] | (record[7] << 8));
        uint16_t c = (uint16_t)(record[8] | (record[9] << 8));
        uint32_t timestamp = (uint32_t)record[12] |
            ((uint32_t)record[13] << 8) |
            ((uint32_t)record[14] << 16) |
            ((uint32_t)record[15] << 24);
#else
        (void)producer;
        (void)consumer;
#endif

        if (state->have_sequence &&
            sequence != (uint16_t)(state->last_sequence + 1)) {
                state->sequence_faults++;
                cmn_err(CE_WARN, "galleryhid%d: sequence fault last=%u now=%u "
                    "faults=%lu", state->instance, state->last_sequence,
                    sequence, state->sequence_faults);
        }
        state->last_sequence = sequence;
        state->have_sequence = B_TRUE;
        state->event_count++;

#if GHID_DEBUG_LOG
        if (record[0] == GHID_EVENT_POINTER_ABS) {
                cmn_err(CE_NOTE, "galleryhid%d: record event=%lu irq=%lu "
                    "seq=%u type=pointer x=%u y=%u buttons=0x%x "
                    "wheel=%d hwheel=%d time=%u producer=%u consumer=%u",
                    state->instance, state->event_count,
                    state->ring_irq_count, sequence, a, b, c,
                    (int)(int8_t)record[10], (int)(int8_t)record[11],
                    timestamp, producer, consumer);
        } else if (record[0] == GHID_EVENT_KEY) {
                cmn_err(CE_NOTE, "galleryhid%d: record event=%lu irq=%lu "
                    "seq=%u type=key flags=0x%x key=0x%x modifiers=0x%x "
                    "time=%u producer=%u consumer=%u", state->instance,
                    state->event_count, state->ring_irq_count, sequence,
                    record[1], a, b, timestamp, producer, consumer);
        } else {
                cmn_err(CE_NOTE, "galleryhid%d: record event=%lu irq=%lu "
                    "seq=%u type=release-all flags=0x%x time=%u "
                    "producer=%u consumer=%u", state->instance,
                    state->event_count, state->ring_irq_count, sequence,
                    record[1], timestamp, producer, consumer);
        }
#endif
}

/*
 * Snapshot restore does not call DDI_RESUME.  A post-load backend hello raises
 * LINK while QEMU gates event frames; discard any pre-reconnect records,
 * release local button state, validate the restored generation, and re-arm.
 * The same path handles a real device reset/epoch change.
 */
static boolean_t
ghid_rearm(ghid_state_t *state)
{
        uint32_t epoch;
        uint32_t producer;

        ghid_reg_put32(state, GHID_REG_IRQ_MASK, 0);
        if (!ghid_header_valid(state)) {
                state->invalid_count++;
                cmn_err(CE_WARN, "galleryhid%d: cannot rearm invalid ABI/ring "
                    "invalid=%lu", state->instance, state->invalid_count);
                return (B_FALSE);
        }

        epoch = ghid_ring_get32(state, GHID_RING_OFF_EPOCH);
        producer = ghid_ring_get32(state, GHID_RING_OFF_PRODUCER);
        if (epoch == 0) {
                state->invalid_count++;
                cmn_err(CE_WARN, "galleryhid%d: cannot rearm zero epoch "
                    "invalid=%lu", state->instance, state->invalid_count);
                return (B_FALSE);
        }

        mutex_enter(&state->lock);
        ghid_emit_release_locked(state);
        mutex_exit(&state->lock);
        state->epoch = epoch;
        state->have_sequence = B_FALSE;
        ghid_ring_put32(state, GHID_RING_OFF_CONSUMER, producer);
        ghid_ring_put32(state, GHID_RING_OFF_LAST_EPOCH, epoch);
        membar_producer();
        ghid_reg_put32(state, GHID_REG_DRIVER_READY, epoch);
        ghid_reg_put32(state, GHID_REG_IRQ_ACK, GHID_IRQ_ALL);
        (void)ghid_ring_get32(state, GHID_RING_OFF_PRODUCER);
        ghid_reg_put32(state, GHID_REG_IRQ_MASK, GHID_IRQ_ALL);
#if GHID_DEBUG_LOG
        cmn_err(CE_NOTE, "galleryhid%d: rearmed epoch=%u producer=%u",
            state->instance, epoch, producer);
#endif
        return (B_TRUE);
}

static uint_t
ghid_intr(caddr_t arg1, caddr_t arg2)
{
        ghid_state_t *state = (ghid_state_t *)arg1;
        uint32_t status;
        uint32_t mask;
        uint32_t handled;
        uint32_t producer;
        uint32_t consumer;
        uint32_t available;
        uint32_t offset;
        uint32_t i;
        uint32_t j;
        uint32_t drained;
        uint32_t next_producer;
        uint8_t record[GHID_RECORD_SIZE];

        (void)arg2;
        status = ghid_reg_get32(state, GHID_REG_IRQ_STATUS);
        mask = ghid_reg_get32(state, GHID_REG_IRQ_MASK);
        handled = status & mask & GHID_IRQ_ALL;
        if (handled == 0)
                return (DDI_INTR_UNCLAIMED);

        state->isr_count++;
        if (handled & (GHID_IRQ_RESET | GHID_IRQ_LINK)) {
#if GHID_DEBUG_LOG
                cmn_err(CE_NOTE, "galleryhid%d: control irq status=0x%x "
                    "isr=%lu ring_irq=%lu events=%lu", state->instance,
                    handled, state->isr_count, state->ring_irq_count,
                    state->event_count);
#endif
                (void)ghid_rearm(state);
                return (DDI_INTR_CLAIMED);
        }

        if (handled & GHID_IRQ_RING) {
                state->ring_irq_count++;
                drained = 0;
                do {
                        producer = ghid_ring_get32(state,
                            GHID_RING_OFF_PRODUCER);
                        membar_consumer();
                        consumer = ghid_ring_get32(state,
                            GHID_RING_OFF_CONSUMER);
                        available = producer - consumer;
                        if (available > GHID_RING_ENTRIES) {
                                state->invalid_count++;
                                cmn_err(CE_WARN, "galleryhid%d: corrupt ring "
                                    "producer=%u consumer=%u invalid=%lu",
                                    state->instance, producer, consumer,
                                    state->invalid_count);
                                available = 0;
                                drained = GHID_RING_ENTRIES;
                        }
                        if (available > GHID_RING_ENTRIES - drained)
                                available = GHID_RING_ENTRIES - drained;
                        for (i = 0; i < available; i++) {
                                offset = GHID_RING_OFF_RECORDS +
                                    ((consumer & GHID_RING_MASK) *
                                    GHID_RECORD_SIZE);
                                for (j = 0; j < GHID_RECORD_SIZE; j++)
                                        record[j] = ghid_ring_get8(state,
                                            offset + j);
                                if (ghid_record_valid(record)) {
                                        ghid_log_record(state, record,
                                            producer, consumer);
                                        if (record[0] ==
                                            GHID_EVENT_POINTER_ABS) {
                                                mutex_enter(&state->lock);
                                                ghid_emit_pointer_locked(
                                                    state, record);
                                                mutex_exit(&state->lock);
                                        } else if (record[0] ==
                                            GHID_EVENT_RELEASE_ALL &&
                                            (record[1] & 0x01U) != 0) {
                                                mutex_enter(&state->lock);
                                                ghid_emit_release_locked(
                                                    state);
                                                mutex_exit(&state->lock);
                                        }
                                } else {
                                        state->invalid_count++;
                                        cmn_err(CE_WARN, "galleryhid%d: "
                                            "invalid record type=0x%x "
                                            "flags=0x%x invalid=%lu",
                                            state->instance, record[0],
                                            record[1], state->invalid_count);
                                }
                                consumer++;
                        }
                        drained += available;
                        ghid_ring_put32(state, GHID_RING_OFF_CONSUMER,
                            consumer);
                        membar_producer();
                        ghid_reg_put32(state, GHID_REG_GUEST_KICK, 1);
                        ghid_reg_put32(state, GHID_REG_IRQ_ACK,
                            GHID_IRQ_RING);
                        next_producer = ghid_ring_get32(state,
                            GHID_RING_OFF_PRODUCER);
                } while (next_producer != consumer &&
                    drained < GHID_RING_ENTRIES);
        }

        ghid_reg_put32(state, GHID_REG_IRQ_ACK, handled & ~GHID_IRQ_RING);
        (void)ghid_ring_get32(state, GHID_RING_OFF_PRODUCER);
        return (DDI_INTR_CLAIMED);
}

static void
ghid_cleanup(ghid_state_t *state)
{
        if (state == NULL)
                return;
        if (state->bar0_handle != NULL)
                ghid_reg_put32(state, GHID_REG_IRQ_MASK, 0);
        if (state->intr_enabled) {
                (void)ddi_intr_disable(state->intr_handle);
                state->intr_enabled = B_FALSE;
        }
        if (state->intr_added) {
                (void)ddi_intr_remove_handler(state->intr_handle);
                state->intr_added = B_FALSE;
        }
        if (state->intr_handle != NULL) {
                (void)ddi_intr_free(state->intr_handle);
                state->intr_handle = NULL;
        }
        ddi_remove_minor_node(state->dip, NULL);
        if (state->lock_init) {
                mutex_destroy(&state->lock);
                state->lock_init = B_FALSE;
        }
        if (state->bar2_handle != NULL)
                ddi_regs_map_free(&state->bar2_handle);
        if (state->bar0_handle != NULL)
                ddi_regs_map_free(&state->bar0_handle);
        if (state->pci_handle != NULL) {
                pci_config_put16(state->pci_handle, PCI_CONF_COMM,
                    state->saved_pci_command);
                pci_config_teardown(&state->pci_handle);
        }
}

static int
ghid_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
        ghid_state_t *state;
        ddi_device_acc_attr_t attr = {
                DDI_DEVICE_ATTR_V0,
                DDI_STRUCTURE_LE_ACC,
                DDI_STRICTORDER_ACC,
                DDI_DEFAULT_ACC
        };
        int nregs;
        int supported;
        int actual;
        int caps;
        uint_t priority;
        off_t bar0_size;
        off_t bar2_size;
        uint32_t producer;

        if (cmd != DDI_ATTACH || ghid_device != NULL)
                return (DDI_FAILURE);
        state = kmem_zalloc(sizeof (*state), KM_SLEEP);
        state->dip = dip;
        state->instance = ddi_get_instance(dip);
        state->screen_width = ddi_prop_get_int(DDI_DEV_T_ANY, dip,
            DDI_PROP_DONTPASS, "screen-width", 0);
        state->screen_height = ddi_prop_get_int(DDI_DEV_T_ANY, dip,
            DDI_PROP_DONTPASS, "screen-height", 0);
        if (state->screen_width < 0 || state->screen_width > 32768 ||
            state->screen_height < 0 || state->screen_height > 32768) {
                cmn_err(CE_WARN, "galleryhid%d: invalid fallback resolution "
                    "%dx%d", state->instance, state->screen_width,
                    state->screen_height);
                goto fail;
        }

        if (ddi_dev_nregs(dip, &nregs) != DDI_SUCCESS || nregs < 3 ||
            ddi_dev_regsize(dip, 1, &bar0_size) != DDI_SUCCESS ||
            ddi_dev_regsize(dip, 2, &bar2_size) != DDI_SUCCESS ||
            bar0_size != GHID_BAR0_SIZE || bar2_size != GHID_BAR2_SIZE) {
                cmn_err(CE_WARN, "galleryhid%d: bad register layout "
                    "nregs=%d bar0=%ld bar2=%ld", state->instance, nregs,
                    (long)bar0_size, (long)bar2_size);
                goto fail;
        }
        if (pci_config_setup(dip, &state->pci_handle) != DDI_SUCCESS)
                goto fail;
        state->saved_pci_command = pci_config_get16(state->pci_handle,
            PCI_CONF_COMM);
        pci_config_put16(state->pci_handle, PCI_CONF_COMM,
            state->saved_pci_command | PCI_COMM_MAE);

        if (ddi_regs_map_setup(dip, 1, &state->bar0, 0, GHID_BAR0_SIZE,
            &attr, &state->bar0_handle) != DDI_SUCCESS ||
            ddi_regs_map_setup(dip, 2, &state->bar2, 0, GHID_BAR2_SIZE,
            &attr, &state->bar2_handle) != DDI_SUCCESS) {
                cmn_err(CE_WARN, "galleryhid%d: BAR map failed",
                    state->instance);
                goto fail;
        }
        ghid_reg_put32(state, GHID_REG_IRQ_MASK, 0);
        if (!ghid_header_valid(state)) {
                cmn_err(CE_WARN, "galleryhid%d: ABI validation failed "
                    "devmagic=0x%x ringmagic=0x%x abi=0x%x",
                    state->instance,
                    ghid_reg_get32(state, GHID_REG_DEVICE_MAGIC),
                    ghid_ring_get32(state, GHID_RING_OFF_MAGIC),
                    ghid_reg_get32(state, GHID_REG_ABI_VERSION));
                goto fail;
        }
        if (ddi_intr_get_supported_types(dip, &supported) != DDI_SUCCESS ||
            (supported & DDI_INTR_TYPE_FIXED) == 0) {
                cmn_err(CE_WARN, "galleryhid%d: fixed INTA unavailable "
                    "types=0x%x", state->instance, supported);
                goto fail;
        }
        if (ddi_intr_alloc(dip, &state->intr_handle, DDI_INTR_TYPE_FIXED,
            0, 1, &actual, DDI_INTR_ALLOC_STRICT) != DDI_SUCCESS ||
            actual != 1)
                goto fail;
        if (ddi_intr_get_pri(state->intr_handle, &priority) != DDI_SUCCESS ||
            priority >= ddi_intr_get_hilevel_pri()) {
                cmn_err(CE_WARN, "galleryhid%d: unsupported high-level "
                    "interrupt priority=%u", state->instance, priority);
                goto fail;
        }
        mutex_init(&state->lock, NULL, MUTEX_DRIVER, DDI_INTR_PRI(priority));
        state->lock_init = B_TRUE;
        if (ddi_intr_get_cap(state->intr_handle, &caps) != DDI_SUCCESS)
                caps = 0;
        if (ddi_intr_add_handler(state->intr_handle, ghid_intr,
            (caddr_t)state, NULL) != DDI_SUCCESS)
                goto fail;
        state->intr_added = B_TRUE;

        producer = ghid_ring_get32(state, GHID_RING_OFF_PRODUCER);
        state->epoch = ghid_ring_get32(state, GHID_RING_OFF_EPOCH);
        if (state->epoch == 0)
                goto fail;
        ghid_ring_put32(state, GHID_RING_OFF_CONSUMER, producer);
        ghid_ring_put32(state, GHID_RING_OFF_LAST_EPOCH, state->epoch);
        membar_producer();
        ghid_reg_put32(state, GHID_REG_DRIVER_READY, state->epoch);
        ghid_reg_put32(state, GHID_REG_IRQ_ACK, GHID_IRQ_ALL);

        if (ddi_create_minor_node(dip, "diag", S_IFCHR, state->instance,
            DDI_PSEUDO, 0) != DDI_SUCCESS)
                goto fail;
        if (ddi_create_minor_node(dip, "mouse", S_IFCHR, state->instance,
            DDI_NT_MOUSE, 0) != DDI_SUCCESS)
                goto fail;
        if (ddi_intr_enable(state->intr_handle) != DDI_SUCCESS)
                goto fail;
        state->intr_enabled = B_TRUE;
        ghid_device = state;
        ddi_set_driver_private(dip, state);
        ghid_reg_put32(state, GHID_REG_IRQ_MASK, GHID_IRQ_ALL);
        ddi_report_dev(dip);
        cmn_err(CE_NOTE, "galleryhid%d: attached BAR0=rnumber1/%ld "
            "BAR2=rnumber2/%ld epoch=%u producer=%u fixed-pri=%u caps=0x%x "
            "resolution=%dx%d",
            state->instance, (long)bar0_size, (long)bar2_size, state->epoch,
            producer, priority, caps, state->screen_width,
            state->screen_height);
        return (DDI_SUCCESS);

fail:
        ghid_cleanup(state);
        kmem_free(state, sizeof (*state));
        return (DDI_FAILURE);
}

static int
ghid_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
        ghid_state_t *state = ddi_get_driver_private(dip);

        if (cmd != DDI_DETACH || state == NULL)
                return (DDI_FAILURE);
        ghid_device = NULL;
        ddi_set_driver_private(dip, NULL);
        ghid_cleanup(state);
        cmn_err(CE_NOTE, "galleryhid%d: detached isr=%lu ring_irq=%lu "
            "events=%lu invalid=%lu sequence_faults=%lu vuid=%lu drops=%lu",
            state->instance,
            state->isr_count, state->ring_irq_count, state->event_count,
            state->invalid_count, state->sequence_faults,
            state->vuid_event_count, state->vuid_drop_count);
        kmem_free(state, sizeof (*state));
        return (DDI_SUCCESS);
}

static int
ghid_getinfo(dev_info_t *dip, ddi_info_cmd_t cmd, void *arg, void **result)
{
        ghid_state_t *state = ghid_device;

        (void)dip;
        (void)arg;
        if (state == NULL)
                return (DDI_FAILURE);
        switch (cmd) {
        case DDI_INFO_DEVT2DEVINFO:
                *result = state->dip;
                return (DDI_SUCCESS);
        case DDI_INFO_DEVT2INSTANCE:
                *result = (void *)(uintptr_t)state->instance;
                return (DDI_SUCCESS);
        default:
                return (DDI_FAILURE);
        }
}
