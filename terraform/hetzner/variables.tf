variable "server_name" {
  description = "Hetzner server name. Must match the existing server when importing."
  type        = string
  default     = "sp-buses-radar-01"
}

variable "server_type" {
  description = <<-DESC
    Hetzner shape. CX = Intel/AMD x86 (amd64), CAX = Ampere (arm64).
    The images are built multi-arch (DESIGN §6.1) so either works, but the
    §6.2 memory budget assumes ~4 GB — do not drop below that.
  DESC
  type        = string
  default     = "cx23"
}

variable "location" {
  description = <<-DESC
    Hetzner has no South American region, so every option is far from the
    SPTrans upstream in São Paulo. This adds a fixed ~100-200 ms to
    upstream_request_duration (DESIGN §5.1) but is irrelevant to the 120 s
    freshness SLO (§5.2). ash (Ashburn, US) is the closest to Brazil;
    hel1/fsn1/nbg1 are European.
  DESC
  type        = string
  default     = "hel1"
}

variable "image" {
  description = "Base OS image. k3s is installed by Layer B, not baked in."
  type        = string
  default     = "ubuntu-26.04"
}

variable "ssh_key_name" {
  description = "Name of the SSH key as stored in the Hetzner Cloud project."
  type        = string
  default     = "fernandos-laptot"
}

variable "ssh_public_key" {
  description = "Contents of the SSH public key authorised for root."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = <<-DESC
    Sources permitted to reach port 22. Defaults to the whole internet because
    the operator's residential IP is dynamic; the real control is that password
    authentication is disabled and only the key above is accepted. Narrow this
    if a static IP ever becomes available.
  DESC
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
