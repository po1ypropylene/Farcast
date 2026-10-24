#import "RDPClipboard.h"
#import "RDPDirectory.h"
#define REFIID WINPR_REFIID
#import <dirent.h>
#import <fcntl.h>
#import <freerdp/client/cliprdr.h>
#import <sys/stat.h>
#import <unistd.h>

// MS-RDPECLIP file lists use relative UTF-16 paths and separate range requests.
static const UINT32 fileFormat = 0xC001, effectFormat = 0xC002;
static const NSUInteger maxEntries = 20000, chunkSize = 256 * 1024;
static const NSUInteger rangeWindow = 8;
static const NSUInteger descriptorWireSize = 592; // MS-RDPECLIP packed FILEDESCRIPTORW, not native alignment.
static const NSTimeInterval responseTimeout = 30;
static const int64_t fileTimeEpoch = 11644473600LL;
static const uint64_t fileTimeTicks = 10000000ULL;
static const uint64_t maxCacheBytes = 8ULL * 1024 * 1024 * 1024;

static BOOL safeComponent(NSString *name) {
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."] || [name hasSuffix:@"."] || [name hasSuffix:@" "] ||
        [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"<>:\"/\\|?*"]].location !=
            NSNotFound ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    NSString *stem = [[name componentsSeparatedByString:@"."].firstObject uppercaseString];
    if ([@[ @"CON", @"PRN", @"AUX", @"NUL", @"CONIN$", @"CONOUT$" ] containsObject:stem])
        return NO;
    if (stem.length == 4 && ([stem hasPrefix:@"COM"] || [stem hasPrefix:@"LPT"]) &&
        [@"0123456789¹²³" containsString:[stem substringFromIndex:3]])
        return NO;
    return YES;
}
static NSString *pathKey(NSString *path) { return path.precomposedStringWithCanonicalMapping.lowercaseString; }
static BOOL safePath(NSString *path) {
    if (!path.length || path.length >= 260 || ![path dataUsingEncoding:NSUTF8StringEncoding])
        return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!safeComponent(part))
            return NO;
    return YES;
}
// Each component is opened relative to the retained root; links are never followed.
static int openRelative(int root, NSString *path, int flags, mode_t mode) {
    int current = dup(root);
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count && current >= 0; i++) {
        int next = openat(current, [parts[i] fileSystemRepresentation],
                          (i + 1 == parts.count ? flags : O_RDONLY | O_DIRECTORY) | O_NOFOLLOW | O_CLOEXEC, mode);
        close(current);
        current = next;
    }
    return current;
}
static BOOL makeDirectory(int root, NSString *path) {
    int current = dup(root);
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (current < 0)
            return NO;
        if (mkdirat(current, part.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
            close(current);
            return NO;
        }
        int next = openat(current, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(current);
        current = next;
    }
    if (current < 0)
        return NO;
    close(current);
    return YES;
}
@interface FCClipboardRoot : NSObject
@property(nonatomic) int fd;
@property(nonatomic) BOOL scoped;
@property(nonatomic, strong) NSURL *url;
@end
@implementation FCClipboardRoot
- (instancetype)init {
    if ((self = [super init]))
        _fd = -1;
    return self;
}
- (void)dealloc {
    if (_fd >= 0)
        close(_fd);
    if (_scoped)
        [_url stopAccessingSecurityScopedResource];
}
@end
@interface FCClipboardEntry : NSObject
@property(nonatomic, strong) FCClipboardRoot *root;
@property(nonatomic, copy) NSString *relative;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) struct stat metadata;
@property(nonatomic) uint64_t size;
@property(nonatomic) uint64_t writeTime;
@property(nonatomic) BOOL directory;
@end
@implementation FCClipboardEntry
@end

// A process-wide reservation includes retained batches and their cleanup grace period.
// Only the worker creates owning storage, immediately after mkdtemp.
@interface FCClipboardStorage : NSObject
@property(nonatomic, strong) NSURL *root;
@property(nonatomic) uint64_t bytes;
@property(nonatomic) NSUInteger entries;
- (BOOL)reserveBytes:(uint64_t)bytes entries:(NSUInteger)entries;
- (void)remove;
@end
@implementation FCClipboardStorage
static uint64_t storageBytes;
static NSUInteger storageEntries;
- (BOOL)reserveBytes:(uint64_t)bytes entries:(NSUInteger)entries {
    @synchronized(FCClipboardStorage.class) {
        if (bytes > maxCacheBytes - storageBytes || entries > maxEntries - storageEntries)
            return NO;
        storageBytes += bytes;
        storageEntries += entries;
        _bytes += bytes;
        _entries += entries;
        return YES;
    }
}
- (void)remove {
    if (!_root)
        return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:_root error:&error] && error.code != NSFileNoSuchFileError)
        return; // Failed deletion must not release a reservation for files still on disk.
    @synchronized(FCClipboardStorage.class) {
        storageBytes -= _bytes;
        storageEntries -= _entries;
        _bytes = 0;
        _entries = 0;
    }
    _root = nil;
}
- (void)dealloc {
    [self remove];
}
@end

