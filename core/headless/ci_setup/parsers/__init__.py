"""Parsers for the text that iw, nmcli, rfkill, ip -j, wpa_cli and hostapd_cli print.

Every parser here is a total function: it takes text and returns plain data, it never raises on any input (the text
comes from a command whose output we do not control, and an SSID chosen by a stranger is part of it), it never touches
the system, and what it returns is JSON-serialisable after ``to_dict``. Lines a parser does not understand are skipped,
not guessed at. Output that can contain attacker-chosen text (SSIDs from a neighbour's beacon) is kept as bytes or as
escaped text next to a flag saying whether it is safe to use.
"""
