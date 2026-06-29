# Deployment — Todozee Document Reader (Surya OCR API, GPU)

Infrastructure-as-code (Terraform) + CI/CD (GitHub Actions) for running the
Surya OCR FastAPI server (`ocr_api.py`) on a single GPU EC2 instance in
**ap-south-1 (Mumbai)**.

## Architecture

```
Internet ──▶ Caddy (:443 auto-HTTPS) ──▶ uvicorn/FastAPI 127.0.0.1:8040
              docreader.chatbucket.chat        (ocr_api.py, systemd service)
EC2 g4dn.xlarge (NVIDIA T4 16GB, Ubuntu 22.04 DLAMI, 100GB gp3) + Elastic IP
IAM role (SSM + CloudWatch) · CloudWatch agent (mem/disk/GPU) · CW alarms
```

- **GPU inference** — the instance boots from the AWS *Deep Learning Base GPU
  AMI* (NVIDIA driver + CUDA preinstalled); the bootstrap installs a CUDA
  build of torch. `TORCH_DEVICE=cuda` is forced so a missing GPU fails loud.
- **Models** download automatically on first run from Surya's public CDN
  (~several GB, no auth token needed) and cache under
  `/opt/todozee-doc-reader/model-cache` + `hf-cache`.

## Layout on the instance

```
/opt/todozee-doc-reader/
├── repo/          # git checkout (CI/CD pulls here; ocr_api.py at its root)
├── venv/          # Python 3.10 virtualenv (CUDA torch + surya-ocr)
├── hf-cache/      # HF_HOME (tokenizer/config cache)
├── model-cache/   # XDG_CACHE_HOME (Surya datalab model cache)
└── app.env        # systemd EnvironmentFile
repo/logs/         # ocr_api.log (daily-rotated) + annotated debug PNGs
```

Service: `todozee-doc-reader.service` runs `venv/bin/python ocr_api.py`
(uvicorn on `0.0.0.0:8040`). Caddy reverse-proxies `:443` → `:8040`.

## Endpoints

| Method | Path           | What it does                            |
|--------|----------------|-----------------------------------------|
| GET    | `/health`      | Health check (`models_loaded` flag)     |
| POST   | `/ocr`         | Upload image/PDF → text + bboxes        |
| GET    | `/logs`        | List log files + annotated images       |
| GET    | `/logs/{name}` | Download a specific log/annotated image |

## Provision

```bash
cd terraform
terraform init
terraform apply              # creates SSH key, SG, IAM, EC2 GPU, EIP, alarms
terraform output             # public_ip, ssh_command, health_url, ...
```

State is **local** (no remote backend). The generated SSH private key is
written to `terraform/todozee-doc-reader-key.pem` (gitignored).

> **GPU quota note:** g4dn/g5 instances draw from the *Running On-Demand G and
> VT instances* vCPU quota (8 in this account/region). If `apply` fails with
> `VcpuLimitExceeded`, free capacity or raise the quota (Service Quotas code
> `L-DB2E81BA`) before retrying.

## CI/CD

- **`.github/workflows/deploy-ci.yml`** — byte-compiles `ocr_api.py` /
  `client.py` on every push (sanity check; the upstream Surya library keeps
  its own `ci.yml`).
- **`.github/workflows/deploy.yml`** — on push to `main`, SSHes to the
  instance, `git reset --hard origin/main`, `pip install -r requirements.txt`,
  restarts the service, waits for `/health`.

Required GitHub repository **secrets**:

| Secret        | Value                                                    |
|---------------|----------------------------------------------------------|
| `EC2_HOST`    | Elastic IP (`terraform output public_ip`)                |
| `EC2_SSH_KEY` | Contents of `terraform/todozee-doc-reader-key.pem`       |
| `EC2_USER`    | `ubuntu` (optional; default)                             |

## DNS + HTTPS

`chatbucket.chat` is managed outside this AWS account, so add an **A-record**
manually: `docreader.chatbucket.chat → <public_ip>`. Caddy obtains a Let's
Encrypt cert via HTTP-01 once the record resolves (restart Caddy if it boot-
looped before DNS was live: `sudo systemctl restart caddy`).

## Smoke test

```bash
# Over IP before DNS (HTTP, Caddy will redirect to HTTPS once cert issued):
curl -F file=@invoice.pdf http://<public_ip>/ocr        # via Caddy
# Or directly against uvicorn through an SSH tunnel:
ssh -i terraform/todozee-doc-reader-key.pem -L 8040:127.0.0.1:8040 ubuntu@<public_ip>
curl -s http://127.0.0.1:8040/health
```

## Teardown

```bash
cd terraform
terraform destroy
```
