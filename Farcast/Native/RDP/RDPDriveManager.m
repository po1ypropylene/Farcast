#import "RDPDrive.h"
#define REFIID WINPR_REFIID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <freerdp/addin.h>
#import <freerdp/channels/rdpdr.h>
#import <freerdp/client/channels.h>
#import <freerdp/freerdp.h>
#pragma clang diagnostic pop

// FreeRDP device registration, bookmark configuration and provider lifecycle.
// Filesystem requests remain in the independently owned FCRDPDrive backend.
static NSMutableDictionary *registry(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      table = [NSMutableDictionary new];
    });
    return table;
}
typedef struct {
    DEVICE device;
    void *backend;
    void *queue;
    char *name;
} FCDriveDevice;
static UINT deviceRequest(DEVICE *device, IRP *irp) {
    FCDriveDevice *d = (void *)device;
    FCRDPDrive *backend = (__bridge FCRDPDrive *)d->backend;
    dispatch_async((__bridge dispatch_queue_t)d->queue, ^{
      [backend processIRP:irp];
    });
    return CHANNEL_RC_OK;
}
static UINT deviceFree(DEVICE *device) {
    FCDriveDevice *d = (void *)device;
    FCRDPDrive *backend = (__bridge_transfer FCRDPDrive *)d->backend;
    dispatch_queue_t queue = (__bridge_transfer dispatch_queue_t)d->queue;
    dispatch_sync(queue, ^{
      [backend shutdown];
    });
    Stream_Free(device->data, TRUE);
    free(d->name);
    free(d);
    return CHANNEL_RC_OK;
}
static UINT driveEntry(DEVICE_SERVICE_ENTRY_POINTS *ep) {
    RDPDR_DRIVE *drive = (void *)ep->device;
    NSString *deviceName = ep->device->Name ? [NSString stringWithUTF8String:ep->device->Name] : nil;
    NSString *path = drive->Path ? [NSString stringWithUTF8String:drive->Path] : nil;
    if (!deviceName || !path)
        return ERROR_INVALID_DATA;
    NSDictionary *config;
    @synchronized(registry()) {
        config = registry()[[NSString stringWithFormat:@"%p|%@|%@", ep->rdpcontext->settings, deviceName, path]];
    }
    if (!config)
        return ERROR_ACCESS_DENIED;
    FCRDPDrive *backend = [[FCRDPDrive alloc] initWithURL:config[@"url"] readOnly:[config[@"readOnly"] boolValue]];
    if (!backend)
        return ERROR_ACCESS_DENIED;
    FCDriveDevice *d = calloc(1, sizeof(*d));
    if (!d)
        return CHANNEL_RC_NO_MEMORY;
    d->name = strdup([config[@"shortName"] UTF8String]);
    d->device.name = d->name;
    d->device.type = RDPDR_DTYP_FILESYSTEM;
    d->device.IRPRequest = deviceRequest;
    d->device.Free = deviceFree;
    // Windows App and FreeRDP encode the full drive name as terminated UTF-8.
    // UTF-16 introduces embedded zero bytes that Windows can treat as a short name.
    NSData *name = [[config[@"name"] stringByAppendingString:[NSString stringWithCharacters:(unichar[]){0} length:1]]
        dataUsingEncoding:NSUTF8StringEncoding];
    d->device.data = Stream_New(NULL, name.length);
    if (!d->device.data || !d->name) {
        Stream_Free(d->device.data, TRUE);
        free(d->name);
        free(d);
        return CHANNEL_RC_NO_MEMORY;
    }
    Stream_Write(d->device.data, name.bytes, name.length);
    d->backend = (__bridge_retained void *)backend;
    d->queue = (__bridge_retained void *)dispatch_queue_create("Farcast.RDP.Folder", DISPATCH_QUEUE_SERIAL);
    UINT status = ep->RegisterDevice(ep->devman, &d->device);
    if (status)
        deviceFree(&d->device);
    return status;
}
static PVIRTUALCHANNELENTRY addin(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags) {
    if (name && type && !strcmp(name, "drive") && !strcmp(type, "DeviceServiceEntry"))
        return (PVIRTUALCHANNELENTRY)driveEntry;
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}
@implementation FCRDPDriveManager {
    NSMutableArray<NSString *> *_tokens;
}
+ (void)registerProvider {
    (void)freerdp_register_addin_provider(addin, 0);
}
- (instancetype)init {
    if ((self = [super init]))
        _tokens = [NSMutableArray new];
    return self;
}
- (BOOL)configure:(NSArray<NSDictionary *> *)folders settings:(rdpSettings *)settings {
    if (folders.count > 16)
        return NO;
    NSMutableSet *names = [NSMutableSet new];
    for (NSDictionary *folder in folders) {
        NSString *name = folder[@"name"];
        NSData *bookmark = folder[@"bookmark"];
        BOOL stale = NO;
        if (![name isKindOfClass:NSString.class] || !name.length || name.length > 32 ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|"]]
                    .location != NSNotFound ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [name isEqual:@"."] || [name isEqual:@".."] || [name hasSuffix:@"."] || [name hasSuffix:@" "] ||
            [names containsObject:name.precomposedStringWithCanonicalMapping.lowercaseString] ||
            ![bookmark isKindOfClass:NSData.class] || !bookmark.length)
            return NO;
        [names addObject:name.precomposedStringWithCanonicalMapping.lowercaseString];
        NSURL *url = [NSURL
            URLByResolvingBookmarkData:bookmark
                               options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
                         relativeToURL:nil
                   bookmarkDataIsStale:&stale
                                 error:NULL];
        if (!url || stale)
            return NO;
        FCRDPDrive *probe = [[FCRDPDrive alloc] initWithURL:url readOnly:[folder[@"readOnly"] ?: @YES boolValue]];
        if (!probe)
            return NO;
        [probe shutdown];
        NSString *token = [NSString stringWithFormat:@"%p|%@|%@", settings, name, url.path];
        @synchronized(registry()) {
            registry()[token] = @{
                @"url" : url,
                @"name" : name,
                @"readOnly" : folder[@"readOnly"] ?: @YES,
                @"shortName" : [NSString stringWithFormat:@"Mac%02lu", (unsigned long)_tokens.count + 1]
            };
        }
        [_tokens addObject:token];
        const char *args[] = {name.UTF8String, url.fileSystemRepresentation};
        RDPDR_DEVICE *device = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, 2, args);
        if (!device)
            return NO;
        if (!freerdp_device_collection_add(settings, device)) {
            freerdp_device_free(device);
            return NO;
        }
    }
    // Explicit devices only: RedirectDrives would also add a wildcard export.
    freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectHomeDrive, FALSE);
    if (folders.count)
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, TRUE);
    return YES;
}
- (void)close {
    @synchronized(registry()) {
        for (NSString *token in _tokens)
            [registry() removeObjectForKey:token];
    }
    [_tokens removeAllObjects];
}
- (void)dealloc {
    [self close];
}
@end
