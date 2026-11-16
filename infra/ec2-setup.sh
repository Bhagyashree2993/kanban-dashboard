#!/usr/bin/env bash
# =============================================================================
# EC2 bootstrap (Ubuntu 22.04 / 24.04): Docker Engine + Jenkins LTS.
# Use as EC2 "User data", or run manually:  sudo bash infra/ec2-setup.sh
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> base packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg git fontconfig openjdk-21-jre-headless

echo ">>> 2 GB swap (keeps npm/vite builds from OOM-killing Jenkins on small instances)"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo ">>> Docker Engine (official repo)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# Default log rotation for every container (docker logs stay usable, disk doesn't fill)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable --now docker
systemctl restart docker

echo ">>> Jenkins LTS (official repo)"
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins

# Jenkins needs Docker; cap its JVM so it can't starve the app
usermod -aG docker jenkins
id ubuntu >/dev/null 2>&1 && usermod -aG docker ubuntu
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Xms256m -Xmx768m"
EOF
systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins

echo ">>> deploy state dir (writable by jenkins and anyone in the docker group)"
mkdir -p /opt/kanban/proxy
chown -R jenkins:docker /opt/kanban
chmod -R 2775 /opt/kanban

echo ">>> done"
docker --version
java -version 2>&1 | head -1
echo "Jenkins: http://<EC2_PUBLIC_IP>:8080"
echo "Initial admin password: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
