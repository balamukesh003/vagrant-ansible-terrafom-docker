#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- APT speedups + parallel downloads ---
sudo tee /etc/apt/apt.conf.d/99-speed >/dev/null <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ForceIPv4 "true";
Acquire::Languages "none";
APT::Install-Recommends "false";
Dpkg::Use-Pty "0";
Acquire::Queue-Mode "access";
APT::Fetcher::MaxParallelDownloads "8";
Acquire::PDiffs "false";
EOF

# --- Use Ubuntu's mirror auto-selector ---
sudo tee /etc/apt/sources.list >/dev/null <<'EOF'
deb mirror://mirrors.ubuntu.com/mirrors.txt jammy main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt jammy-updates main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt jammy-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF

sudo apt-get clean

# --- Base tools ---
sudo apt-get update -y
sudo apt-get install -y curl gnupg lsb-release ca-certificates software-properties-common

# --- Add official Docker repo (idempotent: no gpg overwrite prompt) ---
sudo mkdir -p /usr/share/keyrings
sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
curl -fsSL --retry 5 --retry-delay 3 https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update -y

# --- Install Docker (skipped if already installed) ---
if command -v docker >/dev/null 2>&1; then
  DOCKER_SRC="already installed"
else
  if timeout 180s sudo apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true \
      install -y docker-ce docker-ce-cli containerd.io; then
    DOCKER_SRC="docker-ce (docker.com)"
  else
    echo ">> docker-ce slow; trying get.docker.com convenience script"
    if curl -fsSL https://get.docker.com | sudo sh; then
      DOCKER_SRC="get.docker.com"
    else
      echo ">> Falling back to Ubuntu docker.io (last resort)"
      sudo rm -f /etc/apt/sources.list.d/docker.list
      sudo apt-get update -y
      sudo apt-get install -y docker.io containerd runc
      DOCKER_SRC="ubuntu docker.io"
    fi
  fi
fi

# --- Docker on host VM ---
sudo systemctl enable --now docker
docker --version || true
echo ">> Docker source: ${DOCKER_SRC}"
sudo usermod -aG docker vagrant

# --- Optional: load pre-saved image if present (skips docker pull) ---
if [[ -f /home/vagrant/ansible-ssh-22.04.tar ]]; then
  sudo docker load -i /home/vagrant/ansible-ssh-22.04.tar || true
fi

# --- Permissions for your repo path (if needed) ---
sudo chown -R vagrant:vagrant /home/vagrant/terraform-docker || true

# --- SSH key for Ansible (host VM -> containers), created only if missing ---
sudo -u vagrant mkdir -p /home/vagrant/.ssh
sudo chmod 700 /home/vagrant/.ssh
if [[ ! -f /home/vagrant/.ssh/id_rsa ]]; then
  sudo -u vagrant ssh-keygen -t rsa -b 2048 -N "" -f /home/vagrant/.ssh/id_rsa
fi
pubkey=$(cat /home/vagrant/.ssh/id_rsa.pub)

# --- Network + Workers using your prebuilt image ---
sudo docker network create --subnet=172.20.0.0/24 ansible-net 2>/dev/null || true

for i in 1 2; do
  cname="worker$i"
  cip="172.20.0.1$i"

  # Recreate container
  sudo docker rm -f "$cname" 2>/dev/null || true
  sudo docker volume create "worker_${i}_ssh" >/dev/null

  sudo docker run -d --name "$cname" --hostname "$cname" \
    --net ansible-net --ip "$cip" \
    --privileged --restart=always \
    -v "worker_${i}_ssh:/root/.ssh" \
    deenamanick/ansible-ssh:22.04

  # Inject authorized_keys (does not touch the host's sshd)
  echo "$pubkey" | sudo docker exec -i "$cname" bash -lc '
    umask 077
    mkdir -p /root/.ssh
    cat > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
  '

  # Ensure sshd INSIDE the container is running
  sudo docker exec "$cname" bash -lc '
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now ssh || systemctl enable --now sshd || true
    else
      service ssh start || service sshd start || /etc/init.d/ssh start || true
    fi
  '
done

# --- Wait for container SSH ports (max 60s each) ---
for i in 1 2; do
  cname="worker$i"
  echo "Waiting for SSH in $cname..."
  tries=0
  until sudo docker exec "$cname" bash -lc 'timeout 1 bash -c "</dev/tcp/127.0.0.1/22" 2>/dev/null'; do
    tries=$((tries + 1))
    if [[ $tries -ge 60 ]]; then
      echo "ERROR: SSH in $cname did not come up within 60s" >&2
      exit 1
    fi
    sleep 1
  done
  echo "$cname: SSH is ready."
done

# IMPORTANT: Do NOT restart ssh on the Vagrant VM here (that kills provisioning).
# If you must apply host sshd changes, reload at the VERY END:
# (sleep 2; sudo systemctl reload ssh || sudo systemctl reload sshd || true) & disown