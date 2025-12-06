terraform {
  # Add the required providers here, confirming the source and version.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# NOTE: The provider configurations (provider "aws" { ... }) are intentionally 
# removed from this file, as they must be defined only once in your 
# `providers.tf` file to avoid the "Duplicate provider configuration" error.

# ---------------------------------------------------
# 1. DATA SOURCES
# ---------------------------------------------------

# Standard bucket lookup to get the ARN of the primary bucket.
data "aws_s3_bucket" "primary" {
  for_each = local.dr_bucket_configurations
  bucket   = each.value.primary_bucket_name
  provider = aws.primary
}

# ---------------------------------------------------
# 2. DR Bucket Creation & Module Call
# ---------------------------------------------------

module "dr_s3_setup" {
  for_each = local.dr_bucket_configurations

  source = "../dr-s3-module"

  # Provider mapping: Link root providers to child module requirements
  providers = {
    aws     = aws.dr
    control = aws.mrap_control
  }

  context = var.context
  name    = each.value.dr_bucket_name
  mrap_control_plane_region = var.mrap_control_plane_region
  primary_versioning_id = aws_s3_bucket_versioning.primary[each.key].id

  # --- CONFIGURATION SETTINGS (Hardcoded to Secure Defaults) ---
  # These properties cannot be fetched from unmanaged buckets via data sources.

  # 1. ACL: Enforce Private
  mirrored_acl = "private"

  # 2. Versioning: Enforce Enabled (Required for Replication)
  mirrored_versioning_status = "Enabled"

  # 3. Public Access Block: Block All (Secure by default)
  mirrored_pab_config = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  # Website config is optional/null
  website_configuration = null

  # --- CRR Failback Configuration (DR -> Primary) ---
  replication_configuration = {
    rules = [{
      id                               = "ReplicateToSourceBucket"
      status                           = "Enabled"
      priority                         = 1
      delete_marker_replication_status = "Enabled"
      destinations = [{
        bucket_arn    = data.aws_s3_bucket.primary[each.key].arn
        storage_class = "STANDARD"
      }]
      filter = { prefix = "" }
    }]
  }

  # IAM Role for Replication
  replication_iam = {
    role_name   = "${each.value.dr_bucket_name}-s3-replication-role"
    policy_name = "${each.value.dr_bucket_name}-s3-replication-policy"
    destination_bucket_arns = [
      data.aws_s3_bucket.primary[each.key].arn,
      "arn:aws:s3:::${each.value.dr_bucket_name}"
    ]
  }

  # --- MRAP CONFIGURATION ---
  mrap_name = "${each.key}-mrap"
  mrap_regions = [
    {
      bucket_arn              = data.aws_s3_bucket.primary[each.key].arn
      bucket_name             = each.value.primary_bucket_name
      traffic_dial_percentage = 0
    },
    {
      # Use synthesized ARN to avoid dependency cycles
      bucket_arn              = "arn:aws:s3:::${each.value.dr_bucket_name}"
      bucket_name             = each.value.dr_bucket_name
      traffic_dial_percentage = 100
    }
  ]
}


# ---------------------------------------------------
# 3. CRR Configuration on Existing Primary Bucket (Primary -> DR)
# ---------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "primary_to_dr" {
  for_each = local.dr_bucket_configurations

  provider = aws.primary

  bucket = each.value.primary_bucket_name
  role   = module.dr_s3_setup[each.key].replication_iam_role_arn

  rule {
    id       = "ReplicateToDRBucket"
    status   = "Enabled"
    priority = 1

    destination {
      bucket = module.dr_s3_setup[each.key].s3_bucket_arn
    }
  }
}
resource "aws_s3_bucket_versioning" "primary" {
  for_each = local.dr_bucket_configurations

  provider = aws.primary # Use the primary region provider
  bucket   = each.value.primary_bucket_name

  versioning_configuration {
    status = "Enabled"
  }
}
# ---------------------------------------------------
# 4. MRAP IAM ROLE (Root Level)
# ---------------------------------------------------

resource "aws_iam_role" "mrap_role" {
  for_each = local.dr_bucket_configurations
  provider = aws.mrap_control

  name = "${each.key}-mrap-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "mrap_policy" {
  for_each = local.dr_bucket_configurations
  provider = aws.mrap_control
  name     = "${each.key}-mrap-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:PutObjectAcl"
        ]
        Resource = [
          data.aws_s3_bucket.primary[each.key].arn,
          module.dr_s3_setup[each.key].s3_bucket_arn,
          "${data.aws_s3_bucket.primary[each.key].arn}/*",
          "${module.dr_s3_setup[each.key].s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow", Action = "s3:ListAllMyBuckets", Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mrap_policy_attach" {
  for_each   = local.dr_bucket_configurations
  provider   = aws.mrap_control
  role       = aws_iam_role.mrap_role[each.key].name
  policy_arn = aws_iam_policy.mrap_policy[each.key].arn
}
