#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

// Optional local RE probe: synthetic settings only, no sockets or credentials.
// The application does not link or load AVConference.
int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference", RTLD_LAZY))
            return 77;
        Class cls = NSClassFromString(@"VCMediaNegotiationBlobBandwidthSettings");
        if (!cls || ![cls instancesRespondToSelector:NSSelectorFromString(@"newBandwidthConfigurations")])
            return 77;
        for (unsigned profile = 0; profile < 2; profile++) {
            id settings = [cls new];
            [settings setValue:@0 forKey:@"configuration"];
            [settings setValue:@(profile ? 60000000 : 20000000) forKey:@"maxBandwidth"];
            [settings setValue:@(profile ? 262144 : 98304) forKey:@"configurationExtension"];
            NSData *data = [settings valueForKey:@"data"];
            const uint8_t wifi[] = {8, 0, 16, 128, 218, 196, 9, 24, 128, 128, 6};
            const uint8_t wired[] = {8, 0, 16, 128, 142, 206, 28, 24, 128, 128, 16};
            if (data.length != sizeof(wifi) || memcmp(data.bytes, profile ? wired : wifi, sizeof(wifi)))
                return 1;
            // newBandwidthConfigurations returns owned objects with synthetic
            // connection type, arbiter mode and maximum network bandwidth.
            SEL selector = NSSelectorFromString(@"newBandwidthConfigurations");
            CFTypeRef configsRef = ((CFTypeRef(*)(id, SEL))objc_msgSend)(settings, selector);
            NSArray *configs = CFBridgingRelease(configsRef);
            if (configs.count != (profile ? 1 : 2))
                return 1;
            for (id config in configs) {
                unsigned type = [[config valueForKey:@"connectionType"] unsignedIntValue];
                unsigned mode = [[config valueForKey:@"mode"] unsignedIntValue];
                unsigned maximum = [[config valueForKey:@"maxBandwidth"] unsignedIntValue];
                if (profile ? (type != 7 || mode != 5 || maximum != 60000000)
                            : ((type != 4 && type != 5) || mode != 6 || maximum != 20000000))
                    return 1;
                printf("profile %u: connection type %u, mode %u, ceiling %u\n", profile, type, mode, maximum);
            }
        }
        puts("PASS Apple bandwidth field 3 is configurationExtension, not a bitrate");
    }
}
