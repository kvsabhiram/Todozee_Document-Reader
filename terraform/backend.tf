# Remote state backend — S3 (versioned + encrypted) with S3-native state
# locking (use_lockfile). The bucket is created out-of-band (AWS CLI bootstrap),
# since a backend can't live in the state it stores. See DEPLOYMENT.md.
#
# Backend config must be static literals (no variables/interpolation allowed).
terraform {
  backend "s3" {
    bucket       = "todozee-doc-reader-tfstate-637560253183"
    key          = "todozee-doc-reader/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # S3-native state locking (replaces the deprecated DynamoDB lock)
  }
}
