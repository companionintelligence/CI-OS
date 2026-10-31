# Invariants of the Companion OS installer overlay (backends/cachyos/installer/), checked on the files alone: no build, no network,
# no root. Called by installer-config.sh; prints PASS/FAIL/SKIP lines and exits non-zero when anything failed.
#
#   python3 -I backends/cachyos/iso/tests/installer-config.py
#
# Python 3 standard library + PyYAML (python-yaml; yamllint needs it already). Reads the two recorded fixtures in
# installer-fixtures/: packages.json (every package name checked against archlinux.org and the CachyOS repository on the day it
# was written, by installer/packages/check-packages.py) and upstream-3.4.2-13.facts (the shape of the pinned installer).
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True

try:
    import yaml
except ImportError:
    print("SKIP  installer-config.py needs PyYAML (python-yaml)")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CACHYOS = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.dirname(os.path.dirname(CACHYOS))
INST = os.path.join(CACHYOS, "installer")
PROV = os.path.join(CACHYOS, "provision")
OVERLAY_FILES = os.path.join(CACHYOS, "iso", "overlay", "files", "airootfs")
FIX = os.path.join(HERE, "installer-fixtures")

passed = failed = 0


def ok(desc):
    global passed
    passed += 1
    print("PASS  " + desc)


def bad(desc, detail=""):
    global failed
    failed += 1
    print("FAIL  " + desc)
    for line in str(detail).splitlines():
        print("      " + line)


def check(desc, cond, detail=""):
    if cond:
        ok(desc)
    else:
        bad(desc, detail)


def load_yaml(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def strip_comments(src):
    """Shell/YAML/desktop comment lines removed (a line whose first non-blank character is #)."""
    return "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))


def walk_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from walk_strings(k)
            yield from walk_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk_strings(v)


def kv(path):
    out = {}
    for line in text(path).splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


# ---------------------------------------------------------------------------------------------------------------------------------
print("== YAML")
modules_dir = os.path.join(INST, "modules")
confs = sorted(f for f in os.listdir(modules_dir) if f.endswith((".conf", ".yaml")))
docs = {}
for f in confs:
    try:
        docs[f] = load_yaml(os.path.join(modules_dir, f))
        ok("modules/%s parses as YAML" % f)
    except yaml.YAMLError as exc:
        bad("modules/%s parses as YAML" % f, exc)
try:
    settings = load_yaml(os.path.join(INST, "settings.conf"))
    ok("settings.conf parses as YAML")
except yaml.YAMLError as exc:
    settings = {}
    bad("settings.conf parses as YAML", exc)
try:
    branding = load_yaml(os.path.join(INST, "branding", "companion", "branding.desc"))
    ok("branding/companion/branding.desc parses as YAML (placeholders are quoted)")
except yaml.YAMLError as exc:
    branding = {}
    bad("branding/companion/branding.desc parses as YAML", exc)

contract = kv(os.path.join(INST, "contract.env"))
facts_lines = [l.rstrip("\n") for l in open(os.path.join(FIX, "upstream-3.4.2-13.facts"), encoding="utf-8") if l.strip() and not l.startswith("#")]
up_modules = {l.split(" ", 1)[1] for l in facts_lines if l.startswith("module ")}
up_confs = {l.split(" ", 1)[1] for l in facts_lines if l.startswith("conf ")}
up_owned = {l.split(" ", 2)[2] for l in facts_lines if l.startswith("owned cachyos-hello ")}

# ---------------------------------------------------------------------------------------------------------------------------------
print("== branding (no CachyOS in what the installer shows)")
bdir = os.path.join(INST, "branding", "companion")
btxt = {f: text(os.path.join(bdir, f)) for f in os.listdir(bdir)}
check("the branding component contains no 'cachyos' (any case) in branding.desc, show.qml or stylesheet.qss",
      not any(re.search("cachy", v, re.I) for v in btxt.values()),
      "\n".join("%s: %s" % (f, m) for f, v in btxt.items() for m in re.findall(".*cachy.*", v, re.I)))
strings = branding.get("strings", {})
check("productName, shortProductName and bootloaderEntryName are 'Companion OS'",
      all(strings.get(k) == "Companion OS" for k in ("productName", "shortProductName", "bootloaderEntryName")), strings)
check("componentName == directory name == settings.conf branding == contract.env",
      branding.get("componentName") == "companion" == settings.get("branding") == contract["CI_BRANDING_COMPONENT"])
check("no uploadServer: the failure page cannot send the install log anywhere", "uploadServer" not in branding)
urls = [strings.get(k, "") for k in strings if k.lower().endswith("url")]
check("the branding URLs are the product's own (ci.computer)", urls and all(u.startswith("https://ci.computer") for u in urls), urls)
check("images are the three rendered PNGs", branding.get("images") == {"productLogo": "logo.png", "productIcon": "icon.png", "productWelcome": "welcome.png"})
check("the slideshow is show.qml, API 2", branding.get("slideshow") == "show.qml" and branding.get("slideshowAPI") == 2)
placeholders = set()
for v in btxt.values():
    placeholders |= set(re.findall(r"@[A-Z][A-Z_]*@", v))
# What stage-installer.sh fills: the `-e "s|@NAME@|...|g"` expressions of its subst(), read from the script itself.
known = {"@%s@" % k for k in re.findall(r'-e "s\|@([A-Z][A-Z_]*)@\|', text(os.path.join(INST, "stage-installer.sh")))}
check("every placeholder in the branding templates is one stage-installer.sh fills", placeholders <= known, placeholders - known)
check("no hex colour is typed in the branding templates (the brand tokens are the only source)",
      not any(re.search(r"#[0-9a-fA-F]{6}\b", strip_comments(v)) for v in btxt.values()))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== module configs (decision D6) against contract.env")
bl = docs["bootloader.conf"]
check("bootloader: GRUB, the UEFI entry is companion-os, the fallback is installed, no hybrid GRUB",
      bl.get("efiBootLoader") == contract["CI_BOOTLOADER"] == "grub" and bl.get("efiBootloaderId") == contract["CI_EFI_BOOTLOADER_ID"] == "companion-os"
      and bl.get("installEFIFallback") is True and bl.get("installHybridGRUB") is False)
check("bootloader: still reads the chooser's choice from global storage", bl.get("efiBootLoaderVar") == "packagechooser_bootloader")
check("bootloader: no CachyOS wallpaper path (limineSplashLogo emptied)", not re.search("cachy", str(bl.get("limineSplashLogo", "")), re.I))
chooser = docs["packagechooser_bootloader.conf"]
check("the bootloader chooser offers GRUB only, preselected",
      [i["id"] for i in chooser["items"]] == ["grub"] and chooser.get("default") == "grub" and chooser.get("mode") == "required")
check("the chooser item has no CachyOS screenshot and no platform filter (a handheld would see an empty page)",
      "screenshot" in chooser["items"][0] and "cachy" not in chooser["items"][0]["screenshot"].lower() and "platform" not in chooser["items"][0])
shot = str(chooser["items"][0].get("screenshot", ""))
render_specs = re.search(r"^for spec in ([^;]+); do", text(os.path.join(INST, "render-installer-assets.sh")), re.M)
rendered = {x.split(":")[0] for x in (render_specs.group(1).split() if render_specs else [])}
check("the chooser's picture is the Companion mark rendered into the branding directory, NOT Calamares' built-in placeholder (a blue zip-archive icon in a white square on ISO #4)",
      shot == "/usr/share/calamares/branding/companion/" + os.path.basename(shot) and os.path.basename(shot) in rendered and not shot.startswith(":/"), (shot, sorted(rendered)))
check("the chooser instance is named 'bootloader' (global storage key packagechooser_bootloader)",
      any(i.get("id") == "bootloader" and i.get("module") == "packagechooser" and i.get("config") == "packagechooser_bootloader.conf" for i in settings["instances"]))
g = docs["grubcfg.conf"]
check("grubcfg: GRUB_THEME is the Companion OS theme (contract.env), defaults are forced, the distributor is the branding's",
      g["defaults"]["GRUB_THEME"] == contract["CI_INSTALLED_GRUB_THEME"] and g.get("always_use_defaults") is True and g.get("keep_distributor") is False)
check("grubcfg: the kernel parameters are the installer's (nowatchdog, nvme_load=YES)", g.get("kernel_params") == ["nowatchdog", "nvme_load=YES"])
p = docs["plymouthcfg.conf"]
check("plymouthcfg: the Companion OS theme for every GPU",
      p.get("plymouth_theme") == p.get("plymouth_theme_amdgpu") == contract["CI_INSTALLED_PLYMOUTH_THEME"])
u = docs["users.conf"]
groups = {(x if isinstance(x, str) else x["name"]): x for x in u["defaultGroups"]}
check("users: docker is a default group that is created when missing (must_exist false, system true)",
      isinstance(groups.get("docker"), dict) and groups["docker"].get("must_exist") is False and groups["docker"].get("system") is True)
check("users: wheel stays the sudoers group; the hostname template is companion-os",
      u.get("sudoersGroup") == "wheel" and u["hostname"]["template"] == contract["CI_HOSTNAME"] == "companion-os")
check("users: the installer's other defaultGroups are all still there",
      {"wheel", "rfkill", "sys", "users", "lp", "video", "network", "storage", "audio", "nopasswdlogin"} <= set(groups))
w = docs["welcome_online.conf"]
check("welcome: the internet check URL is the contract's neutral one, not a CachyOS host",
      w["requirements"]["internetCheckUrl"] == contract["CI_INTERNET_CHECK_URL"] and "cachy" not in w["requirements"]["internetCheckUrl"].lower())
check("welcome: internet and ram are still required", set(w["requirements"]["required"]) == {"ram", "internet"})
n = docs["netinstall.conf"]
check("netinstall: the only package-list source is the overlay's own file:// copy (no GitHub, no http)",
      n["groupsUrl"] == ["file:///etc/calamares/modules/netinstall.yaml"] and n.get("required") is True)
ps = docs["pacstrap.conf"]
check("pacstrap: the CachyOS boot-animation and theme packages are gone, plymouth stays",
      "plymouth" in ps["basePackages"] and not any(x.startswith("cachyos-plymouth") for x in ps["basePackages"]))
check("pacstrap: the UFW script is not copied (nothing would remove it)", "/etc/calamares/scripts/enable-ufw" not in ps["postInstallFiles"])
check("pacstrap: the base system's CachyOS plumbing is kept (hooks, keyring, mirrorlists, settings, chwd)",
      {"cachyos-hooks", "cachyos-keyring", "cachyos-mirrorlist", "cachyos-settings", "chwd", "base", "sudo"} <= set(ps["basePackages"]))

def values_only(doc):
    return [s for s in walk_strings(doc)]

forbidden = re.compile(r"cachyos\.org|raw\.githubusercontent|githubusercontent|paste\.|wiki\.cachyos", re.I)
bad_hits = []
for f, d in docs.items():
    for s in values_only(d):
        if forbidden.search(s):
            bad_hits.append("%s: %s" % (f, s))
bad_hits += ["settings.conf: %s" % s for s in values_only(settings) if forbidden.search(s)]
bad_hits += ["branding.desc: %s" % s for s in values_only(branding) if forbidden.search(s)]
check("no configured value points at a CachyOS web host, raw GitHub or a paste server", not bad_hits, "\n".join(bad_hits))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== install sequence (settings.conf)")
seq = []
for blk in settings["sequence"]:
    for mode, items in blk.items():
        seq.extend((mode, i) for i in items)
exec_ = [i for m, i in seq if m == "exec"]
show = [i for m, i in seq if m == "show"]
def before(a, b, lst=exec_):
    return a in lst and b in lst and lst.index(a) < lst.index(b)
check("show: welcome, locale, keyboard, bootloader chooser, partition, netinstall, users, summary, finished",
      show == ["welcome@online", "locale", "keyboard", "packagechooser@bootloader", "partition", "netinstall", "users", "summary", "finished"], show)
check("no desktop chooser, no UFW step, no greeter step (dropped on purpose)",
      not any(x in exec_ + show for x in ("packagechooser@desktop", "shellprocess@enable_ufw", "shellprocess@greetd")))
check("exec: packages@online runs after pacstrap and users", before("pacstrap", "packages@online") and before("users", "packages@online"))
check("exec: ci_os_stage is right after packages@online and before plymouthcfg, initcpio, grubcfg, bootloader and services-systemd",
      exec_.index("shellprocess@ci_os_stage") == exec_.index("packages@online") + 1
      and all(before("shellprocess@ci_os_stage", x) for x in ("plymouthcfg", "initcpiocfg", "initcpio", "grubcfg", "bootloader", "services-systemd")))
check("exec: grubcfg runs before bootloader (grub-mkconfig reads the theme and the distributor)", before("grubcfg", "bootloader"))
check("exec: services-systemd runs after ci_os_stage (the units it enables must exist)", before("shellprocess@ci_os_stage", "services-systemd"))
check("exec: ci_os_fixups runs after the stock final shellprocess and after bootloader", before("shellprocess", "shellprocess@ci_os_fixups") and before("bootloader", "shellprocess@ci_os_fixups"))
check("exec: the stock shellprocess (user home from /etc/skel) runs AFTER ci_os_stage, so the skeleton edits reach the home",
      before("shellprocess@ci_os_stage", "shellprocess"))
check("exec: the stock steps that write the target's pacman.conf and keyring are kept",
      all(x in exec_ for x in ("shellprocess@before-online", "shellprocess@initialize_pacman", "shellprocess@modify_mk_hook", "shellprocess@reset_mk_hook", "chwd")))
inst_ids = {(i["module"], i["id"]) for i in settings["instances"]}
used = {tuple(x.split("@", 1)) for x in exec_ + show if "@" in x}
check("every module@instance in the sequence has an instance (and the reverse)",
      {(m, i) for m, i in used} == {(m, i) for m, i in inst_ids}, "used-only: %s\ninstances-only: %s" % (sorted(used - inst_ids), sorted(inst_ids - used)))
miss = [i["config"] for i in settings["instances"] if not os.path.exists(os.path.join(modules_dir, i["config"])) and i["config"] not in up_confs]
check("every instance config exists in the overlay or in the pinned installer", not miss, miss)
mods = {x.split("@")[0] for x in exec_ + show}
check("every module of the sequence exists in the pinned installer", mods <= up_modules, sorted(mods - up_modules))
check("branding is 'companion'; prompt-install stays true", settings["branding"] == "companion" and settings.get("prompt-install") is True)

# ---------------------------------------------------------------------------------------------------------------------------------
print("== services")
units = {x["name"]: x for x in docs["services-systemd.conf"]["units"]}
payload_dir = os.path.join(REPO, "core", "headless", "payload")
payload_units = sorted(os.path.splitext(f)[0] for f in os.listdir(os.path.join(payload_dir, "systemd", "system")) if f.endswith(".service"))
# The units setup-device-hotspot-start.sh starts by name when the monitor decides there is no network: they need no `enable`, and must
# not have one (hostapd-setup enabled = an access point at every boot; nginx enabled = the setup API on port 80 on every network).
hotspot = strip_comments(text(os.path.join(payload_dir, "usr", "local", "bin", "setup-device-hotspot-start.sh")))
on_demand = sorted(set(re.findall(r"systemctl start ([A-Za-z0-9@_-]+)(?:\.service)?", hotspot)))
enabled = {n for n, u in units.items() if u.get("action") == "enable"}
boot_units = ["docker"] + [u for u in payload_units if u not in on_demand] + ["ci-os-first-boot-setup", "ci-os-first-boot-setup.timer"]
check("services-systemd enables docker, the units of the headless payload that nothing starts on demand (the backend, the monitor) and the first-boot service and timer",
      all(units.get(x, {}).get("action") == "enable" for x in boot_units) and {"setup-backend", "setup-network-monitor"} <= set(boot_units), [x for x in boot_units if x not in units])
check("the access point and nginx are started on demand by the hotspot script, so services-systemd does NOT enable them (no AP and no port 80 at every boot)",
      {"nginx", "hostapd-setup", "dnsmasq-setup"} <= set(on_demand) and not (set(on_demand) & enabled), "on demand: %s; enabled anyway: %s" % (on_demand, sorted(set(on_demand) & enabled)))
check("the monitor is what runs the hotspot script, and the backend it enables binds the loopback only (enabling it opens no port)",
      "setup-device-hotspot-start.sh" in text(os.path.join(payload_dir, "usr", "local", "bin", "setup-network-monitor.sh"))
      and "--bind 127.0.0.1:5000" in text(os.path.join(payload_dir, "systemd", "system", "setup-backend.service")))
check("none of the added units is mandatory (a missing optional unit must not abort the install)",
      all(units[x].get("mandatory") is False for x in boot_units if x in units))
check("tailscaled and ollama are NOT enabled here (provision.sh enables them after configuring them)",
      "tailscaled" not in units and "ollama" not in units)

# ---------------------------------------------------------------------------------------------------------------------------------
print("== packages")
fx = json.load(open(os.path.join(FIX, "packages.json"), encoding="utf-8"))
found = set(fx["found"])
spec = importlib.util.spec_from_file_location("ci_pkglist", os.path.join(INST, "lib", "ci-pkglist.py"))
pk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pk)
always, optional = pk.package_sets(INST)
code = pk.code_added(INST)
code_all = set(code["always"]) | set(code["optional"]) | set(code["unused"])
live_extra = [l.split("#")[0].strip() for l in text(os.path.join(INST, "packages", "live-extra.list")).splitlines() if l.split("#")[0].strip()]
names = set(always) | set(optional) | set(ps["basePackages"]) | set(live_extra)
check("every package name in the overlay was found on archlinux.org or the CachyOS repository (fixture, %s)" % fx["checked"],
      names <= found, sorted(names - found))
