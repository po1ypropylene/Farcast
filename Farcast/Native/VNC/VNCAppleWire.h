#import <Foundation/Foundation.h>

// Unaligned, host-independent access to the Apple/RTP network byte order.
static inline uint16_t FCVNCRead16(const void *bytes) {
    const uint8_t *p = bytes;
    return (uint16_t)p[0] << 8 | p[1];
}
static inline uint32_t FCVNCRead32(const void *bytes) {
    const uint8_t *p = bytes;
    return (uint32_t)FCVNCRead16(p) << 16 | FCVNCRead16(p + 2);
}
static inline void FCVNCWrite16(void *bytes, NSUInteger n) {
    uint8_t *p = bytes;
    p[0] = n >> 8;
    p[1] = n;
}
static inline void FCVNCWrite32(void *bytes, uint32_t n) {
    uint8_t *p = bytes;
    FCVNCWrite16(p, n >> 16);
    FCVNCWrite16(p + 2, n);
}

#define FCVNC_APP_NAME "Farcast"
#define FCVNC_DISPLAY_NAME "Farcast Virtual Display"
#define FCVNC_APPLE_BANNER "RFB 003.889\n"
#define FCVNC_SRP_OPTIONS @"mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2"

// Explicit byte layouts avoid compiler padding and keep bounds beside offsets.
enum {
    FCVNCDisplayHeaderSize = 12,
    FCVNCDisplayInfoSize = 156,
    FCVNCDisplayModeSize = 28,
    FCVNCDisplayFlags = 122,
    FCVNCDisplayDepth = 126,
    FCVNCDisplayPhysicalWidth = 130,
    FCVNCDisplayPhysicalHeight = 134,
    FCVNCDisplayMaxWidth = 138,
    FCVNCDisplayMaxHeight = 142,
    FCVNCDisplayModeCount = 154,
    FCVNCDesktopLoginSize = 202,
    FCVNCDesktopLoginCredentials = 74,
    FCVNCDesktopCredentialSize = 64,
    FCVNCMediaHeaderSize = 36,
    FCVNCMediaKeySize = 46,
    FCVNCMediaAudioOffset = FCVNCMediaHeaderSize + 2 * FCVNCMediaKeySize,
    FCVNCMediaFixedSize = FCVNCMediaAudioOffset + 2 * FCVNCMediaKeySize
};
