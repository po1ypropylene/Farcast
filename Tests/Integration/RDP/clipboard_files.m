#import "RDPClipboard.h"
#define REFIID WINPR_REFIID
#import <fcntl.h>
#import <freerdp/client/cliprdr.h>
#import <sys/stat.h>
#import <unistd.h>

static NSData *formatData, *fileData;
static UINT16 formatFlags, fileFlags;
static CLIPRDR_FILE_CONTENTS_REQUEST pending;
static NSMutableArray<NSValue *> *pendingRequests;
static UINT32 requestedFormat, advertised;
static NSUInteger checks;
static void check(BOOL value, const char *name) {
    if (!value) {
        fprintf(stderr, "FAIL RDP file clipboard: %s\n", name);
        exit(1);
    }
    checks++;
}
static UINT sendCaps(CliprdrClientContext *c, const CLIPRDR_CAPABILITIES *caps) { return 0; }
static UINT sendList(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *list) {
    advertised = list->numFormats;
    return 0;
}
static UINT ackList(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST_RESPONSE *v) { return 0; }
static UINT sendRequest(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *v) {
    requestedFormat = v->requestedFormatId;
    return 0;
}
static UINT sendResponse(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_RESPONSE *v) {
    formatFlags = v->common.msgFlags;
    formatData = [NSData dataWithBytes:v->requestedFormatData length:v->common.dataLen];
    return 0;
}
static UINT sendFileRequest(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_REQUEST *v) {
    pending = *v;
    [pendingRequests addObject:[NSValue valueWithBytes:v objCType:@encode(CLIPRDR_FILE_CONTENTS_REQUEST)]];
    return 0;
}
static UINT sendFileResponse(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_RESPONSE *v) {
    fileFlags = v->common.msgFlags;
    fileData = [NSData dataWithBytes:v->requestedData length:v->cbRequested];
    return 0;
}
static UINT sendLock(CliprdrClientContext *c, const CLIPRDR_LOCK_CLIPBOARD_DATA *v) { return 0; }
static UINT sendUnlock(CliprdrClientContext *c, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *v) { return 0; }
static void remoteFormat(CliprdrClientContext *c) {
    CLIPRDR_FORMAT format = {.formatId = 0xC321, .formatName = "FileGroupDescriptorW"};
    CLIPRDR_FORMAT_LIST list = {0};
    list.numFormats = 1;
    list.formats = &format;
    check(c->ServerFormatList(c, &list) == 0, "remote formats");
}
static void remoteDescriptors(CliprdrClientContext *c, NSData *bytes) {
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = (UINT32)bytes.length;
    response.requestedFormatData = bytes.bytes;
    check(c->ServerFormatDataResponse(c, &response) == 0, "remote descriptor response");
}
static NSData *descriptor(NSString *name, UINT32 attributes, uint64_t size) {
    FILEDESCRIPTORW d = {0};
    d.dwFlags = FD_ATTRIBUTES | FD_FILESIZE;
    d.dwFileAttributes = attributes;
    d.nFileSizeHigh = (UINT32)(size >> 32);
    d.nFileSizeLow = (UINT32)size;
    [name getCharacters:d.cFileName range:NSMakeRange(0, name.length)];
    BYTE *bytes = NULL;
    UINT32 length = 0;
    check(cliprdr_serialize_file_list_ex(CB_STREAM_FILECLIP_ENABLED | CB_HUGE_FILE_SUPPORT_ENABLED, &d, 1, &bytes,
                                         &length) == 0,
          "serialize fixture");
    NSData *result = [NSData dataWithBytes:bytes length:length];
    free(bytes);
    return result;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        NSURL *root = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSFileManager *fm = NSFileManager.defaultManager;
        pendingRequests = [NSMutableArray new];
        NSURL *tree = [root URLByAppendingPathComponent:@"Folder"];
        [fm createDirectoryAtURL:[tree URLByAppendingPathComponent:@"Nested"]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:NULL];
        NSMutableData *payload = [NSMutableData dataWithLength:700123];
        for (NSUInteger i = 0; i < payload.length; i++)
            ((BYTE *)payload.mutableBytes)[i] = (BYTE)(i * 31);
        NSURL *source = [tree URLByAppendingPathComponent:@"Nested/繁體😀.bin"];
        [payload writeToURL:source atomically:YES];
        [NSData.data writeToURL:[tree URLByAppendingPathComponent:@"Empty"] atomically:YES];
        CliprdrClientContext channel = {0};
        channel.ClientCapabilities = sendCaps;
        channel.ClientFormatList = sendList;
        channel.ClientFormatListResponse = ackList;
        channel.ClientFormatDataRequest = sendRequest;
        channel.ClientFormatDataResponse = sendResponse;
        channel.ClientFileContentsRequest = sendFileRequest;
        channel.ClientFileContentsResponse = sendFileResponse;
        channel.ClientLockClipboardData = sendLock;
        channel.ClientUnlockClipboardData = sendUnlock;
        FCRDPClipboard *bridge = [FCRDPClipboard new];
        [bridge attach:&channel];
        __block NSArray<NSURL *> *received;
        __block NSString *message;
        bridge.onFiles = ^(NSArray<NSURL *> *files) {
          received = files;
        };
        bridge.onProgress = ^(NSString *text) {
          message = text;
        };
        CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
        general.capabilitySetType = CB_CAPSTYPE_GENERAL;
        general.capabilitySetLength = 12;
        general.generalFlags = CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA | CB_HUGE_FILE_SUPPORT_ENABLED;
        CLIPRDR_CAPABILITIES caps = {0};
        caps.cCapabilitiesSets = 1;
        caps.capabilitySets = (void *)&general;
        channel.ServerCapabilities(&channel, &caps);
        [bridge setFiles:@[ tree ]];
        channel.MonitorReady(&channel, NULL);
        check(advertised == 2, "files queued before ready, copy effect advertised");
        CLIPRDR_FORMAT_DATA_REQUEST request = {0};
        request.requestedFormatId = 0xC001;
        channel.ServerFormatDataRequest(&channel, &request);
        check(formatFlags == CB_RESPONSE_OK, "outbound descriptors");
        NSData *descriptors = formatData;
        FILEDESCRIPTORW *entries = NULL;
        UINT32 count = 0;
        check(cliprdr_parse_file_list(descriptors.bytes, (UINT32)descriptors.length, &entries, &count) == 0 &&
                  count == 4,
              "nested and empty entries");
        UINT32 binaryIndex = 0;
        for (UINT32 i = 0; i < count; i++)
            if (entries[i].nFileSizeLow == payload.length)
                binaryIndex = i;
        CLIPRDR_LOCK_CLIPBOARD_DATA lock = {0};
        lock.clipDataId = 42;
        channel.ServerLockClipboardData(&channel, &lock);
        [bridge setText:@"new clipboard"];
        CLIPRDR_FILE_CONTENTS_REQUEST file = {0};
        file.haveClipDataId = TRUE;
        file.clipDataId = 42;
        file.listIndex = binaryIndex;
        file.dwFlags = FILECONTENTS_RANGE;
        file.nPositionLow = 123;
        file.cbRequested = 321;
        file.streamId = 7;
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_OK && [fileData isEqual:[payload subdataWithRange:NSMakeRange(123, 321)]],
              "locked old clipboard random range");
        CLIPRDR_UNLOCK_CLIPBOARD_DATA unlock = {0};
        unlock.clipDataId = 42;
        channel.ServerUnlockClipboardData(&channel, &unlock);
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_FAIL, "expired lock fails");
        [bridge setFiles:@[ tree ]];
        file.haveClipDataId = FALSE;
        file.cbRequested = 300000;
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_OK && fileData.length == 256 * 1024,
              "large peer requests receive a bounded short response");
        file.cbRequested = 32;
        file.listIndex = count;
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_FAIL, "invalid index refused");
        file.listIndex = binaryIndex;
        [bridge setActive:NO];
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_FAIL && advertised == 0, "inactive session does not expose files");
        [bridge setActive:YES];
        [bridge setFiles:@[ tree ]];
        remoteFormat(&channel);
        check(requestedFormat == 0xC321, "remote registered format ID mapped by name");
        [pendingRequests removeAllObjects];
        remoteDescriptors(&channel, descriptors);
        NSUInteger ranges = 0;
        while (!received && ranges < 20) {
            check(pendingRequests.count > 0, "download has pending work");
            CLIPRDR_FILE_CONTENTS_REQUEST next;
            [pendingRequests.firstObject getValue:&next];
            [pendingRequests removeObjectAtIndex:0];
            NSData *bytes;
            if (next.dwFlags == FILECONTENTS_SIZE) {
                uint64_t size = CFSwapInt64HostToLittle(entries[next.listIndex].nFileSizeLow);
                bytes = [NSData dataWithBytes:&size length:8];
            } else {
                bytes = [payload subdataWithRange:NSMakeRange(next.nPositionLow, next.cbRequested)];
                ranges++;
            }
            CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
            response.common.msgFlags = CB_RESPONSE_OK;
            response.streamId = next.streamId;
            response.cbRequested = (UINT32)bytes.length;
            response.requestedData = bytes.bytes;
            channel.ServerFileContentsResponse(&channel, &response);
        }
        check(received.count == 1 && ranges == 3, "bounded multi-chunk download finishes");
        NSURL *download = [received.firstObject URLByAppendingPathComponent:@"Nested/繁體😀.bin"];
        check([[NSData dataWithContentsOfURL:download] isEqual:payload],
              "remote bytes and Unicode folder names preserved");
        check([NSData dataWithContentsOfURL:[received.firstObject URLByAppendingPathComponent:@"Empty"]].length == 0,
              "empty file preserved");
        struct stat info;
        stat(download.fileSystemRepresentation, &info);
        check((info.st_mode & 0777) == 0600, "private downloaded file");
        free(entries);
        for (NSString *bad in @[
                 @"..\\escape", @"/absolute", @"C:\\absolute", @"a\\..\\escape", @"a/../escape", @"CON", @"trailing."
             ]) {
            message = nil;
            remoteFormat(&channel);
            remoteDescriptors(&channel, descriptor(bad, FILE_ATTRIBUTE_NORMAL, 1));
            check([message hasPrefix:@"Clipboard file transfer failed"], "unsafe remote path rejected");
        }
        for (NSArray<NSString *> *names in
             @[ @[ @"same", @"SAME" ], @[ @"Folder/a", @"folder/b" ], @[ @"parent", @"parent/child" ] ]) {
            NSData *first = descriptor(names[0], FILE_ATTRIBUTE_NORMAL, 1);
            NSData *second = descriptor(names[1], FILE_ATTRIBUTE_NORMAL, 1);
            NSMutableData *combined = [first mutableCopy];
            uint32_t two = CFSwapInt32HostToLittle(2);
            [combined replaceBytesInRange:NSMakeRange(0, 4) withBytes:&two];
            [combined appendData:[second subdataWithRange:NSMakeRange(4, second.length - 4)]];
            remoteFormat(&channel);
            remoteDescriptors(&channel, combined);
            check([message hasPrefix:@"Clipboard file transfer failed"],
                  "remote case aliases and file-parent conflicts rejected");
        }
        remoteFormat(&channel);
        remoteDescriptors(&channel, descriptor(@"link", FILE_ATTRIBUTE_REPARSE_POINT, 1));
        check([message hasPrefix:@"Clipboard file transfer failed"], "remote reparse point rejected");
        remoteFormat(&channel);
        remoteDescriptors(&channel, descriptor(@"large", FILE_ATTRIBUTE_NORMAL, 9ULL << 30));
        check([message hasPrefix:@"Clipboard file transfer failed"], "remote temporary quota enforced");
        // A real-size batch is advertised before completion. Reorder responses,
        // send a short block and replay a duplicate to exercise stream identity.
        received = nil;
        __block FCRDPClipboardFileBatch *batch;
        bridge.onBatch = ^(FCRDPClipboardFileBatch *value) {
          batch = value;
        };
        const NSUInteger largeSize = 50 * 1024 * 1024 + 123;
        NSMutableData *large = [NSMutableData dataWithLength:largeSize];
        for (NSUInteger i = 0; i < largeSize; i++)
            ((BYTE *)large.mutableBytes)[i] = (BYTE)(i * 17 + i / 65536);
        remoteFormat(&channel);
        [pendingRequests removeAllObjects];
        remoteDescriptors(&channel, descriptor(@"50MB.bin", FILE_ATTRIBUTE_NORMAL, largeSize));
        check(batch.files.count == 1 && ![batch waitUntilReadyWithTimeout:0],
              "pending file items advertised before the 50 MB download");
        __block BOOL waiterReady = NO;
        dispatch_semaphore_t waiterDone = dispatch_semaphore_create(0);
        FCRDPClipboardFileBatch *waitingBatch = batch;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          waiterReady = [waitingBatch waitUntilReadyWithTimeout:10];
          dispatch_semaphore_signal(waiterDone);
        });
        NSUInteger maxPending = 0;
        BOOL shortRead = NO;
        while (pendingRequests.count) {
            maxPending = MAX(maxPending, pendingRequests.count);
            check(pendingRequests.count <= 8, "range pipeline remains bounded");
            CLIPRDR_FILE_CONTENTS_REQUEST next;
            [pendingRequests.lastObject getValue:&next];
            [pendingRequests removeLastObject];
            NSData *bytes;
            if (next.dwFlags == FILECONTENTS_SIZE) {
                uint64_t size = CFSwapInt64HostToLittle(largeSize);
                bytes = [NSData dataWithBytes:&size length:8];
            } else {
                NSUInteger length = next.cbRequested;
                if (!shortRead && length > 1) {
                    length /= 2;
                    shortRead = YES;
                }
                bytes = [large subdataWithRange:NSMakeRange(next.nPositionLow, length)];
            }
            CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
            response.common.msgFlags = CB_RESPONSE_OK;
            response.streamId = next.streamId;
            response.cbRequested = (UINT32)bytes.length;
            response.requestedData = bytes.bytes;
            check(channel.ServerFileContentsResponse(&channel, &response) == 0, "50 MB response accepted");
            if (next.dwFlags == FILECONTENTS_RANGE)
                channel.ServerFileContentsResponse(&channel, &response);
        }
        check(maxPending == 8 && shortRead && [batch waitUntilReadyWithTimeout:0],
              "out-of-order pipeline and short range complete");
        check(dispatch_semaphore_wait(waiterDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && waiterReady,
              "paste fulfillment wakes without a main-thread callback");
        NSURL *largeDownload = batch.files.firstObject;
        check([[NSData dataWithContentsOfURL:largeDownload] isEqual:large], "50 MB bytes preserved");
        remoteFormat(&channel);
        [pendingRequests removeAllObjects];
        remoteDescriptors(&channel, descriptor(@"interrupted.bin", FILE_ATTRIBUTE_NORMAL, 100));
        FCRDPClipboardFileBatch *interrupted = batch;
        check(![interrupted waitUntilReadyWithTimeout:0], "new generation starts pending");
        [bridge setText:@"cancel pending paste"];
        check(![interrupted waitUntilReadyWithTimeout:1] && ![fm fileExistsAtPath:interrupted.files.firstObject.path],
              "cancellation wakes fulfillment and removes partial files");
        [bridge detach];
        check([fm fileExistsAtPath:largeDownload.path], "provider batch survives disconnect");
        [fm removeItemAtURL:largeDownload.URLByDeletingLastPathComponent error:NULL];
        bridge.onBatch = nil;
        [bridge attach:&channel];
        channel.ServerCapabilities(&channel, &caps);
        channel.MonitorReady(&channel, NULL);
        remoteFormat(&channel);
        [bridge setText:@"local replacement"];
        remoteDescriptors(&channel, descriptor(@"stale", FILE_ATTRIBUTE_NORMAL, 1));
        check(requestedFormat == 0xC321, "late descriptor drained after local copy");
        received = nil;
        remoteFormat(&channel);
        remoteDescriptors(&channel, descriptor(@"cancelled", FILE_ATTRIBUTE_NORMAL, 100));
        UINT32 cancelled = pending.streamId;
        [bridge setActive:NO];
        uint64_t size = 100;
        CLIPRDR_FILE_CONTENTS_RESPONSE late = {0};
        late.common.msgFlags = CB_RESPONSE_OK;
        late.streamId = cancelled;
        late.cbRequested = 8;
        late.requestedData = (BYTE *)&size;
        channel.ServerFileContentsResponse(&channel, &late);
        check(!received, "late file response ignored after deselection");
        [bridge setActive:YES];
        NSURL *sparse = [root URLByAppendingPathComponent:@"Sparse.bin"];
        int fd = open(sparse.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR, 0600);
        off_t offset = (1ULL << 32) + 17;
        pwrite(fd, "ABCD", 4, offset);
        close(fd);
        [bridge setFiles:@[ sparse ]];
        file = (CLIPRDR_FILE_CONTENTS_REQUEST){0};
        file.dwFlags = FILECONTENTS_RANGE;
        file.nPositionHigh = 1;
        file.nPositionLow = 17;
        file.cbRequested = 4;
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_OK && [fileData isEqual:[@"ABCD" dataUsingEncoding:NSUTF8StringEncoding]],
              "64-bit outbound offsets");
        fd = open(sparse.fileSystemRepresentation, O_WRONLY);
        ftruncate(fd, 1);
        close(fd);
        channel.ServerFileContentsRequest(&channel, &file);
        check(fileFlags == CB_RESPONSE_FAIL, "changed source fails closed");
        NSURL *link = [root URLByAppendingPathComponent:@"Link"];
        symlink(source.fileSystemRepresentation, link.fileSystemRepresentation);
        [bridge setFiles:@[ link ]];
        check(advertised == 0, "local symlink rejected");
        NSURL *stage = received.firstObject;
        [bridge detach];
        check(![fm fileExistsAtPath:download.path] && (!stage || ![fm fileExistsAtPath:stage.path]),
              "completed downloads removed on disconnect");
        printf("PASS %lu RDP file clipboard checks\n", (unsigned long)checks);
    }
    return 0;
}
