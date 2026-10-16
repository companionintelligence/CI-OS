# Appended to the copy of the upstream profiledef.sh by the overlay step (later assignments win), sourced by mkarchiso.
# shellcheck shell=bash disable=SC2034

# Product identity of the image (decision D1). The medium is found by archisosearchuuid, never by the label, so
# renaming the label touches no boot path. iso_label is the ISO 9660 volume id: 32 characters at most.
iso_name="companion-os-plasma"
iso_label="COMPANION_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Companion Intelligence <https://ci.computer>"
iso_application="Companion OS Live/Installer"

# mkarchiso drops the modes of the files it copies from airootfs/ and only restores what is listed here, so every
# executable this overlay adds is listed (the test tests/overlay-brand.sh checks that nothing is missing).
file_permissions+=(
  ["/usr/share/libalpm/scripts/zz-ci-os-os-release"]="0:0:755"
  ["/usr/share/libalpm/scripts/zz-ci-os-skel"]="0:0:755"
  ["/usr/share/ci-os/installed/carry-over"]="0:0:755"
  ["/usr/lib/systemd/system-generators/companion-vm-timeouts"]="0:0:755"
  ["/usr/libexec/ci-os/apply-wallpaper"]="0:0:755"
)
