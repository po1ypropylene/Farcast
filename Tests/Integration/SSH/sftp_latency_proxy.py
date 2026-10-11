"""Owned loopback proxy: RTT (default 20 ms) and optional per-direction KiB/s cap."""
import asyncio
from pathlib import Path
import sys

async def main():
    rtt = float(sys.argv[3]) if len(sys.argv) > 3 else 20
    if not 0 <= rtt <= 200: raise ValueError('RTT must be 0–200 ms')
    delay = rtt / 2000
    rate = float(sys.argv[4]) * 1024 if len(sys.argv) > 4 else 0
    if rate < 0: raise ValueError('Bandwidth must be nonnegative KiB/s')
    async def handle(reader, writer):
        peer_reader, peer_writer = await asyncio.open_connection('127.0.0.1', int(sys.argv[1]))
        async def relay(source, destination):
            pending = asyncio.Queue(maxsize=64)
            async def read():
                try:
                    next_delivery = 0
                    while data := await source.read(4096 if rate else 65536):
                        when = asyncio.get_running_loop().time() + delay
                        if rate:
                            when = max(when, next_delivery) + len(data) / rate
                            next_delivery = when
                        await pending.put((when, data))
                finally: await pending.put((0, None))
            async def write():
                while True:
                    when, data = await pending.get()
                    if data is None: break
                    await asyncio.sleep(max(0, when-asyncio.get_running_loop().time()))
                    destination.write(data)
                    await destination.drain()
            try: await asyncio.gather(read(), write())
            finally: destination.close()
        await asyncio.gather(relay(reader, peer_writer), relay(peer_reader, writer), return_exceptions=True)
    server = await asyncio.start_server(handle, '127.0.0.1', 0)
    Path(sys.argv[2]).write_text(str(server.sockets[0].getsockname()[1]))
    async with server: await server.serve_forever()
asyncio.run(main())
