#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Bootstrap for the Todozee Document Reader (Surya OCR API, GPU inference)
# Rendered by Terraform (templatefile). Bash variable braces are written
# doubled (double-dollar) so Terraform passes them through; single-dollar
# brace values are Terraform-injected from the resource.
#
# Base image: AWS Deep Learning Base GPU AMI (Ubuntu 22.04) — NVIDIA
# driver + CUDA already present, so we only install a CUDA torch build.
# ─────────────────────────────────────────────────────────────────────
set -euxo pipefail
exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "=== bootstrap start $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

APP_DIR=/opt/${project_name}
REPO_DIR=$${APP_DIR}/repo
VENV_DIR=$${APP_DIR}/venv
HF_HOME_DIR=$${APP_DIR}/hf-cache
CACHE_DIR=$${APP_DIR}/model-cache

mkdir -p "$${APP_DIR}" "$${HF_HOME_DIR}" "$${CACHE_DIR}"

# ── 0. Confirm the GPU is visible (fail loud if the AMI/driver is wrong) ─
nvidia-smi || { echo "ERROR: nvidia-smi failed — no GPU/driver."; exit 1; }

# ── 1. System packages (OpenCV runtime libs for surya/opencv-headless) ──
apt-get update -y
apt-get install -y --no-install-recommends \
  git curl ca-certificates gnupg unzip jq \
  python3.10 python3.10-venv python3.10-dev python3-pip \
  build-essential libglib2.0-0 libgl1 libsm6 libxext6 libxrender1

# ── 2. AWS CLI v2 (CloudWatch agent config fetch helper; harmless if present) ─
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/awscli.zip /tmp/aws
fi

# ── 3. Clone the application ──────────────────────────────────────────
git config --system --add safe.directory "$${REPO_DIR}" || true
git clone "${repo_url}" "$${REPO_DIR}"
git -C "$${REPO_DIR}" checkout "${git_ref}"

# ── 4. Python venv + CUDA torch + app deps ────────────────────────────
python3.10 -m venv "$${VENV_DIR}"
"$${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools

# GPU torch. PyPI default already ships a CUDA build on linux-x86_64;
# torch_cuda_index lets you pin a specific CUDA wheel index if needed.
TORCH_INDEX="${torch_cuda_index}"
if [ -n "$${TORCH_INDEX}" ]; then
  "$${VENV_DIR}/bin/pip" install --index-url "$${TORCH_INDEX}" torch torchvision
else
  "$${VENV_DIR}/bin/pip" install torch torchvision
fi

# surya-ocr + FastAPI server deps (torch already satisfied -> skipped)
"$${VENV_DIR}/bin/pip" install -r "$${REPO_DIR}/requirements.txt"

# ── 5. App environment file ───────────────────────────────────────────
ENV_FILE=$${APP_DIR}/app.env
cat > "$${ENV_FILE}" <<EOF
TORCH_DEVICE=cuda
HF_HOME=$${HF_HOME_DIR}
XDG_CACHE_HOME=$${CACHE_DIR}
PYTHONUNBUFFERED=1
TOKENIZERS_PARALLELISM=false
EOF
chmod 600 "$${ENV_FILE}"

# Everything under APP_DIR owned by the service user
chown -R ubuntu:ubuntu "$${APP_DIR}"

# ── 6. systemd service ────────────────────────────────────────────────
cat > /etc/systemd/system/${project_name}.service <<EOF
[Unit]
Description=Todozee Document Reader (Surya OCR API, GPU)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=$${REPO_DIR}
EnvironmentFile=$${ENV_FILE}
ExecStart=$${VENV_DIR}/bin/python ocr_api.py
Restart=on-failure
RestartSec=10
# First boot downloads several GB of models; give it room.
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${project_name}.service
systemctl start ${project_name}.service

# ── 7. Caddy reverse proxy (auto-HTTPS) ───────────────────────────────
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

cat > /etc/caddy/Caddyfile <<EOF
{
    email ${acme_email}
}

${domain} {
    encode zstd gzip
    request_body {
        max_size 50MB
    }
    reverse_proxy 127.0.0.1:${app_port}
}
EOF

systemctl enable caddy
systemctl restart caddy

# ── 8. CloudWatch agent (memory + disk + GPU metrics, bootstrap log) ──
curl -fsSL "https://amazoncloudwatch-agent-${region}.s3.${region}.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -o /tmp/cwagent.deb || \
  curl -fsSL "https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -o /tmp/cwagent.deb
dpkg -i -E /tmp/cwagent.deb || true
rm -f /tmp/cwagent.deb

# Quoted heredoc: bash performs no expansion. Terraform still renders
# project_name before the script runs; the doubled-dollar InstanceId
# token below stays literal for the CloudWatch agent to resolve.
cat > /opt/aws/amazon-cloudwatch-agent/etc/cw-config.json <<'EOF'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "TodozeeDocReader",
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] },
      "nvidia_gpu": {
        "measurement": [
          "utilization_gpu",
          "memory_used",
          "memory_total",
          "temperature_gpu"
        ]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/bootstrap.log",
            "log_group_name": "/${project_name}/bootstrap",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/opt/${project_name}/repo/logs/ocr_api.log",
            "log_group_name": "/${project_name}/app",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/cw-config.json || true

echo "=== bootstrap finished $(date -u) ==="
