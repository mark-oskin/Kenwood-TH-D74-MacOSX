#!/usr/bin/env python3
"""Convert a saved RepeaterBook "Proximity Search" results page into a CHIRP CSV.

    python3 Scripts/repeaterbook_html_to_chirp.py results.html -o repeaters.csv

The page is the one you get by saving the search results from repeaterbook.com
in a browser. Rows come out sorted alphabetically by name (the town), then by
frequency. Only the Python standard library is used.
"""

import argparse
import csv
import re
import sys
from collections import Counter
from html.parser import HTMLParser

CHIRP_COLUMNS = [
    "Location", "Name", "Frequency", "Duplex", "Offset", "Tone", "rToneFreq",
    "cToneFreq", "DtcsCode", "DtcsPolarity", "RxDtcsCode", "CrossMode", "Mode",
    "TStep", "Skip", "Power", "Comment", "URCALL", "RPT1CALL", "RPT2CALL", "DVCODE",
]

# Column order of the results table.
FREQ, OFFSET, ACCESS, CALL, LOCATION, STATE, USE, MODES, DISTANCE, STATUS = range(1, 11)

CTCSS_TONES = {
    "67.0", "69.3", "71.9", "74.4", "77.0", "79.7", "82.5", "85.4", "88.5", "91.5",
    "94.8", "97.4", "100.0", "103.5", "107.2", "110.9", "114.8", "118.8", "123.0",
    "127.3", "131.8", "136.5", "141.3", "146.2", "151.4", "156.7", "159.8", "162.2",
    "165.5", "167.9", "171.3", "173.8", "177.3", "179.9", "183.5", "186.2", "189.9",
    "192.8", "196.6", "199.5", "203.5", "206.5", "210.7", "218.1", "225.7", "229.1",
    "233.6", "241.8", "250.3", "254.1",
}

NAME_LENGTH = 16  # TH-D74 channel names


