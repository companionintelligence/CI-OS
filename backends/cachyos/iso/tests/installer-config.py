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
          and l.split("|")[1].strip() in ("exists", "contains", "oexists", "lexists", "keys", "settings-drift", "list-drift", "code-names", "settings") for l in gl))
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

print()
print("== installer-config.py: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
