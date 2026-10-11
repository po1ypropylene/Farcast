// Synthetic wire assertions inside the pinned FreeRDP sample peer. No host input or data.
static BOOL fc_fixture_display_check(rdpSettings *settings) {
    if (!getenv("FARCAST_FIXTURE_DISPLAY"))
        return TRUE;
    if (freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount) <= 1) {
        if (freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) == 1280 &&
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight) == 720 &&
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor) == 200 &&
            freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor) == 100)
            fprintf(stderr, "PASS display wire Retina core geometry and scale\n");
        return TRUE;
    }
    if (freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount) != 2 ||
        freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) != 2080 ||
        freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight) != 720)
        return FALSE;
    const rdpMonitor *primary = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 0);
    const rdpMonitor *left = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 1);
    if (!primary || !left || !primary->is_primary || primary->x || primary->y || primary->width != 1280 ||
        primary->height != 720 || left->is_primary || left->x != -800 || left->y || left->width != 800 ||
        left->height != 600 || primary->attributes.desktopScaleFactor != 200 ||
        left->attributes.desktopScaleFactor != 100 || primary->attributes.deviceScaleFactor != 100 ||
        left->attributes.deviceScaleFactor != 100)
        return FALSE;
    fprintf(stderr, "PASS display wire monitor definitions and mixed DPI\n");
    return TRUE;
}
static void fc_fixture_display_pointer(rdpInput *input, UINT16 x, UINT16 y) {
    if (!getenv("FARCAST_FIXTURE_DISPLAY") ||
        freerdp_settings_get_uint32(input->context->settings, FreeRDP_MonitorCount) != 2)
        return;
    if (x == 50 && y == 50)
        fprintf(stderr, "PASS display wire left-monitor pointer\n");
    if (x == 900 && y == 100)
        fprintf(stderr, "PASS display wire primary-monitor pointer\n");
}
