# snapcast-tools
Scripts to manage and make things easier with snapcast

## snap-server-manager.sh:
``bash -c "$(curl -fsSL https://raw.githubusercontent.com/NaturalDevCR/snapcast-tools/refs/heads/main/snap-server-manager.sh)"``

### Config generation changes
- Adds a global `process:///usr/bin/ffmpeg` Silence source inside `[stream]` with `codec=null` to be invisible to users.
- Creates individual pipe sources for known FIFOs with `codec=null` and `sampleformat=48000:16:2`.
- Adds MetaStreams that reference the Silence fallback with `codec=pcm`, matching Snapserver best practices.

Example entries added to `/etc/snapserver.conf`:

```
[stream]
source = process:///usr/bin/ffmpeg?name=Silence&codec=null&sampleformat=48000:16:2&params=-f lavfi -i anullsrc=r=48000:cl=stereo -f s16le -ar 48000 -ac 2 -
source = pipe:///var/lib/snapserver/fifo/snapfifo_frontdesk?name=PC-FrontDesk&codec=null&sampleformat=48000:16:2
source = pipe:///var/lib/snapserver/fifo/snapfifo_aracari?name=PC-Aracari&codec=null&sampleformat=48000:16:2
source = pipe:///var/lib/snapserver/fifo/snapfifo_azuracastrestaurants?name=Azuracast-Restaurants&codec=null&sampleformat=48000:16:2
source = pipe:///var/lib/snapserver/fifo/snapfifo_azuracastfrontdesk?name=Azuracast-FrontDesk&codec=null&sampleformat=48000:16:2
source = pipe:///var/lib/snapserver/fifo/snapfifo_azuracastoutdoors?name=Azuracast-Outdoors&codec=null&sampleformat=48000:16:2
source = pipe:///var/lib/snapserver/fifo/snapfifo_pcpool?name=PC-Pool&codec=null&sampleformat=48000:16:2

source = meta:///PC-FrontDesk/Silence?name=FrontDesk&codec=pcm&sampleformat=48000:16:2
source = meta:///PC-Aracari/Silence?name=Aracari&codec=pcm&sampleformat=48000:16:2
source = meta:///Azuracast-Restaurants/Silence?name=Restaurants&codec=pcm&sampleformat=48000:16:2
source = meta:///Azuracast-FrontDesk/Silence?name=AzuraFrontDesk&codec=pcm&sampleformat=48000:16:2
source = meta:///Azuracast-Outdoors/Silence?name=Outdoors&codec=pcm&sampleformat=48000:16:2
source = meta:///PC-Pool/Silence?name=Pool&codec=pcm&sampleformat=48000:16:2
```

This ensures all user-facing streams have a stable Silence fallback using MetaStreams.

## snapclient-setup.sh:
``bash -c "$(curl -fsSL https://raw.githubusercontent.com/NaturalDevCR/snapcast-tools/refs/heads/main/snapclient-setup.sh)"``
