provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = var.pm_tls_insecure
}

# Random root password per container. Login is by SSH key; this just avoids a
# blank or shared password. Kept in state only:
#   terraform output -json root_passwords
resource "random_password" "root" {
  for_each = var.instances

  length           = 24
  special          = true
  override_special = "!@#%^*-_=+."
}

resource "proxmox_lxc" "qbittorrent" {
  for_each = var.instances

  target_node  = var.pve_node
  vmid         = each.value.vmid
  hostname     = each.key
  description  = "qBittorrent + PIA WireGuard. Configured by the Ansible role qbittorrent-pia."
  ostemplate   = var.ostemplate
  unprivileged = true
  onboot       = true
  start        = true

  cores  = each.value.cores
  memory = each.value.memory
  swap   = 0

  password        = random_password.root[each.key].result
  ssh_public_keys = file(pathexpand(var.ssh_public_key))

  # Docker inside an unprivileged LXC needs nesting.
  features {
    nesting = true
  }

  rootfs {
    storage = var.rootfs_storage
    size    = "${each.value.disk}G"
  }

  network {
    name     = "eth0"
    bridge   = var.bridge
    ip       = each.value.ip
    gw       = var.gateway
    firewall = true
  }

  # The /data bind mount needs root@pam, which an API token can't have, so
  # host/apply-data-mounts.sh adds it over SSH. Ignore that drift here.
  lifecycle {
    ignore_changes = [mountpoint]
  }
}
