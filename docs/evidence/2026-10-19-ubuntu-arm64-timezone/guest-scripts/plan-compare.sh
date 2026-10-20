#!/bin/sh
# read-only: the old helper of the image and the new helper of the branch, each with --plan (nothing is written, nothing is installed)
OLD=/usr/libexec/ci-os/ci-os-auto-install
curl -s 10.0.2.2:8811/h -o /tmp/h
{
echo "== image's own helper, --plan"; python3 $OLD --plan 2>&1 | grep -n -E "TIME ZONE|^ *timezone"
echo "== helper of this branch, --plan"; python3 /tmp/h --plan 2>&1 | grep -n -E "TIME ZONE|^ *timezone"
echo "== live session tools"; command -v curl timedatectl
echo "zone names in timedatectl list-timezones: $(timedatectl list-timezones | wc -l); America/Los_Angeles listed: $(timedatectl list-timezones | grep -c -x America/Los_Angeles)"
snap list ubuntu-desktop-bootstrap 2>&1
} > /tmp/plan.txt 2>&1
curl -s --data-binary @/tmp/plan.txt 10.0.2.2:8811/up/plan-live
