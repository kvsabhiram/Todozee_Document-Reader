# ─────────────────────────────────────────────────────────────────────
# GitHub Actions OIDC — lets CI assume a short-lived AWS role with NO
# long-lived keys. Trust is scoped to this repo's main branch only.
# ─────────────────────────────────────────────────────────────────────

variable "github_repo" {
  description = "owner/repo allowed to assume the CI role via OIDC."
  type        = string
  default     = "kvsabhiram/Todozee_Document-Reader"
}

variable "state_bucket" {
  description = "S3 bucket holding the Terraform remote state (see backend.tf)."
  type        = string
  default     = "todozee-doc-reader-tfstate-637560253183"
}

# The GitHub OIDC provider already exists in this account — reference it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Trust policy: only GitHub Actions runs on refs/heads/main of github_repo,
# presenting an STS-audience token, may assume this role.
data "aws_iam_policy_document" "gha_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_oidc" {
  name                 = "${var.project_name}-gha-oidc"
  description          = "GitHub Actions (main) OIDC role for CI - read + TF state, no long-lived keys."
  assume_role_policy   = data.aws_iam_policy_document.gha_assume.json
  max_session_duration = 3600
}

# Read-only across the account so `terraform plan` can refresh state.
# (Apply-level write permissions are intentionally NOT granted yet — add them
# behind a GitHub Environment approval when wiring apply-on-merge.)
resource "aws_iam_role_policy_attachment" "gha_readonly" {
  role       = aws_iam_role.gha_oidc.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Read/write the Terraform state object + lock file in the state bucket.
data "aws_iam_policy_document" "gha_state" {
  statement {
    sid       = "StateObject"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "gha_state" {
  name   = "${var.project_name}-gha-tfstate"
  role   = aws_iam_role.gha_oidc.id
  policy = data.aws_iam_policy_document.gha_state.json
}

output "gha_oidc_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC (no stored keys)."
  value       = aws_iam_role.gha_oidc.arn
}
