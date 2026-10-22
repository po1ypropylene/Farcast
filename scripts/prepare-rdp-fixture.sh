#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d .dependencies/sources/FreeRDP ]] || scripts/prepare-dependencies.sh
fixture_source="$PWD/.dependencies/rdp-fixture/source"
mkdir -p "$(dirname "$fixture_source")"
if [[ ! -d "$fixture_source" ]]; then cp -R .dependencies/sources/FreeRDP "$fixture_source"; fi
# Start from the exact upstream sample each time; production libraries are untouched.
git -C .dependencies/sources/FreeRDP show HEAD:server/Sample/sfreerdp.c > "$fixture_source/server/Sample/sfreerdp.c"
git -C .dependencies/sources/FreeRDP show HEAD:server/Sample/sfreerdp.h > "$fixture_source/server/Sample/sfreerdp.h"
cp Tests/Integration/RDP/clipboard_fixture.h "$fixture_source/server/Sample/fc_clipboard_fixture.h"
cp Tests/Integration/RDP/drive_fixture.h "$fixture_source/server/Sample/fc_drive_fixture.h"
cp Tests/Integration/RDP/display_fixture.h "$fixture_source/server/Sample/fc_display_fixture.h"
cp Tests/Integration/RDP/keyboard_fixture.h "$fixture_source/server/Sample/fc_keyboard_fixture.h"
cp Tests/Integration/RDP/resize_fixture.h "$fixture_source/server/Sample/fc_resize_fixture.h"
python3 - "$fixture_source/server/Sample/sfreerdp.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); text = path.read_text()
header = path.with_suffix('.h')
header.write_text(header.read_text().replace('RdpsndServerContext* rdpsnd;', 'RdpsndServerContext* rdpsnd;\n    struct s_cliprdr_server_context* fc_clipboard;\n    struct s_rdpdr_server_context* fc_drive;\n    struct fc_fixture_resize* fc_resize;\n    int fc_keyboard_index;'))
text = text.replace('struct server_info', '#include "fc_clipboard_fixture.h"\n#include "fc_drive_fixture.h"\n#include "fc_display_fixture.h"\n#include "fc_resize_fixture.h"\n#include "fc_keyboard_fixture.h"\n\nstruct server_info', 1)
text = text.replace('rdpsnd_server_context_free(context->rdpsnd);', 'fc_fixture_resize_stop(context);\n        fc_fixture_drive_stop(context);\n        fc_fixture_clipboard_stop(context);\n        rdpsnd_server_context_free(context->rdpsnd);')
text = text.replace('/* Dynamic Virtual Channels */', 'if (!fc_fixture_clipboard_start(context)) return FALSE;\n    if (!fc_fixture_drive_start(context)) return FALSE;\n\n    /* Dynamic Virtual Channels */')
text = text.replace('instance->Open(instance, nullptr, (UINT16)port)', 'instance->Open(instance, "127.0.0.1", (UINT16)port)')
text = text.replace('freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE)', 'freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, getenv("FARCAST_FIXTURE_NLA") != nullptr)')
# First activation may deliberately omit pixels to exercise one-shot GFX fallback.
needle = 'static BOOL tf_peer_activate(freerdp_peer* client)\n{'
assert needle in text
text = text.replace(needle, needle + '\n    static LONG fc_activation_count;\n    if (getenv("FARCAST_FIXTURE_GFX_FALLBACK") && InterlockedIncrement(&fc_activation_count) == 1) return TRUE;', 1)
text = text.replace('client->PostConnect = tf_peer_post_connect;', '''if (getenv("FARCAST_FIXTURE_SAM"))
        freerdp_settings_set_string(settings, FreeRDP_NtlmSamFile, getenv("FARCAST_FIXTURE_SAM"));
    client->PostConnect = tf_peer_post_connect;''')
# Assert monitor blocks decoded from the client, and the actual pointer wire coordinates.
needle = 'static BOOL tf_peer_post_connect(freerdp_peer* client)\n{'
assert needle in text
text = text.replace(needle, needle + '\n    if (!fc_fixture_display_check(client->context->settings)) return FALSE;', 1)
needle = 'static BOOL tf_peer_mouse_event(rdpInput* input, UINT16 flags, UINT16 x, UINT16 y)\n{'
assert needle in text
text = text.replace(needle, needle + '\n    fc_fixture_display_pointer(input, x, y);', 1)
# Decode actual input PDUs on the peer, independently of view callback assertions.
for name, args in [("synchronize", "'s', (UINT16)flags, 0"),
                   ("keyboard", "'k', flags, code"), ("unicode_keyboard", "'u', flags, code")]:
    declaration = f"static BOOL tf_peer_{name}_event(rdpInput* input, "
    start = text.index(declaration)
    body = text.index("\n{", start) + 2
    text = text[:body] + f"\n    if (!fc_fixture_keyboard_event(input, {args})) return FALSE;" + text[body:]
# Resize callbacks are queued from the disp thread and adopted only on the peer worker.
text = text.replace('status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);',
                    'status = WaitForMultipleObjects(count, handles, FALSE, getenv("FARCAST_FIXTURE_RESIZE") ? 20 : INFINITE);')
# The sample otherwise attempts DVC initialization before channels are joined and
# remains INITIALIZED without a channel. Start the resize peer after activation.
text = text.replace('WTSVirtualChannelManagerCheckFileDescriptor(context->vcm)',
                    '(getenv("FARCAST_FIXTURE_RESIZE") ? WTSVirtualChannelManagerCheckFileDescriptorEx(context->vcm, context->activated) : WTSVirtualChannelManagerCheckFileDescriptor(context->vcm))')
