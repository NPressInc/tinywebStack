#cloud-config
hostname: ${FQDN}
fqdn: ${FQDN}
manage_etc_hosts: true
package_update: true
package_upgrade: true
packages:
  - curl
  - sudo
  - rsync
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
write_files:
  - path: /root/.ssh/authorized_keys
    owner: root:root
    permissions: "0600"
    content: |
      ${ADMIN_SSH_PUBKEY_CONTENT}
runcmd:
  - systemctl enable --now qemu-guest-agent || true
  - chmod 700 /root/.ssh
