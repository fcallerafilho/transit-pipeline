resource "hcloud_ssh_key" "operator" {
  name       = var.ssh_key_name
  public_key = var.ssh_public_key
}

# The only inbound port is SSH.
#
# There is deliberately no 80/443 rule: ingress arrives through an OUTBOUND
# Cloudflare Tunnel connection (DESIGN §6.4), so the box never needs to be
# reachable from the internet on a web port. This is the same property that
# makes the owned-hardware option viable behind CGNAT, and it means the host
# has no public attack surface beyond sshd.
resource "hcloud_firewall" "transit" {
  name = "${var.server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }

  # ICMP kept open: ping/MTU discovery is worth more for debugging than it
  # costs in exposure.
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "transit" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location

  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.transit.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Hetzner's own backups are off: DESIGN §6.3 makes durability an application
  # concern (a nightly pg_dump to a second location), not a platform feature.
  # Turning them on here would quietly contradict that trade-off.
  backups = false

  labels = {
    project = "transit-pipeline"
    layer   = "a"
  }

  # This host accrues the continuous runtime that DESIGN §9.2 artifact 5 is
  # measured over (§9.3). A replacement resets that clock to zero, so an
  # accidental destroy is far more expensive here than the machine is.
  # Removing this guard is a deliberate act, not a side effect of a plan.
  lifecycle {
    prevent_destroy = true

    # ssh_keys is consumed by Hetzner at creation time and never reported back
    # by the API, so an imported server shows it as an unresolvable diff that
    # forces replacement on every plan. Ignoring it is the honest description of
    # reality: which keys can actually log in is owned by the OS (sshd and
    # authorized_keys), not by this attribute. Changing the value here would not
    # change access on a running box anyway.
    ignore_changes = [ssh_keys]
  }
}
