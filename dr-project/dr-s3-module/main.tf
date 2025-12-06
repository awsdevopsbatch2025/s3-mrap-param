terraform {
  required_providers {
    # 1. Standard AWS Provider (for S3 Buckets, IAM)
    # Required to satisfy the root module's explicit mapping: aws = aws.dr
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" 
    }
    
    # 2. Global S3 Control Plane Provider (for MRAP)
    # Required for resources that need the control plane (us-east-1) region.
    control = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # 3. Null Provider
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

variable "mrap_control_plane_region" {
  description = "The region where the S3 MRAP control plane is managed (e.g., us-east-1). This is required for the AWS CLI call."
  type        = string
}

# ---------------------------------------------------
# 1. DR BUCKET CREATION (Region: DR Region)
# *** EXPLICITLY set provider = aws (maps to aws.dr) ***
# ---------------------------------------------------

resource "aws_s3_bucket" "dr" {
  provider = aws 
  
  bucket = var.name
  
  tags = {
    Name        = var.context.project
    Environment = var.context.environment
  }
}

resource "aws_s3_bucket_versioning" "dr" {
  provider = aws 
  
  bucket = aws_s3_bucket.dr.id
  versioning_configuration {
    status = var.mirrored_versioning_status
  }
}


resource "aws_s3_bucket_public_access_block" "dr" {
  provider = aws 

  bucket = aws_s3_bucket.dr.id
  block_public_acls       = var.mirrored_pab_config.block_public_acls
  block_public_policy     = var.mirrored_pab_config.block_public_policy
  ignore_public_acls      = var.mirrored_pab_config.ignore_public_acls
  restrict_public_buckets = var.mirrored_pab_config.restrict_public_buckets
}

# ---------------------------------------------------
# 2. CRR IAM ROLE (DR -> Primary)
# *** EXPLICITLY set provider = aws (maps to aws.dr) ***
# ---------------------------------------------------

resource "aws_iam_role" "replication_role" {
  provider = aws 
  
  name = var.replication_iam.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "replication_policy" {
  provider = aws 
  
  name = var.replication_iam.policy_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Permissions for S3 to inspect the DR bucket (List, Get)
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = var.replication_iam.destination_bucket_arns[1] 
      },
      # Permissions for S3 to read objects/versions from the DR bucket
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectACL",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${var.replication_iam.destination_bucket_arns[1]}/*"
      },
      # Permissions for S3 to write replicated objects to both buckets
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = var.replication_iam.destination_bucket_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "replication_attach" {
  provider = aws 

  role      = aws_iam_role.replication_role.name
  policy_arn = aws_iam_policy.replication_policy.arn
}

# ---------------------------------------------------
# 3. CRR CONFIGURATION (DR -> Primary, for Failback)
# *** EXPLICITLY set provider = aws (maps to aws.dr) ***
# ---------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "dr_to_primary" {
  provider = aws 

  bucket = aws_s3_bucket.dr.id
  role   = aws_iam_role.replication_role.arn
  
  depends_on = [
    var.primary_versioning_id
  ]

  dynamic "rule" {
    for_each = var.replication_configuration.rules
    content {
      id       = rule.value.id
      status   = rule.value.status
      priority = rule.value.priority
      
      dynamic "delete_marker_replication" {
        for_each = try(rule.value.delete_marker_replication_status == "Enabled" ? [1] : [], [])
        content {
          status = "Enabled"
        }
      }

      dynamic "destination" {
        for_each = rule.value.destinations
        content {
          bucket        = destination.value.bucket_arn
          storage_class = destination.value.storage_class
        }
      }

      dynamic "filter" {
        for_each = try(rule.value.filter != null ? [rule.value.filter] : [], [])
        content {
          prefix = filter.value.prefix
        }
      }
    }
  }
}

# ---------------------------------------------------
# 4. MULTI-REGION ACCESS POINT (MRAP) & TRAFFIC ROUTING
# *** EXPLICITLY set provider = control ***
# ---------------------------------------------------

resource "aws_s3control_multi_region_access_point" "dr_mrap" {
  provider = control 
  
  details {
    name = var.mrap_name

    dynamic "region" {
      for_each = var.mrap_regions
      content {
        bucket = region.value.bucket_name
      }
    }
  }
}

# --- MRAP TRAFFIC DIAL WORKAROUND ---

# Extract primary and DR bucket data based on initial dial percentage
locals {
  primary_bucket_data = [for r in var.mrap_regions : r if r.traffic_dial_percentage == 100][0]
  dr_bucket_data      = [for r in var.mrap_regions : r if r.traffic_dial_percentage == 0][0]
}

data "aws_caller_identity" "current" {
  provider = control 
}

resource "null_resource" "mrap_traffic_dial" {
  count = var.mrap_name != null ? 1 : 0

  # Trigger a replacement if the traffic dial percentages change
  triggers = {
    mrap_arn           = aws_s3control_multi_region_access_point.dr_mrap.arn 
    primary_bucket     = lookup(var.mrap_regions[0], "bucket_name", "")
    dr_bucket          = lookup(var.mrap_regions[1], "bucket_name", "")
    primary_dial       = lookup(var.mrap_regions[0], "traffic_dial_percentage", 0)
    dr_dial            = lookup(var.mrap_regions[1], "traffic_dial_percentage", 0)
    mrap_control_plane = var.mrap_control_plane_region
  }

  provisioner "local-exec" {
    # *** FIX FOR WINDOWS: Use CMD as the interpreter. ***
    # Note: Command substitution logic is simplified as we are using interpolated HCL strings.
    interpreter = ["cmd", "/C"]
    
    command = <<EOT
      @echo off
      SET MRAP_ARN=%TF_VAR_mrap_arn%
      SET ACCOUNT_ID=%TF_VAR_account_id%

      # Pass Terraform values as environment variables since string interpolation inside cmd scripts is complex
      
      echo Setting MRAP traffic dial via AWS CLI (CMD):
      echo   Primary Bucket Dial: ${lookup(var.mrap_regions[0], "traffic_dial_percentage", 0)}%%
      echo   DR Bucket Dial: ${lookup(var.mrap_regions[1], "traffic_dial_percentage", 0)}%%

      # The ARN extraction is complex in CMD, let's use the full ARN directly from the resource output.
      # The MRAP ARN has the format: arn:aws:s3::ACCOUNT_ID:accesspoint/ALIAS.mrap
      
      REM Execute the AWS CLI command to set the routes
      aws s3control submit-multi-region-access-point-routes ^
        --account-id ${data.aws_caller_identity.current.account_id} ^
        --mrap ${aws_s3control_multi_region_access_point.dr_mrap.arn} ^
        --route-updates "Bucket=${lookup(var.mrap_regions[0], "bucket_name", "")},TrafficDialPercentage=${lookup(var.mrap_regions[0], "traffic_dial_percentage", 0)}" "Bucket=${lookup(var.mrap_regions[1], "bucket_name", "")},TrafficDialPercentage=${lookup(var.mrap_regions[1], "traffic_dial_percentage", 0)}" ^
        --region ${var.mrap_control_plane_region}

      REM Check exit code (Errorlevel) - AWS CLI returns 0 on success
      IF %ERRORLEVEL% NEQ 0 (
        echo Error: AWS CLI call failed to set MRAP routes.
        exit 1
      )

      echo ^✓ MRAP Traffic dial submission complete.
EOT
  }


  depends_on = [
    aws_s3control_multi_region_access_point.dr_mrap
  ]
}