needle = '\t\t/* Handle dynamic virtual channel initializations */'
assert needle in text
text = text.replace(needle, '\t\tif (!fc_fixture_resize_tick(context)) break;\n' + needle, 1)
path.write_text(text)
PY
# Correct a fixture-only server decoder that incorrectly expects file bytes after
# the MS-RDPEFS write completion's count/padding. Production libraries are untouched.
git -C .dependencies/sources/FreeRDP show HEAD:channels/rdpdr/server/rdpdr_main.c > "$fixture_source/channels/rdpdr/server/rdpdr_main.c"
python3 - "$fixture_source/channels/rdpdr/server/rdpdr_main.c" <<'PYFIX'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
a=s.index('static UINT rdpdr_server_drive_write_file_callback(')
b=s.index('static UINT rdpdr_server_drive_write_file(',a)
part=s[a:b]
part=part.replace('\tif (!Stream_CheckAndLogRequiredLengthWLog(priv->log, s, length))\n\t\treturn ERROR_INVALID_DATA;\n','')
s=s[:a]+part+s[b:]
# Request the FileBothDirectoryInformation form used for Explorer browsing.
# Its wire record omits the native reserved byte: 93 fixed bytes before FileName.
needle='Stream_Write_UINT32(s, FileDirectoryInformation); /* FsInformationClass (4 bytes) */'
assert s.count(needle)==1
s=s.replace(needle, 'Stream_Write_UINT32(s, getenv("FARCAST_FIXTURE_DRIVE_BOTH") ? FileBothDirectoryInformation : FileDirectoryInformation); /* FsInformationClass */')
needle='const UINT32 fileNameLength = Stream_Get_UINT32(s); /* FileNameLength (4 bytes) */'
assert s.count(needle)==1
s=s.replace(needle, needle + '''
    if (getenv("FARCAST_FIXTURE_DRIVE_BOTH"))
    {
        if (!Stream_CheckAndLogRequiredLengthWLog(log, s, 29)) return ERROR_INVALID_DATA;
        Stream_Seek(s, 29); /* EaSize, ShortNameLength and ShortName; no Reserved byte. */
    }
''')
a=s.index('static UINT rdpdr_server_drive_query_directory_callback2(')
b=s.index('static UINT rdpdr_server_drive_query_directory_callback1(',a)
part=s[a:b]
needle='FILE_DIRECTORY_INFORMATION fdi = WINPR_C_ARRAY_INIT;'
assert needle in part
part=part.replace(needle, '''
    if (length > 0 && getenv("FARCAST_FIXTURE_DRIVE_BOTH"))
    {
        if (length < 93 || !Stream_CheckAndLogRequiredLengthWLog(priv->log, s, length))
            return ERROR_INVALID_DATA;
        const BYTE* bytes = Stream_ConstPointer(s);
        const UINT32 namesize = (UINT32)bytes[60] | ((UINT32)bytes[61] << 8) |
                               ((UINT32)bytes[62] << 16) | ((UINT32)bytes[63] << 24);
        if (namesize != length - 93 || namesize % 2) return ERROR_INVALID_DATA;
    }
''' + needle)
# Retain upstream's minimum empty-response size. Although MS-RDPEFS calls
# padding optional, Windows also requires it at enumeration end.
s=s[:a]+part+s[b:]
# Probe directory opens ending in a separator, while retaining the canonical
# search path for the following query. Production FreeRDP remains unchanged.
a=s.index('static UINT rdpdr_server_drive_query_directory(RdpdrServerContext* context,')
b=s.index('/*************************************************',a)
part=s[a:b]
needle='''return rdpdr_server_send_device_create_request(
	    context, irp->DeviceId, irp->CompletionId, irp->PathName, FILE_READ_DATA | SYNCHRONIZE,'''
assert needle in part
part=part.replace(needle, r'''char openPath[sizeof(irp->PathName)] = {0};
    strncpy(openPath, irp->PathName, sizeof(openPath) - 1);
    if (openPath[0] && getenv("FARCAST_FIXTURE_DRIVE_DIRECTORY_SUFFIX"))
        winpr_str_append("\\", openPath, ARRAYSIZE(openPath), nullptr);
    return rdpdr_server_send_device_create_request(
	    context, irp->DeviceId, irp->CompletionId, openPath, FILE_READ_DATA | SYNCHRONIZE,''')
s=s[:a]+part+s[b:]; p.write_text(s)
PYFIX
cmake -S "$fixture_source" -B .dependencies/rdp-fixture/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DBUILD_SHARED_LIBS=ON -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_COMMON=ON -DWITH_SERVER=ON -DWITH_SHADOW=OFF -DWITH_PROXY=OFF \
  -DWITH_SAMPLE=ON -DWITH_SDL=OFF -DWITH_X11=OFF -DWITH_FFMPEG=OFF \
  -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_OPUS=OFF \
  -DWITH_PCSC=OFF -DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_AAD=OFF \
  -DWITH_JSON_DISABLED=ON -DCHANNEL_URBDRC=OFF -DWITH_MANPAGES=OFF \
  -DOPENSSL_ROOT_DIR="$PWD/Vendor/Native"
cmake --build .dependencies/rdp-fixture/build -j "$(sysctl -n hw.ncpu)"