@interface FCRDPClipboardFileBatch ()
- (instancetype)initWithStorage:(FCClipboardStorage *)storage files:(NSArray<NSURL *> *)files;
- (void)finish:(BOOL)success;
- (BOOL)takeRequest;
@end
@implementation FCRDPClipboardFileBatch {
    FCClipboardStorage *_storage;
    NSCondition *_condition;
    BOOL _finished, _success, _requested, _started;
}
// Public materialized batches borrow their URLs; they never delete caller-owned files.
- (instancetype)initWithRoot:(NSURL *)root files:(NSArray<NSURL *> *)files {
    if ((self = [super init])) {
        _files = [files copy];
        _condition = [NSCondition new];
        _finished = _success = YES;
    }
    return self;
}
- (instancetype)initWithStorage:(FCClipboardStorage *)storage files:(NSArray<NSURL *> *)files {
    if ((self = [self initWithRoot:storage.root files:files])) {
        _storage = storage;
        _finished = _success = NO;
    }
    return self;
}
- (void)requestContents {
    [_condition lock];
    if (!_finished)
        _requested = YES;
    [_condition unlock];
}
- (void)cancel {
    [self finish:NO];
}
- (BOOL)isFinished {
    [_condition lock];
    BOOL finished = _finished;
    [_condition unlock];
    return finished;
}
- (BOOL)takeRequest {
    [_condition lock];
    BOOL start = _requested && !_started && !_finished;
    if (start)
        _started = YES;
    [_condition unlock];
    return start;
}
- (void)finish:(BOOL)success {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _success = success;
        [_condition broadcast];
    }
    [_condition unlock];
}
- (BOOL)waitUntilReadyWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0, timeout)];
    [_condition lock];
    while (!_finished && [_condition waitUntilDate:deadline]) {
    }
    BOOL success = _finished && _success;
    [_condition unlock];
    return success;
}
- (void)dealloc {
    FCClipboardStorage *storage = _storage;
    if (!storage)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                   ^{
                     [storage remove];
                   });
}
@end

@interface FCClipboardRange : NSObject
@property(nonatomic) uint64_t offset;
@property(nonatomic) UINT32 length;
@property(nonatomic) NSTimeInterval sent;
@end
@implementation FCClipboardRange
@end

@interface FCRDPClipboard () {
    CliprdrClientContext *_channel;
    BOOL _active, _ready;
    UINT32 _serverFlags;
    NSString *_text;
    NSArray<FCClipboardEntry *> *_local;
    NSData *_descriptors;
    NSMutableDictionary<NSNumber *, NSArray<FCClipboardEntry *> *> *_locks;
    NSUInteger _generation, _requestGeneration;
    UINT32 _nextFormat, _pendingFormat, _remoteLock, _nextID, _expectedStream, _expectedLength;
    NSArray<FCClipboardEntry *> *_remote;
    NSUInteger _index, _stageEntries;
    uint64_t _position;
    NSURL *_stage;
    FCClipboardStorage *_storage;
    int _stageFD, _fileFD;
    NSMutableArray<FCClipboardStorage *> *_completed;
    NSTimeInterval _lastProgress;
    NSTimeInterval _lastNotice;
    NSMutableDictionary<NSNumber *, FCClipboardRange *> *_ranges;
    uint64_t _requestedPosition;
    FCRDPClipboardFileBatch *_batch;
}
- (UINT)advertise;
- (UINT)capabilities:(const CLIPRDR_CAPABILITIES *)caps;
- (UINT)ready;
- (UINT)formats:(const CLIPRDR_FORMAT_LIST *)list;
- (UINT)request:(const CLIPRDR_FORMAT_DATA_REQUEST *)request;
- (UINT)response:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response;
- (UINT)fileRequest:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request;
- (UINT)fileResponse:(const CLIPRDR_FILE_CONTENTS_RESPONSE *)response;
- (UINT)lock:(UINT32)identifier;
- (void)unlock:(UINT32)identifier;
@end
static FCRDPClipboard *clipboard(CliprdrClientContext *clip) { return (__bridge FCRDPClipboard *)clip->custom; }
static UINT receiveCaps(CliprdrClientContext *c, const CLIPRDR_CAPABILITIES *v) {
    return [clipboard(c) capabilities:v];
}
static UINT receiveReady(CliprdrClientContext *c, const CLIPRDR_MONITOR_READY *v) { return [clipboard(c) ready]; }
static UINT receiveFormats(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *v) { return [clipboard(c) formats:v]; }
static UINT receiveRequest(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *v) {
    return [clipboard(c) request:v];
}
static UINT receiveResponse(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_RESPONSE *v) {
    return [clipboard(c) response:v];
}
static UINT receiveFileRequest(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_REQUEST *v) {
    return [clipboard(c) fileRequest:v];
}
static UINT receiveFileResponse(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_RESPONSE *v) {
    return [clipboard(c) fileResponse:v];
}
static UINT receiveLock(CliprdrClientContext *c, const CLIPRDR_LOCK_CLIPBOARD_DATA *v) {
    return [clipboard(c) lock:v->clipDataId];
}
static UINT receiveUnlock(CliprdrClientContext *c, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *v) {
    [clipboard(c) unlock:v->clipDataId];
    return CHANNEL_RC_OK;
}

