#import "RDPDrive.h"
#define REFIID WINPR_REFIID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <freerdp/addin.h>
#import <freerdp/channels/rdpdr.h>
#import <freerdp/client/channels.h>
#import <freerdp/freerdp.h>
#pragma clang diagnostic pop
#import <dirent.h>
#import <fcntl.h>
#import <fnmatch.h>
#import <sys/attr.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

// Independent root-confined MS-RDPEFS backend; FreeRDP owns channel framing and
// device/completion IDs. No operation interprets a remote path as an absolute URL.
typedef struct {
    const BYTE *bytes;
    size_t left;
    BOOL valid;
} Reader;
static uint64_t take(Reader *r, size_t count) {
    if (r->left < count) {
        r->valid = NO;
        return 0;
    }
    uint64_t value = 0;
    for (size_t i = 0; i < count; i++)
        value |= (uint64_t)r->bytes[i] << (8 * i);
    r->bytes += count;
    r->left -= count;
    return value;
}
static void skip(Reader *r, size_t count) {
    if (r->left < count)
        r->valid = NO;
    else {
        r->bytes += count;
        r->left -= count;
    }
}
static NSString *string(Reader *r, uint32_t length) {
    if (!r->valid || length > r->left || length > 16384 || length % 2) {
        r->valid = NO;
        return nil;
    }
    NSString *value = [[NSString alloc] initWithBytes:r->bytes
                                               length:length
                                             encoding:NSUTF16LittleEndianStringEncoding];
    skip(r, length);
    NSString *nul = [NSString stringWithCharacters:(unichar[]){0} length:1];
    if ([value hasSuffix:nul])
        value = [value substringToIndex:value.length - 1];
    if (!value)
        r->valid = NO;
    return value;
}
static NSString *relativePath(NSString *wire) {
    if (!wire || [wire hasPrefix:@"/"] || [wire hasPrefix:@"\\\\"] || [wire containsString:@":"] ||
        [wire rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    NSString *path = [wire stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([path hasPrefix:@"/"])
        path = [path substringFromIndex:1];
    if (!path.length)
        return @"";
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 64 || ![path dataUsingEncoding:NSUTF8StringEncoding])
        return nil;
    for (NSString *part in parts)
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || part.length > 255)
            return nil;
    return path;
}
static int beneath(int root, NSString *path, int flags, mode_t mode) {
    if (!path.length)
        return dup(root);
    int fd = dup(root);
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count && fd >= 0; i++) {
        int next =
            openat(fd, [parts[i] fileSystemRepresentation],
                   (i + 1 == parts.count ? flags : O_RDONLY | O_DIRECTORY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode);
        close(fd);
        fd = next;
    }
    return fd;
}
static NTSTATUS statusForErrno(void) {
    switch (errno) {
    case ENOENT:
        return STATUS_OBJECT_NAME_NOT_FOUND;
    case ENOTDIR:
        return STATUS_NOT_A_DIRECTORY;
    case EISDIR:
        return STATUS_FILE_IS_A_DIRECTORY;
    case EEXIST:
        return STATUS_OBJECT_NAME_COLLISION;
    case ENOTEMPTY:
        return STATUS_DIRECTORY_NOT_EMPTY;
    case EACCES:
    case EPERM:
    case ELOOP:
        return STATUS_ACCESS_DENIED;
    case ENOSPC:
        return STATUS_DISK_FULL;
    case EROFS:
        return STATUS_MEDIA_WRITE_PROTECTED;
    default:
        return STATUS_UNSUCCESSFUL;
    }
}
static uint64_t fileTime(struct timespec t) {
    return ((uint64_t)t.tv_sec + 11644473600ULL) * 10000000ULL + t.tv_nsec / 100;
}
static struct timespec unixTime(uint64_t t) {
    return (struct timespec){(time_t)(t / 10000000ULL - 11644473600ULL), (long)(t % 10000000ULL * 100)};
}
static uint32_t attributes(struct stat s, BOOL readOnly) {
    uint32_t attrs = S_ISDIR(s.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_ARCHIVE;
    if (readOnly || !(s.st_mode & S_IWUSR))
        attrs |= FILE_ATTRIBUTE_READONLY;
    if (s.st_flags & UF_HIDDEN)
        attrs |= FILE_ATTRIBUTE_HIDDEN;
    return attrs;
}
static const uint32_t readMask = GENERIC_READ | GENERIC_ALL | FILE_READ_DATA;
static const uint32_t writeMask = GENERIC_WRITE | GENERIC_ALL | FILE_WRITE_DATA | FILE_APPEND_DATA;
static const uint32_t mutationMask = GENERIC_WRITE | GENERIC_ALL | DELETE | FILE_WRITE_DATA | FILE_APPEND_DATA |
                                     FILE_WRITE_ATTRIBUTES | FILE_WRITE_EA | WRITE_DAC | WRITE_OWNER;
@interface FCDriveHandle : NSObject
@property int fd;
@property uint32_t access, sharing;
@property BOOL directory, deleting, append;
@property(copy) NSString *path;
@property(strong) NSArray<NSString *> *listing;
@property(copy) NSString *pattern;
@property NSUInteger cursor;
@end
@implementation FCDriveHandle
- (instancetype)init {
    if ((self = [super init]))
        _fd = -1;
    return self;
}
- (void)dealloc {
    if (_fd >= 0)
        close(_fd);
}
@end
@implementation FCRDPDrive {
    NSURL *_url;
    BOOL _scoped, _readOnly, _closed;
    int _root;
    uint32_t _nextHandle;
    NSMutableDictionary<NSNumber *, FCDriveHandle *> *_handles;
}
- (instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly {
    if ((self = [super init])) {
        _url = url;
        _readOnly = readOnly;
        _root = -1;
        _scoped = [url startAccessingSecurityScopedResource];
        _root = open(url.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        _handles = [NSMutableDictionary new];
        if (_root < 0)
            return nil;
    }
    return self;
}
- (void)dealloc {
    [self shutdown];
}
- (BOOL)stillBeneath:(FCDriveHandle *)handle {
    int fd = beneath(_root, handle.path, O_RDONLY, 0);
    struct stat current, pinned;
    BOOL same = fd >= 0 && !fstat(fd, &current) && !fstat(handle.fd, &pinned) && current.st_dev == pinned.st_dev &&
                current.st_ino == pinned.st_ino;
    if (fd >= 0)
        close(fd);
    return same;
}
- (NTSTATUS)remove:(FCDriveHandle *)handle {
    if (_readOnly || !handle.path.length || ![self stillBeneath:handle])
        return STATUS_ACCESS_DENIED;
    int parent = beneath(_root, handle.path.stringByDeletingLastPathComponent, O_RDONLY | O_DIRECTORY, 0);
    if (parent < 0)
        return statusForErrno();
    int result =
        unlinkat(parent, handle.path.lastPathComponent.fileSystemRepresentation, handle.directory ? AT_REMOVEDIR : 0);
    NTSTATUS status = result == 0 ? STATUS_SUCCESS : statusForErrno();
    close(parent);
    return status;
}
- (void)shutdown {
    if (_closed)
        return;
    _closed = YES;
    // Cancelled sessions retire handles without performing pending deletion.
    [_handles removeAllObjects];
    if (_root >= 0) {
        close(_root);
        _root = -1;
    }
    if (_scoped) {
        [_url stopAccessingSecurityScopedResource];
        _scoped = NO;
    }
}
- (NTSTATUS)create:(Reader *)r output:(wStream *)out {
    uint32_t access = (uint32_t)take(r, 4);
    (void)take(r, 8);
    (void)take(r, 4);
    uint32_t sharing = (uint32_t)take(r, 4), disposition = (uint32_t)take(r, 4), options = (uint32_t)take(r, 4);
    uint32_t length = (uint32_t)take(r, 4);
    NSString *path = relativePath(string(r, length));
    if (!r->valid || !path || disposition > FILE_OVERWRITE_IF || _handles.count >= 1024)
        return STATUS_INVALID_PARAMETER;
    if (access & MAXIMUM_ALLOWED)
        access |= _readOnly ? GENERIC_READ : GENERIC_READ | GENERIC_WRITE | DELETE;
    BOOL mutation = (access & mutationMask) || disposition != FILE_OPEN || (options & FILE_DELETE_ON_CLOSE);
    if (_readOnly && mutation)
        return STATUS_ACCESS_DENIED;
    if ((options & FILE_DELETE_ON_CLOSE) && !(access & (DELETE | GENERIC_ALL)))
        return STATUS_ACCESS_DENIED;
    BOOL directory = (options & FILE_DIRECTORY_FILE) != 0;
    struct stat existing;
    BOOL exists = NO;
    int checkFD = beneath(_root, path, O_RDONLY, 0);
    if (checkFD >= 0) {
        exists = !fstat(checkFD, &existing);
        close(checkFD);
    }
    for (FCDriveHandle *h in _handles.allValues) {
        struct stat pinned;
        BOOL same = [h.path isEqual:path] || (exists && !fstat(h.fd, &pinned) && pinned.st_dev == existing.st_dev &&
                                              pinned.st_ino == existing.st_ino);
        if (!same)
            continue;
        if (h.deleting)
            return STATUS_DELETE_PENDING;
        if (((access & readMask) && !(h.sharing & FILE_SHARE_READ)) ||
            ((access & writeMask) && !(h.sharing & FILE_SHARE_WRITE)) ||
            ((access & (DELETE | GENERIC_ALL)) && !(h.sharing & FILE_SHARE_DELETE)) ||
            ((h.access & readMask) && !(sharing & FILE_SHARE_READ)) ||
            ((h.access & writeMask) && !(sharing & FILE_SHARE_WRITE)) ||
            ((h.access & (DELETE | GENERIC_ALL)) && !(sharing & FILE_SHARE_DELETE)))
            return STATUS_SHARING_VIOLATION;
    }
    if (exists && disposition == FILE_CREATE)
        return STATUS_OBJECT_NAME_COLLISION;
    if (!exists && (disposition == FILE_OPEN || disposition == FILE_OVERWRITE))
        return STATUS_OBJECT_NAME_NOT_FOUND;
    if (exists && !S_ISREG(existing.st_mode) && !S_ISDIR(existing.st_mode))
        return STATUS_ACCESS_DENIED;
    if (exists)
        directory = S_ISDIR(existing.st_mode);
    if ((options & FILE_NON_DIRECTORY_FILE) && directory)
        return STATUS_FILE_IS_A_DIRECTORY;
    if ((options & FILE_DIRECTORY_FILE) && exists && !directory)
        return STATUS_NOT_A_DIRECTORY;
    if (!path.length && (mutation || !directory))
        return STATUS_ACCESS_DENIED;
    int flags = access & writeMask ? O_RDWR : O_RDONLY;
    if (directory) {
        if (!exists) {
            int parent = beneath(_root, path.stringByDeletingLastPathComponent, O_RDONLY | O_DIRECTORY, 0);
            if (parent < 0)
                return statusForErrno();
            int result = mkdirat(parent, path.lastPathComponent.fileSystemRepresentation, 0700);
            close(parent);
            if (result)
                return statusForErrno();
        } else if (disposition == FILE_SUPERSEDE || disposition == FILE_OVERWRITE || disposition == FILE_OVERWRITE_IF)
            return STATUS_ACCESS_DENIED;
        flags = O_RDONLY | O_DIRECTORY;
    } else {
        if (disposition == FILE_CREATE)
            flags |= O_CREAT | O_EXCL;
        else if (disposition == FILE_OPEN_IF)
            flags |= O_CREAT;
        else if (disposition == FILE_SUPERSEDE || disposition == FILE_OVERWRITE_IF)
            flags |= O_CREAT;
        if (disposition == FILE_SUPERSEDE || disposition == FILE_OVERWRITE || disposition == FILE_OVERWRITE_IF) {
            if (!(access & writeMask))
                return STATUS_ACCESS_DENIED;
            flags |= O_TRUNC;
        }
    }
    int fd = beneath(_root, path, flags, 0600);
    if (fd < 0)
        return statusForErrno();
    struct stat info;
    if (fstat(fd, &info) || (!S_ISDIR(info.st_mode) && !S_ISREG(info.st_mode))) {
        close(fd);
        return STATUS_ACCESS_DENIED;
    }
    FCDriveHandle *h = [FCDriveHandle new];
    h.fd = fd;
    h.path = path;
    h.access = access;
    h.sharing = sharing;
    h.directory = S_ISDIR(info.st_mode);
    h.deleting = (options & FILE_DELETE_ON_CLOSE) != 0;
    h.append = (access & FILE_APPEND_DATA) && !(access & (FILE_WRITE_DATA | GENERIC_WRITE | GENERIC_ALL));
    uint32_t identifier = 1;
    while (_handles[@(identifier)])
        identifier++;
    _handles[@(identifier)] = h;
    Stream_Write_UINT32(out, identifier);
    Stream_Write_UINT8(
        out, exists
                 ? (disposition == FILE_OVERWRITE || disposition == FILE_OVERWRITE_IF ? FILE_OVERWRITTEN : FILE_OPENED)
                 : FILE_SUPERSEDED);
    return STATUS_SUCCESS;
}
- (void)basic:(wStream *)out info:(struct stat)s {
    Stream_Write_UINT64(out, fileTime(s.st_birthtimespec));
    Stream_Write_UINT64(out, fileTime(s.st_atimespec));
    Stream_Write_UINT64(out, fileTime(s.st_mtimespec));
    Stream_Write_UINT64(out, fileTime(s.st_ctimespec));
    Stream_Write_UINT32(out, attributes(s, _readOnly));
}
- (NTSTATUS)query:(FCDriveHandle *)h kind:(uint32_t)kind output:(wStream *)out {
    struct stat s;
    if (fstat(h.fd, &s))
        return statusForErrno();
    switch (kind) {
    case FileBasicInformation:
        [self basic:out info:s];
        break;
    case FileStandardInformation:
        Stream_Write_UINT64(out, (uint64_t)s.st_blocks * 512);
        Stream_Write_UINT64(out, h.directory ? 0 : s.st_size);
        Stream_Write_UINT32(out, (uint32_t)s.st_nlink);
        Stream_Write_UINT8(out, h.deleting);
        Stream_Write_UINT8(out, h.directory);
        break;
    case FileNameInformation:
    case FileAllInformation: {
        NSData *name = [[@"\\" stringByAppendingString:[h.path stringByReplacingOccurrencesOfString:@"/"
                                                                                         withString:@"\\"]]
            dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        if (kind == FileAllInformation) {
            [self basic:out info:s];
            Stream_Write_UINT32(out, 0);
            Stream_Write_UINT64(out, (uint64_t)s.st_blocks * 512);
            Stream_Write_UINT64(out, h.directory ? 0 : s.st_size);
            Stream_Write_UINT32(out, (uint32_t)s.st_nlink);
            Stream_Write_UINT8(out, h.deleting);
            Stream_Write_UINT8(out, h.directory);
            Stream_Write_UINT16(out, 0);
            Stream_Write_UINT64(out, s.st_ino);
            Stream_Write_UINT32(out, 0); // Extended attribute size.
            Stream_Write_UINT32(out, h.access);
            Stream_Write_UINT64(out, 0); // Reads/writes use explicit offsets.
            Stream_Write_UINT32(out, 0); // Mode.
            Stream_Write_UINT32(out, 0); // Alignment requirement.
        }
        Stream_Write_UINT32(out, (uint32_t)name.length);
        Stream_Write(out, name.bytes, name.length);
        break;
    }
    case FileAttributeTagInformation:
        Stream_Write_UINT32(out, attributes(s, _readOnly));
        Stream_Write_UINT32(out, 0);
        break;
    case FileEndOfFileInformation:
        Stream_Write_UINT64(out, s.st_size);
        break;
    case FileInternalInformation:
        Stream_Write_UINT64(out, s.st_ino);
        break;
    default:
        return STATUS_NOT_SUPPORTED;
    }
    return STATUS_SUCCESS;
}
- (NTSTATUS)set:(FCDriveHandle *)h kind:(uint32_t)kind reader:(Reader *)r {
    if (_readOnly || ![self stillBeneath:h])
        return STATUS_ACCESS_DENIED;
    if (kind == FileDispositionInformation) {
        if (!(h.access & (DELETE | GENERIC_ALL)) || !h.path.length)
            return STATUS_ACCESS_DENIED;
        BOOL deleting = take(r, 1) != 0;
        if (!r->valid)
            return STATUS_INVALID_PARAMETER;
        if (deleting && h.directory) {
            DIR *directory = fdopendir(dup(h.fd));
            if (!directory)
                return statusForErrno();
            rewinddir(directory);
            BOOL empty = YES;
            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
                    empty = NO;
                    break;
                }
            }
            closedir(directory);
            if (!empty)
                return STATUS_DIRECTORY_NOT_EMPTY;
        }
        h.deleting = deleting;
        return STATUS_SUCCESS;
    }
    if (kind == FileRenameInformation) {
        if (!(h.access & (DELETE | GENERIC_ALL)) || !h.path.length)
            return STATUS_ACCESS_DENIED;
        BOOL replace = take(r, 1) != 0;
        if (take(r, 1) != 0)
            return STATUS_NOT_SUPPORTED;
        uint32_t length = (uint32_t)take(r, 4);
        NSString *target = relativePath(string(r, length));
        if (!r->valid || !target.length)
            return STATUS_INVALID_PARAMETER;
        for (FCDriveHandle *other in _handles.allValues)
            if (([other.path isEqual:target] || [other.path isEqual:h.path]) && other != h &&
                !(other.sharing & FILE_SHARE_DELETE))
                return STATUS_SHARING_VIOLATION;
        int from = beneath(_root, h.path.stringByDeletingLastPathComponent, O_RDONLY | O_DIRECTORY, 0);
        int to = beneath(_root, target.stringByDeletingLastPathComponent, O_RDONLY | O_DIRECTORY, 0);
        if (from < 0 || to < 0) {
            if (from >= 0)
                close(from);
            if (to >= 0)
                close(to);
            return STATUS_ACCESS_DENIED;
        }
        struct stat destination;
        BOOL exists =
            !fstatat(to, target.lastPathComponent.fileSystemRepresentation, &destination, AT_SYMLINK_NOFOLLOW);
        if (exists && (!S_ISREG(destination.st_mode) || h.directory)) {
            close(from);
            close(to);
            return STATUS_ACCESS_DENIED;
        }
        int result = renameatx_np(from, h.path.lastPathComponent.fileSystemRepresentation, to,
                                  target.lastPathComponent.fileSystemRepresentation, replace ? 0 : RENAME_EXCL);
        NTSTATUS status = result == 0 ? STATUS_SUCCESS : statusForErrno();
        close(from);
        close(to);
        if (!result) {
            NSString *old = h.path;
            for (FCDriveHandle *other in _handles.allValues) {
                if ([other.path isEqual:old])
                    other.path = target;
                else if ([other.path hasPrefix:[old stringByAppendingString:@"/"]])
                    other.path = [target stringByAppendingString:[other.path substringFromIndex:old.length]];
            }
        }
        return status;
    }
    if (kind == FileEndOfFileInformation || kind == FileAllocationInformation) {
        if (!(h.access & writeMask) || h.directory)
            return STATUS_ACCESS_DENIED;
        uint64_t size = take(r, 8);
        if (!r->valid || size > INT64_MAX)
            return STATUS_INVALID_PARAMETER;
        // Allocation is a hint, never an instruction to discard existing content.
        if (kind == FileAllocationInformation)
            return STATUS_SUCCESS;
        return ftruncate(h.fd, (off_t)size) == 0 ? STATUS_SUCCESS : statusForErrno();
    }
    if (kind == FileBasicInformation) {
        if (!(h.access & (FILE_WRITE_ATTRIBUTES | GENERIC_WRITE | GENERIC_ALL)))
            return STATUS_ACCESS_DENIED;
        uint64_t birth = take(r, 8), accessed = take(r, 8), modified = take(r, 8);
        (void)take(r, 8);
        uint32_t attrs = (uint32_t)take(r, 4);
        if (attrs & ~(FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NORMAL | FILE_ATTRIBUTE_ARCHIVE |
                      FILE_ATTRIBUTE_DIRECTORY))
            return STATUS_NOT_SUPPORTED;
        if (!r->valid)
            return STATUS_INVALID_PARAMETER;
        struct stat info;
        if (fstat(h.fd, &info))
            return statusForErrno();
        struct attrlist list = {0};
        list.bitmapcount = ATTR_BIT_MAP_COUNT;
        struct timespec times[3];
        NSUInteger count = 0;
        if (birth && birth != UINT64_MAX) {
            list.commonattr |= ATTR_CMN_CRTIME;
            times[count++] = unixTime(birth);
        }
        if (modified && modified != UINT64_MAX) {
            list.commonattr |= ATTR_CMN_MODTIME;
            times[count++] = unixTime(modified);
        }
        if (accessed && accessed != UINT64_MAX) {
            list.commonattr |= ATTR_CMN_ACCTIME;
            times[count++] = unixTime(accessed);
        }
        if (count && fsetattrlist(h.fd, &list, times, count * sizeof(struct timespec), 0))
            return statusForErrno();
        if (attrs) {
            if (attrs & ~(FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NORMAL |
                          FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_DIRECTORY))
                return STATUS_NOT_SUPPORTED;
            mode_t mode = attrs & FILE_ATTRIBUTE_READONLY ? info.st_mode & ~0222 : info.st_mode | 0200;
            if (fchmod(h.fd, mode & 0777) ||
                fchflags(h.fd, attrs & FILE_ATTRIBUTE_HIDDEN ? info.st_flags | UF_HIDDEN : info.st_flags & ~UF_HIDDEN))
                return statusForErrno();
        }
        return STATUS_SUCCESS;
    }
    return STATUS_NOT_SUPPORTED;
}
- (NTSTATUS)directory:(FCDriveHandle *)h reader:(Reader *)r output:(wStream *)out {
    uint32_t kind = (uint32_t)take(r, 4);
    BOOL initial = take(r, 1) != 0;
    uint32_t length = (uint32_t)take(r, 4);
    skip(r, 23);
    NSString *wire = string(r, length);
    if (!r->valid || !h.directory)
        return STATUS_INVALID_PARAMETER;
    if (kind != FileDirectoryInformation && kind != FileFullDirectoryInformation &&
        kind != FileBothDirectoryInformation && kind != FileNamesInformation)
        return STATUS_NOT_SUPPORTED;
    if (initial || !h.listing) {
        NSString *path = relativePath(wire);
        if (!path)
            return STATUS_ACCESS_DENIED;
        NSString *parent = path.stringByDeletingLastPathComponent;
        if (parent.length && ![parent isEqual:h.path])
            return STATUS_ACCESS_DENIED;
        h.pattern = path.length ? path.lastPathComponent : @"*";
        if ([h.pattern isEqual:@"*.*"])
            h.pattern = @"*";
        DIR *dir = fdopendir(dup(h.fd));
        if (!dir)
            return statusForErrno();
        rewinddir(dir);
        NSMutableArray *names = [NSMutableArray new];
        struct dirent *entry;
        BOOL okay = YES;
        while (YES) {
            errno = 0;
            entry = readdir(dir);
            if (!entry) {
                okay = errno == 0;
                break;
            }
            NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
            if (!name || [name isEqual:@"."] || [name isEqual:@".."] ||
                fnmatch(h.pattern.lowercaseString.UTF8String, name.lowercaseString.UTF8String, 0))
                continue;
            struct stat s;
            if (fstatat(h.fd, entry->d_name, &s, AT_SYMLINK_NOFOLLOW) || (!S_ISREG(s.st_mode) && !S_ISDIR(s.st_mode)))
                continue;
            if (names.count == 20000) {
                okay = NO;
                break;
            }
            [names addObject:name];
        }
        closedir(dir);
        if (!okay)
            return STATUS_INSUFFICIENT_RESOURCES;
        h.listing = [names sortedArrayUsingSelector:@selector(compare:)];
        h.cursor = 0;
    }
    while (h.cursor < h.listing.count) {
        NSString *name = h.listing[h.cursor++];
        struct stat s;
        if (fstatat(h.fd, name.fileSystemRepresentation, &s, AT_SYMLINK_NOFOLLOW) ||
            (!S_ISREG(s.st_mode) && !S_ISDIR(s.st_mode)))
            continue;
        NSData *encoded = [name dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        Stream_Write_UINT32(out, 0);
        Stream_Write_UINT32(out, (uint32_t)h.cursor);
        if (kind != FileNamesInformation) {
            Stream_Write_UINT64(out, fileTime(s.st_birthtimespec));
            Stream_Write_UINT64(out, fileTime(s.st_atimespec));
            Stream_Write_UINT64(out, fileTime(s.st_mtimespec));
            Stream_Write_UINT64(out, fileTime(s.st_ctimespec));
            Stream_Write_UINT64(out, S_ISDIR(s.st_mode) ? 0 : s.st_size);
            Stream_Write_UINT64(out, (uint64_t)s.st_blocks * 512);
            Stream_Write_UINT32(out, attributes(s, _readOnly));
        }
        Stream_Write_UINT32(out, (uint32_t)encoded.length);
        if (kind == FileFullDirectoryInformation || kind == FileBothDirectoryInformation)
            Stream_Write_UINT32(out, 0);
        if (kind == FileBothDirectoryInformation) {
            Stream_Write_UINT8(out, 0);
            Stream_Write_UINT8(out, 0);
            Stream_Zero(out, 24);
        }
        Stream_Write(out, encoded.bytes, encoded.length);
        return STATUS_SUCCESS;
    }
    return STATUS_NO_MORE_FILES;
}
- (NTSTATUS)volume:(uint32_t)kind output:(wStream *)out {
    struct statfs fs;
    if (fstatfs(_root, &fs))
        return statusForErrno();
    switch (kind) {
    case FileFsVolumeInformation: {
        NSData *label = [@"Mac folder" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        Stream_Write_UINT64(out, 0);
        Stream_Write_UINT32(out, (uint32_t)fs.f_fsid.val[0]);
        Stream_Write_UINT32(out, (uint32_t)label.length);
        Stream_Write_UINT8(out, 0);
        Stream_Write(out, label.bytes, label.length);
        break;
    }
    case FileFsSizeInformation:
    case FileFsFullSizeInformation:
        Stream_Write_UINT64(out, fs.f_blocks);
        Stream_Write_UINT64(out, fs.f_bavail);
        if (kind == FileFsFullSizeInformation)
            Stream_Write_UINT64(out, fs.f_bfree);
        Stream_Write_UINT32(out, 1);
        Stream_Write_UINT32(out, fs.f_bsize);
        break;
    case FileFsDeviceInformation:
        Stream_Write_UINT32(out, FILE_DEVICE_DISK);
        Stream_Write_UINT32(out, FILE_REMOTE_DEVICE | (_readOnly ? FILE_READ_ONLY_DEVICE : 0));
        break;
    case FileFsAttributeInformation: {
        NSData *name = [@"macOS" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        Stream_Write_UINT32(out,
                            FILE_CASE_PRESERVED_NAMES | FILE_UNICODE_ON_DISK | (_readOnly ? FILE_READ_ONLY_VOLUME : 0));
        Stream_Write_UINT32(out, 255);
        Stream_Write_UINT32(out, (uint32_t)name.length);
        Stream_Write(out, name.bytes, name.length);
        break;
    }
    default:
        return STATUS_NOT_SUPPORTED;
    }
    return STATUS_SUCCESS;
}
- (void)processIRP:(IRP *)irp {
    @autoreleasepool {
        Reader r = {Stream_Pointer(irp->input), Stream_GetRemainingLength(irp->input), YES};
        wStream *out = irp->output;
        size_t start = Stream_GetPosition(out);
        irp->IoStatus = STATUS_INVALID_PARAMETER;
        if (_closed || irp->cancelled) {
            irp->IoStatus = STATUS_CANCELLED;
            irp->Complete(irp);
            return;
        }
        if (!Stream_EnsureRemainingCapacity(out, 1024 * 1024 + 4096)) {
            irp->IoStatus = STATUS_INSUFFICIENT_RESOURCES;
            irp->Complete(irp);
            return;
        }
        FCDriveHandle *h = _handles[@(irp->FileId)];
        if (irp->MajorFunction == IRP_MJ_CREATE)
            irp->IoStatus = [self create:&r output:out];
        else if (irp->MajorFunction == IRP_MJ_QUERY_VOLUME_INFORMATION) {
            uint32_t kind = (uint32_t)take(&r, 4);
            Stream_Write_UINT32(out, 0);
            irp->IoStatus = r.valid ? [self volume:kind output:out] : STATUS_INVALID_PARAMETER;
        } else if (!h)
            irp->IoStatus = STATUS_INVALID_HANDLE;
        else
            switch (irp->MajorFunction) {
            case IRP_MJ_CLOSE:
                irp->IoStatus = h.deleting ? [self remove:h] : STATUS_SUCCESS;
                [_handles removeObjectForKey:@(irp->FileId)];
                Stream_Zero(out, 5);
                break;
            case IRP_MJ_READ: {
                uint32_t length = (uint32_t)take(&r, 4);
                uint64_t offset = take(&r, 8);
                skip(&r, 20);
                if (!r.valid || length > 1024 * 1024 || offset > INT64_MAX || length > INT64_MAX - offset)
                    break;
                if (!(h.access & readMask) || h.directory) {
                    irp->IoStatus = STATUS_ACCESS_DENIED;
                    break;
                }
                NSMutableData *data = [NSMutableData dataWithLength:length];
                ssize_t count;
                do {
                    count = pread(h.fd, data.mutableBytes, length, (off_t)offset);
                } while (count < 0 && errno == EINTR);
                irp->IoStatus = count < 0 ? statusForErrno() : STATUS_SUCCESS;
                Stream_Write_UINT32(out, count < 0 ? 0 : (uint32_t)count);
                if (count > 0)
                    Stream_Write(out, data.bytes, count);
                break;
            }
            case IRP_MJ_WRITE: {
                uint32_t length = (uint32_t)take(&r, 4);
                uint64_t offset = take(&r, 8);
                skip(&r, 20);
                if (_readOnly || !(h.access & writeMask) || h.directory || ![self stillBeneath:h]) {
                    irp->IoStatus = STATUS_ACCESS_DENIED;
                    break;
                }
                if (!r.valid || length > r.left || length > 1024 * 1024 || offset > INT64_MAX ||
                    length > INT64_MAX - offset)
                    break;
                if (h.append) {
                    struct stat s;
                    if (fstat(h.fd, &s)) {
                        irp->IoStatus = statusForErrno();
                        break;
                    }
                    offset = s.st_size;
                }
                NSUInteger done = 0;
                while (done < length) {
                    ssize_t count = pwrite(h.fd, r.bytes + done, length - done, (off_t)(offset + done));
                    if (count < 0 && errno == EINTR)
                        continue;
                    if (count <= 0)
                        break;
                    done += count;
                }
                irp->IoStatus = done == length ? STATUS_SUCCESS : statusForErrno();
                Stream_Write_UINT32(out, (uint32_t)done);
                Stream_Write_UINT8(out, 0);
                break;
            }
            case IRP_MJ_QUERY_INFORMATION: {
                uint32_t kind = (uint32_t)take(&r, 4);
                Stream_Write_UINT32(out, 0);
                irp->IoStatus = r.valid ? [self query:h kind:kind output:out] : STATUS_INVALID_PARAMETER;
                break;
            }
            case IRP_MJ_SET_INFORMATION: {
                uint32_t kind = (uint32_t)take(&r, 4), length = (uint32_t)take(&r, 4);
                skip(&r, 24);
                if (!r.valid || length > r.left)
                    break;
                r.left = length;
                irp->IoStatus = [self set:h kind:kind reader:&r];
                Stream_Write_UINT32(out, length);
                break;
            }
            case IRP_MJ_DIRECTORY_CONTROL:
                Stream_Write_UINT32(out, 0);
                irp->IoStatus = irp->MinorFunction == IRP_MN_QUERY_DIRECTORY ? [self directory:h reader:&r output:out]
                                                                             : STATUS_NOT_SUPPORTED;
                break;
            default:
                irp->IoStatus = _readOnly && (irp->MajorFunction == IRP_MJ_SET_VOLUME_INFORMATION ||
                                              irp->MajorFunction == IRP_MJ_DEVICE_CONTROL)
                                    ? STATUS_ACCESS_DENIED
                                    : STATUS_NOT_SUPPORTED;
                break;
            }
        if (irp->IoStatus != STATUS_SUCCESS) {
            Stream_SetPosition(out, start);
            if (irp->MajorFunction == IRP_MJ_CREATE || irp->MajorFunction == IRP_MJ_CLOSE ||
                irp->MajorFunction == IRP_MJ_WRITE)
                Stream_Zero(out, 5);
            else
                Stream_Write_UINT32(out, 0);
        } else if (irp->MajorFunction == IRP_MJ_QUERY_INFORMATION ||
                   irp->MajorFunction == IRP_MJ_QUERY_VOLUME_INFORMATION ||
                   irp->MajorFunction == IRP_MJ_DIRECTORY_CONTROL) {
            size_t end = Stream_GetPosition(out);
            Stream_SetPosition(out, start);
            Stream_Write_UINT32(out, (uint32_t)(end - start - 4));
            Stream_SetPosition(out, end);
        }
        (void)irp->Complete(irp);
    }
}
@end
