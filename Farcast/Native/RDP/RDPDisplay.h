#import <Foundation/Foundation.h>
#import <freerdp/client/disp.h>
#import <freerdp/freerdp.h>
#import <math.h>

enum { FCDisplayMaximumDimension = 16384, FCDisplayMaximumPixels = 64 * 1024 * 1024 };

// Independently validated inputs; FreeRDP owns protocol serialization and settings storage.
static BOOL FCReadDisplayInteger(NSDictionary *value, NSString *key, NSInteger low, NSInteger high, NSInteger *out) {
    NSNumber *number = value[key];
    if (![number isKindOfClass:NSNumber.class] || !isfinite(number.doubleValue) || number.doubleValue < low ||
        number.doubleValue > high || number.doubleValue != number.integerValue)
        return NO;
    *out = number.integerValue;
    return YES;
}
static BOOL FCReadMonitorDefinitions(NSArray<NSDictionary *> *definitions, rdpMonitor monitors[16], UINT32 *width,
                                     UINT32 *height) {
    if (definitions.count < 1 || definitions.count > 16)
        return NO;
    NSInteger left = 0, top = 0, right = 0, bottom = 0;
    NSUInteger primaryCount = 0;
    for (NSUInteger i = 0; i < definitions.count; i++) {
        NSDictionary *d = definitions[i];
        if (![d isKindOfClass:NSDictionary.class])
            return NO;
        NSInteger x, y, w, h, primary, scale, physicalWidth, physicalHeight, orientation;
        if (!FCReadDisplayInteger(d, @"x", -16384, 16384, &x) || !FCReadDisplayInteger(d, @"y", -16384, 16384, &y) ||
            !FCReadDisplayInteger(d, @"width", 200, 8192, &w) || !FCReadDisplayInteger(d, @"height", 200, 8192, &h) ||
            w % 2 || !FCReadDisplayInteger(d, @"primary", 0, 1, &primary) ||
            !FCReadDisplayInteger(d, @"scale", 100, 500, &scale) ||
            !FCReadDisplayInteger(d, @"physicalWidth", 0, 10000, &physicalWidth) ||
            !FCReadDisplayInteger(d, @"physicalHeight", 0, 10000, &physicalHeight) ||
            !FCReadDisplayInteger(d, @"orientation", 0, 270, &orientation) || orientation % 90)
            return NO;
        if (primary && (x || y))
            return NO;
        primaryCount += primary;
        monitors[i] = (rdpMonitor){.x = (INT32)x,
                                   .y = (INT32)y,
                                   .width = (INT32)w,
                                   .height = (INT32)h,
                                   .is_primary = (UINT32)primary,
                                   .orig_screen = (UINT32)i,
                                   .attributes = {.physicalWidth = (UINT32)physicalWidth,
                                                  .physicalHeight = (UINT32)physicalHeight,
                                                  .orientation = (UINT32)orientation,
                                                  .desktopScaleFactor = (UINT32)scale,
                                                  .deviceScaleFactor = 100}};
        left = MIN(left, x);
        top = MIN(top, y);
        right = MAX(right, x + w);
        bottom = MAX(bottom, y + h);
        for (NSUInteger j = 0; j < i; j++) {
            rdpMonitor m = monitors[j];
            if (MAX(x, m.x) < MIN(x + w, m.x + m.width) && MAX(y, m.y) < MIN(y + h, m.y + m.height))
                return NO;
        }
    }
    if (primaryCount != 1 || right - left > FCDisplayMaximumDimension || bottom - top > FCDisplayMaximumDimension ||
        (UINT64)(right - left) * (bottom - top) > FCDisplayMaximumPixels)
        return NO;
    BOOL reached[16] = {YES};
    for (NSUInteger pass = 0; pass < definitions.count; pass++) {
        for (NSUInteger i = 0; i < definitions.count; i++) {
            for (NSUInteger j = 0; !reached[i] && j < definitions.count; j++) {
                rdpMonitor a = monitors[i], b = monitors[j];
                if (reached[j] && MAX(a.x, b.x) <= MIN(a.x + a.width, b.x + b.width) &&
                    MAX(a.y, b.y) <= MIN(a.y + a.height, b.y + b.height))
                    reached[i] = YES;
            }
        }
    }
    for (NSUInteger i = 0; i < definitions.count; i++)
        if (!reached[i])
            return NO;
    *width = (UINT32)(right - left);
    *height = (UINT32)(bottom - top);
    return YES;
}
static BOOL FCConfigureMonitorDefinitions(rdpSettings *settings, NSArray<NSDictionary *> *definitions) {
    if (!definitions.count)
        return YES;
    rdpMonitor monitors[16] = {0};
    UINT32 width = 0, height = 0;
    if (!FCReadMonitorDefinitions(definitions, monitors, &width, &height))
        return NO;
    return freerdp_settings_set_monitor_def_array_sorted(settings, monitors, definitions.count) &&
           freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, definitions.count > 1) &&
           freerdp_settings_set_bool(settings, FreeRDP_SpanMonitors, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_ForceMultimon, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_HasMonitorAttributes, TRUE) &&
           // A single desktop needs only effective graphics dimensions. Requesting
           // a Monitor Layout reply makes FreeRDP wait for a PDU some hosts omit
           // when multimon is off, preventing activation even at ordinary sizes.
           freerdp_settings_set_bool(settings, FreeRDP_SupportMonitorLayoutPdu, definitions.count > 1) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor,
                                       monitors[0].attributes.desktopScaleFactor) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, 100);
}
static BOOL FCDisplayAreaAllowed(UINT32 count, UINT64 area, UINT32 maximumCount, UINT32 factorA, UINT32 factorB) {
    if (!count || count > 16 || !maximumCount || count > maximumCount || !factorA || !factorB)
        return NO;
    if ((UINT64)maximumCount > UINT64_MAX / factorA || (UINT64)maximumCount * factorA > UINT64_MAX / factorB)
        return NO;
    return area <= (UINT64)maximumCount * factorA * factorB;
}