check("the fixture lists nothing missing", not fx["missing"], fx["missing"])
check("the fixture has no name the overlay no longer uses (re-run check-packages.py after removing packages)",
      found <= names, sorted(found - names))
# The packages pacstrap/main.py adds in code (cachyos-grub-theme among them) are the installer's, not the overlay's: the checks below are
# about what the overlay itself asks for.
all_names = (set(always) | set(optional) | set(ps["basePackages"])) - code_all
check("no firewall package anywhere (ufw, ufw-extras, plasma-firewall): the edition ships no host firewall",
      not (all_names & {"ufw", "ufw-extras", "plasma-firewall", "firewalld"}))
check("no CachyOS-branded application or artwork package (hello, wallpapers, themes, shell configs, kernel manager, installer GUIs, cachy-update)",
      not [x for x in all_names if re.match(r"(cachyos-(hello|wallpapers|plymouth|grub-theme|kernel-manager|packageinstaller|fish|zsh|emerald|iridescent|nord|micro)|cachy-update$|arch-update$)", x)],
      sorted(x for x in all_names if x.startswith(("cachyos-", "cachy-", "arch-update"))))
check("cachy-update is not installed (ISO #4: a 'Cachy-Update' menu entry and a teal C tray icon in every desktop frame, the only CachyOS-named UI), and no 'arch-update' unit is enabled for it",
      "cachy-update" not in names and not any("arch-update" in str(n) for n in units), [x for x in ("cachy-update",) if x in names] + [n for n in units if "arch-update" in str(n)])
check("the post-install fix-up removes cachy-update if it arrives anyway, and hides it when pacman refuses",
      "pacman -Rns --noconfirm cachy-update" in text(os.path.join(INST, "scripts", "ci-os-post-install-fixups.sh"))
      and "arch-update-tray.desktop" in text(os.path.join(INST, "scripts", "ci-os-post-install-fixups.sh")))
ops = set(pk.operations(INST))
check("the core operations include the container stack (docker, docker-compose, docker-buildx) and the tools of ci-hub.sh (jq, curl, openssl)",
      {"docker", "docker-compose", "docker-buildx", "jq", "curl", "openssl"} <= ops, ops)
arch_install = text(os.path.join(REPO, "backends", "arch", "headless-setup", "install.sh"))
m = re.search(r"^ARCH_DEPS=\(([^)]*)\)", arch_install, re.M)
deps = m.group(1).split() if m else []
installed_somewhere = ops | all_names
check("every runtime dependency backends/arch/headless-setup/install.sh installs for the payload (ARCH_DEPS) is installed by this edition",
      deps and set(deps) <= installed_somewhere | {"python"}, sorted(set(deps) - installed_somewhere))
check("`iw`, which the payload's scripts call, is in the operations", "iw" in ops)
check("the live image's extra package (kdialog) is in the list the check covers", "kdialog" in live_extra)
check("an opt-in group exists for NVIDIA and AMD local AI, and none of their packages is in the always-on set",
      {"ollama-cuda", "ollama-rocm"} <= set(optional) and not ({"ollama-cuda", "ollama-rocm", "nvidia-container-toolkit"} & set(always)))
check("ollama and its Vulkan backend are in the core operations (no `curl | sh` install)", {"ollama", "ollama-vulkan"} <= ops)
check("Firefox is selected by default (the Companion apps are web based)", "firefox" in always)
check("the kernels of the base are in the always-on set", {"linux-cachyos", "linux-cachyos-lts"} <= set(always))
check("plasma-login-manager and plasma-desktop are in the always-on set", {"plasma-login-manager", "plasma-desktop"} <= set(always))
check("the preflight set ('always') holds every pacstrap.conf basePackages name: the base system is checked before a disk is touched, not only the package job's list",
      set(ps["basePackages"]) <= set(always), sorted(set(ps["basePackages"]) - set(always)))
check("pacstrap-code-added.list: the names the launcher preflights are 'always' (grub, grub-hook, both microcodes, the kernels) and 'optional' (filesystems, handheld); other bootloaders are 'unused', in neither set",
      {"grub", "grub-hook", "cachyos-grub-theme", "intel-ucode", "amd-ucode", "linux-cachyos", "linux-cachyos-lts"} <= set(code["always"])
      and {"zfs-utils", "snapper", "grub-btrfs-support", "bcachefs-tools"} <= set(code["optional"])
      and {"limine", "refind", "systemd-boot-manager"} <= set(code["unused"])
      and not (code_all - set(code["unused"])) & {"limine", "refind", "systemd-boot-manager", "limine-entry-tool"}
      and not set(code["unused"]) & (set(always) | set(optional)), code)
check("the 'unused' names are exactly the bootloaders the chooser does not offer (it offers GRUB only), so no reachable path adds them",
      [i["id"] for i in chooser["items"]] == ["grub"] and all(re.match(r"^(limine|refind|systemd-boot)", n) for n in code["unused"]), code["unused"])
# What the pinned installer's pacstrap/main.py adds in code, read independently of ci-guards.sh from the recorded statements (facts).
pm_lines = [l.split(" ", 2)[2] for l in open(os.path.join(FIX, "upstream-3.4.2-13.facts"), encoding="utf-8").read().split("\n")
            if l.startswith("marker /usr/lib/calamares/modules/pacstrap/main.py ")]
