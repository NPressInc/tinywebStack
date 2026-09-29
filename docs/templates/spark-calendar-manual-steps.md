# Manual steps on spark (calendar PRs)

Paste this section into calendar-related PR bodies after editing if needed.

On each VM after pulling the branch:

```bash
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

IP_A=$(virsh domifaddr tws-family-a | awk '/ipv4/ {print $4}' | cut -d/ -f1)
IP_B=$(virsh domifaddr tws-family-b | awk '/ipv4/ {print $4}' | cut -d/ -f1)

while read -r node domain ip; do
  [[ -z "$node" || -z "$domain" || -z "$ip" ]] && continue
  ./scripts/vm/remote-run.sh "$ip" install-nextcloud-calendar.sh "$domain" "$node"
  ./scripts/vm/remote-run.sh "$ip" setup-family-calendars.sh "$domain" "$node"
  ./scripts/vm/remote-run.sh "$ip" family-groups.sh
done <<EOF
family-a family-a.family.test $IP_A
family-b family-b.family.test $IP_B
EOF
```

From the spark repo root (not the VM install path alone):

```bash
./scripts/spark/verify-calendar-e2e.sh family-a family-a.family.test
./scripts/spark/verify-calendar-e2e.sh family-b family-b.family.test
```

Confirm `family-init` completes without `Permission denied`, `/family/calendar` returns 200 for parents, re-running `setup-family-calendars.sh` does not hit share 429, and invite verify leaves no events in Nextcloud calendar trash.
