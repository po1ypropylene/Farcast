#import <Foundation/Foundation.h>
#import <Security/Security.h>

#ifndef CONTENT_REVISION
#define CONTENT_REVISION 1
#endif

// Test-only credentials in a disposable keychain; never query the login keychain.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 2;
        BOOL create = [@(argv[1]) isEqual:@"create"];
        NSString *path = @(argv[2]);
        const char *password = "owned-signing-fixture-password";
        CFArrayRef originalSearchList = NULL;
        SecKeychainRef keychain = NULL;
        OSStatus status = SecKeychainCopySearchList(&originalSearchList);
        if (status)
            return 1;
        if (create && [NSFileManager.defaultManager fileExistsAtPath:path]) {
            CFRelease(originalSearchList);
            return 1;
        }
        status = create ? SecKeychainCreate(path.fileSystemRepresentation, (UInt32)strlen(password), password, false,
                                            NULL, &keychain)
                        : SecKeychainOpen(path.fileSystemRepresentation, &keychain);
        if (!status)
            status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
        NSData *expected = [@"synthetic-update-token" dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *request = [@{
            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService : @"com.peterpo.farcast.signing-fixture",
            (__bridge id)kSecAttrAccount : @"owned-test-item"
        } mutableCopy];
        if (!status && create) {
            request[(__bridge id)kSecUseKeychain] = (__bridge id)keychain;
            request[(__bridge id)kSecValueData] = expected;
            status = SecItemAdd((__bridge CFDictionaryRef)request, NULL);
        } else if (!status) {
            request[(__bridge id)kSecMatchSearchList] = @[ (__bridge id)keychain ];
            request[(__bridge id)kSecReturnData] = @YES;
            request[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
            CFTypeRef result = NULL;
            status = SecItemCopyMatching((__bridge CFDictionaryRef)request, &result);
            if (!status && ![expected isEqual:(__bridge id)result])
                status = errSecDecode;
            if (result)
                CFRelease(result);
        }
        OSStatus deleted = !create && keychain ? SecKeychainDelete(keychain) : errSecSuccess;
        // Creating a keychain can alter the search list. Restore it on every path.
        OSStatus restored = SecKeychainSetSearchList(originalSearchList);
        if (keychain)
            CFRelease(keychain);
        CFRelease(originalSearchList);
        BOOL passed = status == errSecSuccess && deleted == errSecSuccess && restored == errSecSuccess;
        printf("%s isolated Keychain %s (binary revision %d, status=%d)\n", passed ? "PASS" : "FAIL",
               create ? "create" : "read after code update without authorization UI", CONTENT_REVISION, (int)status);
        return passed ? 0 : 1;
    }
}