recorded, depth, on = set(), 0, False
for l in pm_lines:
    if re.search(r"base_packages\s*(\+=|\.append\s*\()", l):
        on, depth = True, 0
    if on:
        recorded |= set(re.findall(r'"([A-Za-z0-9@._+-]+)"', l))
        depth += len(re.findall(r"[\[(]", l)) - len(re.findall(r"[\])]", l))
        if depth <= 0:
            on = False
check("pacstrap-code-added.list names exactly the packages the pinned installer's pacstrap/main.py adds in code (from the recorded facts)",
      recorded == code_all and len(recorded) > 20, "only in the code: %s; only in the list: %s" % (sorted(recorded - code_all), sorted(code_all - recorded)))
gl = [l for l in text(os.path.join(INST, "guards.list")).splitlines() if re.match(r"^(critical|cosmetic)\s*\|", l)]
check("guards.list rows all have 5 fields and a known severity and kind",
      all(len(l.split("|")) == 5 and l.split("|")[0].strip() in ("critical", "cosmetic")
          and l.split("|")[1].strip() in ("exists", "contains", "oexists", "lexists", "keys", "settings-drift", "list-drift", "code-names", "settings", "shell-timeouts") for l in gl))
sd_row = [l for l in gl if "settings-drift" in l][0].split("|")
sd = sd_row[2].strip()
dropped = {x for x in ("packagechooser@desktop", "shellprocess@enable_ufw", "shellprocess@greetd")}
check("guards.list's drift allow-list names exactly the dropped steps", set(sd[len("allow="):].split(",")) == dropped, sd)
anchors = sd_row[3].strip()
check("settings-drift has anchors (the steps the overlay is built around: partition, pacstrap, packages@online, bootloader, and the partition page), all in the overlay's own sequence",
      set(anchors[len("anchors="):].split(",")) == {"exec:partition", "exec:pacstrap", "exec:packages@online", "exec:bootloader", "show:partition"}
      and all(a in {"exec:" + x for x in exec_} | {"show:" + x for x in show} for a in anchors[len("anchors="):].split(",")), anchors)
keys_rows = {l.split("|")[2].strip(): l.split("|")[0].strip() for l in gl if l.split("|")[1].strip() == "keys"}
check("`keys` is critical for pacstrap and bootloader (their Python reads the frozen copy's keys directly) and cosmetic for every other config",
      keys_rows.get("pacstrap") == keys_rows.get("bootloader") == "critical" and all(v == "cosmetic" for k, v in keys_rows.items() if k not in ("pacstrap", "bootloader"))
      and len(keys_rows) >= 10, keys_rows)
up_lists = {(l.split(" ")[1], l.split(" ")[2]): set(l.split(" ")[3:]) for l in facts_lines if l.startswith("list ")}
ld_rows = {l.split("|")[2].strip(): set(l.split("|")[3].strip()[len("allow="):].split(",")) for l in gl if l.split("|")[1].strip() == "list-drift"}
mine = {("pacstrap", "basePackages"): set(ps["basePackages"]), ("pacstrap", "postInstallFiles"): set(ps["postInstallFiles"])}
check("list-drift covers pacstrap basePackages and postInstallFiles, and its allow-lists are exactly what the pinned installer has and the overlay dropped",
      set(ld_rows) == {"pacstrap:basePackages", "pacstrap:postInstallFiles"}
      and all(up_lists[tuple(k.split(":"))] - mine[tuple(k.split(":"))] == v and not mine[tuple(k.split(":"))] - up_lists[tuple(k.split(":"))] for k, v in ld_rows.items()),
      {k: (sorted(up_lists[tuple(k.split(":"))] - mine[tuple(k.split(":"))]), sorted(v)) for k, v in ld_rows.items()})
check("a code-names guard pins pacstrap-code-added.list against the installer's pacstrap/main.py, and the list is a staged overlay file (oexists)",
      any(l.split("|")[1].strip() == "code-names" and l.split("|")[0].strip() == "critical" and l.split("|")[3].strip() == "pacstrap-code-added.list" for l in gl)
      and any(l.split("|")[1].strip() == "oexists" and l.split("|")[2].strip() == "pacstrap-code-added.list" for l in gl))
up_exec = [l.split(" ", 1)[1].split(":", 1)[1] for l in facts_lines if l.startswith("seq exec:")]
up_show = [l.split(" ", 1)[1].split(":", 1)[1] for l in facts_lines if l.startswith("seq show:")]
check("the steps settings.conf drops are exactly the pinned installer's sequence minus ours",
      (set(up_exec) | set(up_show)) - set(exec_) - set(show) == dropped, sorted((set(up_exec) | set(up_show)) - set(exec_) - set(show)))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== live-session pieces")
desk = {}
for line in text(os.path.join(OVERLAY_FILES, "usr", "share", "applications", "ci-os-install.desktop")).splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        desk[k] = v
check("the launcher entry is 'Install Companion OS', icon ci-os-logo, runs /usr/local/bin/calamares-online.sh without a terminal",
      desk.get("Name") == "Install Companion OS" and desk.get("Icon") == "ci-os-logo" and desk.get("Exec") == "/usr/local/bin/calamares-online.sh"
      and desk.get("Terminal") == "false" and desk.get("Type") == "Application")
hook = text(os.path.join(OVERLAY_FILES, "etc", "pacman.d", "hooks", "ci-os-neutralise-hello.hook"))
check("the hello hook carries upstream's removal marker on its first line (zzzz99 deletes it after the build)", hook.splitlines()[0] == "# remove from airootfs!")
check("the hello hook fires after the package is installed or upgraded, as a PostTransaction",
      "Target = cachyos-hello" in hook and "When = PostTransaction" in hook and "Operation = Install" in hook and "Operation = Upgrade" in hook)
for path in sorted(up_owned):
    check("the hello hook edits %s, which the package owns (recorded from its pacman database)" % path, path in hook)
check("the hook name sorts before upstream's zzzz99-remove-custom-hooks-from-airootfs (alphabetical hook order, suffix ignored)",
      "ci-os-neutralise-hello" < "zzzz99-remove-custom-hooks-from-airootfs")
check("the hello hook removes the skeleton autostart and hides the menu entry",
      "rm -f /etc/skel/.config/autostart/cachyos-hello.desktop" in hook and "NoDisplay=true" in hook)

launcher = text(os.path.join(OVERLAY_FILES, "usr", "local", "bin", "calamares-online.sh"))
code = strip_comments(launcher)
check("the launcher never names a CachyOS web host or raw GitHub in code", not forbidden.search(code), [m for m in forbidden.findall(code)])
check("the launcher keeps upstream's pieces: the keyring populate, cachyos-calamares-next, pkexec-wrapper, calamares -D6",
      all(s in code for s in ("pacman-key --populate archlinux cachyos", "cachyos-calamares-next", "pkexec-wrapper calamares -D6", "timedatectl set-ntp true")))
check("the launcher logs to /home/liveuser/companion-install.log", "/home/liveuser/companion-install.log" in launcher)
check("the launcher has no set -e (errors are handled one by one) but uses set -u", re.search(r"^set -u$", launcher, re.M) and not re.search(r"^set -e", launcher, re.M))
umask_lines = [l for l in code.splitlines() if "umask" in l]
check("the launcher sets umask 077 only inside a subshell around the log (Calamares inherits the launcher's umask through pkexec)",
      umask_lines and all(l.strip().startswith("( umask 077; touch") for l in umask_lines), umask_lines)
check("the launcher prints no password or secret (no read -s, no passwd, no token)", not re.search(r"read\s+-s|passwd|\btoken\b|secret", code, re.I))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== installer stylesheet (branding/companion/stylesheet.qss) and what the pages show")
# ISO #4 frames: the progress bar's fill had the window colour, the selected rows of the keyboard / bootloader / package lists were
# invisible, the Welcome help icon was a dark pictogram on teal, package descriptions were cut off. The cause of the first two is the
# colour scheme CI-OS-Dark: Window, View, Button and Selection are all brand teal (10,99,88). The scheme is shared with the Ubuntu
# edition, so the stylesheet sets the colours itself, from the brand tokens, and these checks hold it to WCAG 2.1.
qss_src = text(os.path.join(INST, "branding", "companion", "stylesheet.qss"))
qss_body = re.sub(r"/\*.*?\*/", "", qss_src, flags=re.S)
tokens = dict(re.findall(r'^(CI_[A-Z0-9_]+)="(#[0-9a-fA-F]{6})"', text(os.path.join(REPO, "vendor", "brand", "tokens", "tokens.sh")), re.M))
stager_src = text(os.path.join(INST, "stage-installer.sh"))
ph_tokens = dict(re.findall(r'-e "s\|@([A-Z_]+)@\|\$(CI_[A-Z0-9_]+)\|g"', stager_src))
ph_hex = {k: tokens.get(v) for k, v in ph_tokens.items()}
used = sorted(set(re.findall(r"@([A-Z_]+)@", qss_body)))
check("every placeholder of the stylesheet is filled by stage-installer.sh from a token that exists in vendor/brand/tokens/tokens.sh",
      used and all(ph_hex.get(u) for u in used), [u for u in used if not ph_hex.get(u)])
