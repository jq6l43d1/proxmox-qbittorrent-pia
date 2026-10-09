output "containers" {
  description = "Created qBittorrent LXCs"
  value = {
    for k, c in proxmox_lxc.qbittorrent : k => {
      vmid = c.vmid
      ip   = c.network[0].ip
    }
  }
}

output "root_passwords" {
  value     = { for k, p in random_password.root : k => p.result }
  sensitive = true
}
