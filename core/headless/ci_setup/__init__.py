"""ci_setup: the tested, side-effect-free library behind the Companion OS headless Wi-Fi setup.

This package is the foundation of the setup redesign described in docs/architecture/headless-setup.md:
validators, parsers for the command output the setup code has to read (iw, nmcli, rfkill, ip -j, hostapd and
wpa_supplicant status), the regulatory-domain and "should the access point be offered" policies, credential and
token handling, the captive-portal probe answers, the setup job state machine, the renderers for the
hostapd, dnsmasq and nftables configuration, and operation-bound owner statements with a replay guard.

Rules every module here follows:

* Importing a module does nothing: no file is opened, no process is started, no socket is created. A test
  enforces this with an audit hook.
* Nothing needs root. Functions take their input as text, and the few that touch the system take an injectable
  runner or file-system object (see runners.py and fs.py), so a Mac or a CI container can run all of it.
* Time comes from an injected clock (clock.py), randomness from an injectable source that defaults to the
  secrets module, so every state machine is deterministic under test. Elapsed time is always a monotonic reading;
  the one use of wall-clock time is an absolute expiry that a signer chose (statement.py, through clock.WallClock).
* statement.py and replay.py (owner statements and the guard that makes each one single-use) are libraries only: nothing
  calls them yet. The signature check, the wall clock and the replay store are arguments, and the only store here keeps
  its markers in memory. A store that writes files will be a module of its own, imported only by a daemon, never by
  this package and never by the read-only command line.
* Nothing in here changes system state. The CLI (python3 -m ci_setup) only reads.
* Python 3.8 or newer, standard library only.
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
