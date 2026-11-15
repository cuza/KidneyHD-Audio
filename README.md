<p align="center"><img src="res/icon.svg" width="128" height="128" alt="KidneyHD Audio icon"></p>

# KidneyHD Audio

A macOS driver for the Line 6 POD HD family. It makes the pedal a USB sound card again on current
macOS, with 48 kHz, 24-bit stereo in and out, and lets preset editors talk to it at the same time.
It needs no Line 6 software and no kernel extension.

Line 6 stopped updating its driver, and its kernel extension does not load on current Macs without
lowering system security. KidneyHD Audio replaces it with a user-space Core Audio driver and a small
background service.

| Pedal | USB ID | Status |
|---|---|---|
| POD HD Desktop | 0e41:4156 | tested |
| POD HD500 | 0e41:414d | should work, untested |
| POD HD500X | 0e41:4159 | should work, untested |
| POD HD Pro | 0e41:4157 | should work, untested |
| POD HD Pro X | 0e41:415a | should work, untested |

The HD300 and HD400 use a different USB layout and are not supported. If you own one of the
untested models, please open an issue with your results.

Requires macOS 14 or later, on Apple silicon or Intel.

## Install

Download the latest
[KidneyHD-Audio.pkg](https://github.com/cuza/KidneyHD-Audio/releases/latest/download/KidneyHD-Audio.pkg)
from the Releases page and open it. The installer
adds:

- `/Library/Audio/Plug-Ins/HAL/KidneyHDAudio.driver`, the audio driver, which Core Audio loads.
- `/Library/Application Support/KidneyHD Audio/kidneyhd-audiod`, the control service. launchd starts
  it from `/Library/LaunchDaemons/dev.cuza.kidneyhd-audiod.plist`.
- `/Library/Application Support/KidneyHD Audio/uninstall.sh`.

The installer restarts Core Audio, so sound on the Mac stops for a moment. A newer version installs
over an old one without an uninstall first.

To remove everything:

    sudo "/Library/Application Support/KidneyHD Audio/uninstall.sh"

## Use

Plug in the pedal. It appears in System Settings › Sound and in Audio MIDI Setup under its model
name, for example "POD HD Desktop", with two input and two output channels.

In a DAW, pick the pedal as the input and output device. The rate is fixed at 48 kHz, so set the
project to 48 kHz. The driver reports its latency, 70 frames each way, so DAWs that compensate for
recording latency line up recordings without a manual offset. If you hear clicks, raise the DAW's
buffer size.

The macOS volume slider and keys set the output level. The driver scales the samples it sends, from
0 dB down to -64 dB and silence, and keeps the setting across restarts. The input has no volume
control.

## Editors and the control service

The pedal mutes USB playback unless the host keeps reading its control channel, and only one
program can open that channel. The control service, `kidneyhd-audiod`, holds the channel whenever
a pedal is attached and shares it, so any number of editors can run while you play audio through
the pedal. Any app can use it; it does not have to be KidneyHD.

### The socket

Connect to the Unix socket `/var/run/kidneyhd-audiod.sock` (any local user can). Messages in both
directions are one length byte followed by one raw USB packet of that length, up to 64 bytes. A
USB packet is `[n][0][t][0]` followed by `n` data bytes, `t = 1` for the first packet of a message
and `t = 4` for the rest; the editor protocol inside is the one POD HD Edit uses.

- Packets you send go to the pedal. The service sends one editor's message whole before the next
  editor's: while you are partway through a message, other editors' packets wait, so send each
  message's packets together. If you stop for a second in the middle of a message, the others go on.
- Every packet the pedal sends goes to every connected editor, including answers to other editors'
  requests. Match answers to your requests by their contents, and expect messages the pedal sends on
  its own, such as edits made on its panel.
- Send a single `0` byte to ask for the hello. The answer comes only to you, as a `0` byte, a
  little-endian 16-bit length and that many bytes of JSON:

      {"pedal": true, "pid": 16729, "serial": "21PHD0M...", "usbfw": 4160, "licenses": "f8ffffffffffffff"}

  `pedal` says whether a pedal is open and `pid` is its USB product ID (0x4159 for the HD500X).
  `serial`, `usbfw` (0x1040 for USB firmware 1.04) and `licenses` (the 8 model pack license bytes,
  where a cleared bit is a licensed pack) appear when the pedal reported them.

A minimal client, in Python:

    import json, socket, struct
    s = socket.socket(socket.AF_UNIX); s.connect("/var/run/kidneyhd-audiod.sock")
    s.sendall(b"\0")                                   # hello
    assert s.recv(1) == b"\0"
    (n,) = struct.unpack("<H", s.recv(2)); print(json.loads(s.recv(n)))

### XPC

Sandboxed apps cannot open the socket. Apps signed by the same developer team as the service reach
it through the Mach service `ECKB9WN282.dev.cuza.kidney.audiod`, since a sandbox only allows Mach
services named after one of the app's App Groups. Each message is a dictionary with one raw USB
packet under the key `pkt`. A message with `hello` set gets a reply with the same fields as the
socket's hello, with `licenses` as data. XPC editors share the pedal with socket editors under the
same rules.

Without the control service, the audio driver keeps reads pending on the control channel itself
while audio plays, but editors cannot connect.

## Troubleshooting

Read the logs of both parts:

    log stream --predicate 'eventMessage BEGINSWITH "KidneyHD Audio" OR eventMessage BEGINSWITH "kidneyhd-audiod"'

For past messages, use `log show --last 10m` with the same predicate. While audio plays, a healthy
stream logs nothing. "audio glitch" lines report USB errors, audio that arrived late from Core
Audio, or gaps in the output.

If the pedal is missing from Sound settings:

- Check that the driver is installed: `ls /Library/Audio/Plug-Ins/HAL/KidneyHDAudio.driver`.
- Check that macOS sees the pedal. System Information › USB lists it under the vendor ID `0e41`.
  Use a direct USB port or a powered hub.
- Restart Core Audio with `sudo killall coreaudiod`, then look for "pedal attached" in the logs.

If playback is silent or the pedal stops answering the editor:

- Check that the control service runs: `sudo launchctl print system/dev.cuza.kidneyhd-audiod`. The
  logs should show "pedal control channel open".
- When reads from the pedal fail, the service clears the error. If that does not help, it opens the
  control channel again. If the pedal still does not answer, restart the service with
  `sudo launchctl kickstart -k system/dev.cuza.kidneyhd-audiod`, or unplug the pedal and plug it
  back in.
- Only one program can open the control channel. Quit other tools that open the pedal directly.

## Security

- The control service runs as root. It opens only the pedal's control interface and its own socket.
- The socket is `root:staff`, mode 0660. Every local user account is in the `staff` group, so any
  local user can send control messages to the pedal, including ones that change presets and
  settings. System accounts outside `staff` and remote users cannot connect.
- The XPC service accepts only apps signed by team `ECKB9WN282`.
- The audio driver runs in Core Audio's sandboxed driver host. Its `Info.plist` asks only for the
  USB user clients it needs.
- The control service reads the pedal's serial number and model pack license bits. It passes them
  only in the hello reply, to the socket or XPC editor that asked, and does not log them.
- Release packages carry a Developer ID signature and Apple's notarization. CI builds unsigned
  packages, for testing only.

## How it works

The pedal's USB interfaces are vendor-specific, so macOS's built-in USB audio support ignores them.

- Interface 0 carries audio on alternate setting 1, with isochronous OUT `0x02` and IN `0x86`. Each
  125 µs microframe carries one packet of 48 kHz, 2-channel, signed 24-bit little-endian samples,
  with no headers. The driver reports this as the stream's physical format and keeps the samples in
  it. Apps see 32-bit float, and Core Audio converts between the two. The driver applies the output
  volume to the float mix before that conversion.
- The pedal is the clock master. Each output packet carries as many frames as a recent input packet
  did, and the driver turns USB completion times into Core Audio's clock with a delay-locked loop.
- The driver reports 70 frames of latency each way. On a POD HD Desktop, `make latency` measured a
  round trip of 140 frames, 2.9 ms, beyond the buffer and safety offsets.
- Interface 1 is the control channel: bulk OUT `0x01`, bulk IN `0x81`, 64-byte packets.

USB playback only sounds while the host keeps reads pending on bulk IN `0x81`. Without them the
pedal mutes playback within seconds. Linux's `snd-usb-podhd` keeps reads pending too. The control
service keeps 16 reads queued whenever a pedal is attached, as Line 6's driver did. It also sends
the monitor level message `0c 00 01 00 02 00 04 41 04 00 13 00` with a little-endian float gain of
1.0, which sets the USB playback level. The volume control does not change this level.

When it opens the control channel, the control service also reads the pedal's USB firmware version,
serial number and model pack license bits with vendor request `0x67` on the whole device. Linux's
line6 driver and Line 6's software send the same requests.

Source layout:

- `src/`: the Core Audio plug-in, `driver.c`, and the USB engine, `usb.m` and `pod.h`.
- `daemon/`: the control service and its launchd plist.
- `pkg/`: installer scripts and the uninstall script.
- `res/`: the device icon and its SVG source.
- `tools/`: hardware checks for `make test`, `make check` and `make latency`.

## Build from source

The Xcode command line tools are enough.

    make                      # build/KidneyHDAudio.driver and build/kidneyhd-audiod
    sudo make install         # install both and restart Core Audio
    sudo make uninstall       # remove both and restart Core Audio

Run `make` as yourself before `sudo make install`, so root does not own the build folder.

The XPC service accepts only clients signed by team `ECKB9WN282`, and its name carries that team ID
as an App Group prefix. If you sign an editor with your own team, change `XPC_SERVICE` and
`XPC_PEER_REQUIREMENT` in `daemon/kidneyhd-audiod.m` and the `MachServices` key in
`daemon/dev.cuza.kidneyhd-audiod.plist` to your team ID and App Group. The Unix socket needs no
change.

Checks against a real pedal:

    make test                 # USB engine alone; stop the control service and any audio first
    make check                # plays a tone through the installed driver and reports overloads
    make latency              # round-trip latency; needs a loopback cable

`make latency` needs a cable from one of the pedal's outputs back into its input, and a preset with
no amp and no effects. It plays a click every half second and finds each click in the input. It then
prints the median delay beyond the buffer and safety offsets, next to the latency the driver
reports. The result varies by a few frames between runs. If your model measures far from 140 frames,
please open an issue with the output.

## Credits

The USB layout and audio format follow the Linux kernel's `line6` driver. KidneyHD Audio includes no
code from it.

## Disclaimer

KidneyHD Audio is an independent project, not affiliated with or endorsed by Line 6, Yamaha Guitar
Group or Yamaha Corporation. "Line 6" and "POD" are trademarks of their owners. This README uses them
only to name the hardware the driver supports.

## License

MIT. See [LICENSE](LICENSE).
