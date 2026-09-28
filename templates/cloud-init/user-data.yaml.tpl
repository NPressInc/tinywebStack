#cloud-config
hostname: ${FQDN}
fqdn: ${FQDN}
manage_etc_hosts: true
package_update: true
package_upgrade: true
packages:
  - curl
  - sudo
  - qemu-guest-agent
users:
  - name: ${PROVISION_SSH_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ADMIN_SSH_PUBKEY_CONTENT}
ssh_pwauth: false
chpasswd:
  expire: false
runcmd:
  - systemctl enable --now qemu-guest-agent || true
