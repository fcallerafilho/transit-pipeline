#!/usr/bin/env bash
#
# Layer B — step 1 of 2: turn a bare Linux box into a k3s node.
# (Step 2 is `kubectl apply -f k8s/`, which is byte-identical everywhere.)
#
# This script is host-agnostic by contract (DESIGN §12): it must run unchanged on
# a Hetzner VM, an Oracle A1 VM, or owned hardware. Nothing cloud-specific belongs
# here — that is Layer A's job.
#
# Idempotent: safe to re-run. Run as root on the target host.
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-stable}"

log() { printf '\n=== %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

log "Host"
uname -srm
if [ -r /etc/os-release ]; then . /etc/os-release; echo "${PRETTY_NAME:-unknown}"; fi
echo "memory: $(free -h | awk '/^Mem:/ {print $2}')  disk: $(df -h / | awk 'NR==2 {print $2}')"

# The firewall in Layer A leaves port 22 open to the internet, on the explicit
# grounds that key-only authentication is the real control. Make that true rather
# than assumed. Hetzner images that provision a root password default to allowing
# password login, which would silently invalidate that reasoning.
log "Enforcing key-only SSH"
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-transit-hardening.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  echo "password authentication disabled"
else
  echo "sshd config test FAILED — reverting, fix by hand" >&2
  rm -f /etc/ssh/sshd_config.d/10-transit-hardening.conf
  exit 1
fi

if command -v k3s >/dev/null 2>&1; then
  log "k3s already installed — skipping install"
else
  log "Installing k3s (${K3S_CHANNEL})"
  # --disable traefik:  ingress arrives through the Cloudflare Tunnel (DESIGN §6.4),
  #                     so an in-cluster ingress controller is dead weight against
  #                     the §6.2 memory budget.
  # --disable servicelb: no cloud load balancer on any host — same §6.4 reasoning.
  #                     Services stay ClusterIP; cloudflared reaches them from inside.
  # local-path storage is left ENABLED on purpose: it is the §6.3 storage decision.
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -s - \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 600
fi

log "Waiting for the node to become Ready"
for _ in $(seq 1 60); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; then break; fi
  sleep 2
done
k3s kubectl get nodes -o wide

log "Versions"
# Not piped through head: with 'set -o pipefail' a reader that exits early sends
# SIGPIPE to k3s and fails the whole script after the install has already
# succeeded. Both lines are worth printing anyway.
k3s --version

log "Done"
cat <<'NEXT'
k3s is up. kubeconfig: /etc/rancher/k3s/k3s.yaml

Next (from the laptop, not here):
  make secrets-remote     # create the namespace + secrets out-of-band
  make deploy-remote      # kubectl apply -f k8s/  — unchanged from local
NEXT
