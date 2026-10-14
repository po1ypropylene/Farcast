#import "RDPDrive.h"
#define REFIID WINPR_REFIID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <freerdp/channels/rdpdr.h>
#pragma clang diagnostic pop
#import <fcntl.h>
#import <unistd.h>
static NTSTATUS result;
static NSData *output;
static NSUInteger checks;
static void check(BOOL value, const char *message) {
    if (!value) {
        fprintf(stderr, "FAIL redirected folder: %s\n", message);
        exit(1);
    }
    checks++;
}
static UINT completed(IRP *irp) {
    result = irp->IoStatus;
    output = [NSData dataWithBytes:Stream_Buffer(irp->output) length:Stream_GetPosition(irp->output)];
    return 0;
}
static void invoke(FCRDPDrive *drive, UINT32 major, UINT32 file, UINT32 minor, wStream *input) {
    Stream_SealLength(input);
    Stream_SetPosition(input, 0);
    IRP irp = {0};
    irp.MajorFunction = major;
    irp.MinorFunction = minor;
    irp.FileId = file;
    irp.input = input;
    irp.output = Stream_New(NULL, 128);
    irp.Complete = completed;
    [drive processIRP:&irp];
    if (major == IRP_MJ_DIRECTORY_CONTROL && minor == IRP_MN_QUERY_DIRECTORY && result != STATUS_SUCCESS) {
        check(output.length == 5 && memcmp(output.bytes, (BYTE[5]){0}, 5) == 0,
              "Windows empty directory response includes its padding byte");
    }
    Stream_Free(irp.output, TRUE);
    Stream_Free(input, TRUE);
}
static UINT32 create(FCRDPDrive *drive, NSString *path, UINT32 access, UINT32 disposition, UINT32 options,
                     UINT32 share) {
    wStream *s = Stream_New(NULL, 17000);
    NSMutableData *name = [[path dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
    uint16_t zero = 0;
    [name appendBytes:&zero length:2];
    Stream_Write_UINT32(s, access);
    Stream_Write_UINT64(s, 0);
    Stream_Write_UINT32(s, FILE_ATTRIBUTE_NORMAL);
    Stream_Write_UINT32(s, share);
    Stream_Write_UINT32(s, disposition);
    Stream_Write_UINT32(s, options);
    Stream_Write_UINT32(s, (UINT32)name.length);
    Stream_Write(s, name.bytes, name.length);
    invoke(drive, IRP_MJ_CREATE, 0, 0, s);
    if (result != STATUS_SUCCESS)
        return 0;
    uint32_t identifier;
    memcpy(&identifier, output.bytes, 4);
    return CFSwapInt32LittleToHost(identifier);
}
static void closeFile(FCRDPDrive *drive, UINT32 identifier) {
    invoke(drive, IRP_MJ_CLOSE, identifier, 0, Stream_New(NULL, 1));
}
static void readFile(FCRDPDrive *drive, UINT32 identifier, uint64_t offset, UINT32 length) {
    wStream *s = Stream_New(NULL, 32);
    Stream_Write_UINT32(s, length);
    Stream_Write_UINT64(s, offset);
    Stream_Zero(s, 20);
    invoke(drive, IRP_MJ_READ, identifier, 0, s);
}
static void writeFile(FCRDPDrive *drive, UINT32 identifier, uint64_t offset, NSData *bytes) {
    wStream *s = Stream_New(NULL, bytes.length + 32);
    Stream_Write_UINT32(s, (UINT32)bytes.length);
    Stream_Write_UINT64(s, offset);
    Stream_Zero(s, 20);
    Stream_Write(s, bytes.bytes, bytes.length);
    invoke(drive, IRP_MJ_WRITE, identifier, 0, s);
}
static void setInfo(FCRDPDrive *drive, UINT32 identifier, UINT32 kind, NSData *bytes) {
    wStream *s = Stream_New(NULL, bytes.length + 32);
    Stream_Write_UINT32(s, kind);
    Stream_Write_UINT32(s, (UINT32)bytes.length);
    Stream_Zero(s, 24);
    Stream_Write(s, bytes.bytes, bytes.length);
    invoke(drive, IRP_MJ_SET_INFORMATION, identifier, 0, s);
}
static void queryInfo(FCRDPDrive *drive, UINT32 identifier, UINT32 kind) {
    wStream *s = Stream_New(NULL, 32);
    Stream_Write_UINT32(s, kind);
    Stream_Write_UINT32(s, 0);
    Stream_Zero(s, 24);
    invoke(drive, IRP_MJ_QUERY_INFORMATION, identifier, 0, s);
}
static NSData *renameData(NSString *path, BOOL replace) {
    NSMutableData *data = [NSMutableData dataWithBytes:(BYTE[]){replace, 0} length:2];
    NSData *name = [path dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    uint32_t length = CFSwapInt32HostToLittle((uint32_t)name.length);
    [data appendBytes:&length length:4];
    [data appendData:name];
    return data;
}
static void queryDirectory(FCRDPDrive *drive, UINT32 file, UINT32 kind, BOOL initial, NSString *pattern) {
    wStream *s = Stream_New(NULL, 17000);
    NSMutableData *path = [[pattern dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
    if (initial) {
        uint16_t zero = 0;
        [path appendBytes:&zero length:2];
    }
    Stream_Write_UINT32(s, kind);
    Stream_Write_UINT8(s, initial);
    Stream_Write_UINT32(s, (UINT32)path.length);
    Stream_Zero(s, 23);
    if (path.length)
        Stream_Write(s, path.bytes, path.length);
    invoke(drive, IRP_MJ_DIRECTORY_CONTROL, file, IRP_MN_QUERY_DIRECTORY, s);
}
static uint32_t word(NSData *data, NSUInteger offset) {
    uint32_t value;
    check(offset + 4 <= data.length, "directory field bounds");
    memcpy(&value, (const BYTE *)data.bytes + offset, 4);
    return CFSwapInt32LittleToHost(value);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        NSURL *root = [NSURL fileURLWithPath:@(argv[1])];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *export = [root URLByAppendingPathComponent:@"export"];
        NSURL *outside = [root URLByAppendingPathComponent:@"outside"];
        [fm createDirectoryAtURL:export withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtURL:outside withIntermediateDirectories:YES attributes:nil error:NULL];
        NSData *payload = [@"Synthetic bytes 繁體😀" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *original = [export URLByAppendingPathComponent:@"original.bin"];
        [payload writeToURL:original atomically:YES];
        [payload writeToURL:[export URLByAppendingPathComponent:@"繁體😀.bin"] atomically:YES];
        NSURL *nested = [export URLByAppendingPathComponent:@"Nested/繁體😀"];
        [fm createDirectoryAtURL:nested withIntermediateDirectories:YES attributes:nil error:NULL];
        [payload writeToURL:[nested URLByAppendingPathComponent:@"original.bin"] atomically:YES];
        [payload writeToURL:[nested URLByAppendingPathComponent:@"繁體😀.bin"] atomically:YES];
        [payload writeToURL:[outside URLByAppendingPathComponent:@"protected.bin"] atomically:YES];
        symlink(outside.fileSystemRepresentation,
                [export URLByAppendingPathComponent:@"escape"].fileSystemRepresentation);
        symlink(original.fileSystemRepresentation,
                [export URLByAppendingPathComponent:@"link"].fileSystemRepresentation);
        FCRDPDrive *rw = [[FCRDPDrive alloc] initWithURL:export readOnly:NO];
        UINT32 fullAccess = GENERIC_READ | GENERIC_WRITE | DELETE;
        UINT32 shares = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        UINT32 h = create(rw, @"\\new.bin", fullAccess, FILE_CREATE, FILE_NON_DIRECTORY_FILE, shares);
        check(h > 0, "create writable file");
        writeFile(rw, h, 0, payload);
        check(result == STATUS_SUCCESS, "write");
        readFile(rw, h, 0, (UINT32)payload.length);
        check(result == STATUS_SUCCESS && [[output subdataWithRange:NSMakeRange(4, output.length - 4)] isEqual:payload],
              "read byte equality");
        readFile(rw, h, payload.length, 1);
        check(result == STATUS_SUCCESS && output.length == 4 && memcmp(output.bytes, (BYTE[4]){0}, 4) == 0,
              "file EOF retains its four-byte empty read response");
        writeFile(rw, h, (1ULL << 32) + 9, [@"large" dataUsingEncoding:NSUTF8StringEncoding]);
        check(result == STATUS_SUCCESS, "64-bit write");
        readFile(rw, h, (1ULL << 32) + 9, 5);
        check(result == STATUS_SUCCESS && output.length == 9, "64-bit read");
        uint64_t size = CFSwapInt64HostToLittle(payload.length);
        setInfo(rw, h, FileEndOfFileInformation, [NSData dataWithBytes:&size length:8]);
        check(result == STATUS_SUCCESS, "truncate");
        for (NSNumber *kind in
             @[ @(FileNameInformation), @(FileAllInformation), @(FileBasicInformation), @(FileStandardInformation) ]) {
            queryInfo(rw, h, kind.unsignedIntValue);
            check(result == STATUS_SUCCESS && output.length > 8, "query name/basic/standard/all metadata");
        }
        setInfo(rw, h, FileRenameInformation, renameData(@"\\renamed.bin", NO));
        check(result == STATUS_SUCCESS, "rename");
        check([fm fileExistsAtPath:[export URLByAppendingPathComponent:@"renamed.bin"].path], "rename destination");
        setInfo(rw, h, FileRenameInformation, renameData(@"\\escape\\outside.bin", YES));
        check(result == STATUS_ACCESS_DENIED, "rename intermediate symlink denied");
        setInfo(rw, h, FileDispositionInformation, [NSData dataWithBytes:(BYTE[]){1} length:1]);
        check(result == STATUS_SUCCESS, "delete pending");
        closeFile(rw, h);
        check(result == STATUS_SUCCESS &&
                  ![fm fileExistsAtPath:[export URLByAppendingPathComponent:@"renamed.bin"].path],
              "delete on close");
        for (NSString *bad in @[
                 @"\\..\\outside\\protected.bin", @"/absolute", @"C:\\absolute", @"\\\\network\\share",
                 @"escape/protected.bin", @"link"
             ]) {
            check(create(rw, bad, fullAccess, FILE_OPEN_IF, 0, shares) == 0, "traversal/link open refused");
        }
        h = create(rw, @"original.bin", GENERIC_READ, FILE_OPEN, 0, 0);
        check(h > 0, "exclusive open");
        check(create(rw, @"original.bin", GENERIC_WRITE, FILE_OPEN, 0, shares) == 0 &&
                  result == STATUS_SHARING_VIOLATION,
              "share conflict");
        closeFile(rw, h);
        UINT32 directory = create(rw, @"\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        check(directory > 0, "root directory open");
        NSMutableSet *listed = [NSMutableSet new];
        for (NSUInteger i = 0; i < 10; i++) {
            wStream *s = Stream_New(NULL, 40);
            NSData *pattern = [@"\\*" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
            Stream_Write_UINT32(s, FileNamesInformation);
            Stream_Write_UINT8(s, i == 0);
            Stream_Write_UINT32(s, (UINT32)pattern.length);
            Stream_Zero(s, 23);
            Stream_Write(s, pattern.bytes, pattern.length);
            invoke(rw, IRP_MJ_DIRECTORY_CONTROL, directory, IRP_MN_QUERY_DIRECTORY, s);
            if (result == STATUS_NO_MORE_FILES)
                break;
            check(result == STATUS_SUCCESS && output.length >= 16, "directory page");
            NSString *name = [[NSString alloc] initWithBytes:(BYTE *)output.bytes + 16
                                                      length:output.length - 16
                                                    encoding:NSUTF16LittleEndianStringEncoding];
            [listed addObject:name];
        }
        check([listed containsObject:@"original.bin"] && ![listed containsObject:@"escape"] &&
                  ![listed containsObject:@"link"],
              "listing excludes links");
        closeFile(rw, directory);
        // MS-RDPEFS omits native-structure reserved fields. Decode all four
        // formats at their specified wire offsets, independently of the writer.
        const UINT32 directoryKinds[] = {FileDirectoryInformation, FileFullDirectoryInformation,
                                         FileBothDirectoryInformation, FileNamesInformation};
        const NSUInteger fixedLengths[] = {64, 68, 93, 12};
        for (NSString *base in @[ @"", @"Nested\\繁體😀" ]) {
            for (NSUInteger kindIndex = 0; kindIndex < 4; kindIndex++) {
                NSString *path = [@"\\" stringByAppendingString:base];
                UINT32 handle = create(rw, path, GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
                check(handle != 0, "Explorer root or nested directory open");
                NSMutableSet *names = [NSMutableSet new];
                BOOL finished = NO;
                for (NSUInteger page = 0; page < 20; page++) {
                    queryDirectory(rw, handle, directoryKinds[kindIndex], page == 0,
                                   page == 0 ? (base.length ? [path stringByAppendingString:@"\\*.*"] : @"\\*.*")
                                             : nil);
                    if (result == STATUS_NO_MORE_FILES) {
                        finished = YES;
                        break;
                    }
                    check(result == STATUS_SUCCESS, "Explorer directory query succeeds");
                    NSUInteger nameOffset = 4 + fixedLengths[kindIndex];
                    uint32_t length = word(output, 4 + (directoryKinds[kindIndex] == FileNamesInformation ? 8 : 60));
                    check(word(output, 0) == fixedLengths[kindIndex] + length && output.length == nameOffset + length,
                          "directory wire length excludes native padding");
                    check(word(output, 4) == 0 && length % 2 == 0, "single complete directory entry");
                    NSString *name = [[NSString alloc] initWithBytes:(const BYTE *)output.bytes + nameOffset
                                                              length:length
                                                            encoding:NSUTF16LittleEndianStringEncoding];
                    check(name != nil, "directory wire name decodes");
                    [names addObject:name];
                }
                check(finished && [names containsObject:@"original.bin"] && [names containsObject:@"繁體😀.bin"] &&
                          ![names containsObject:@"escape"] && ![names containsObject:@"link"],
                      "all directory formats preserve Unicode and confined pagination");
                closeFile(rw, handle);
            }
        }
        // Independent cursors must not share the root's seek position. A folder
        // larger than the former snapshot cap must enumerate completely.
        NSURL *many = [export URLByAppendingPathComponent:@"Many"];
        [fm createDirectoryAtURL:many withIntermediateDirectories:NO attributes:nil error:NULL];
        for (NSUInteger i = 0; i < 20005; i++) {
            NSURL *url = [many URLByAppendingPathComponent:[NSString stringWithFormat:@"item-%05lu", (unsigned long)i]];
            check([NSData.data writeToURL:url atomically:NO], "large directory fixture file");
        }
        UINT32 first = create(rw, @"Many", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        UINT32 second = create(rw, @"Many", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        NSMutableSet *manyNames = [NSMutableSet new];
        NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
        for (NSUInteger i = 0; i <= 20005; i++) {
            queryDirectory(rw, first, FileNamesInformation, i == 0, i == 0 ? @"Many/*" : nil);
            if (result == STATUS_NO_MORE_FILES)
                break;
            check(result == STATUS_SUCCESS, "large streamed listing does not hit the old 20000-entry cap");
            NSString *name = [[NSString alloc] initWithBytes:(const BYTE *)output.bytes + 16
                                                      length:word(output, 12)
                                                    encoding:NSUTF16LittleEndianStringEncoding];
            [manyNames addObject:name];
            if (i == 10) {
                queryDirectory(rw, second, FileNamesInformation, YES, @"Many/*");
                check(result == STATUS_SUCCESS, "independent search starts during another enumeration");
                queryDirectory(rw, second, FileNamesInformation, YES, @"Many/*");
                check(result == STATUS_SUCCESS, "restarting a second search preserves the first cursor");
            }
        }
        check(result == STATUS_NO_MORE_FILES && manyNames.count == 20005,
              "large search has no missing or duplicate entries");
        printf("PASS streamed 20005-entry local enumeration in %.3f seconds (no network)\n",
               NSProcessInfo.processInfo.systemUptime - began);
        closeFile(rw, first);
        closeFile(rw, second);
        UINT32 metadataOnly = create(rw, @"Many", FILE_READ_ATTRIBUTES, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        queryDirectory(rw, metadataOnly, FileNamesInformation, YES, @"Many/*");
        check(result == STATUS_ACCESS_DENIED, "directory listing requires list-directory access");
        closeFile(rw, metadataOnly);
        for (FCRDPDrive *drive in @[ rw, [[FCRDPDrive alloc] initWithURL:export readOnly:YES] ]) {
            UINT32 file = create(drive, @"\\Nested\\繁體😀\\original.bin", GENERIC_READ, FILE_OPEN,
                                 FILE_NON_DIRECTORY_FILE, shares);
            check(file != 0, "nested Unicode file open");
            readFile(drive, file, 0, (UINT32)payload.length);
            check(result == STATUS_SUCCESS &&
                      [[output subdataWithRange:NSMakeRange(4, output.length - 4)] isEqual:payload],
                  "nested file byte equality");
            queryInfo(drive, file, FileNameInformation);
            check(result == STATUS_SUCCESS && output.length >= 8 && word(output, 4) == output.length - 8,
                  "nested file name metadata has a complete bounded response");
            NSString *name = [[NSString alloc] initWithBytes:(const BYTE *)output.bytes + 8
                                                      length:output.length - 8
                                                    encoding:NSUTF16LittleEndianStringEncoding];
            check(result == STATUS_SUCCESS && [name isEqual:@"\\Nested\\繁體😀\\original.bin"],
                  "nested file metadata retains canonical name");
            const UINT32 kinds[] = {FileBasicInformation, FileStandardInformation, FileAttributeTagInformation};
            const UINT32 lengths[] = {36, 22, 8};
            for (NSUInteger i = 0; i < 3; i++) {
                queryInfo(drive, file, kinds[i]);
                check(result == STATUS_SUCCESS && word(output, 0) == lengths[i] && output.length == lengths[i] + 4,
                      "file metadata has packed RDP length");
                if (kinds[i] == FileStandardInformation)
                    check(((const BYTE *)output.bytes)[25] == 0, "file metadata identifies a file");
            }
            closeFile(drive, file);
            file = create(drive, @"\\Nested\\繁體😀\\original.bin", GENERIC_READ | GENERIC_WRITE, FILE_OPEN,
                          FILE_NON_DIRECTORY_FILE, shares);
            if (drive == rw) {
                check(file != 0, "nested writable file open");
                writeFile(drive, file, 0, payload);
                check(result == STATUS_SUCCESS, "nested file write");
                readFile(drive, file, 0, (UINT32)payload.length);
                check(result == STATUS_SUCCESS &&
                          [[output subdataWithRange:NSMakeRange(4, output.length - 4)] isEqual:payload],
                      "nested write-read byte equality");
                closeFile(drive, file);
            } else {
                check(file == 0 && result == STATUS_ACCESS_DENIED, "nested read-only write open denied");
            }
            directory = create(drive, @"\\Nested\\繁體😀\\", GENERIC_READ, FILE_OPEN, 0, shares);
            check(directory != 0, "trailing separator conveys directory intent without create option");
            queryInfo(drive, directory, FileStandardInformation);
            check(result == STATUS_SUCCESS && output.length == 26 && ((const BYTE *)output.bytes)[25] == 1,
                  "nested directory metadata identifies a directory");
            queryDirectory(drive, directory, FileBothDirectoryInformation, YES, @"\\Nested\\繁體😀\\*.*");
            check(result == STATUS_SUCCESS, "nested directory browsing on both access policies");
            queryDirectory(drive, directory, FileBothDirectoryInformation, YES, @"\\Nested\\other\\*.*");
            check(result == STATUS_ACCESS_DENIED, "directory query cannot target a different parent");
            closeFile(drive, directory);
            check(create(drive, @"\\Nested\\繁體😀\\original.bin\\", GENERIC_READ, FILE_OPEN, 0, shares) == 0 &&
                      result == STATUS_NOT_A_DIRECTORY,
                  "trailing separator cannot turn a regular file into a directory");
            check(create(drive, @"\\Nested\\繁體😀\\\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares) == 0,
                  "normalization does not accept repeated separators");
            check(create(drive, @"\\Nested\\..\\outside\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares) == 0,
                  "directory suffix does not weaken traversal rejection");
            check(create(drive, @"\\escape\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares) == 0,
                  "directory suffix does not follow a symlink");
            check([[NSData dataWithContentsOfURL:[nested URLByAppendingPathComponent:@"original.bin"]] isEqual:payload],
                  "nested file preserves its bytes under both access policies");
        }
        directory = create(rw, @"\\Nested\\繁體😀\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        check(directory != 0, "directory open with trailing separator");
        queryDirectory(rw, directory, FileBothDirectoryInformation, YES, @"\\Nested\\繁體😀\\*.*");
        check(result == STATUS_SUCCESS, "trailing-separator directory lists its own children");
        closeFile(rw, directory);
        directory = create(rw, @"\\Nested\\繁體😀\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, 0);
        check(directory != 0 &&
                  create(rw, @"\\Nested\\繁體😀", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares) == 0 &&
                  result == STATUS_SHARING_VIOLATION,
              "directory aliases share the same access policy and handle identity");
        closeFile(rw, directory);
        h = create(rw, @"\\Nested\\繁體😀\\new.bin", fullAccess, FILE_CREATE, FILE_NON_DIRECTORY_FILE, shares);
        check(h != 0, "create file inside nested folder");
        writeFile(rw, h, 0, payload);
        check(result == STATUS_SUCCESS, "write newly created nested file");
        setInfo(rw, h, FileRenameInformation, renameData(@"\\Nested\\繁體😀\\renamed.bin", NO));
        check(result == STATUS_SUCCESS, "rename file inside nested folder");
        readFile(rw, h, 0, (UINT32)payload.length);
        check(result == STATUS_SUCCESS && [[output subdataWithRange:NSMakeRange(4, output.length - 4)] isEqual:payload],
              "renamed nested file retains bytes and handle");
        setInfo(rw, h, FileDispositionInformation, [NSData dataWithBytes:(BYTE[]){1} length:1]);
        check(result == STATUS_SUCCESS, "mark nested file for deletion");
        closeFile(rw, h);
        check(result == STATUS_SUCCESS &&
                  ![fm fileExistsAtPath:[nested URLByAppendingPathComponent:@"renamed.bin"].path],
              "delete nested file on close");
        directory = create(rw, @"\\Nested\\Empty\\", fullAccess, FILE_CREATE, FILE_DIRECTORY_FILE, shares);
        check(directory != 0, "create nested directory with a trailing separator");
        queryDirectory(rw, directory, FileBothDirectoryInformation, YES, @"\\Nested\\Empty\\*.*");
        check(result == STATUS_NO_SUCH_FILE, "empty nested directory enumerates without a malformed reply");
        setInfo(rw, directory, FileRenameInformation, renameData(@"\\Nested\\RenamedEmpty\\", NO));
        check(result == STATUS_SUCCESS, "rename directory through the shared path validator");
        setInfo(rw, directory, FileDispositionInformation, [NSData dataWithBytes:(BYTE[]){1} length:1]);
        check(result == STATUS_SUCCESS, "mark empty nested directory for deletion");
        closeFile(rw, directory);
        check(result == STATUS_SUCCESS &&
                  ![fm fileExistsAtPath:[export URLByAppendingPathComponent:@"Nested/RenamedEmpty"].path],
              "delete empty nested directory on close");
        directory = create(rw, @"\\", GENERIC_READ, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        queryDirectory(rw, directory, FileBothDirectoryInformation, YES, @"\\not-present-*");
        check(result == STATUS_NO_SUCH_FILE && output.length == 5 && word(output, 0) == 0,
              "initial empty search reports no such file with an empty response");
        queryDirectory(rw, directory, FileBothDirectoryInformation, NO, nil);
        check(result == STATUS_NO_MORE_FILES, "empty-search continuation reports enumeration end");
        queryDirectory(rw, directory, FileBothDirectoryInformation, YES, @"\\original.bin");
        check(result == STATUS_SUCCESS, "exact directory search begins");
        wStream *ignored = Stream_New(NULL, 33);
        Stream_Write_UINT32(ignored, FileBothDirectoryInformation);
        Stream_Write_UINT8(ignored, 0);
        Stream_Write_UINT32(ignored, UINT32_MAX);
        Stream_Zero(ignored, 23);
        Stream_Write_UINT8(ignored, 0xFF);
        invoke(rw, IRP_MJ_DIRECTORY_CONTROL, directory, IRP_MN_QUERY_DIRECTORY, ignored);
        check(result == STATUS_NO_MORE_FILES, "continuation ignores unused path contents and length");
        closeFile(rw, directory);
        UINT32 rootHandle = create(rw, @"\\", GENERIC_READ | DELETE, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        check(rootHandle == 0 && result == STATUS_ACCESS_DENIED, "root mutation access refused");
        [fm createDirectoryAtURL:[export URLByAppendingPathComponent:@"nonempty"]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:NULL];
        [payload writeToURL:[export URLByAppendingPathComponent:@"nonempty/file"] atomically:YES];
        UINT32 nonempty = create(rw, @"nonempty", GENERIC_READ | DELETE, FILE_OPEN, FILE_DIRECTORY_FILE, shares);
        setInfo(rw, nonempty, FileDispositionInformation, [NSData dataWithBytes:(BYTE[]){1} length:1]);
        check(result == STATUS_DIRECTORY_NOT_EMPTY, "nonempty directory deletion rejected when marked");
        closeFile(rw, nonempty);
        invoke(rw, IRP_MJ_CREATE, 0, 0, Stream_New(NULL, 1));
        check(result == STATUS_INVALID_PARAMETER, "truncated request rejected");
        FCRDPDrive *ro = [[FCRDPDrive alloc] initWithURL:export readOnly:YES];
        UINT32 reader = create(ro, @"original.bin", GENERIC_READ, FILE_OPEN, 0, shares);
        check(reader > 0, "read-only open/read allowed");
        readFile(ro, reader, 0, (UINT32)payload.length);
        check(result == STATUS_SUCCESS, "read-only data read");
        for (UINT32 access = 0; access < 7; access++) {
            UINT32 masks[] = {GENERIC_WRITE,    GENERIC_ALL,   DELETE,   FILE_WRITE_ATTRIBUTES,
                              FILE_APPEND_DATA, FILE_WRITE_EA, WRITE_DAC};
            check(create(ro, @"original.bin", masks[access], FILE_OPEN, 0, shares) == 0 &&
                      result == STATUS_ACCESS_DENIED,
                  "read-only mutation access denied");
        }
        for (UINT32 disposition = 0; disposition <= FILE_OVERWRITE_IF; disposition++) {
            if (disposition == FILE_OPEN)
                continue;
            check(create(ro, @"original.bin", GENERIC_READ, disposition, 0, shares) == 0 &&
                      result == STATUS_ACCESS_DENIED,
                  "read-only create/replacement denied before mutation");
        }
        writeFile(ro, reader, 0, [@"change" dataUsingEncoding:NSUTF8StringEncoding]);
        check(result == STATUS_ACCESS_DENIED, "read-only write denied");
        for (NSNumber *kind in @[
                 @(FileBasicInformation), @(FileEndOfFileInformation), @(FileAllocationInformation),
                 @(FileRenameInformation), @(FileDispositionInformation)
             ]) {
            setInfo(ro, reader, kind.unsignedIntValue, [NSMutableData dataWithLength:40]);
            check(result == STATUS_ACCESS_DENIED, "read-only metadata/delete/rename/truncate denied");
        }
        invoke(ro, IRP_MJ_DEVICE_CONTROL, reader, 0, Stream_New(NULL, 32));
        check(result == STATUS_ACCESS_DENIED, "read-only controls denied");
        check([[NSData dataWithContentsOfURL:original] isEqual:payload], "read-only original unchanged");
        closeFile(ro, reader);
        [ro shutdown];
        invoke(ro, IRP_MJ_READ, reader, 0, Stream_New(NULL, 32));
        check(result == STATUS_CANCELLED && output.length == 4, "disconnected file read has its empty length field");
        queryDirectory(ro, reader, FileBothDirectoryInformation, NO, nil);
        check(result == STATUS_CANCELLED, "disconnected directory retains the Windows response shape");
        h = create(rw, @"cancel.bin", fullAccess, FILE_CREATE, FILE_DELETE_ON_CLOSE, shares);
        check(h > 0, "pending delete setup");
        [rw shutdown];
        check([fm fileExistsAtPath:[export URLByAppendingPathComponent:@"cancel.bin"].path],
              "disconnect does not execute pending deletion");
        check([[NSData dataWithContentsOfURL:[outside URLByAppendingPathComponent:@"protected.bin"]] isEqual:payload],
              "outside root unchanged");
        printf("PASS %lu redirected-folder filesystem checks\n", (unsigned long)checks);
    }
    return 0;
}
