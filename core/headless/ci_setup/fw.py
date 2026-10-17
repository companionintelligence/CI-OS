"""The nftables ruleset that exists only while the setup access point is up.

What it does, and why each part is there (report 02, section 4.4):

* a dedicated pair of tables, ``inet ci_setup`` and ``ip ci_setup_nat``, created when the AP comes up and deleted when it
  goes down. Nothing else (ufw, firewalld, Docker) is edited;
* the filter chain hooks ``prerouting`` at priority ``raw`` (-300), which runs before connection tracking and before
  Docker's DNAT rules (``dstnat``, -100). A container port published on 0.0.0.0 is therefore NOT reachable from the AP,
  which an INPUT-chain rule could not guarantee because Docker's NAT diverts the packet first;
* from the AP interface only these are accepted: DHCP (client port 68 to server port 67, before the client has an
  address); and, from a source address inside the AP subnet, DNS to any destination (hard-coded resolvers are redirected to the
  AP's dnsmasq), HTTP to any destination (redirected to the portal), the portal port on the AP address, mDNS, and ping to the AP
  address at 5 per second. Everything else from the
  interface is dropped, including SSH, the CI Hub on 5002, Ollama on 11434 and every published container port;
* a ``forward`` chain drops everything entering or leaving the AP interface, so a failure of the redirects leaves a client with
  nothing instead of a route to the LAN;
* the NAT table redirects port 53 (UDP and TCP) to the local resolver and port 80 to the portal port, so the portal does not
  need port 80 and never competes with Traefik for it.

One limit worth knowing: ``accept`` in a base chain ends evaluation of THAT chain only. A packet accepted here still passes
through other base chains on the same hook (another table's), so a host firewall with a default-deny input policy (ufw) would
still drop the portal port unless it allows the AP interface. The images this ships on have no default-deny firewall; where
one exists, the agent must open the AP interface in it for the lifetime of the AP.
"""
from __future__ import annotations

from typing import Optional

from .errors import ValidationError
from .templating import load_template, render_template
from .validators import Ipv4Net, is_rfc1918, parse_ipv4, validate_ifname, validate_ipv4_subnet, validate_port

TABLES = (("inet", "ci_setup"), ("ip", "ci_setup_nat"))
DEFAULT_PORT = 8080


def render_nft(iface: str, ap_ip: str, port: int = DEFAULT_PORT, subnet: Optional[str] = None) -> str:
    """The ruleset to load with ``nft -f``. ``port`` is where the portal listens on the AP address (1024 to 65535, not 53
    or 80: those are the redirected ports). ``subnet`` is the AP's network (default: the /24 around ``ap_ip``); every rule
    except DHCP also requires a source address inside it, so a client cannot use a spoofed address to be served."""
    validate_ifname(iface, "iface")
    addr = parse_ipv4(ap_ip, "ap_ip")
    if not is_rfc1918(addr):
        raise ValidationError("ap_ip", "range", "must be a private address")
    validate_port(port, "port", minimum=1024)       # 53 and 80 are the redirected ports and fall below the minimum
    net = validate_ipv4_subnet(subnet, "subnet") if subnet is not None else Ipv4Net(addr & 0xFFFFFF00, 24)
    if not net.contains(addr):
        raise ValidationError("subnet", "range", "does not contain the access point address")
    return render_template(load_template("ci_setup.nft.in"), {"IFACE": iface, "AP_IP": ap_ip, "PORT": str(port),
                                                               "SUBNET": net.cidr()})


def render_nft_teardown() -> str:
    """The script that removes both tables whether or not they exist (``add`` first, so ``delete`` cannot fail)."""
    lines = []
    for family, name in TABLES:
        lines.append("add table %s %s" % (family, name))
        lines.append("delete table %s %s" % (family, name))
    return "\n".join(lines) + "\n"