class ResultsTable(HTMLParser):
    """Collects the text of each cell of each body row of the results table."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self._in_body = False
        self._row = None
        self._cell = None
        self._status = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "tbody":
            self._in_body = True
        elif not self._in_body:
            return
        elif tag == "tr":
            self._row = []
        elif tag == "td" and self._row is not None:
            self._cell = []
            self._status = None
        elif tag == "span" and self._cell is not None and "status-icon" in attrs.get("class", ""):
            self._status = attrs.get("title", "")

    def handle_endtag(self, tag):
        if tag == "tbody":
            self._in_body = False
        elif tag == "td" and self._cell is not None and self._row is not None:
            text = " ".join("".join(self._cell).split())
            # The status cell is only an emoji; use its tooltip instead.
            self._row.append(self._status if self._status is not None else text)
            self._cell = None
        elif tag == "tr" and self._row is not None:
            self.rows.append(self._row)
            self._row = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)


def band_of(mhz):
    for low, high, name in ((144, 148, "2m"), (222, 225, "1.25m"), (420, 450, "70cm")):
        if low <= mhz <= high:
            return name
    return None


def parse_row(cells):
    """Turns one table row into a dict of CHIRP fields plus sorting helpers."""
    freq_text = cells[FREQ].split()
    freq = float(freq_text[0])
    simplex = "Simplex" in freq_text[1:]

    offset_match = re.match(r"([+-]?)([\d.]+)\s*MHz", cells[OFFSET])
    offset = float(offset_match.group(2)) if offset_match else 0.0
    sign = offset_match.group(1) if offset_match else ""
    if simplex or offset == 0:
        duplex, offset_out = "", 0.0
    else:
        tx = freq + offset if sign != "-" else freq - offset
        if band_of(tx) != band_of(freq):
            # Cross-band pair: CHIRP stores the transmit frequency itself.
            duplex, offset_out = "split", tx
        else:
            duplex, offset_out = (sign or "+"), offset

    # "Access" is the tone you transmit: a CTCSS tone, a DCS code ("D023"),
    # "CSQ" for none, sometimes prefixed by digital codes ("CC 1 103.5").
    access = cells[ACCESS]
    tone_mode, rtone, dtcs = "", "88.5", "023"
    words = access.split()
    dcs = [w for w in words if re.fullmatch(r"D\d{3}", w)]
    ctcss = [w for w in words if w in CTCSS_TONES]
    if dcs:
        tone_mode, dtcs = "DTCS", dcs[0][1:]
    elif ctcss:
        tone_mode, rtone = "Tone", ctcss[-1]

    modes = cells[MODES].split()
    town = cells[LOCATION].split(",")[0].strip()
    distance = cells[DISTANCE].split()

    comment = "; ".join(part for part in (
        cells[CALL],
        f"{cells[LOCATION]}, {cells[STATE]}",
        cells[USE].title(),
        " ".join(modes),
        f"access {access}" if access and not (len(words) == 1 and (dcs or ctcss)) else "",
        f"{distance[0]} mi {distance[1]}" if len(distance) == 2 else "",
        cells[STATUS] if cells[STATUS] != "Operational" else "",
    ) if part)

    return {
        "town": town,
        "call": cells[CALL],
        "freq": freq,
        "miles": float(distance[0]) if distance else None,
        "status": cells[STATUS],
        "use": cells[USE],
        "csv": {
            "Name": town[:NAME_LENGTH],
            "Frequency": f"{freq:.6f}",
            "Duplex": duplex,
            "Offset": f"{offset_out:.6f}",
            "Tone": tone_mode,
            "rToneFreq": rtone,
            "cToneFreq": "88.5",
            "DtcsCode": dtcs,
            "DtcsPolarity": "NN",
            "RxDtcsCode": "023",
            "CrossMode": "Tone->Tone",
            "Mode": "NFM" if "FM-N" in modes and "FM" not in modes else "FM",
            "TStep": "25.00" if freq >= 300 else "5.00",
            "Skip": "",
            "Power": "",
            "Comment": comment,
            "URCALL": "", "RPT1CALL": "", "RPT2CALL": "", "DVCODE": "",
        },
    }


def name_with_call(town, call):
    """"Springfield W1ABC": the town, shortened if needed so the call sign fits."""
    room = NAME_LENGTH - len(call) - 1
    return f"{town[:room].rstrip()} {call}" if room >= 3 else town[:NAME_LENGTH]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("html", help="saved RepeaterBook proximity search results page")
    parser.add_argument("-o", "--output", default="repeaters-chirp.csv", help="CSV file to write (default: %(default)s)")
    parser.add_argument("--max-miles", type=float, help="keep only repeaters within this distance")
    parser.add_argument("--operational-only", action="store_true", help="drop repeaters not listed as operational")
    parser.add_argument("--open-only", action="store_true", help="drop closed and private repeaters")
    parser.add_argument("--first-channel", type=int, default=0, help="number for the first row (default: %(default)s)")
    args = parser.parse_args()

    table = ResultsTable()
    with open(args.html, encoding="utf-8", errors="replace") as page:
        table.feed(page.read())

    entries, skipped = [], Counter()
    for cells in table.rows:
        if len(cells) != 11:
            skipped["unrecognised row"] += 1
            continue
        try:
            entry = parse_row(cells)
        except (ValueError, IndexError):
            skipped["unreadable row"] += 1
            continue
        if args.max_miles is not None and (entry["miles"] is None or entry["miles"] > args.max_miles):
            skipped[f"beyond {args.max_miles:g} miles"] += 1
        elif args.operational_only and entry["status"] != "Operational":
            skipped["not operational"] += 1
        elif args.open_only and entry["use"] != "OPEN":
            skipped["closed or private"] += 1
        else:
            entries.append(entry)

    if not entries:
        sys.exit("No repeaters found. Is this a saved RepeaterBook results page?")

    # A town with several repeaters gets the call sign added to tell them apart.
    per_town = Counter(entry["town"].lower() for entry in entries)
    for entry in entries:
        if per_town[entry["town"].lower()] > 1:
            entry["csv"]["Name"] = name_with_call(entry["town"], entry["call"])

    entries.sort(key=lambda e: (e["csv"]["Name"].lower(), e["freq"]))

    with open(args.output, "w", newline="", encoding="utf-8") as out:
        writer = csv.DictWriter(out, fieldnames=CHIRP_COLUMNS)
        writer.writeheader()
        for number, entry in enumerate(entries, start=args.first_channel):
            writer.writerow({"Location": number, **entry["csv"]})

    print(f"Wrote {len(entries)} repeaters to {args.output}")
    for reason, count in skipped.items():
        print(f"  left out {count}: {reason}")


if __name__ == "__main__":
    main()
