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
cp Tests/Integration/RDP/resize_fixture.h "$fixture_source/server/Sample/fc_resize_fixture.h"
python3 - "$fixture_source/server/Sample/sfreerdp.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); text = path.read_text()
header = path.with_suffix('.h')
header.write_text(header.read_text().replace('RdpsndServerContext* rdpsnd;', 'RdpsndServerContext* rdpsnd;\n    struct s_cliprdr_server_context* fc_clipboard;\n    struct s_rdpdr_server_context* fc_drive;\n    struct fc_fixture_resize* fc_resize;'))
text = text.replace('struct server_info', '#include "fc_clipboard_fixture.h"\n#include "fc_drive_fixture.h"\n#include "fc_display_fixture.h"\n#include "fc_resize_fixture.h"\n\nstruct server_info', 1)
text = text.replace('rdpsnd_server_context_free(context->rdpsnd);', 'fc_fixture_resize_stop(context);\n        fc_fixture_drive_stop(context);\n        fc_fixture_clipboard_stop(context);\n        rdpsnd_server_context_free(context->rdpsnd);')
text = text.replace('/* Dynamic Virtual Channels */', 'if (!fc_fixture_clipboard_start(context)) return FALSE;\n    if (!fc_fixture_drive_start(context)) return FALSE;\n\n    /* Dynamic Virtual Channels */')
text = text.replace('instance->Open(instance, nullptr, (UINT16)port)', 'instance->Open(instance, "127.0.0.1", (UINT16)port)')
text = text.replace('freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE)', 'freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, getenv("FARCAST_FIXTURE_NLA") != nullptr)')
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
