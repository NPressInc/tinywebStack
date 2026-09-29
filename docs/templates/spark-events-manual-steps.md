# Manual steps on spark (Mobilizon / events PRs)

Paste this section into events-related PR bodies after editing if needed.

On spark, from the **git checkout root** (not `scripts/` alone):

```bash
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

./scripts/spark/sync-all-vm-peer-hosts.sh

IP_A=$(virsh domifaddr tws-family-a | awk '/ipv4/ {print $4}' | cut -d/ -f1)
IP_B=$(virsh domifaddr tws-family-b | awk '/ipv4/ {print $4}' | cut -d/ -f1)

while read -r node domain ip; do
  [[ -z "$node" || -z "$domain" || -z "$ip" ]] && continue
  ./scripts/vm/remote-run.sh "$ip" install-mobilizon.sh "$domain" "$node"
  ./scripts/vm/remote-run.sh "$ip" mobilizon-lab-ca-trust.sh
  ./scripts/vm/remote-run.sh "$ip" family-groups.sh
done <<EOF
family-a family-a.family.test $IP_A
family-b family-b.family.test $IP_B
EOF

./scripts/spark/configure-federation-pair.sh "$IP_A" "$IP_B"

./scripts/spark/verify-events-e2e.sh \
  family-a family-b \
  family-a.family.test family-b.family.test \
  mobilizon.fr
```

Confirm `mobilizon.federation` has **visitors** allowed and **no portal tile**, toggled-off kids cannot log in via `/api`, and cross-home RSVP succeeds.
