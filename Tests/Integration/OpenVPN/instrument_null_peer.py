"""Instrument only the disposable, checksum-verified fixture server, never app code.
OpenVPN's null device discards decrypted packets before the normal TUN-write log.
This fixed marker verifies an expected synthetic TCP SYN after authentication and
before that discard, without printing any packet contents.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1])
text = source.read_text()
anchor = '        /* Did we just receive an openvpn ping packet? */'
assert text.count(anchor) == 1
probe = '''        /* Farcast owned null-device regression probe. */
        if (c->c2.buf.len >= 40)
        {
            const unsigned char *p = BPTR(&c->c2.buf);
            if (p[0] == 0x45 && p[9] == 6 && p[16] == 10 && p[17] == 99
                && p[18] == 0 && p[19] == 1 && (p[33] & 0x12) == 0x02)
            {
                msg(M_INFO, "FARCAST_FIXTURE_DECRYPTED_TCP_SYN");
            }
        }

'''
source.write_text(text.replace(anchor, probe + anchor))
