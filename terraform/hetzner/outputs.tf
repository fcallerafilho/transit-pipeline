output "ipv4" {
  description = "Public IPv4 — the SSH target and the Layer B bootstrap target."
  value       = hcloud_server.transit.ipv4_address
}

output "ipv6" {
  value = hcloud_server.transit.ipv6_address
}

output "ssh" {
  description = "Ready-to-paste SSH command."
  value       = "ssh root@${hcloud_server.transit.ipv4_address}"
}
