// license:BSD-3-Clause
// copyright-holders:osgallery lab
/***************************************************************************

    ctlsock.h — mamectl: compiled-in guest-control module (osgallery #45)

    Unconditional module bring-up, called once per running_machine from the
    end of osd_common_t::init (src/osd/modules/lib/osdobj_common.cpp), which
    executes inside machine_phase::INIT — before save registration closes
    (machine.cpp:372), so the module's one persistent timer and its notifier
    subscriptions are legal there (proven, Stage-0 V4).

    Only the socket LISTENER (and with it the legacy command-file tail) is
    env-gated on MAME_CTL_SOCK. The module object, its persistent timer and
    its notifiers are created whether or not the env is set: that is the
    unconditional-timer rule — enabled and disabled arms share ONE savestate
    signature, so one binary and one golden serve both A/B arms and every
    rollback tier (proven empirically, Stage-0 V4: cross-loads in both
    directions succeed).

    The two engraved covenants live at the top of ctlsock.cpp.

***************************************************************************/
#ifndef MAME_OSD_CTLSOCK_CTLSOCK_H
#define MAME_OSD_CTLSOCK_CTLSOCK_H

#pragma once

class running_machine;

void ctlsock_init(running_machine &machine);

#endif // MAME_OSD_CTLSOCK_CTLSOCK_H
