# TH-D74 Programmer for macOS

A Mac app and command-line tool for programming the memory channels of a
Kenwood TH-D74 handheld radio, over Bluetooth or USB.

Kenwood's own programming software (MCP-D74) is Windows-only. This is an
independent, open-source alternative for the Mac. It is not affiliated with or
endorsed by JVCKENWOOD.

> **Early software, use at your own risk.** It writes to your radio's memory
> using a protocol worked out by the community, not one published by Kenwood.
> It has been tested on one US TH-D74A (firmware 1.06) over Bluetooth.
> **Make a full backup first** (see below) and keep it somewhere safe.

## What it does

- Reads the radio's memory channels into a spreadsheet-style table.
- Edits name, frequency, shift, offset, mode, tone / CTCSS / DCS, step,
  scan skip and memory group for each channel.
- Writes changes back. Only the 256-byte memory blocks that actually differ
  are written, and each is read back to verify it.
- Imports repeaters from CHIRP-format CSV files, with select-by-distance and
  duplicate detection, into the memory group of your choice.
- Renames the radio's 30 memory groups.
- Saves and restores full memory backups.

## What it does not do (yet)

- No D-STAR repeater list, callsign list, APRS, or menu settings editing.
- USB is implemented but **untested**; only Bluetooth has been exercised.
- The TH-D75 is not supported.
- Some fields rest on partial knowledge. In particular, each channel stores a
  band code (0 for 2 m, 1 for 1.25 m, 2 for 70 cm on the test radio); for
  frequencies outside those bands the value written is a guess.

## Install

Download `TH-D74-Programmer.zip` from the
[Releases](https://github.com/mark-oskin/Kenwood-TH-D74-MacOSX/releases) page
and unzip it. It needs macOS 14 or later and runs on Apple silicon and Intel.

The app is signed with a Developer ID and notarized by Apple, so it opens
like any other downloaded app. If you would rather not run a binary from the
internet, build it from source (below); it takes a minute.

## Connecting the radio

### Bluetooth

1. On the radio, set **Menu 930** (Bluetooth) to On.
2. Open **Menu 934** (Pairing Mode).
3. On the Mac, open **System Settings > Bluetooth** and connect to `TH-D74`.
4. Launch the app and choose **Read from Radio**. macOS asks for Bluetooth
   permission the first time.

The radio must not be in KISS mode ([F], [LIST] cycles APRS / KISS / off); it
ignores PC commands while KISS is on.

### USB

Plug in a Micro-USB data cable. The radio should appear as a serial device
(`/dev/cu.usbmodem…`), which the app prefers over Bluetooth when present.
This path has not been tested on a real radio yet; reports are welcome.

## Using the app

1. **Back up first.** Radio > *Read Full Memory from Radio* (about 40 seconds
   over Bluetooth), then File > *Save Backup As…*.
2. **Read from Radio** loads the channel area (a few seconds).
3. Edit cells in the table. Typing a frequency into an empty slot creates a
   channel; clearing the frequency empties the slot. Changed rows get a dot.
4. **Write to Radio** makes the radio match the table.

While reading or writing, the radio shows its programming screen. It restarts
when the session ends, and takes a few seconds before it accepts another
connection.

### Importing repeaters

*File > Import Repeaters from CSV…* accepts the CSV format used by
[CHIRP](https://chirpmyradio.com), which most repeater sources can produce.
Tick the rows you want (or use *Select Within N miles* when the file carries
distances), pick a group and a starting channel, and add them. The sheet stays
open so you can, for example, put nearby repeaters in one group and the rest
in another.

`Scripts/repeaterbook_html_to_chirp.py` converts a saved RepeaterBook
*Proximity Search* results page into such a CSV, sorted alphabetically by
town:

```
python3 Scripts/repeaterbook_html_to_chirp.py "Proximity Search Results.html" \
    -o repeaters.csv --max-miles 25 --operational-only
```

RepeaterBook's data is theirs: use the converted file for programming your own
radio, and do not redistribute it.

## Command-line tool

```
swift run thd74 info                 # model and firmware
swift run thd74 dump                 # channels via live commands (no names)
swift run thd74 clone backup.bin --full   # full memory backup
swift run thd74 show backup.bin      # list channels in a backup
swift run thd74 rename 7 "Simplex"   # WRITES: rename one channel
swift run thd74 restore backup.bin   # WRITES: make the radio match a backup
```

Pass `--port /dev/cu.usbmodemXXXX` to force a serial device, or
`--port bluetooth` to force Bluetooth.

## Building from source

Requires Xcode 16 or later (Swift 6).

```
swift test                 # run the unit tests
./Scripts/make-app.sh      # builds build/TH-D74 Programmer.app (ad-hoc signed)
```

`Scripts/release.sh <team-id> <notary-profile>` produces the signed, notarized
zip that goes on the Releases page. It needs an Apple developer account; see
the comments at the top of the script.

The project is a Swift package:

| Target | Purpose |
|---|---|
| `THD74Kit` | Transports, radio commands, memory image codec, CSV import |
| `thd74` | Command-line tool |
| `THD74App` | SwiftUI app |

## How it works

The radio speaks two protocols over the same serial link:

- **Live commands**: ASCII lines such as `ID`, `FV` and `ME 000`, ending in a
  carriage return. `ME` reads or writes one channel but carries no name.
- **Programming ("MCP") mode**: `0M PROGRAM` switches the radio to a binary
  protocol that reads and writes its memory in 256-byte blocks
  (`R`/`W` + block number, acknowledged with `0x06`), ended with `E`, after
  which the radio restarts. The app uses this mode for everything.

Memory layout used by this tool (500,480 bytes in all):

| Offset | Contents |
|---|---|
| `0x02000` | 1200 × 4-byte flags: band code / in use, scan lockout, group |
| `0x04000` | Channels, 40 bytes each, six to a 256-byte block |
| `0x10000` | 1200 × 16-byte channel names; group names start at index 1152 |

Things learned the hard way, in case they save someone else the time:

- The `/dev/cu.TH-D74` device macOS creates for a paired radio is unreliable:
  it often opens without bringing up the link. This tool opens the radio's
  Serial Port RFCOMM channel directly through IOBluetooth instead.
- A Bluetooth baseband link left over from an earlier session makes the radio
  refuse the serial channel. The tool always drops any existing link first,
  and closes the link when it is done.
- IOBluetooth only opens the channel from the main thread, and delivers data
  through the main dispatch queue, so radio operations run as main run-loop
  blocks.
- In the 40-byte channel record, the transmit step is the whole low nibble of
  byte 8 (CHIRP's driver documents it as three bits).

## Acknowledgements

This tool is a fresh implementation, but it would not exist without the
people who worked the protocol out:

- [CHIRP](https://chirpmyradio.com) and its TH-D74 driver, for the
  programming-mode protocol and memory layout.
- [LA3QMA/TH-D74-Kenwood](https://github.com/LA3QMA/TH-D74-Kenwood), for the
  live command reference.
- [Travis Goodspeed's codeplugtool](https://github.com/travisgoodspeed/codeplugtool),
  for a second look at the `ME` command.
- [Hamlib](https://github.com/Hamlib/Hamlib).

## Licence

MIT. See [LICENSE](LICENSE).

Kenwood and TH-D74 are trademarks of JVCKENWOOD Corporation.
