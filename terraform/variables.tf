variable "pm_api_url" {
  description = "Proxmox API URL, e.g. https://192.168.1.10:8006/api2/json"
  type        = string
}

variable "pm_api_token_id" {
  description = "API token id, e.g. terraform@pve!iac"
  type        = string
  sensitive   = true
}

variable "pm_api_token_secret" {
  type      = string
  sensitive = true
}

variable "pm_tls_insecure" {
  description = "Skip TLS verification (Proxmox ships a self-signed cert)"
  type        = bool
  default     = true
}

variable "pve_node" {
  type    = string
  default = "proxmox"
}

variable "ssh_public_key" {
  description = "Public key installed for root in each container (Ansible connects with it)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ostemplate" {
  type    = string
  default = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "rootfs_storage" {
  type    = string
  default = "local-lvm"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "gateway" {
  description = "LAN gateway for the containers"
  type        = string
}

variable "instances" {
  description = "One LXC per qBittorrent instance, keyed by hostname"
  type = map(object({
    vmid   = number
    ip     = string # CIDR, e.g. 192.168.1.151/24
    memory = optional(number, 3072)
    cores  = optional(number, 2)
    disk   = optional(number, 20)
  }))
}
