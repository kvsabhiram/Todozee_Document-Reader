variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_name" {
  description = "Short name used to tag and name resources."
  type        = string
  default     = "todozee-doc-reader"
}

variable "instance_type" {
  description = "EC2 instance type. GPU inference -> g4dn.xlarge (NVIDIA T4 16GB, 4 vCPU / 16 GB)."
  type        = string
  default     = "g4dn.xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB. DLAMI base snapshot is 75GB; leave headroom for CUDA torch + Surya model cache + annotated logs."
  type        = number
  default     = 100
}

variable "domain" {
  description = "Public hostname Caddy serves with auto-HTTPS."
  type        = string
  default     = "docreader.chatbucket.chat"
}

variable "acme_email" {
  description = "Email used by Caddy/Let's Encrypt for ACME registration."
  type        = string
  default     = "udathak@gmail.com"
}

variable "repo_url" {
  description = "Git repository cloned onto the instance."
  type        = string
  default     = "https://github.com/kvsabhiram/Todozee_Document-Reader.git"
}

variable "git_ref" {
  description = "Git branch/tag/commit to check out."
  type        = string
  default     = "main"
}

variable "app_port" {
  description = "Port the FastAPI/uvicorn app listens on (see ocr_api.py)."
  type        = number
  default     = 8040
}

variable "torch_cuda_index" {
  description = "Optional PyTorch wheel index override. Empty = PyPI default, which already ships a CUDA build on Linux x86_64 (matched to the DLAMI driver). Set e.g. https://download.pytorch.org/whl/cu126 to pin."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to reach SSH (port 22). Lock this down to your IP for production."
  type        = string
  default     = "0.0.0.0/0"
}