@implementation FCRDPClipboard
- (instancetype)init {
    if ((self = [super init])) {
        _active = YES;
        _stageFD = _fileFD = -1;
        _locks = [NSMutableDictionary new];
        _completed = [NSMutableArray new];
        _ranges = [NSMutableDictionary new];
    }
    return self;
}
- (NSTimeInterval)monotonicTime {
    return NSProcessInfo.processInfo.systemUptime;
}
- (void)progress:(NSString *)message {
    if (self.onProgress)
        self.onProgress(message);
}
- (void)attach:(CliprdrClientContext *)channel {
    if (_channel && _channel != channel)
        [self detach];
    _channel = channel;
    channel->custom = (__bridge void *)self;
    channel->ServerCapabilities = receiveCaps;
    channel->MonitorReady = receiveReady;
    channel->ServerFormatList = receiveFormats;
    channel->ServerFormatDataRequest = receiveRequest;
    channel->ServerFormatDataResponse = receiveResponse;
    channel->ServerFileContentsRequest = receiveFileRequest;
    channel->ServerFileContentsResponse = receiveFileResponse;
    channel->ServerLockClipboardData = receiveLock;
    channel->ServerUnlockClipboardData = receiveUnlock;
}
- (void)cancelRemote {
    _generation++;
    _nextFormat = 0;
    _expectedStream = 0;
    [_ranges removeAllObjects];
    [_batch finish:NO];
    _batch = nil;
    if (_remoteLock && _channel) {
        CLIPRDR_UNLOCK_CLIPBOARD_DATA unlock = {0};
        unlock.clipDataId = _remoteLock;
        (void)_channel->ClientUnlockClipboardData(_channel, &unlock);
    }
    _remoteLock = 0;
    if (_fileFD >= 0)
        close(_fileFD);
    if (_stageFD >= 0)
        close(_stageFD);
    _fileFD = _stageFD = -1;
    [_storage remove];
    _storage = nil;
    _stage = nil;
    _stageEntries = 0;
    _remote = nil;
}
- (void)detach {
    [self cancelRemote];
    if (_channel && _channel->custom == (__bridge void *)self)
        _channel->custom = NULL;
    _channel = NULL;
    _ready = NO;
    _serverFlags = 0;
    _pendingFormat = 0;
    _text = nil;
    _local = nil;
    _descriptors = nil;
    [_locks removeAllObjects];
    for (FCClipboardStorage *storage in _completed)
        [storage remove];
    [_completed removeAllObjects];
}
- (void)dealloc {
    [self detach];
}
- (void)setActive:(BOOL)active {
    if (_active == active)
        return;
    _active = active;
    [self cancelRemote];
    _text = nil;
    _local = nil;
    _descriptors = nil;
    [_locks removeAllObjects];
    (void)[self advertise];
    [self progress:@""];
}
- (void)setText:(NSString *)text {
    [self cancelRemote];
    _local = nil;
    _descriptors = nil;
    _text = _active ? [text copy] : nil;
    [self progress:@""];
    (void)[self advertise];
}
- (BOOL)addEntry:(int)fd
            root:(FCClipboardRoot *)root
        relative:(NSString *)relative
            name:(NSString *)name
         entries:(NSMutableArray *)entries
            keys:(NSMutableSet *)keys {
    struct stat info;
    if (entries.count >= maxEntries || !safePath(name) || [keys containsObject:pathKey(name)] || fstat(fd, &info) ||
        (!S_ISREG(info.st_mode) && !S_ISDIR(info.st_mode)) || info.st_size < 0)
        return NO;
    [keys addObject:pathKey(name)];
    FCClipboardEntry *entry = [FCClipboardEntry new];
    entry.root = root;
    entry.relative = relative;
    entry.name = name;
    entry.metadata = info;
    entry.directory = S_ISDIR(info.st_mode);
    entry.size = entry.directory ? 0 : (uint64_t)info.st_size;
    [entries addObject:entry];
    if (!entry.directory)
        return YES;
    DIR *directory = FCRDPOpenDirectory(fd);
    if (!directory)
        return NO;
    BOOL result = YES;
    struct dirent *child;
    while (YES) {
        errno = 0;
        child = readdir(directory);
        if (!child) {
            if (errno)
                result = NO;
            break;
        }
        if (!strcmp(child->d_name, ".") || !strcmp(child->d_name, ".."))
            continue;
        NSString *component = [[NSString alloc] initWithUTF8String:child->d_name];
        int next = openat(fd, child->d_name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (!component || next < 0) {
            result = NO;
            if (next >= 0)
                close(next);
            break;
        }
        result = [self addEntry:next
                           root:root
                       relative:(relative.length ? [relative stringByAppendingPathComponent:component] : component)name
                               :[name stringByAppendingPathComponent:component]
                        entries:entries
                           keys:keys];
        close(next);
        if (!result)
            break;
    }
    closedir(directory);
    return result;
}
- (void)setFiles:(NSArray<NSURL *> *)files {
    [self cancelRemote];
    _text = nil;
    _local = nil;
    _descriptors = nil;
    NSMutableArray *entries = [NSMutableArray new];
    NSMutableSet *keys = [NSMutableSet new];
    BOOL valid = _active && files.count > 0 && files.count <= maxEntries;
    for (NSURL *url in files) {
        if (!valid || !url.isFileURL) {
            valid = NO;
            break;
        }
        FCClipboardRoot *root = [FCClipboardRoot new];
        root.url = url;
        root.scoped = [url startAccessingSecurityScopedResource];
        root.fd = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (root.fd < 0 || ![self addEntry:root.fd
                                      root:root
                                  relative:@""
                                      name:url.lastPathComponent
                                   entries:entries
                                      keys:keys]) {
            valid = NO;
            break;
        }
    }
    if (valid) {
        FILEDESCRIPTORW *descriptors = calloc(entries.count, sizeof(FILEDESCRIPTORW));
        if (descriptors) {
            for (NSUInteger i = 0; i < entries.count; i++) {
                FCClipboardEntry *entry = entries[i];
                FILEDESCRIPTORW *d = &descriptors[i];
                d->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI | FD_WRITESTIME;
                uint64_t ticks =
                    ((uint64_t)entry.metadata.st_mtimespec.tv_sec + (uint64_t)fileTimeEpoch) * fileTimeTicks +
                    entry.metadata.st_mtimespec.tv_nsec / 100;
                d->ftLastWriteTime.dwHighDateTime = (UINT32)(ticks >> 32);
                d->ftLastWriteTime.dwLowDateTime = (UINT32)ticks;
                d->dwFileAttributes = entry.directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
                d->nFileSizeHigh = (UINT32)(entry.size >> 32);
                d->nFileSizeLow = (UINT32)entry.size;
                NSString *name = [entry.name stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
                [name getCharacters:d->cFileName range:NSMakeRange(0, name.length)];
            }
            BYTE *bytes = NULL;
            UINT32 length = 0;
            if (CHANNEL_RC_OK ==
                cliprdr_serialize_file_list_ex(CB_STREAM_FILECLIP_ENABLED | CB_HUGE_FILE_SUPPORT_ENABLED, descriptors,
                                               (UINT32)entries.count, &bytes, &length)) {
                _descriptors = [NSData dataWithBytes:bytes length:length];
                _local = entries;
            }
            free(bytes);
            free(descriptors);
        }
    }
    if (!_local)
        [self progress:@"Cannot share these clipboard files. Use readable regular files or folders with "
                       @"Windows-compatible names."];
    else if (!(_serverFlags & CB_STREAM_FILECLIP_ENABLED) && _ready)
        [self progress:@"This server does not support file clipboard sharing."];
    else
        [self progress:@""];
    (void)[self advertise];
}
- (UINT)advertise {
    if (!_ready || !_channel)
        return CHANNEL_RC_OK;
    CLIPRDR_FORMAT formats[2] = {0};
    CLIPRDR_FORMAT_LIST list = {0};
    list.formats = formats;
    BOOL canShareFiles = (_serverFlags & CB_STREAM_FILECLIP_ENABLED) != 0;
    for (FCClipboardEntry *entry in _local)
        if (entry.size > UINT32_MAX && !(_serverFlags & CB_HUGE_FILE_SUPPORT_ENABLED))
            canShareFiles = NO;
    if (_active && _local.count && !canShareFiles)
        [self progress:(_serverFlags & CB_STREAM_FILECLIP_ENABLED)
                           ? @"This server does not support the size of these clipboard files."
                           : @"This server does not support file clipboard sharing."];
    if (_active && _local.count && canShareFiles) {
        formats[0] = (CLIPRDR_FORMAT){.formatId = fileFormat, .formatName = "FileGroupDescriptorW"};
        formats[1] = (CLIPRDR_FORMAT){.formatId = effectFormat, .formatName = "Preferred DropEffect"};
        list.numFormats = 2;
    } else if (_active && _text) {
        formats[0].formatId = CF_UNICODETEXT;
        list.numFormats = 1;
    }
    return _channel->ClientFormatList(_channel, &list);
}
- (UINT)capabilities:(const CLIPRDR_CAPABILITIES *)caps {
    const BYTE *cursor = (const BYTE *)caps->capabilitySets;
    for (UINT32 i = 0; i < caps->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *set = (const void *)cursor;
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL && set->capabilitySetLength >= 12)
            _serverFlags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)set)->generalFlags;
        cursor += set->capabilitySetLength;
    }
    return CHANNEL_RC_OK;
}
- (UINT)ready {
    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
                           CB_CAN_LOCK_CLIPDATA | CB_HUGE_FILE_SUPPORT_ENABLED;
    CLIPRDR_CAPABILITIES caps = {0};
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (void *)&general;
    UINT rc = _channel->ClientCapabilities(_channel, &caps);
    if (rc)
        return rc;
    _ready = YES;
    return [self advertise];
}
- (UINT)startRequest {
    if (!_channel || !_active || _pendingFormat || !_nextFormat)
        return CHANNEL_RC_OK;
    _pendingFormat = _nextFormat;
    _nextFormat = 0;
    _requestGeneration = _generation;
    _lastProgress = [self monotonicTime];
    if (_pendingFormat != CF_UNICODETEXT)
        [self progress:@"Waiting for Windows clipboard file details…"];
    if (_pendingFormat != CF_UNICODETEXT && (_serverFlags & CB_CAN_LOCK_CLIPDATA)) {
        _remoteLock = ++_nextID ?: ++_nextID;
        CLIPRDR_LOCK_CLIPBOARD_DATA lock = {0};
        lock.clipDataId = _remoteLock;
        UINT rc = _channel->ClientLockClipboardData(_channel, &lock);
        if (rc)
            return rc;
    }
    CLIPRDR_FORMAT_DATA_REQUEST request = {0};
    request.requestedFormatId = _pendingFormat;
    return _channel->ClientFormatDataRequest(_channel, &request);
}
- (UINT)formats:(const CLIPRDR_FORMAT_LIST *)list {
    [self cancelRemote];
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = _channel->ClientFormatListResponse(_channel, &response);
    if (rc || !_active)
        return rc;
    UINT32 text = 0, files = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT)
            text = CF_UNICODETEXT;
        if (list->formats[i].formatName && !strcmp(list->formats[i].formatName, "FileGroupDescriptorW"))
            files = list->formats[i].formatId;
    }
    _nextFormat = files && (_serverFlags & CB_STREAM_FILECLIP_ENABLED) ? files : text;
    if (self.onRemoteChange)
        self.onRemoteChange();
    if (files && !(_serverFlags & CB_STREAM_FILECLIP_ENABLED))
        [self progress:@"This server does not support file clipboard sharing."];
    else
        [self progress:@""];
    // Unsupported formats (for example images) preserve the local pasteboard.
    return [self startRequest];
}
- (UINT)request:(const CLIPRDR_FORMAT_DATA_REQUEST *)request {
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgFlags = CB_RESPONSE_FAIL;
    NSData *data = nil;
    if (_active && request->requestedFormatId == CF_UNICODETEXT && _text) {
        NSMutableData *bytes = [[_text dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
        uint16_t zero = 0;
        [bytes appendBytes:&zero length:2];
        data = bytes;
    } else if (_active && request->requestedFormatId == fileFormat)
        data = _descriptors;
    else if (_active && request->requestedFormatId == effectFormat && _local.count) {
        uint32_t copy = CFSwapInt32HostToLittle(1);
        data = [NSData dataWithBytes:&copy length:4];
    }
    if (data) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)data.length;
        response.requestedFormatData = data.bytes;
    }
    return _channel->ClientFormatDataResponse(_channel, &response);
}
- (BOOL)beginFiles:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response {
    if (response->common.dataLen < 4 || response->common.dataLen > 4 + maxEntries * descriptorWireSize ||
        !response->requestedFormatData)
        return NO;
    UINT32 count = 0;
    memcpy(&count, response->requestedFormatData, 4);
    count = CFSwapInt32LittleToHost(count);
    if (!count || count > maxEntries || response->common.dataLen != 4 + count * descriptorWireSize)
        return NO;
    FILEDESCRIPTORW *descriptors = NULL;
    if (CHANNEL_RC_OK !=
        cliprdr_parse_file_list(response->requestedFormatData, response->common.dataLen, &descriptors, &count)) {
        free(descriptors);
        return NO;
    }
    NSMutableArray *entries = [NSMutableArray new];
    NSMutableDictionary *keys = [NSMutableDictionary new];
    BOOL valid = YES;
    for (UINT32 i = 0; i < count; i++) {
        FILEDESCRIPTORW *d = &descriptors[i];
        NSUInteger length = 0;
        while (length < 260 && d->cFileName[length])
            length++;
        if (length == 260 || !(d->dwFlags & FD_ATTRIBUTES) || (d->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            valid = NO;
            break;
        }
        NSString *name = [[NSString alloc] initWithCharacters:d->cFileName length:length];
        name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!safePath(name) || keys[pathKey(name)]) {
            valid = NO;
            break;
        }
        FCClipboardEntry *entry = [FCClipboardEntry new];
        entry.name = name;
        entry.directory = (d->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (d->dwFlags & FD_WRITESTIME)
            entry.writeTime = ((uint64_t)d->ftLastWriteTime.dwHighDateTime << 32) | d->ftLastWriteTime.dwLowDateTime;
        entry.size = d->dwFlags & FD_FILESIZE ? ((uint64_t)d->nFileSizeHigh << 32) | d->nFileSizeLow : UINT64_MAX;
        if (!entry.directory && entry.size != UINT64_MAX && entry.size > maxCacheBytes) {
            valid = NO;
            break;
        }
        keys[pathKey(name)] = entry;
        [entries addObject:entry];
    }
    free(descriptors);
    NSMutableDictionary<NSString *, NSString *> *prefixes = [NSMutableDictionary new];
    for (FCClipboardEntry *entry in entries) {
        NSString *prefix = @"";
        for (NSString *component in [entry.name componentsSeparatedByString:@"/"]) {
            prefix = [prefix stringByAppendingPathComponent:component];
            NSString *key = pathKey(prefix), *spelling = prefix.precomposedStringWithCanonicalMapping;
            if (prefixes[key] && ![prefixes[key] isEqual:spelling])
                valid = NO;
            prefixes[key] = spelling;
        }
        NSString *parent = entry.name.stringByDeletingLastPathComponent;
        while (parent.length) {
            FCClipboardEntry *ancestor = keys[pathKey(parent)];
            if (ancestor && !ancestor.directory) {
                valid = NO;
                break;
            }
            parent = parent.stringByDeletingLastPathComponent;
        }
    }
    if (!valid || prefixes.count > maxEntries)
        return NO;
    _stageEntries = prefixes.count;
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Farcast-RDP-XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    char *created = mkdtemp(buffer);
    if (created)
        _stage = [NSURL fileURLWithFileSystemRepresentation:created isDirectory:YES relativeToURL:nil];
    free(buffer);
    if (!_stage)
        return NO;
    _storage = [FCClipboardStorage new];
    _storage.root = _stage;
    if (![_storage reserveBytes:0 entries:_stageEntries])
        return NO;
    _stageFD = open(_stage.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (_stageFD < 0)
        return NO;
    _remote = entries;
    _index = 0;
    _position = 0;
    _lastNotice = 0;
    if (self.onBatch) {
        NSMutableArray *urls = [NSMutableArray new];
        NSMutableSet *names = [NSMutableSet new];
        for (FCClipboardEntry *entry in entries) {
            NSString *top = [entry.name componentsSeparatedByString:@"/"].firstObject;
            if (![names containsObject:top]) {
                [names addObject:top];
                [urls addObject:[_stage URLByAppendingPathComponent:top]];
            }
        }
        _batch = [[FCRDPClipboardFileBatch alloc] initWithStorage:_storage files:urls];
        // Publish metadata only. A provider's explicit request is consumed by
        // tick on this worker; no SIZE/RANGE requests or tree creation on Copy.
        self.onBatch(_batch);
    }
    return YES;
}
- (void)failedTransfer {
    [self cancelRemote];
    [self progress:@"Clipboard file transfer failed or exceeded the 8 GiB temporary-storage limit. Copy the files "
                   @"again to retry."];
}
- (UINT)response:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response {
    UINT32 requested = _pendingFormat;
    _pendingFormat = 0;
    if (!_active || _requestGeneration != _generation)
        return [self startRequest];
    if (!(response->common.msgFlags & CB_RESPONSE_OK)) {
        [self failedTransfer];
        return CHANNEL_RC_OK;
    }
    if (requested == CF_UNICODETEXT) {
        if (response->common.dataLen > 1024 * 1024 || response->common.dataLen % 2 || !response->requestedFormatData)
            return CHANNEL_RC_OK;
        NSString *text = [[NSString alloc] initWithBytes:response->requestedFormatData
                                                  length:response->common.dataLen
                                                encoding:NSUTF16LittleEndianStringEncoding];
        NSRange nul = [text rangeOfString:[NSString stringWithCharacters:(unichar[]){0} length:1]];
        if (nul.location != NSNotFound)
            text = [text substringToIndex:nul.location];
        if (text && self.onText)
            self.onText(text);
        return CHANNEL_RC_OK;
    }
    if (!requested)
        return CHANNEL_RC_OK;
    if (![self beginFiles:response]) {
        [self failedTransfer];
        return CHANNEL_RC_OK;
    }
    if (_batch) {
        [self progress:@"Windows files are available to paste in Finder."];
        return CHANNEL_RC_OK;
    }
    // Headless consumers that install onFiles explicitly consume immediately.
    return [self startTransfer];
}
- (UINT)startTransfer {
    for (FCClipboardEntry *entry in _remote) {
        NSString *directory = entry.directory ? entry.name : entry.name.stringByDeletingLastPathComponent;
        if (directory.length && !makeDirectory(_stageFD, directory)) {
            [self failedTransfer];
            return CHANNEL_RC_OK;
        }
    }
    return [self nextFile];
}
- (UINT)sendFileRequest:(BOOL)size {
    CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
    request.streamId = ++_nextID ?: ++_nextID;
    request.listIndex = (UINT32)_index;
    request.dwFlags = size ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
    uint64_t offset = size ? 0 : _requestedPosition;
    request.nPositionHigh = (UINT32)(offset >> 32);
    request.nPositionLow = (UINT32)offset;
    request.cbRequested = size ? 8 : (UINT32)MIN(chunkSize, _remote[_index].size - offset);
    request.haveClipDataId = _remoteLock != 0;
    request.clipDataId = _remoteLock;
    if (size) {
        _expectedStream = request.streamId;
        _expectedLength = request.cbRequested;
        [self progress:[NSString stringWithFormat:@"Waiting for Windows clipboard file size (%lu of %lu)…",
                                                  (unsigned long)_index + 1, (unsigned long)_remote.count]];
    } else {
        FCClipboardRange *range = [FCClipboardRange new];
        range.offset = offset;
        range.length = request.cbRequested;
        range.sent = [self monotonicTime];
        _ranges[@(request.streamId)] = range;
        _requestedPosition += request.cbRequested;
    }
    _lastProgress = [self monotonicTime];
    return _channel->ClientFileContentsRequest(_channel, &request);
}
- (UINT)fillRanges {
    while (_ranges.count < rangeWindow && _requestedPosition < _remote[_index].size) {
        UINT rc = [self sendFileRequest:NO];
        if (rc)
            return rc;
    }
    return CHANNEL_RC_OK;
}
- (UINT)nextFile {
    while (_index < _remote.count && _remote[_index].directory)
        _index++;
    if (_index < _remote.count) {
        _position = 0;
        _requestedPosition = 0;
        [_ranges removeAllObjects];
        return [self sendFileRequest:YES];
    }
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableSet *names = [NSMutableSet new];
    for (FCClipboardEntry *entry in _remote) {
        NSString *top = [entry.name componentsSeparatedByString:@"/"].firstObject;
        if (![names containsObject:top]) {
            [names addObject:top];
            [urls addObject:[_stage URLByAppendingPathComponent:top]];
        }
    }
    FCRDPClipboardFileBatch *batch = _batch;
    if (!batch)
        [_completed addObject:_storage];
    _storage = nil; // Batch or immediate consumer now owns the reservation.
    _stage = nil;
    // Restore folder dates only after all descendants have been materialized.
    for (FCClipboardEntry *entry in _remote.reverseObjectEnumerator) {
        if (!entry.writeTime)
            continue;
        int fd = openRelative(_stageFD, entry.name, O_RDONLY, 0);
        if (fd >= 0) {
            struct timespec times[2] = {{0, UTIME_OMIT},
                                        {(time_t)((int64_t)(entry.writeTime / fileTimeTicks) - fileTimeEpoch),
                                         (long)(entry.writeTime % fileTimeTicks * 100)}};
            futimens(fd, times);
            close(fd);
        }
    }
    [batch finish:YES];
    [self cancelRemote];
    [self progress:@"Clipboard files are ready to paste in Finder."];
    if (!batch && self.onFiles)
        self.onFiles(urls);
    return CHANNEL_RC_OK;
}
- (UINT)fileResponse:(const CLIPRDR_FILE_CONTENTS_RESPONSE *)response {
    FCClipboardRange *range = _ranges[@(response->streamId)];
    BOOL sizeResponse = _expectedStream && response->streamId == _expectedStream;
    if (!_remote || (!range && !sizeResponse))
        return CHANNEL_RC_OK;
    if (sizeResponse)
        _expectedStream = 0;
    else
        [_ranges removeObjectForKey:@(response->streamId)];
    if (!(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedData ||
        response->cbRequested > (sizeResponse ? _expectedLength : range.length) || response->cbRequested == 0) {
        [self failedTransfer];
        return CHANNEL_RC_OK;
    }
    FCClipboardEntry *entry = _remote[_index];
    _lastProgress = [self monotonicTime];
    if (sizeResponse) {
        if (response->cbRequested != 8) {
            [self failedTransfer];
            return CHANNEL_RC_OK;
        }
        uint64_t size;
        memcpy(&size, response->requestedData, 8);
        size = CFSwapInt64LittleToHost(size);
        if ((entry.size != UINT64_MAX && size != entry.size) || size > maxCacheBytes ||
            (size > UINT32_MAX && !(_serverFlags & CB_HUGE_FILE_SUPPORT_ENABLED))) {
            [self failedTransfer];
            return CHANNEL_RC_OK;
        }
        entry.size = size;
        if (![_storage reserveBytes:size entries:0]) {
            [self failedTransfer];
            return CHANNEL_RC_OK;
        }
        _fileFD = openRelative(_stageFD, entry.name, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (_fileFD < 0) {
            [self failedTransfer];
            return CHANNEL_RC_OK;
        }
    } else {
        const BYTE *bytes = response->requestedData;
        NSUInteger left = response->cbRequested;
        while (left) {
            ssize_t written = pwrite(_fileFD, bytes, left, (off_t)(range.offset + response->cbRequested - left));
            if (written < 0 && errno == EINTR)
                continue;
            if (written <= 0) {
                [self failedTransfer];
                return CHANNEL_RC_OK;
            }
            left -= written;
            bytes += written;
        }
        _position += response->cbRequested;
        if (response->cbRequested < range.length) {
            // A short read is legal. Request only its missing suffix, preserving
            // stream correlation and the disjoint offsets already in flight.
            CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
            request.streamId = ++_nextID ?: ++_nextID;
            request.listIndex = (UINT32)_index;
            request.dwFlags = FILECONTENTS_RANGE;
            range.offset += response->cbRequested;
            range.length -= response->cbRequested;
            range.sent = _lastProgress;
            request.nPositionHigh = (UINT32)(range.offset >> 32);
            request.nPositionLow = (UINT32)range.offset;
            request.cbRequested = range.length;
            request.haveClipDataId = _remoteLock != 0;
            request.clipDataId = _remoteLock;
            _ranges[@(request.streamId)] = range;
            UINT rc = _channel->ClientFileContentsRequest(_channel, &request);
            if (rc)
                return rc;
        }
    }
    if (_lastProgress - _lastNotice >= 0.5 || _position == entry.size) {
        _lastNotice = _lastProgress;
        [self progress:[NSString stringWithFormat:@"Receiving clipboard file %lu of %lu: %.1f of %.1f MB…",
                                                  (unsigned long)_index + 1, (unsigned long)_remote.count,
                                                  _position / 1000000.0, entry.size / 1000000.0]];
    }
    if (_position < entry.size || _ranges.count)
        return [self fillRanges];
    BOOL saved = fsync(_fileFD) == 0;
    close(_fileFD);
    _fileFD = -1;
    if (!saved) {
        [self failedTransfer];
        return CHANNEL_RC_OK;
    }
    _index++;
    return [self nextFile];
}
- (UINT)lock:(UINT32)identifier {
    if (_active && _local && _locks.count < 8)
        _locks[@(identifier)] = _local;
    return CHANNEL_RC_OK;
}
- (void)unlock:(UINT32)identifier {
    [_locks removeObjectForKey:@(identifier)];
}
- (UINT)fileRequest:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request {
    CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
    response.streamId = request->streamId;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    NSArray *entries = request->haveClipDataId ? _locks[@(request->clipDataId)] : _local;
    NSMutableData *data = nil;
    if (_active && request->listIndex < entries.count &&
        (!request->nPositionHigh || (_serverFlags & CB_HUGE_FILE_SUPPORT_ENABLED)) &&
        (request->dwFlags != FILECONTENTS_SIZE || (!request->nPositionHigh && !request->nPositionLow))) {
        FCClipboardEntry *entry = entries[request->listIndex];
        int fd = entry.relative.length ? openRelative(entry.root.fd, entry.relative, O_RDONLY | O_NONBLOCK, 0)
                                       : dup(entry.root.fd);
        struct stat info;
        struct stat original = entry.metadata;
        BOOL matches = fd >= 0 && !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_dev == original.st_dev &&
                       info.st_ino == original.st_ino && info.st_size == original.st_size &&
                       info.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec &&
                       info.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec;
        if (matches && request->dwFlags == FILECONTENTS_SIZE && request->cbRequested == 8) {
            uint64_t size = CFSwapInt64HostToLittle(entry.size);
            data = [[NSMutableData alloc] initWithBytes:&size length:8];
        } else if (matches && request->dwFlags == FILECONTENTS_RANGE) {
            uint64_t position = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
            if (position <= entry.size) {
                NSUInteger length = (NSUInteger)MIN(chunkSize, MIN(request->cbRequested, entry.size - position));
                data = [NSMutableData dataWithLength:length];
                NSUInteger readBytes = 0;
                while (readBytes < length) {
                    ssize_t got = pread(fd, (BYTE *)data.mutableBytes + readBytes, length - readBytes,
                                        (off_t)(position + readBytes));
                    if (got < 0 && errno == EINTR)
                        continue;
                    if (got <= 0) {
                        data = nil;
                        break;
                    }
                    readBytes += got;
                }
            }
        }
        if (data && (fstat(fd, &info) != 0 || info.st_size != original.st_size ||
                     info.st_mtimespec.tv_sec != original.st_mtimespec.tv_sec ||
                     info.st_mtimespec.tv_nsec != original.st_mtimespec.tv_nsec))
            data = nil;
        if (fd >= 0)
            close(fd);
    }
    if (data) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.cbRequested = (UINT32)data.length;
        response.requestedData = data.bytes;
    }
    return _channel->ClientFileContentsResponse(_channel, &response);
}
- (void)tick {
    if (_batch.isFinished && ![_batch waitUntilReadyWithTimeout:0]) {
        [self cancelRemote];
        [self progress:@"Clipboard file transfer cancelled. Copy the files again to retry."];
    }
    if (_active && _channel && [_batch takeRequest]) {
        if ([self startTransfer] != CHANNEL_RC_OK)
            [self failedTransfer];
    }
    BOOL stalledRange = NO;
    for (FCClipboardRange *range in _ranges.allValues)
        if ([self monotonicTime] - range.sent > responseTimeout)
            stalledRange = YES;
    if (stalledRange ||
        ((_pendingFormat || _expectedStream) && [self monotonicTime] - _lastProgress > responseTimeout)) {
        // A format reply has no request ID, so safely recovering requires a new channel.
        BOOL formatTimedOut = _pendingFormat != 0;
        [self failedTransfer];
        if (formatTimedOut) {
            [self detach];
            [self progress:@"The remote clipboard did not respond. Reconnecting the desktop is required."];
            if (self.onFailure)
                self.onFailure();
        }
        _lastProgress = [self monotonicTime];
    }
}
@end
