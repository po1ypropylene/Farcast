#include <freerdp/server/disp.h>
#include <winpr/sysinfo.h>

// Owned synthetic Display Control peer. Library codecs serialize and parse actual PDUs.
struct fc_fixture_resize {
    DispServerContext *channel;
    CRITICAL_SECTION lock;
    DISPLAY_CONTROL_MONITOR_LAYOUT latest;
    BOOL pending, caps;
    UINT64 opened;
};
static UINT fc_fixture_resize_layout(DispServerContext *channel, const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU *pdu) {
    testPeerContext *peer = channel->custom;
    struct fc_fixture_resize *state = peer->fc_resize;
    if (pdu->NumMonitors != 1 || pdu->MonitorLayoutSize != 40)
        return ERROR_INVALID_DATA;
    const DISPLAY_CONTROL_MONITOR_LAYOUT *m = pdu->Monitors;
    if (m->Flags != DISPLAY_CONTROL_MONITOR_PRIMARY || m->Left || m->Top || m->Width < 200 || m->Width > 8192 ||
        m->Width % 2 || m->Height < 200 || m->Height > 8192 || m->DesktopScaleFactor < 100 ||
        m->DesktopScaleFactor > 500 ||
        (m->DeviceScaleFactor != 100 && m->DeviceScaleFactor != 140 && m->DeviceScaleFactor != 180))
        return ERROR_INVALID_DATA;
    EnterCriticalSection(&state->lock);
    state->latest = *m;
    state->pending = TRUE;
    LeaveCriticalSection(&state->lock);
    fprintf(stderr, "PASS resize wire %ux%u scale %u device %u\n", m->Width, m->Height, m->DesktopScaleFactor,
            m->DeviceScaleFactor);
    return CHANNEL_RC_OK;
}
static BOOL fc_fixture_resize_tick(testPeerContext *peer) {
    const char *mode = getenv("FARCAST_FIXTURE_RESIZE");
    if (!mode)
        return TRUE;
    if (!peer->fc_resize && WTSVirtualChannelManagerGetDrdynvcState(peer->vcm) == DRDYNVC_STATE_READY) {
        struct fc_fixture_resize *state = calloc(1, sizeof(*state));
        if (!state)
            return FALSE;
        InitializeCriticalSection(&state->lock);
        peer->fc_resize = state;
        state->channel = disp_server_context_new(peer->vcm);
        if (!state->channel)
            return FALSE;
        state->channel->custom = peer;
        state->channel->rdpcontext = (rdpContext *)peer;
        state->channel->DispMonitorLayout = fc_fixture_resize_layout;
        state->channel->MaxNumMonitors = 1;
        state->channel->MaxMonitorAreaFactorA = !strcmp(mode, "restricted") ? 640 : 8192;
        state->channel->MaxMonitorAreaFactorB = !strcmp(mode, "restricted") ? 480 : 8192;
        if (state->channel->Open(state->channel) != CHANNEL_RC_OK)
            return FALSE;
        state->opened = GetTickCount64();
    }
    struct fc_fixture_resize *state = peer->fc_resize;
    if (!state)
        return TRUE;
    if (!state->caps && GetTickCount64() - state->opened > 1000) {
        if (state->channel->DisplayControlCaps(state->channel) != CHANNEL_RC_OK)
            return FALSE;
        state->caps = TRUE;
    }
    DISPLAY_CONTROL_MONITOR_LAYOUT next;
    EnterCriticalSection(&state->lock);
    BOOL pending = state->pending;
    next = state->latest;
    state->pending = FALSE;
    LeaveCriticalSection(&state->lock);
    if (!pending || !strcmp(mode, "ignored"))
        return TRUE;
    rdpContext *context = (rdpContext *)peer;
    if (!freerdp_settings_set_uint32(context->settings, FreeRDP_DesktopWidth, next.Width) ||
        !freerdp_settings_set_uint32(context->settings, FreeRDP_DesktopHeight, next.Height) ||
        !rfx_context_reset(peer->rfx_context, next.Width, next.Height))
        return FALSE;
    peer->activated = FALSE;
    return context->update->DesktopResize(context);
}
static void fc_fixture_resize_stop(testPeerContext *peer) {
    struct fc_fixture_resize *state = peer->fc_resize;
    if (!state)
        return;
    if (state->channel)
        disp_server_context_free(state->channel);
    DeleteCriticalSection(&state->lock);
    free(state);
    peer->fc_resize = NULL;
}
