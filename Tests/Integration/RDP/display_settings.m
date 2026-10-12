#import <Foundation/Foundation.h>
#define REFIID WINPR_REFIID
#import "RDPDisplay.h"
int main(void) {
    @autoreleasepool {
        NSDictionary *primary = @{
            @"x" : @0,
            @"y" : @0,
            @"width" : @1280,
            @"height" : @720,
            @"primary" : @1,
            @"scale" : @200,
            @"physicalWidth" : @300,
            @"physicalHeight" : @200,
            @"orientation" : @0
        };
        NSMutableDictionary *left = [primary mutableCopy];
        left[@"x"] = @(-800);
        left[@"width"] = @800;
        left[@"height"] = @600;
        left[@"primary"] = @0;
        left[@"scale"] = @100;
        rdpSettings *settings = freerdp_settings_new(0);
        assert(FCConfigureMonitorDefinitions(settings, @[ primary, left ]));
        assert(freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) == 2080);
        assert(freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight) == 720);
        assert(freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount) == 2);
        assert(freerdp_settings_get_bool(settings, FreeRDP_UseMultimon));
        assert(freerdp_settings_get_bool(settings, FreeRDP_SupportMonitorLayoutPdu));
        assert(!freerdp_settings_get_bool(settings, FreeRDP_SpanMonitors));
        assert(freerdp_settings_get_bool(settings, FreeRDP_HasMonitorAttributes));
        const rdpMonitor *p = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 0);
        const rdpMonitor *l = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 1);
        assert(p->is_primary && p->x == 0 && p->attributes.desktopScaleFactor == 200 &&
               p->attributes.deviceScaleFactor == 100);
        assert(l->x == -800 && l->attributes.desktopScaleFactor == 100);
        printf("PASS native separate monitor settings, signed origins, per-monitor DPI and valid device scale\n");
        assert(FCConfigureMonitorDefinitions(settings, @[ primary ]));
        assert(!freerdp_settings_get_bool(settings, FreeRDP_UseMultimon));
        assert(!freerdp_settings_get_bool(settings, FreeRDP_SupportMonitorLayoutPdu));
        assert(freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) == 1280);
        assert(freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight) == 720);
        assert(freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor) == 200);
        printf(
            "PASS single-monitor full screen retains resolution and Retina without requiring a Monitor Layout reply\n");
        rdpMonitor monitors[16];
        UINT32 w, h;
        for (NSDictionary *change in @[
                 @{@"width" : @801},
                 @{@"x" : @(-799)},
                 @{@"x" : @(-900)},
                 @{@"scale" : @501},
                 @{@"primary" : @1},
                 @{@"height" : @100},
                 @{@"width" : @800.5},
                 @{@"orientation" : @45}
             ]) {
            NSMutableDictionary *bad = [left mutableCopy];
            [bad addEntriesFromDictionary:change];
            assert(!FCReadMonitorDefinitions(@[ primary, bad ], monitors, &w, &h));
        }
        assert(!FCReadMonitorDefinitions(@[], monitors, &w, &h));
        NSMutableArray *tooMany = [NSMutableArray new];
        for (int i = 0; i < 17; i++)
            [tooMany addObject:primary];
        assert(!FCReadMonitorDefinitions(tooMany, monitors, &w, &h));
        printf("PASS native layout rejects overlap, gaps, invalid geometry, scale, primary and oversized lists\n");
        assert(FCDisplayAreaAllowed(1, 1280 * 720, 2, 2048, 2048));
        assert(!FCDisplayAreaAllowed(3, 1280 * 720, 2, 2048, 2048));
        assert(!FCDisplayAreaAllowed(1, 1280 * 720, 1, 200, 200));
        assert(!FCDisplayAreaAllowed(1, 100, UINT32_MAX, UINT32_MAX, UINT32_MAX));
        assert(!FCDisplayAreaAllowed(1, 100, 0, 0, 0));
        printf("PASS display capability count, area, missing caps and checked-overflow limits\n");
        freerdp_settings_free(settings);
    }
}