check("the stylesheet types no colour itself (no #rrggbb, no rgb()): the brand canon is the only place a hex value is written (style-canon lint)",
      not re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\s*\(", qss_body), re.findall(r"#[0-9a-fA-F]{3,8}\b|rgba?\s*\([^)]*\)", qss_body))

def qss_rules(body):
    out = {}
    for sel, decls in re.findall(r"([^{}]+)\{([^{}]*)\}", body):
        props = {}
        for d in decls.split(";"):
            if ":" in d:
                k, v = d.split(":", 1)
                props[k.strip()] = v.strip()
        for one_sel in sel.split(","):
            out.setdefault(" ".join(one_sel.split()), {}).update(props)
    return out
rules = qss_rules(qss_body)
def hexof(v):
    m = re.search(r"@([A-Z_]+)@", v or "")
    return ph_hex.get(m.group(1)) if m else None
def lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
def lum(h):
    r, g, b = (int(h.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
scheme = {}
sec = None
for ln in text(os.path.join(REPO, "backends", "_mixins", "kde-plasma", "CI-OS-Dark.colors")).splitlines():
    m_ = re.match(r"^\[(.+)\]$", ln.strip())
    if m_:
        sec = m_.group(1)
    elif sec and "=" in ln:
        scheme[(sec, ln.split("=", 1)[0])] = ln.split("=", 1)[1].strip()
rgb_hex = lambda s_: "#%02x%02x%02x" % tuple(int(x) for x in s_.split(",")[:3])
win_bg = rgb_hex(scheme[("Colors:Window", "BackgroundNormal")])
sel_bg_scheme = rgb_hex(scheme[("Colors:Selection", "BackgroundNormal")])

pb, chunk, view = rules.get("QProgressBar", {}), rules.get("QProgressBar::chunk", {}), rules.get("QAbstractItemView", {})
track, fill, ptext = hexof(pb.get("background-color")), hexof(chunk.get("background-color")), hexof(pb.get("color"))
outline = hexof(pb.get("border"))
sel_bg, sel_fg = hexof(view.get("selection-background-color")), hexof(view.get("selection-color"))
check("the progress bar has its own track, fill, text colour and outline (the scheme's Highlight, which the stock bar fills with, equals the window colour %s)" % win_bg,
      all((track, fill, ptext, outline)), (track, fill, ptext, outline))
check("progress bar: centred text, a fixed height, and the chunk is a different colour from the track and from the window",
      pb.get("text-align") == "center" and pb.get("min-height") == pb.get("max-height") and fill not in (track, win_bg), (pb, chunk))
check("progress bar text is AA on the fill (>= 4.5) and on the track (>= 4.5)",
      bool(ptext and fill and track) and contrast(ptext, fill) >= 4.5 and contrast(ptext, track) >= 4.5,
      "%.2f on the fill, %.2f on the track" % (contrast(ptext, fill), contrast(ptext, track)) if ptext and fill and track else "missing colours")
check("progress bar: the fill stands out from the track and the track's outline from the window, both >= 3:1 (WCAG 1.4.11)",
      bool(fill and track and outline) and contrast(fill, track) >= 3 and contrast(outline, win_bg) >= 3,
      "fill/track %.2f, outline/window %.2f" % (contrast(fill, track), contrast(outline, win_bg)) if fill and track and outline else "missing colours")
check("selected rows (QAbstractItemView selection colours): their own colours, dark text on a light row >= 7:1 (AAA), and the row against the window >= 3:1 (the scheme's selection is the window colour: invisible)",
      bool(sel_bg and sel_fg) and sel_bg != win_bg and contrast(sel_fg, sel_bg) >= 7 and contrast(sel_bg, win_bg) >= 3,
      "text/row %.2f, row/window %.2f" % (contrast(sel_fg, sel_bg), contrast(sel_bg, win_bg)) if sel_bg and sel_fg else "missing colours")
check("the Welcome page link buttons (#supportButton, #donateButton, #releaseNotesButton, #knownIssuesButton, the stock names) lose their stock dark pictogram: icon-size 0px, and the widget property as well",
      all(rules.get(n, {}).get("icon-size") == "0px" and rules.get(n, {}).get("qproperty-iconSize") == "0px 0px" for n in ("#supportButton", "#donateButton", "#releaseNotesButton", "#knownIssuesButton")),
      {n: rules.get(n) for n in ("#supportButton", "#donateButton", "#releaseNotesButton", "#knownIssuesButton")})
# ISO #5 (frames install/02b and 05b): the zone list's popup showed no highlight for the current entry or under the pointer, and the selected radio
# of the partition page was a bare white dot without its ring. Both come from the same scheme (Window, View, Button and Selection are all brand teal),
# plus, for the popup, a list-style popup that a stylesheet cannot reach: the sheet switches the combo boxes to the menu-style popup, which it paints.
cbx = rules.get("QComboBox", {})
cb_item, cb_sel = rules.get("QComboBox::item", {}), rules.get("QComboBox::item:selected", {})
cb_bg, cb_fg = hexof(cb_sel.get("background-color")), hexof(cb_sel.get("color"))
check("combo box popups: the menu-style popup is switched on (combobox-popup: 1: the list-style one is painted by a delegate no stylesheet reaches, so ISO #5's current and hovered entries had no highlight), every entry has a transparent base rule (else Breeze draws an empty check box on each unstyled row) and the selected one the selection colours",
      cbx.get("combobox-popup") == "1" and cb_item.get("background-color") == "transparent" and cb_bg == sel_bg and cb_fg == sel_fg and bool(cb_bg and cb_fg),
      (cbx, cb_item, cb_sel))
check("combo box popups: the highlighted entry is readable and visible: dark text on the sage row >= 7:1 (AAA) and the row against the window >= 3:1",
      bool(cb_bg and cb_fg) and contrast(cb_fg, cb_bg) >= 7 and contrast(cb_bg, win_bg) >= 3,
      "text/row %.2f, row/window %.2f" % (contrast(cb_fg, cb_bg), contrast(cb_bg, win_bg)) if cb_bg and cb_fg else "missing colours")
ri, ri_hover, ri_on = rules.get("QRadioButton::indicator", {}), rules.get("QRadioButton::indicator:hover", {}), rules.get("QRadioButton::indicator:checked", {})
def px(v):
    m_ = re.match(r"^(\d+)px", (v or "").strip())
    return int(m_.group(1)) if m_ else None
ring, ring_on = hexof(ri.get("border")), hexof(ri_on.get("border"))
dot_stops = re.findall(r"stop:\s*([0-9.]+)\s+(@[A-Z_]+@|transparent)", ri_on.get("background-color", ""))
size_ok = px(ri.get("width")) is not None and px(ri.get("width")) == px(ri.get("height")) and px((ri.get("border") or "").split()[0]) is not None
diameter = (px(ri.get("width")) or 0) + 2 * (px((ri.get("border") or "0px").split()[0]) or 0)
check("radio buttons: the indicator is drawn by the sheet (Breeze's dot and ring are both the window colour here): a square box of a fixed size with a border, border-radius half the outer diameter (a circle), nothing behind it",
      size_ok and px(ri.get("border-radius")) * 2 == diameter and ri.get("background-color") == "transparent", (ri, diameter))
check("radio buttons: the ring is the muted outline colour (>= 3:1 on the window, WCAG 1.4.11), the checked ring and dot the selection colour (>= 3:1 on the window), with a gap of the window showing between them (the gradient goes sage, sage, transparent, transparent)",
      bool(ring and ring_on) and contrast(ring, win_bg) >= 3 and contrast(ring_on, win_bg) >= 3 and ring_on == sel_bg
      and [(a_, hexof(b_) if b_ != "transparent" else b_) for a_, b_ in dot_stops] == [("0", sel_bg), ("0.5", sel_bg), ("0.62", "transparent"), ("1", "transparent")]
      and hexof(ri_hover.get("border-color")) == sel_bg,
      "ring/window %.2f, checked/window %.2f, stops %s" % (contrast(ring, win_bg), contrast(ring_on, win_bg), dot_stops) if ring and ring_on else (ri, ri_on))
check("the checked dot is inside the ring: its outer stop (0.5 of the 12 px box = 6 px) leaves a 1.4 px gap to the 2 px border at 0.62, and the box is 12 px wide",
      px(ri.get("width")) == 12 and ("stop: 0.5 " in ri_on.get("background-color", "")) and ("stop: 0.62 " in ri_on.get("background-color", "")))
check("the stylesheet keeps what the stock one sets for the installer: the 13 px base font and no icons on the dialog button box",
      rules.get("QWidget", {}).get("font") == "13px" and rules.get("QDialogButtonBox", {}).get("dialogbuttonbox-buttons-have-icons") == "0")
check("the stylesheet parses as plain QSS: balanced braces, every declaration ends with a semicolon, no unknown @ left (QSS parse errors make Qt drop the whole sheet silently)",
      qss_body.count("{") == qss_body.count("}") and not re.search(r"[^;{}\s][ \t]*\n\s*\}", qss_body) and "@" not in re.sub(r"@[A-Z_]+@", "", qss_body), qss_body.count("{"))

def visible_groups(groups):
    for g in groups or []:
        if isinstance(g, dict) and not g.get("hidden"):
            yield g
            for sub in visible_groups(g.get("subgroups")):
                yield sub
na = load_yaml(os.path.join(INST, "modules", "netinstall.yaml"))
long_ones = [(len(str(g.get("description", ""))), g["name"]) for g in visible_groups(na) if len(str(g.get("description", ""))) > 72]
check("every package group the user sees has a description of at most 72 characters (ISO #4's 98-character ones were cut off with '...' at the window edge of the 1100 px installer)",
      not long_ones and any(True for _ in visible_groups(na)), long_ones)

# ---------------------------------------------------------------------------------------------------------------------------------
print("== first-boot units")
svc = text(os.path.join(PROV, "systemd", "ci-os-first-boot-setup.service"))
tmr = text(os.path.join(PROV, "systemd", "ci-os-first-boot-setup.timer"))
check("the service never runs in the live session (ConditionKernelCommandLine=!archisobasedir) or after success (marker)",
      "ConditionKernelCommandLine=!archisobasedir" in svc and "ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done" in svc)
def unit_sections(src):
    """A systemd unit as {section: {key: [values...]}} (comments and blank lines dropped; no line continuations in these units)."""
    out, sec = {}, None
    for line in strip_comments(src).splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^\[([A-Za-z]+)\]$", line)
        if m:
            sec = out.setdefault(m.group(1), {})
        elif sec is not None and "=" in line:
            k, v = line.split("=", 1)
            sec.setdefault(k.strip(), []).append(v.strip())
    return out

BOOT_TARGETS = {"sysinit.target", "basic.target", "multi-user.target", "graphical.target", "default.target", "local-fs.target", "getty.target"}
# Start types whose start JOB lasts as long as the process (or its fork parent, or its READY=1): a boot target that wants such a unit
# waits for it (systemd.target(5): a target is ordered After= every unit it Wants= when both have DefaultDependencies=yes).
BLOCKING_TYPES = {"oneshot", "forking", "notify", "notify-reload", "dbus", "idle"}

def holds_boot(unit):
    """Why a unit would hold up the boot targets, as a list of reasons (empty = it does not)."""
    why = []
    svc, inst, unit_sec = unit.get("Service", {}), unit.get("Install", {}), unit.get("Unit", {})
    linked = {t for k in ("WantedBy", "RequiredBy", "UpheldBy") for v in inst.get(k, []) for t in v.split()}
    boot_linked = sorted(linked & BOOT_TARGETS)
    typ = (svc.get("Type") or ["simple"])[-1]
    if boot_linked and typ in BLOCKING_TYPES:
        why.append("Type=%s is linked into %s (its start job lasts as long as the script)" % (typ, ", ".join(boot_linked)))
    ordered_net = [v for k in ("After", "Wants", "Requires") for val in unit_sec.get(k, []) for v in val.split() if v == "network-online.target"]
    if boot_linked and ordered_net:
        why.append("it is linked into %s and ordered after/wanting network-online.target (the wait-online timeout moves into the boot)" % ", ".join(boot_linked))
    before = sorted(v for val in unit_sec.get("Before", []) for v in val.split() if v in BOOT_TARGETS)
    if before:
        why.append("Before=%s" % " ".join(before))
    return why

unit = unit_sections(svc)
check("the service runs /usr/lib/ci-os/first-boot-setup.sh as an exec service (not a oneshot), without RemainAfterExit",
      unit["Service"].get("Type") == ["exec"] and unit["Service"].get("ExecStart") == ["/usr/lib/ci-os/first-boot-setup.sh"]
      and unit["Service"].get("RemainAfterExit") == ["no"], unit["Service"])
check("the service does not hold up the boot targets (ISO #4: a oneshot linked into multi-user.target delayed graphical.target by the whole run, 16 min 27 s with a network)",
      not holds_boot(unit), holds_boot(unit))
check("holds_boot() can see the bug: the ISO #4 shape (oneshot + network-online.target + multi-user.target) is flagged twice, a Before= of a boot target once, and the fixed shapes not at all",
      len(holds_boot(unit_sections("[Unit]\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\n[Install]\nWantedBy=multi-user.target\n"))) == 2
      and holds_boot(unit_sections("[Unit]\nBefore=graphical.target\n[Service]\nType=exec\n")) == ["Before=graphical.target"]
      and not holds_boot(unit_sections("[Unit]\nAfter=network-online.target\n[Service]\nType=oneshot\n")))
check("the service has no network-online ordering at all (the script polls for the network itself; ordering would put wait-online into every boot)",
      "network-online.target" not in strip_comments(svc))
check("the service sets HOME=/root (a system unit has none and ollama panics without one: ISO #4 ended 'degraded' with all models installed)",
      unit["Service"].get("Environment") == ["HOME=/root"], unit["Service"].get("Environment"))
check("the service runs at a lower priority than the desktop it starts beside (Nice > 0)",
      unit["Service"].get("Nice", [""])[-1].isdigit() and int(unit["Service"]["Nice"][-1]) > 0, unit["Service"].get("Nice"))
check("the service has no Restart= (retries are the timer's job; first-boot-setup.sh turns 74 and 75 into exit 0 plus a status file)",
      "Restart" not in unit["Service"], unit["Service"].get("Restart"))
# The run ends in the pull of the largest model of the manifest. At the size recorded in core/manifest/model-packs.yaml, 1800 s needs
# 79 Mbit/s; nothing the unit says may cut the download short: no RuntimeMaxSec, and no small TimeoutStartSec on a type whose start job
# lasts as long as the run.
def secs(v):
    return None if v in (None, "infinity", "0") else (int(v) if v.isdigit() else -1)
rt = unit["Service"].get("RuntimeMaxSec", [None])[-1]
tmo = unit["Service"].get("TimeoutStartSec", [None])[-1]
typ = unit["Service"].get("Type", ["simple"])[-1]
check("the service has nothing that can kill a model pull half way (RuntimeMaxSec unset, infinity or at least a day; TimeoutStartSec likewise unless the start job is short)",
      (secs(rt) is None or secs(rt) >= 86400) and (secs(tmo) is None or secs(tmo) >= 86400 or typ in ("exec", "simple")), (rt, tmo, typ))
check("the timer retries every 15 minutes while the marker is absent and is wanted by timers.target",
      "OnUnitInactiveSec=15min" in tmr and "ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done" in tmr and "WantedBy=timers.target" in tmr
      and "ConditionKernelCommandLine=!archisobasedir" in tmr)
check("no casper, apt or Ubuntu mention in the first-boot pieces",
      not re.search(r"casper|/cdrom|apt-get|archive\.ubuntu|snap ", strip_comments(svc + tmr + text(os.path.join(PROV, "first-boot-setup.sh")) + text(os.path.join(PROV, "provision.sh")))))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== first-boot throttle of ollama.service (RT-N2)")
# The models are pulled by ollama.service, not by the first-boot script, so the unit's Nice= and I/O class do not reach the downloads. As on the
# Ubuntu edition (customize-chroot-checks.sh checks the same pair of lines), the script lowers ollama.service to CPUWeight=20 IOWeight=20 for its
# own run only: a runtime property, set before the provisioning call when the unit exists, and taken off again by the EXIT trap whichever way
# the script ends. The check reads the text (the order of the lines, where the undo sits), then RUNS the script against a stub systemctl, and
# shows both can fail: each line removed, the undo behind a return, the throttle after the provisioning, no guard.
import shutil
import subprocess
import tempfile

FB_PATH = os.path.join(PROV, "first-boot-setup.sh")
THROTTLE = "systemctl set-property --runtime ollama.service CPUWeight=20 IOWeight=20"
UNTHROTTLE = "systemctl set-property --runtime ollama.service CPUWeight= IOWeight="


def throttle_problems(src):
    """What is wrong with the way a copy of first-boot-setup.sh throttles ollama.service, as a list of sentences (empty = right)."""
    code = strip_comments(src)
    problems = []
    t = code.find(THROTTLE)
    if t < 0:
        problems.append("the script never runs: " + THROTTLE)
    m = re.search(r"^trap (\w+) EXIT$", code, re.M)
    if not m:
        return problems + ["the script has no EXIT trap, so nothing takes the throttle off"]
    fn = m.group(1)
    body = re.search(r"^%s\(\) \{\n(.*?)^\}$" % re.escape(fn), code, re.M | re.S)
    if not body:
        return problems + ["the EXIT trap names %s, which is not a function of the script" % fn]
    b = body.group(1)
    u = b.find(UNTHROTTLE)
    if u < 0:
        problems.append("the EXIT trap function %s does not undo it (%s)" % (fn, UNTHROTTLE))
    else:
        ret = re.search(r"\breturn\b", b)
        if ret and ret.start() < u:
            problems.append("the undo in %s sits behind a return, so an exit that takes that return leaves the throttle set" % fn)
    if t >= 0:
        if m.start() > t:
            problems.append("the EXIT trap is installed after the throttle, so an exit in between would leave it set")
        p = code.find('bash "$PROVISION_SH"')
        if p < 0 or p < t:
            problems.append("the throttle does not come before the provisioning call")
        if code.rfind("systemctl cat ollama.service", 0, t) < 0:
            problems.append("the throttle is not guarded by `systemctl cat ollama.service` (the unit may not exist)")
    return problems


fb_src = text(FB_PATH)
check("first-boot-setup.sh throttles ollama.service for its own run and undoes it in the EXIT trap (static: order of the lines, guard, undo before any return)",
      throttle_problems(fb_src) == [], throttle_problems(fb_src))


def mutated(src, old, new):
    return src.replace(old, new, 1)


undo_line = 'if [[ "$OLLAMA_THROTTLED" == 1 ]]; then ' + UNTHROTTLE + " >/dev/null 2>&1 || true; fi\n"
throttle_block = ("if command -v systemctl >/dev/null 2>&1 && systemctl cat ollama.service >/dev/null 2>&1; then\n"
                  "    OLLAMA_THROTTLED=1\n    " + THROTTLE + " >/dev/null 2>&1 || true\nfi\n\n")
return_line = '    [[ -n "${LOG_PID:-}" ]] || return 0\n'
# The mutants are made from these lines; if one of them is not where it is expected (a line was removed or reworded), that is a FAIL of its own and
# the mutants are skipped, not a crash that would take the rest of this file with it.
layout_ok = undo_line in fb_src and throttle_block in fb_src and return_line in fb_src and "trap drain_output EXIT\n" in fb_src \
    and 'bash "$PROVISION_SH" "${PROVISION_ARGS[@]}"\n' in fb_src and "systemctl cat ollama.service >/dev/null 2>&1; then\n    OLLAMA_THROTTLED=1" in fb_src
check("the lines of RT-N2 are where this test expects them (the mutants below are made from them)", layout_ok)
MUTANTS = []
if layout_ok:
    MUTANTS = [
        ("the set-property line removed", mutated(fb_src, THROTTLE, "true"), "never runs"),
        ("the undo line removed", mutated(fb_src, UNTHROTTLE, "true"), "does not undo it"),
        ("the undo behind the early return", mutated(mutated(fb_src, "    " + undo_line, ""), return_line, return_line + "    " + undo_line), "behind a return"),
        ("the throttle after the provisioning call", mutated(mutated(fb_src, throttle_block, ""), 'bash "$PROVISION_SH" "${PROVISION_ARGS[@]}"\n',
                                                             'bash "$PROVISION_SH" "${PROVISION_ARGS[@]}"\n' + throttle_block), "does not come before the provisioning call"),
        ("no guard on the unit existing", mutated(fb_src, "systemctl cat ollama.service >/dev/null 2>&1; then\n    OLLAMA_THROTTLED=1", "true; then\n    OLLAMA_THROTTLED=1"), "not guarded"),
        ("the EXIT trap removed", mutated(fb_src, "trap drain_output EXIT\n", ""), "no EXIT trap"),
    ]
for name, src_m, want in MUTANTS:
    probs = throttle_problems(src_m)
    check("the static check can fail: %s -> %s" % (name, want), any(want in x for x in probs), probs)


def run_first_boot(script_path, has_ollama=True, provision_rc=0, live=False):
    """Runs a copy of first-boot-setup.sh against a stub systemctl, a stub provisioner and no network probe; returns the events in order:
    the systemctl calls it made and 'provision-start'. None when it cannot run here (no bash, or the run timed out)."""
    bash = shutil.which("bash")
    if not bash:
        return None
    with tempfile.TemporaryDirectory() as w:
        bindir = os.path.join(w, "bin")
        provdir = os.path.join(w, "boot", "backends", "cachyos", "provision")
        os.makedirs(bindir)
        os.makedirs(provdir)
        events = os.path.join(w, "events")
        with open(os.path.join(bindir, "systemctl"), "w") as fh:
            fh.write('#!/bin/bash\necho "systemctl $*" >> "$EV"\n[ "$1" = cat ] && [ "$HAS_OLLAMA" != 1 ] && exit 1\nexit 0\n')
        with open(os.path.join(provdir, "provision.sh"), "w") as fh:
            fh.write('#!/bin/bash\necho "provision-start" >> "$EV"\nexit "$PRC"\n')
        with open(os.path.join(w, "net-up"), "w") as fh:
            fh.write("#!/bin/bash\nexit 0\n")
        if not shutil.which("flock"):
            with open(os.path.join(bindir, "flock"), "w") as fh:
                fh.write("#!/bin/bash\nexit 0\n")
        for f in ("systemctl", "flock"):
            if os.path.exists(os.path.join(bindir, f)):
                os.chmod(os.path.join(bindir, f), 0o755)
        os.chmod(os.path.join(w, "net-up"), 0o755)
        with open(os.path.join(w, "cmdline"), "w") as fh:
            fh.write("BOOT_IMAGE=/vmlinuz root=UUID=x rw" + (" archisobasedir=arch" if live else "") + "\n")
        env = {"PATH": bindir + ":/usr/bin:/bin:/usr/sbin:/sbin", "EV": events, "HAS_OLLAMA": "1" if has_ollama else "0", "PRC": str(provision_rc),
               "CI_OS_BOOTSTRAP_ROOT": os.path.join(w, "boot"), "CI_OS_STATE_DIR": os.path.join(w, "state"), "CI_OS_LOG_FILE": os.path.join(w, "log"),
               "CI_OS_LOCK_FILE": os.path.join(w, "lock"), "CI_OS_CMDLINE_FILE": os.path.join(w, "cmdline"), "CI_OS_RUN_ARCHISO": os.path.join(w, "no-archiso"),
               "CI_OS_NETWORK_PROBE": os.path.join(w, "net-up"), "CI_OS_NETWORK_TRIES": "2", "CI_OS_NETWORK_SLEEP": "0"}
        try:
            subprocess.run([bash, script_path], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        except subprocess.TimeoutExpired:
            return None
        if not os.path.exists(events):
            return []
        with open(events) as fh:
            return [l.rstrip("\n") for l in fh if l.strip()]


CAT = "systemctl cat ollama.service"
SET_ON = "systemctl set-property --runtime ollama.service CPUWeight=20 IOWeight=20"
SET_OFF = "systemctl set-property --runtime ollama.service CPUWeight= IOWeight="
EXPECT_RUN = [CAT, SET_ON, "provision-start", SET_OFF]
real = run_first_boot(FB_PATH)
if real is None:
    print("SKIP  the behavioural run of first-boot-setup.sh (no bash, or it timed out)")
else:
    check("RUN: with ollama.service present the script lowers its weights, provisions, and takes the weights off at exit", real == EXPECT_RUN, real)
    check("RUN: a failed provisioning (exit 1) still takes them off", run_first_boot(FB_PATH, provision_rc=1) == EXPECT_RUN)
    check("RUN: a degraded provisioning (exit 74, a model is missing) still takes them off", run_first_boot(FB_PATH, provision_rc=74) == EXPECT_RUN)
    check("RUN: no ollama.service: no set-property call at all, and the provisioning still runs", run_first_boot(FB_PATH, has_ollama=False) == [CAT, "provision-start"])
    check("RUN: a live session is never provisioned and touches nothing", run_first_boot(FB_PATH, live=True) == [])
    # The undo behind the early return (mutant 3) is not run: whether it bites depends on whether this bash sets $! for a process substitution
    # (bash 3.2 does not, bash 4.4 and newer do), which is exactly why the static check reads where the line sits.
    with tempfile.TemporaryDirectory() as md:
        for name, src_m, want in [m for i, m in enumerate(MUTANTS) if i != 2]:
            mp = os.path.join(md, "mutant.sh")
            with open(mp, "w") as fh:
                fh.write(src_m)
            got = [run_first_boot(mp), run_first_boot(mp, has_ollama=False)]
            check("RUN: the behaviour check can fail: %s" % name, got != [EXPECT_RUN, [CAT, "provision-start"]], got)

# ---------------------------------------------------------------------------------------------------------------------------------
print("== shellprocess time limits (ISO #5 died at job 13 of 47: Calamares kills a command after 30 s unless it has a timeout)")
# Calamares' shellprocess module (CommandList::run): a command's own `timeout` wins, else the file's top-level one, else 30 s. The pinned
# installer's shellprocess_initialize_pacman.conf gives only update-mirrorlist a limit; `bash /etc/calamares/scripts/create-pacman-keyring`
# (pacman-key --init, pacman -Sy of the keyring packages, pacman-key --populate) got the 30 s and a slow machine killed the install at
# 2 percent, twice in a row on ISO #5 (the populate step alone took about 28 s under QEMU/TCG). The rules are in lib/ci-shellprocess.py.
import subprocess
import tempfile

spec_sp = importlib.util.spec_from_file_location("ci_shellprocess", os.path.join(INST, "lib", "ci-shellprocess.py"))
sp = importlib.util.module_from_spec(spec_sp)
spec_sp.loader.exec_module(sp)
SCRIPTS = os.path.join(INST, "scripts")

def recorded_shellprocess():
    """{conf name: document} of the stock shellprocess configs, from the `spconf` facts (JSON, which is YAML)."""
    out = {}
    for l in facts_lines:
        if l.startswith("spconf "):
            name, js = l.split(" ", 2)[1:]
            out[name] = json.loads(js)
    return out
stock_sp = recorded_shellprocess()
check("the facts record every stock shellprocess config of the pinned installer (the ten conf files), captured by capture-upstream-facts.sh",
      set(stock_sp) == {c for c in up_confs if c.startswith("shellprocess")} and len(stock_sp) == 10, sorted(set(stock_sp) ^ {c for c in up_confs if c.startswith("shellprocess")}))
ip = stock_sp["shellprocess_initialize_pacman.conf"]
kr = {i["command"]: i.get("timeout") for i in ip["script"]}
check("the recorded installer file is the defect: update-mirrorlist has timeout 3600, the keyring command has none, and the file sets no default (so the keyring step runs on 30 s). If a pin bump makes this false the overlay's copy may go; the next check says what must hold until then",
      kr.get("bash /etc/calamares/scripts/update-mirrorlist") == 3600 and kr.get("bash /etc/calamares/scripts/create-pacman-keyring", "absent") is None and "timeout" not in ip, ip)

# 1. what the overlay ships
sp_confs = {f: docs[f] for f in docs if f.startswith("shellprocess")}
bad_sp = {f: sp.audit_doc(f, d, [SCRIPTS]) for f, d in sp_confs.items()}
check("every shellprocess config of the overlay passes rules R1 and R2 (explicit time limits, generous where it runs heavy tools), scripts they run read from the overlay: %s" % ", ".join(sorted(sp_confs)),
      not any(bad_sp.values()) and len(sp_confs) == 5, {f: v for f, v in bad_sp.items() if v})
check("the three stock configs without a complete set of limits are replaced by overlay copies (initialize_pacman, modify_mk_hook, reset_mk_hook); the others (before-online, btrfs_snapshot, cleanup_calamares, the plain shellprocess) already set a file-level limit",
      {"shellprocess_initialize_pacman.conf", "shellprocess_modify_mk_hook.conf", "shellprocess_reset_mk_hook.conf"} <= set(sp_confs)
      and all(isinstance(stock_sp[n].get("timeout"), int) and stock_sp[n]["timeout"] > 0 for n in ("shellprocess-before-online.conf", "shellprocess_btrfs_snapshot.conf", "shellprocess_cleanup_calamares.conf", "shellprocess.conf")),
      {n: stock_sp[n].get("timeout") for n in stock_sp})

# 2. the effective sequence: the overlay's copy where there is one, the recorded installer file otherwise
def sp_steps():
    return sp.sequence_steps(settings)
eff, miss_cfg = {}, []
for step, cfg in sp_steps():
    d = docs.get(cfg) if cfg in docs else stock_sp.get(cfg)
    if d is None:
        miss_cfg.append((step, cfg))
    else:
        eff[cfg] = d
check("every shellprocess step of settings.conf (%s) has a config in the overlay or in the recorded installer" % ", ".join(s_ for s_, _ in sp_steps()), not miss_cfg and len(sp_steps()) == 9, (miss_cfg, sp_steps()))
eff_bad = {c: sp.audit_doc(c, d, [SCRIPTS]) for c, d in eff.items()}
check("the EFFECTIVE configs of the whole sequence (the overlay's copies over the recorded installer files) have an explicit time limit on every command and a generous one on every command that is heavy by its command line (the installer's scripts are read by the guard at run time and by verify-iso.sh on the image)",
      not any(eff_bad.values()), {c: v for c, v in eff_bad.items() if v})
# The same rules on the real stock files, with their scripts, when an unpacked installer is at hand.
real = os.environ.get("CI_OS_REAL_CALAMARES_ROOT")
if real and os.path.isdir(os.path.join(real, "etc", "calamares", "modules")):
    real_problems = sp.audit(real, INST)
    check("the shell-timeouts audit on the REAL installer files (%s): no problem, scripts included" % real, not real_problems, real_problems)
    stock_real = {f: yaml.safe_load(open(os.path.join(real, "etc", "calamares", "modules", f), encoding="utf-8")) for f in os.listdir(os.path.join(real, "etc", "calamares", "modules")) if f.startswith("shellprocess")}
    check("the real installer's own shellprocess_initialize_pacman.conf is flagged by the same audit (the bug is seen on the real file, with its real script)",
          any("create-pacman-keyring" in x and "30 s" in x for x in sp.audit_doc("x", stock_real["shellprocess_initialize_pacman.conf"], [os.path.join(real, "etc", "calamares", "scripts")])))
else:
    print("SKIP  shell-timeouts audit on the real installer files (set CI_OS_REAL_CALAMARES_ROOT to an unpacked cachyos-calamares-next)")

# 3. the copies do not drift from the installer's files: same commands in the same order, every key
for n in ("shellprocess_initialize_pacman.conf", "shellprocess_modify_mk_hook.conf", "shellprocess_reset_mk_hook.conf"):
    mine_cmds = [c for c, _ in sp.items_of(docs[n])]
    stock_cmds = [c for c, _ in sp.items_of(stock_sp[n])]
    check("%s: the same commands in the same order as the installer's file (only time limits were added), the same dontChroot, every key of the installer's file present" % n,
          mine_cmds == stock_cmds and docs[n].get("dontChroot") == stock_sp[n].get("dontChroot") and not sp.compare_docs(n, stock_sp[n], docs[n]),
          (mine_cmds, stock_cmds))
check("the overlay's initialize_pacman copy: update-mirrorlist and create-pacman-keyring each carry their own timeout of at least 3600 s (a 10-year-old laptop on slow Wi-Fi), the file default is at least 600 s",
      all({i["command"]: i.get("timeout", 0) for i in docs["shellprocess_initialize_pacman.conf"]["script"] if isinstance(i, dict)}.get(c, 0) >= 3600
          for c in ("bash /etc/calamares/scripts/update-mirrorlist", "bash /etc/calamares/scripts/create-pacman-keyring"))
      and docs["shellprocess_initialize_pacman.conf"]["timeout"] >= 600)
check("the i18n names of the three copies are the installer's (they are what the install page shows): the same text as the recorded name key, no CachyOS in them",
      all(isinstance(docs[n].get("i18n"), dict) and not re.search("cachy", " ".join(str(v) for v in docs[n]["i18n"].values()), re.I)
          for n in ("shellprocess_initialize_pacman.conf", "shellprocess_modify_mk_hook.conf", "shellprocess_reset_mk_hook.conf")))

# 4. the guard table and the staging
check("guards.list: a critical `shell-timeouts` row, and critical `oexists` rows for the three copies and for lib/ci-shellprocess.py",
      any(re.match(r"^critical\s*\|\s*shell-timeouts\s*\|", l) for l in gl)
      and all(any(re.match(r"^critical\s*\|\s*oexists\s*\|\s*%s\s*\|" % re.escape(x), l) for l in gl)
              for x in ("modules/shellprocess_initialize_pacman.conf", "modules/shellprocess_modify_mk_hook.conf", "modules/shellprocess_reset_mk_hook.conf", "lib/ci-shellprocess.py")))
check("guards.list no longer says the three replaced configs are 'not replaced' (an `exists ... not replaced` row for a file the overlay replaces is a lie)",
      not any(re.search(r"exists\s*\|\s*/etc/calamares/modules/shellprocess_(initialize_pacman|modify_mk_hook|reset_mk_hook)\.conf", l) for l in gl))
check("stage-installer.sh stages lib/ci-shellprocess.py (the guard runs it on the live system)", "ci-shellprocess.py" in stager_src)
check("the overlay ships no Calamares job module of its own (no module.desc, no main.py): nothing in it can carry a default timeout; the stock job modules' process calls default to 0 = no limit (System.h: timeoutSec = 0), which is why pacstrap, packages, chwd and mkinitcpio ran 442 s, 586 s, 132 s and 93 s on ISO #5",
      not [f for dp, dn, fn in os.walk(INST) for f in fn if f in ("module.desc", "main.py")])

# An empty root is the live system itself (calamares-online.sh runs the guards with CI_OS_CALAMARES_ROOT unset, and ci_g_root prints nothing then):
# the reader must look under /etc/calamares, never under ./etc/calamares of whatever directory the launcher happens to run in.
with tempfile.TemporaryDirectory() as td_:
    os.makedirs(os.path.join(td_, "etc", "calamares", "modules"))
    for f_, d_ in stock_sp.items():
        with open(os.path.join(td_, "etc", "calamares", "modules", f_), "w", encoding="utf-8") as fh_:
            json.dump(d_, fh_)
    cwd_ = os.getcwd()
    os.chdir(td_)
    try:
        empty_root = sp.audit("", INST)
        slash_root = sp.audit("/", INST)
    finally:
        os.chdir(cwd_)
check("the audit with an empty root means '/' (the live system), not the working directory: a tree of recorded installer files in the current directory is NOT read (the stock steps are then 'in neither the overlay nor the installer', as on a machine with no /etc/calamares), and '' and '/' agree",
      empty_root == slash_root and (os.path.isdir("/etc/calamares/modules") or any("is in neither the overlay nor the installer" in x for x in empty_root)), (empty_root[:3], slash_root[:3]))

# 5. the rules, on constructed configs: each heavy tool of the brief, the 30 s default, 0, the floors, comments, queries
def audit_one(items, ftimeout=None, scripts=None):
    d = {"dontChroot": True, "script": [({"command": c, **({"timeout": t} if t is not None else {})}) for c, t in items]}
    if ftimeout is not None:
        d["timeout"] = ftimeout
    with tempfile.TemporaryDirectory() as td:
        for nm, body in (scripts or {}).items():
            with open(os.path.join(td, nm), "w", encoding="utf-8") as fh:
                fh.write(body)
        return sp.audit_doc("t.conf", d, [td])
heavy_cmds = ["pacman -Syu --noconfirm", "/usr/bin/pacman -S x", "sudo pacman -Sy", "pacman-key --populate", "pacstrap /mnt base", "cachyos-rate-mirrors", "rate-mirrors arch",
              "curl -fsSL https://example.org/x", "wget -q x", "git clone x", "apt-get install -y x", "yay -S x", "pip install x", "npm ci", "flatpak install x",
              "ollama pull x", "docker pull x"]
miss = [c for c in heavy_cmds if not audit_one([(c, None)])]
check("every network and package tool of the brief is heavy: pacman, pacman-key, pacstrap, rate-mirrors, curl, wget, git, apt, yay, pip, npm, flatpak, ollama, docker (no limit -> a problem)", not miss, miss)
miss = [c for c in heavy_cmds if audit_one([(c, 120)]) == []]
check("... and a 120 s limit is below their 600 s floor", not miss, miss)
miss = [c for c in heavy_cmds if audit_one([(c, 600)]) != []]
check("... and 600 s is enough", not miss, miss)
disk_cmds = ["mkinitcpio -P", "grub-install --target=x", "grub-mkconfig -o x", "btrfs subvolume snapshot a b", "snapper create", "cp -a a b", "cp -rf a b", "cp -R a b", "rsync -a a b", "unsquashfs x", "mkfs.ext4 x",
             "dracut --force", "/usr/bin/dracut -f x", "update-initramfs -u", "plymouth-set-default-theme -R companion-os", "locale-gen", "chroot ${ROOT} locale-gen", "limine-update", "sdboot-manage update"]
miss = [c for c in disk_cmds if not audit_one([(c, None)])]
check("every disk and initramfs tool is heavy too: mkinitcpio, dracut, update-initramfs, plymouth-set-default-theme, locale-gen, grub-install, grub-mkconfig, limine-update, sdboot-manage, btrfs, snapper, cp -a/-r/-R, rsync, unsquashfs, mkfs", not miss, miss)
check("... with a floor of 300 s: 299 is refused, 300 passes", all(audit_one([(c, 299)]) and not audit_one([(c, 300)]) for c in disk_cmds))
light = ["mkdir -p /x", "cp a b", "cp -p a b", "rm -f x", "-rm x", "chmod +x x", "pacman -Qs x", "pacman -Q", "pacman -T x", "echo github-cli", "cat /etc/pacman.conf", "ls /etc/pacman.d/",
         "cp /etc/pacman.d/mirrorlist /x", "echo libgit2 > /x", "systemctl enable docker",
         "mkdir -p /usr/lib/dracut/dracut.conf.d", "ls /etc/dracut.conf.d/", "echo dracut-network", "cp /etc/locale.gen /x", "cat /etc/locale.conf", "echo limine-entry-tool",
         "install -D /x /etc/sdboot-manage.conf", "echo plymouth-theme-x", "ls /usr/lib/initcpio/"]
miss = [c for c in light if audit_one([(c, 30)]) != []]
check("light commands are not heavy: mkdir, cp, rm, chmod, read-only pacman queries (-Q, -T), a package name, a directory (/usr/lib/dracut/) or a path that merely contains a tool's name, systemctl: 30 s is enough", not miss, miss)
check("a light command with NO limit anywhere is still reported (R1: nothing runs on the silent default), once per file, naming its position",
      len(audit_one([("mkdir -p /x", None), ("cp a b", None)])) == 1 and "commands 1, 2" in audit_one([("mkdir -p /x", None), ("cp a b", None)])[0])
check("the file-level timeout is a limit for every command without its own; a command's own wins over the file's (a heavy command with its own 3600 on a 10 s file passes; a heavy one on a 10 s file without its own does not)",
      audit_one([("pacman -Sy", None)], ftimeout=600) == [] and audit_one([("pacman -Sy", 3600)], ftimeout=10) == [] and audit_one([("pacman -Sy", None)], ftimeout=10) != [])
check("0 and negative limits are not generous ones (0 means no limit to Calamares, a negative value means 'use the default')",
      audit_one([("pacman -Sy", 0)]) != [] and audit_one([("pacman -Sy", -1)]) != [] and audit_one([("pacman -Sy", None)], ftimeout=0) != [])
check("effective_timeout follows Calamares: own value (>= 0) first, then the file's, else the 30 s default flagged as not explicit",
      sp.effective_timeout(None, None) == (30, False) and sp.effective_timeout(5, 600) == (5, True) and sp.effective_timeout(None, 600) == (600, True) and sp.effective_timeout(-1, 600) == (600, True))
kscript = {"create-pacman-keyring": "#!/usr/bin/env bash\nexec 2>&1\npacman-key --init\nfor ((i=0;i<5;i++)); do pacman -Sy --noconfirm --needed cachyos-keyring && break; done\npacman-key --populate\n"}
r = audit_one([("bash /etc/calamares/scripts/create-pacman-keyring", None)], ftimeout=None, scripts=kscript)
check("MUTANT ISO #5: the keyring command alone, with no limit, is reported by its script's text (the command line names no tool), with the tools it runs",
      len(r) == 1 and "create-pacman-keyring" in r[0] and "pacman-key" in r[0] and "after 30 s" in r[0], r)
check("... it is the SCRIPT that makes it heavy: the same command line with an empty script is light (reported as the default only)",
      "after 30 s" not in " ".join(audit_one([("bash /etc/calamares/scripts/create-pacman-keyring", None)], scripts={"create-pacman-keyring": ""})))
check("... and a comment in the script that names pacman is not a tool (only code counts)",
      "after 30 s" not in " ".join(audit_one([("bash /etc/calamares/scripts/x.sh", None)], scripts={"x.sh": "# pacman -Syu would be here\necho ok   # curl is not run\n"})))
check("a script that is only copied or removed (the command word is cp or rm, not the script) is not read: cp of a hook that names mkinitcpio is not a heavy command",
      audit_one([("cp /etc/calamares/scripts/90.hook /etc/pacman.d/hooks/", 30)], scripts={"90.hook": "Exec = /usr/share/libalpm/scripts/mkinitcpio-install-calamares\n"}) == [])
check("R3 sees a command and a key the installer's file has and the overlay's copy lacks, and nothing else (the same commands in the same order, in the string and the mapping form, with limits of their own added, are the same)",
      len(sp.compare_docs("n", {"dontChroot": True, "k": "x", "script": ["a", "b"]}, {"dontChroot": True, "script": ["a"]})) == 2
      and not sp.compare_docs("n", {"dontChroot": True, "script": ["a", "b"]}, {"dontChroot": True, "timeout": 5, "script": [{"command": "a"}, {"command": "b", "timeout": 9}]})
      and not sp.compare_docs("n", {"dontChroot": True, "script": ["a  b", "c"]}, {"dontChroot": True, "script": ["a b", "c"]}))
# R3, second half: where the commands run, and in which order. Both change what the installer does without dropping a command or a key.
r3_stock = {"dontChroot": True, "script": ["a", "b", "c"], "i18n": "x"}
def r3(ours_updates=None, **kw):
    ours = dict(r3_stock, **(ours_updates or {}))
    for k_, v_ in kw.items():
        ours[k_] = v_
    return sp.compare_docs("n", r3_stock, ours)
check("R3: the same commands in the same order and the same dontChroot are no problem; extra commands of the overlay's own, between or after the installer's, are none either",
      r3() == [] and r3(script=["a", "x", "b", "c", "y"]) == [] and r3(script=[{"command": "a", "timeout": 1}, "b", {"command": "c"}]) == [])
check("R3: the installer's commands in another order are a problem, and the report names a command that is out of place (a is first in the installer's file; b, then c, must come after it)",
      len(r3(script=["b", "a", "c"])) == 1 and "`b`" in r3(script=["b", "a", "c"])[0]
      and len(r3(script=["c", "b", "a"])) == 2
      and len(r3(script=["a", "c", "b"])) == 1 and "`c`" in r3(script=["a", "c", "b"])[0],
      (r3(script=["b", "a", "c"]), r3(script=["c", "b", "a"]), r3(script=["a", "c", "b"])))
check("R3: a command the installer runs twice and the overlay's copy once is a problem (a dropped repeat), the repeat in place is none",
      sp.compare_docs("n", {"script": ["a", "b", "a"]}, {"script": ["a", "b"]}) != []
      and sp.compare_docs("n", {"script": ["a", "b", "a"]}, {"script": ["a", "b", "a"]}) == []
      and sp.compare_docs("n", {"script": ["a", "b", "a"]}, {"script": ["a", "a", "b"]}) != [])
check("R3: dontChroot decides where every command runs: flipped in either direction is a problem naming both places; a key the installer's file does not set is false (Calamares' default), so the overlay's explicit false agrees; a key the overlay's copy lacks is the key problem, reported once",
      len(r3(dontChroot=False)) == 1 and "live system" in r3(dontChroot=False)[0] and "target" in r3(dontChroot=False)[0]
      and len(sp.compare_docs("n", {"dontChroot": False, "script": ["a"]}, {"dontChroot": True, "script": ["a"]})) == 1
      and len(sp.compare_docs("n", {"script": ["a"]}, {"dontChroot": True, "script": ["a"]})) == 1
      and len(sp.compare_docs("n", {"dontChroot": True, "script": ["a"]}, {"script": ["a"]})) == 1
      and "key 'dontChroot'" in sp.compare_docs("n", {"dontChroot": True, "script": ["a"]}, {"script": ["a"]})[0]
      and sp.compare_docs("n", {"script": ["a"]}, {"dontChroot": False, "script": ["a"]}) == []
      and len(sp.compare_docs("n", {"dontChroot": False, "script": ["a"]}, {"script": ["a"]})) == 1)
check("R3: a dropped command is reported once as dropped, not also as reordered; a dropped key still is a problem of its own",
      len(r3(script=["a", "c"])) == 1 and "does not" in r3(script=["a", "c"])[0]
      and len(sp.compare_docs("n", r3_stock, {"dontChroot": True, "script": ["a", "b", "c"]})) == 1)
# The real thing: the recorded installer files against the overlay's copies, mutated the two ways.
for n_ in ("shellprocess_initialize_pacman.conf", "shellprocess_modify_mk_hook.conf", "shellprocess_reset_mk_hook.conf"):
    st_ = stock_sp[n_]
    cmds_ = [c_ for c_, _ in sp.items_of(st_)]
    swapped = dict(docs[n_], script=[cmds_[1], cmds_[0]] + cmds_[2:])
    flipped = dict(docs[n_], dontChroot=not bool(docs[n_].get("dontChroot")))
    check("%s: reordering its first two commands, or flipping dontChroot, is refused by R3 (the unchanged copy is not)" % n_,
          not sp.compare_docs(n_, st_, docs[n_]) and len(cmds_) >= 2 and cmds_[0] != cmds_[1]
          and any("different" in x or "order" in x for x in sp.compare_docs(n_, st_, swapped))
          and any("dontChroot" in x for x in sp.compare_docs(n_, st_, flipped)),
          (sp.compare_docs(n_, st_, swapped), sp.compare_docs(n_, st_, flipped)))

# The three forms `script:` may take: a list (strings and mappings), one string, one mapping. Iterating a string reads it one character at a
# time and a mapping one key at a time, which made the single-string form a false negative and the single-mapping form a false positive.
check("items_of: a list of strings and mappings, one string, one mapping, an empty string or mapping, no script: the same commands and limits whichever form",
      sp.items_of({"script": ["pacman -Sy", {"command": "cp -a a b", "timeout": 9}]}) == [("pacman -Sy", None), ("cp -a a b", 9)]
      and sp.items_of({"script": "pacman -Syu --noconfirm"}) == [("pacman -Syu --noconfirm", None)]
      and sp.items_of({"script": {"command": "pacman -Syu", "timeout": 900, "verbose": True}}) == [("pacman -Syu", 900)]
      and sp.items_of({"script": ""}) == [] and sp.items_of({"script": {}}) == [] and sp.items_of({}) == [] and sp.items_of(None) == []
      and sp.items_of({"script": 5}) == [])
def audit_form(script, ftimeout=None):
    d = {"dontChroot": True, "script": script}
    if ftimeout is not None:
        d["timeout"] = ftimeout
    return sp.audit_doc("t.conf", d, [])
check("the single-string form is judged like the list: a heavy command with a 20 s file-level limit is refused (it passed when the string was read one character at a time), 600 s passes, no limit is the 30 s default",
      any("may only take 20 s" in x and "pacman" in x for x in audit_form("pacman -Syu --noconfirm", 20))
      and audit_form("pacman -Syu --noconfirm", 600) == []
      and any("after 30 s" in x and "pacman" in x for x in audit_form("pacman -Syu --noconfirm"))
      and audit_form(["pacman -Syu --noconfirm"], 20) == audit_form("pacman -Syu --noconfirm", 20),
      audit_form("pacman -Syu --noconfirm", 20))
check("the single-mapping form is judged like the list: its own timeout counts (900 s on a heavy command, no file-level limit: no problem; it was reported as having no limit), 20 s is refused, none is the 30 s default",
      audit_form({"command": "pacman -Syu --noconfirm", "timeout": 900}) == []
      and any("may only take 20 s" in x for x in audit_form({"command": "pacman -Syu --noconfirm", "timeout": 20}))
      and any("after 30 s" in x for x in audit_form({"command": "pacman -Syu --noconfirm"}))
      and audit_form({"command": "pacman -Syu --noconfirm"}, 600) == []
      and audit_form([{"command": "pacman -Syu --noconfirm", "timeout": 900}]) == [],
      audit_form({"command": "pacman -Syu --noconfirm", "timeout": 900}))
check("capture (the facts' shape) reads the single-string and single-mapping forms as the list of mappings the fake installer tree is built from",
      sp.capture({"dontChroot": True, "script": "a b"})["script"] == [{"command": "a b"}]
      and sp.capture({"script": {"command": "a", "timeout": 5}})["script"] == [{"command": "a", "timeout": 5}])
# The same rules live in verify-iso.sh (its Python is embedded, so it is a copy): the shared part, from the pattern table to compare_docs, must be
# the same text, character for character (the markers say where it starts and ends in both files).
def shared_block(src):
    m_ = re.search(r"^# --- shared:.*?^# --- end shared ---\n", src, re.S | re.M)
    return m_.group(0) if m_ else None
verify_src = text(os.path.join(CACHYOS, "iso", "scripts", "verify-iso.sh"))
lib_src = text(os.path.join(INST, "lib", "ci-shellprocess.py"))
check("verify-iso.sh's embedded audit carries the shared part of lib/ci-shellprocess.py character for character (the HEAVY table, the floors, R1 to R3): a copy that drifted would pass what the guard refuses",
      shared_block(verify_src) is not None and shared_block(verify_src) == shared_block(lib_src) and "HEAVY = [" in shared_block(lib_src) and "NET_FLOOR = %d" % sp.NET_FLOOR in shared_block(lib_src))

# ---------------------------------------------------------------------------------------------------------------------------------
print("== install page labels (ISO #5, 35 percent: 'Installing needed drivers for CachyOS...')")
patch_rows = [[x.strip() for x in l.split("|")] for l in text(os.path.join(INST, "patches.list")).splitlines() if l.strip() and not l.lstrip().startswith("#")]
chwd_rows = [r_ for r_ in patch_rows if r_[0] == "/usr/lib/calamares/modules/chwd/main.py"]
check("patches.list rewrites the driver job's label in chwd/main.py (a Python job's label is its pretty_name(); no config reaches it)", len(chwd_rows) == 1 and len(chwd_rows[0]) == 3, patch_rows)
marker_line = [l for l in facts_lines if l.startswith("marker /usr/lib/calamares/modules/chwd/main.py ")]
check("the recorded installer has the marker the patch looks for in chwd/main.py (so the patch applies to the pinned installer)",
      len(marker_line) == 1 and chwd_rows and marker_line[0].split(" ", 2)[2] == chwd_rows[0][2], marker_line)
def apply_sed(expr, src):
    return subprocess.run(["sed", "-e", expr], input=src, capture_output=True, text=True, check=True).stdout
label_src = '    return _("Installing needed drivers for CachyOS...")\n'
label_out = apply_sed(chwd_rows[0][1], label_src) if chwd_rows else label_src
check("the patch turns the label into 'Installing needed drivers for Companion OS...' and nothing of the line says CachyOS afterwards",
      label_out == '    return _("Installing needed drivers for Companion OS...")\n', label_out)
check("... and it touches no other line: the expression is anchored on the label's own text, so a CachyOS word elsewhere in the module (a comment, an identifier) stays as it is",
      apply_sed(chwd_rows[0][1], "# cachyos-chwd helper\nx = 'CachyOS'\n") == "# cachyos-chwd helper\nx = 'CachyOS'\n")
shipped = {}
for dp, dn, fn in os.walk(INST):
    for f in fn:
        pth = os.path.join(dp, f)
        rel_ = os.path.relpath(pth, INST)
        if f.endswith((".conf", ".yaml", ".qml", ".qss", ".desc")) or rel_ in ("settings.conf",):
            shipped[rel_] = strip_comments(text(pth))
check("no file the installer overlay ships contains a 'for CachyOS' label (case-insensitive) in its code: the install page, the slides and the module texts say Companion OS (the comments that explain the patch are not shipped text and are excluded)",
      not [f for f, t in shipped.items() if re.search(r"for\s+cachyos", t, re.I)], [f for f, t in shipped.items() if re.search(r"for\s+cachyos", t, re.I)])
check("the progress texts of every overlay module config (i18n name, all translations) say nothing about CachyOS",
      not [f for f, d in docs.items() if isinstance(d, dict) and isinstance(d.get("i18n"), dict) and re.search("cachy", " ".join(str(v) for v in d["i18n"].values()), re.I)])
before_online = stock_sp["shellprocess-before-online.conf"]
check("the one stock progress text that names CachyOS (shellprocess-before-online.conf, job 14) is rewritten by an existing patch row, and the Limine and Btrfs snapshot rows are still there",
      any(r_[0].endswith("shellprocess-before-online.conf") and "/name/ s/CachyOS/Companion OS/g" == r_[1] for r_ in patch_rows) and len(patch_rows) == 4)

# ---------------------------------------------------------------------------------------------------------------------------------
print("== boot menu of the installed system (ISO #5: UiApp, a gone DVD drive, the NVMe disk, EFI Shell and a second companion-os in GRUB)")
gdef = docs["grubcfg.conf"]["defaults"]
check("grubcfg.conf sets GRUB_DISABLE_BOOTNEXT and GRUB_DISABLE_OS_PROBER to true (YAML booleans: the grubcfg job writes 'true'), and always_use_defaults makes the job write them",
      gdef.get("GRUB_DISABLE_BOOTNEXT") is True and gdef.get("GRUB_DISABLE_OS_PROBER") is True and docs["grubcfg.conf"].get("always_use_defaults") is True, gdef)
check("the recovery entries stay off and the Companion OS theme stays (nothing else about the menu changed)",
      gdef.get("GRUB_DISABLE_RECOVERY") is True and gdef.get("GRUB_THEME") == contract["CI_INSTALLED_GRUB_THEME"] and gdef.get("GRUB_TIMEOUT") == 5)
check("grubcfg runs before bootloader (grub-mkconfig reads /etc/default/grub when it generates grub.cfg), so the switches are in force when the menu is written", before("grubcfg", "bootloader"))
check("the post-install fix-ups check both switches and a grub.cfg with EFI BootNext entries (they cannot set them: bootloader already ran)",
      all(x in text(os.path.join(INST, "scripts", "ci-os-post-install-fixups.sh")) for x in ("GRUB_DISABLE_BOOTNEXT", "GRUB_DISABLE_OS_PROBER", "efi-bootnext-")))
# The real grubcfg job, with a stand-in libcalamares, on this overlay's own grubcfg.conf: what ends up in the target's /etc/default/grub.
real_main = os.path.join(real, "usr", "lib", "calamares", "modules", "grubcfg", "main.py") if real else ""
if real_main and os.path.isfile(real_main):
    import types
    lib = types.ModuleType("libcalamares")
    lib.utils = types.SimpleNamespace(gettext_path=lambda: "/nonexistent", gettext_languages=lambda: ["en"], target_env_call=lambda args: 1, debug=lambda *a: None, warning=lambda *a: None)
    with tempfile.TemporaryDirectory() as root_dir:
        os.makedirs(os.path.join(root_dir, "etc", "default"))
        with open(os.path.join(root_dir, "etc", "default", "grub"), "w", encoding="utf-8") as fh:
            fh.write('GRUB_DEFAULT=0\nGRUB_DISABLE_OS_PROBER=false\nGRUB_DISTRIBUTOR="Arch"\n#GRUB_DISABLE_BOOTNEXT=true\n')
        lib.job = types.SimpleNamespace(configuration=dict(docs["grubcfg.conf"]))
        lib.globalstorage = types.SimpleNamespace(value=lambda k: {"firmwareType": "efi", "partitions": [{"mountPoint": "/boot/efi", "fs": "vfat"}, {"mountPoint": "/", "fs": "btrfs"}],
                                                                   "rootMountPoint": root_dir, "branding": {"bootloaderEntryName": "Companion OS"}, "packagechooser_bootloader": "grub",
                                                                   "efiSystemPartition": "/boot/efi", "bootLoader": {"x": 1}}.get(k))
        sys.modules["libcalamares"] = lib
        sp_ = importlib.util.spec_from_file_location("grubcfg_real", real_main)
        gm = importlib.util.module_from_spec(sp_)
        sp_.loader.exec_module(gm)
        res = gm.run()
        written = text(os.path.join(root_dir, "etc", "default", "grub"))
        del sys.modules["libcalamares"]
    check("the REAL grubcfg module (3.4.2-13) run on this overlay's grubcfg.conf writes GRUB_DISABLE_BOOTNEXT='true' and GRUB_DISABLE_OS_PROBER='true' into /etc/default/grub (an existing 'false' line is replaced, a commented one is uncommented), the Companion OS theme and distributor",
          res is None and "GRUB_DISABLE_BOOTNEXT='true'" in written and "GRUB_DISABLE_OS_PROBER='true'" in written and "GRUB_DISABLE_OS_PROBER=false" not in written
          and "GRUB_DISTRIBUTOR='Companion OS'" in written and "companion-os/theme.txt" in written, written)
else:
    print("SKIP  the real grubcfg module on this overlay's grubcfg.conf (set CI_OS_REAL_CALAMARES_ROOT to an unpacked cachyos-calamares-next)")

print()
print("== installer-config.py: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
