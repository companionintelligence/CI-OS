"""``python3 -m ci_setup probe | policy | render | selftest``.

The command-line face of the library. It only READS the system - every external command goes through
:class:`ci_setup.runners.ReadOnlyRunner`, which refuses anything that is not on its allow-list - and prints JSON (``render``
prints JSON too, with the file texts as strings, or one file as plain text with ``--raw``). It starts no service, writes no
file and needs no privilege beyond what ``iw`` and ``ip`` ask for themselves.

Exit status: 0 on success, 1 when ``selftest`` fails or ``render`` is refused, 2 for a usage error.

The AP key for ``render`` is read from standard input (``--key-stdin``), never from the command line, where it would be
visible in the process table; ``--example`` uses an obviously fake one.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, Optional, Sequence, TextIO

from . import __version__, apcfg, fw, policy, probe, selftest
from .errors import CiSetupError, ValidationError
from .runners import Runner


def _dump(obj: Any, out: TextIO) -> None:
    out.write(json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n")


def _probe_args(sub: argparse.ArgumentParser) -> None:
    sub.add_argument("--fixtures", metavar="DIR", help="answer from DIR/commands.json instead of running commands")
    sub.add_argument("--country", metavar="XX", help="explicit regulatory country (overrides ci.country)")
    sub.add_argument("--no-scan", action="store_true", help="do not read cached scan results")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python3 -m ci_setup", description=__doc__.split("\n\n")[0])
    p.add_argument("--version", action="version", version="ci_setup " + __version__)
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    sp = sub.add_parser("probe", help="read the Wi-Fi hardware and network state and choose a radio")
    _probe_args(sp)

    pp = sub.add_parser("policy", help="should the setup access point be offered?")
    pp.add_argument("--matrix", action="store_true", help="print every combination instead of one decision")
    pp.add_argument("--table", action="store_true", help="with --matrix: the documentation table as text")
    pp.add_argument("--auto", action="store_true", help="take the facts from a probe of this machine")
    _probe_args(pp)
    pp.add_argument("--context", choices=policy.CONTEXTS, default="installed-unclaimed")
    pp.add_argument("--display", choices=policy.DISPLAYS, default="headless")
    pp.add_argument("--network", choices=policy.NETWORKS, default="down")
    pp.add_argument("--stick", action="store_true", help="booted from a Companion Stick")
    pp.add_argument("--headless-param", choices=policy.HEADLESS_PARAMS, default=None, help="ci.headless= value")
    pp.add_argument("--trigger", action="append", default=[], help="explicit recovery trigger seen (repeatable): "
                    + ", ".join(policy.TRIGGERS))
    pp.add_argument("--no-ap-radio", action="store_true", help="no radio can run an access point")
    pp.add_argument("--setup-key-present", action="store_true", help="a printed setup key exists")
    pp.add_argument("--static-credentials-test", action="store_true")
    pp.add_argument("--provisioning-file", action="store_true")
    pp.add_argument("--provisioning-failed", action="store_true")
    pp.add_argument("--down-for", type=float, default=1e9, metavar="SECONDS", help="how long the network has been down")

    rp = sub.add_parser("render", help="render hostapd.conf, dnsmasq.conf and the nftables rules")
    rp.add_argument("what", choices=("hostapd", "dnsmasq", "nft", "nft-teardown", "all"))
    rp.add_argument("--iface", default="wlan0")
    rp.add_argument("--ssid", default=None)
    keyg = rp.add_mutually_exclusive_group()
    keyg.add_argument("--key-stdin", action="store_true", help="read the AP key (first line) from standard input")
    keyg.add_argument("--example", action="store_true", help="use a fake example SSID and key")
    rp.add_argument("--channel", type=int, default=6)
    rp.add_argument("--band", choices=("2.4", "5"), default="2.4")
    rp.add_argument("--country", default=None)
    rp.add_argument("--subnet", default=apcfg.DEFAULT_SUBNET)
    rp.add_argument("--port", type=int, default=fw.DEFAULT_PORT)
    rp.add_argument("--raw", action="store_true", help="print the single rendered file as plain text")

    sub.add_parser("selftest", help="run the built-in checks")
    return p


def _make_probe(args: argparse.Namespace, runner: Optional[Runner], fs: Any) -> Dict[str, Any]:
    if runner is None:
        runner = probe.fixture_dir_runner(args.fixtures) if args.fixtures else probe.default_runner()
    if fs is None:
        fs = probe.fixture_dir_fs(args.fixtures) if args.fixtures else probe.default_fs()
    return probe.run_probe(runner, fs, explicit_country=args.country, include_scan=not args.no_scan)


def _cmd_probe(args: argparse.Namespace, runner: Optional[Runner], fs: Any, out: TextIO) -> int:
    _dump(_make_probe(args, runner, fs), out)
    return 0


def _cmd_policy(args: argparse.Namespace, runner: Optional[Runner], fs: Any, out: TextIO) -> int:
    if args.matrix:
        if args.table:
            out.write(policy.matrix_table())
        else:
            _dump([{"input": i.to_dict(), "decision": d.to_dict()} for i, d in policy.iter_matrix()], out)
        return 0
    if args.auto:
        rep = _make_probe(args, runner, fs)
        sysf = rep["system"]
        route = bool(rep["ip"]["uplink"])
        inp = policy.PolicyInput(
            context=policy.context_from_facts(sysf["live"], sysf["claimed"]), display=sysf["display"],
            network=policy.network_state(route, rep["network_manager"]["connectivity"]), stick=sysf["stick"],
            headless_param=args.headless_param or sysf["headless_param"], triggers=tuple(args.trigger),
            ap_capable_radio=rep["radio"]["mode"] != "none", has_setup_key=args.setup_key_present,
            static_credentials_test=args.static_credentials_test, provisioning_file=args.provisioning_file,
            provisioning_failed=args.provisioning_failed, network_down_for_s=args.down_for)
    else:
        inp = policy.PolicyInput(
            context=args.context, display=args.display, network=args.network, stick=args.stick,
            headless_param=args.headless_param or "auto", triggers=tuple(args.trigger),
            ap_capable_radio=not args.no_ap_radio, has_setup_key=args.setup_key_present,
            static_credentials_test=args.static_credentials_test, provisioning_file=args.provisioning_file,
            provisioning_failed=args.provisioning_failed, network_down_for_s=args.down_for)
    _dump({"input": inp.to_dict(), "decision": policy.decide(inp).to_dict()}, out)
    return 0


EXAMPLE_SSID = "Companion-Setup-EXAM"
EXAMPLE_KEY = "EXAMPLEKEY12"


def _cmd_render(args: argparse.Namespace, stdin: TextIO, out: TextIO) -> int:
    files = {}  # type: Dict[str, str]
    try:
        needs_key = args.what in ("hostapd", "all")
        ssid, key = args.ssid, None
        if needs_key:
            if args.example:
                ssid, key = ssid or EXAMPLE_SSID, EXAMPLE_KEY
            elif args.key_stdin:
                key = stdin.readline().rstrip("\n")
            else:
                sys.stderr.write("render %s needs --key-stdin or --example\n" % args.what)
                return 2
            if ssid is None:
                ssid = EXAMPLE_SSID
        net = apcfg.parse_cidr(args.subnet, "subnet")
        ap_ip = apcfg.ap_addresses(net)["ap_ip"]
        if args.what in ("hostapd", "all"):
            files["hostapd.conf"] = apcfg.render_hostapd(apcfg.ApParams(
                iface=args.iface, ssid=ssid, passphrase=key, channel=args.channel, band=args.band,
                country=args.country.upper() if args.country else None))
        if args.what in ("dnsmasq", "all"):
            files["dnsmasq.conf"] = apcfg.render_dnsmasq(apcfg.DhcpParams(iface=args.iface, subnet=args.subnet))
        if args.what in ("nft", "all"):
            files["ci_setup.nft"] = fw.render_nft(args.iface, ap_ip, args.port, net.cidr())
        if args.what in ("nft-teardown", "all"):
            files["ci_setup-teardown.nft"] = fw.render_nft_teardown()
    except (ValidationError, CiSetupError) as exc:
        sys.stderr.write("refused: %s\n" % exc)
        return 1
    if args.raw:
        if len(files) != 1:
            sys.stderr.write("--raw needs a single file\n")
            return 2
        out.write(next(iter(files.values())))
    else:
        _dump({"files": files, "note": "hostapd.conf contains the AP key" if "hostapd.conf" in files else ""}, out)
    return 0


def _cmd_selftest(out: TextIO) -> int:
    result = selftest.run_selftest()
    _dump(result, out)
    return 0 if result["ok"] else 1


def main(argv: Optional[Sequence[str]] = None, runner: Optional[Runner] = None, fs: Any = None,
         stdin: Optional[TextIO] = None, stdout: Optional[TextIO] = None) -> int:
    """Entry point; ``runner``, ``fs``, ``stdin`` and ``stdout`` are injectable for tests."""
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    out = stdout if stdout is not None else sys.stdout
    if args.cmd == "probe":
        return _cmd_probe(args, runner, fs, out)
    if args.cmd == "policy":
        return _cmd_policy(args, runner, fs, out)
    if args.cmd == "render":
        return _cmd_render(args, stdin if stdin is not None else sys.stdin, out)
    if args.cmd == "selftest":
        return _cmd_selftest(out)
    return 2
