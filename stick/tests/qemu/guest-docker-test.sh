#!/bin/sh
# Runs as root INSIDE the guest (started by docker-live.sh through systemd.run=). Prints CI-DOCKER-TEST lines on the console.
# usage: guest-docker-test.sh <live-iso|live-stick|installed> <user> <first|second>
MODE="$1"; U="$2"; PHASE="${3:-first}"; FAILED=0
res()  { echo "CI-DOCKER-TEST $1 $2 $3" > /dev/console; }
pass() { res "$1" PASS "$2"; }
fail() { res "$1" FAIL "$2"; FAILED=1; }
t()    { n="$1"; shift; if o="$("$@" 2>&1)"; then pass "$n" "$(echo "$o" | head -1)"; else fail "$n" "$(echo "$o" | tail -2 | tr '\n' ' ')"; fi; }

g="$(id -nG "$U" 2>&1)"
case " $g " in *" docker "*) pass groups "$g" ;; *) fail groups "$g" ;; esac
t cli runuser -u "$U" -- docker version --format '{{.Server.Version}}'      # unprivileged user, no sudo
t daemon-active systemctl is-active docker.service

fs="$(findmnt -no FSTYPE -T /var/lib/docker 2>&1)"
case "$MODE:$fs" in
  *:overlay)                                   fail backing "$fs (overlay on overlay: overlay2 cannot work)" ;;
  live-iso:tmpfs|live-stick:ext4|installed:*)  pass backing "$fs" ;;
  *)                                           fail backing "$MODE got $fs" ;;
esac
res info INFO "$(docker info --format '{{.Driver}} | {{.DriverStatus}}' 2>&1 | tr '\n' ' ')"
res cdisk INFO "containerd root on: $(findmnt -no FSTYPE -T /var/lib/containerd)"

if [ "$MODE" = installed ]; then
  t group-unit systemctl is-enabled ci-os-docker-group.service
  [ "$(systemctl show -p ConditionResult --value ci-os-live-container-storage.service)" = no ] \
     && pass storage-unit-skipped "condition false on an installed system" || fail storage-unit-skipped "storage unit ran on an installed system"
else
  t storage-unit systemctl is-active ci-os-live-container-storage.service
  [ "$(cat /run/ci-os/live-container/backing 2>/dev/null)" = "$([ "$MODE" = live-stick ] && echo persist || echo tmpfs)" ] \
     && pass backing-marker "$(cat /run/ci-os/live-container/backing)" || fail backing-marker "$(cat /run/ci-os/live-container/backing 2>&1)"
fi

if [ "$PHASE" = first ]; then
  t load docker load -i /mnt/t/hello-world.tar
elif [ "$MODE" = live-stick ]; then
  t persisted docker image inspect hello-world --format '{{.Id}}'            # survived the reboot on CI-PERSIST
else
  docker image inspect hello-world >/dev/null 2>&1 && fail not-persisted "tmpfs-backed image survived a reboot?" || pass not-persisted "plain ISO forgets, as designed"
  t load docker load -i /mnt/t/hello-world.tar
fi
out="$(runuser -u "$U" -- docker run --rm --network none hello-world 2>&1)"
case "$out" in *"Hello from Docker!"*) pass run "hello-world, offline, as $U" ;; *) fail run "$(echo "$out" | tail -3 | tr '\n' ' ')" ;; esac

res timing INFO "$(systemd-analyze blame --no-pager 2>/dev/null | grep -E 'docker|containerd|ci-os-live|wait-online' | sed 's/^ *//' | tr '\n' ';')"
res DONE "$([ "$FAILED" = 0 ] && echo PASS || echo FAIL)" "mode=$MODE phase=$PHASE"
exit "$FAILED"
