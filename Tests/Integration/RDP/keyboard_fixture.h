// Ordered keyboard decoding on the owned TLS/NLA peer. No host input is injected.
static BOOL fc_fixture_keyboard_event(rdpInput *input, char type, UINT16 flags, UINT16 code) {
    testPeerContext *context = (testPeerContext *)input->context;
    if (type == 'u' && flags == 0 && code == 0xE000) {
        context->fc_keyboard_index = 1;
        return TRUE;
    }
    if (context->fc_keyboard_index == 0)
        return TRUE;
    static const struct {
        char type;
        UINT16 flags;
        UINT16 code;
    } expected[] = {
        {'k', 0, 0x2A},
        {'k', 0, 0x1E},
        {'k', 0, 0x1E},
        {'k', KBD_FLAGS_RELEASE, 0x1E},
        {'k', KBD_FLAGS_RELEASE, 0x2A},
        {'k', KBD_FLAGS_EXTENDED, 0x1D},
        {'k', KBD_FLAGS_EXTENDED | KBD_FLAGS_RELEASE, 0x1D},
        {'k', KBD_FLAGS_EXTENDED, 0x4B},
        {'k', KBD_FLAGS_EXTENDED | KBD_FLAGS_RELEASE, 0x4B},
        {'u', 0, 0x4E2D},
        {'u', KBD_FLAGS_RELEASE, 0x4E2D},
        {'u', 0, 0xD83D},
        {'u', KBD_FLAGS_RELEASE, 0xD83D},
        {'u', 0, 0xDE00},
        {'u', KBD_FLAGS_RELEASE, 0xDE00},
        {'s', KBD_SYNC_CAPS_LOCK, 0},
        {'s', 0, 0},
        {'u', KBD_FLAGS_RELEASE, 0xE001},
    };
    const size_t index = (size_t)context->fc_keyboard_index - 1;
    if (index >= sizeof(expected) / sizeof(expected[0]) || expected[index].type != type ||
        expected[index].flags != flags || expected[index].code != code) {
        fprintf(stderr, "FAIL keyboard wire ordered event %zu\n", index);
        return FALSE;
    }
    context->fc_keyboard_index++;
    if (index + 1 == sizeof(expected) / sizeof(expected[0])) {
        fprintf(stderr,
                "PASS keyboard wire scan codes, repeats, extended keys, Unicode pairs and toggle synchronization\n");
        context->fc_keyboard_index = 0;
    }
    return TRUE;
}
