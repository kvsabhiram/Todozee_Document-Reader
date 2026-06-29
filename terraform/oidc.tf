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

data "aws_caller_identity" "current" {}

# Read-only/plan role trust: ANY ref or PR in this repo (not forks) may assume
# it. Safe because the role is read-only (+ TF state) and used only by `plan`.
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
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
  description = "Read-only/plan IAM role ARN for GitHub Actions (no stored keys)."
  value       = aws_iam_role.gha_oidc.arn
}

# ─────────────────────────────────────────────────────────────────────
# Apply role — write access for `terraform apply` in CI. Trust is locked
# to refs/heads/main ONLY (PRs/branches cannot assume it), and the apply
# workflow is manual (workflow_dispatch + typed confirmation), so an
# accidental GPU-instance rebuild can't happen unattended.
# ─────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "gha_apply_assume" {
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

resource "aws_iam_role" "gha_apply" {
  name                 = "${var.project_name}-gha-apply"
  description          = "GitHub Actions (main, manual) OIDC role for terraform apply."
  assume_role_policy   = data.aws_iam_policy_document.gha_apply_assume.json
  max_session_duration = 3600
}

# Full access to all services EXCEPT IAM/Organizations (covers ec2, eip, sg,
# cloudwatch, route53, sns, s3). IAM is granted narrowly below.
resource "aws_iam_role_policy_attachment" "gha_apply_poweruser" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Narrowly-scoped IAM: manage only this project's roles/instance-profiles.
data "aws_iam_policy_document" "gha_apply_iam" {
  statement {
    sid = "ManageProjectIAM"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:UpdateRoleDescription", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfilesForRole", "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-*",
    ]
  }
  statement {
    sid       = "PassProjectRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"]
  }
  statement {
    sid = "ReadIAMForPlan"
    actions = [
      "iam:GetOpenIDConnectProvider", "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:ListPolicyVersions", "iam:ListEntitiesForPolicy", "iam:ListRoles",
      "iam:ListInstanceProfiles",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_apply_iam" {
  name   = "${var.project_name}-gha-apply-iam"
  role   = aws_iam_role.gha_apply.id
  policy = data.aws_iam_policy_document.gha_apply_iam.json
}

# Same Terraform-state S3 access as the plan role.
resource "aws_iam_role_policy" "gha_apply_state" {
  name   = "${var.project_name}-gha-apply-tfstate"
  role   = aws_iam_role.gha_apply.id
  policy = data.aws_iam_policy_document.gha_state.json
}

output "gha_apply_role_arn" {
  description = "Write/apply IAM role ARN for GitHub Actions (main, manual dispatch)."
  value       = aws_iam_role.gha_apply.arn
}
