terraform {
  required_providers {
    # Default regional AWS provider
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" 
    }
    # Global S3 control plane provider (required for aws_s3control_multi_region_access_point)
    control = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Required for the null_resource CLI workaround
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
# (Other resources like aws_s3_bucket, IAM roles, etc., remain here)
# ---------------------------------------------------

# ---------------------------------------------------
# 1. DR BUCKET CREATION (Region: DR Region)
# ---------------------------------------------------

resource "aws_s3_bucket" "dr" {
  bucket = var.name
  
  tags = {
    Name        = var.context.project
    Environment = var.context.environment
  }
}

resource "aws_s3_bucket_versioning" "dr" {
  bucket = aws_s3_bucket.dr.id
  versioning_configuration {
    status = var.mirrored_versioning_status
  }
}


resource "aws_s3_bucket_public_access_block" "dr" {
  bucket = aws_s3_bucket.dr.id
  block_public_acls       = var.mirrored_pab_config.block_public_acls
  block_public_policy     = var.mirrored_pab_config.block_public_policy
  ignore_public_acls      = var.mirrored_pab_config.ignore_public_acls
  restrict_public_buckets = var.mirrored_pab_config.restrict_public_buckets
}

# ---------------------------------------------------
# 2. CRR IAM ROLE (DR -> Primary)
# ---------------------------------------------------

resource "aws_iam_role" "replication_role" {
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
  role       = aws_iam_role.replication_role.name
  policy_arn = aws_iam_policy.replication_policy.arn
}

# ---------------------------------------------------
# 3. CRR CONFIGURATION (DR -> Primary, for Failback)
# ---------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "dr_to_primary" {
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

# --- MRAP TRAFFIC DIAL WORKAROUND (REPLACING THE ERROR-PRONE RESOURCE) ---

# Extract primary and DR bucket data based on initial dial percentage
locals {
  primary_bucket_data = [for r in var.mrap_regions : r if r.traffic_dial_percentage == 100][0]
  dr_bucket_data      = [for r in var.mrap_regions : r if r.traffic_dial_percentage == 0][0]
}

data "aws_caller_identity" "current" {
  provider = control # Must use the control plane provider
}

resource "null_resource" "mrap_traffic_dial" {
  count = var.mrap_name != null ? 1 : 0

  # Trigger a replacement if the traffic dial percentages change
  triggers = {
    mrap_name          = var.mrap_name
    primary_bucket     = lookup(var.mrap_regions[0], "bucket_name", "")
    dr_bucket          = lookup(var.mrap_regions[1], "bucket_name", "")
    primary_dial       = lookup(var.mrap_regions[0], "traffic_dial_percentage", 0)
    dr_dial            = lookup(var.mrap_regions[1], "traffic_dial_percentage", 0)
    mrap_control_plane = var.mrap_control_plane_region
  }

  provisioner "local-exec" {
    # Default interpreter is assumed to be 'sh' or 'bash', suitable for non-Windows environments.
    # We are explicitly removing the Windows PowerShell interpreter here.
    
    # NOTE: The command must use standard shell syntax (e.g., echo instead of Write-Host)
    # and properly handle variables and multi-line commands.
    command = <<EOT
      # Extract Account ID from ARN
      MRAP_ARN="${aws_s3control_multi_region_access_point.dr_mrap.arn}"
      ACCOUNT_ID=$(echo $MRAP_ARN | cut -d ':' -f 5)
      PRIMARY_BUCKET_NAME="${lookup(var.mrap_regions[0], "bucket_name", "")}"
      DR_BUCKET_NAME="${lookup(var.mrap_regions[1], "bucket_name", "")}"
      PRIMARY_DIAL=${lookup(var.mrap_regions[0], "traffic_dial_percentage", 0)}
      DR_DIAL=${lookup(var.mrap_regions[1], "traffic_dial_percentage", 0)}
      CONTROL_REGION="${var.mrap_control_plane_region}"

      # Constructing the Route Update strings
      ROUTE_UPDATE_1="Bucket=${PRIMARY_BUCKET_NAME},TrafficDialPercentage=${PRIMARY_DIAL}"
      ROUTE_UPDATE_2="Bucket=${DR_BUCKET_NAME},TrafficDialPercentage=${DR_DIAL}"

      echo "Setting MRAP traffic dial via AWS CLI (Bash):"
      echo "  ${PRIMARY_BUCKET_NAME} Dial: ${PRIMARY_DIAL}%"
      echo "  ${DR_BUCKET_NAME} Dial: ${DR_DIAL}%"

      # Execute the AWS CLI command to set the routes
      aws s3control submit-multi-region-access-point-routes \
        --account-id "${ACCOUNT_ID}" \
        --mrap "${MRAP_ARN}" \
        --route-updates "${ROUTE_UPDATE_1}" "${ROUTE_UPDATE_2}" \
        --region "${CONTROL_REGION}"

      # Check exit code
      if [ $? -ne 0 ]; then
        echo "Error: AWS CLI call failed to set MRAP routes."
        exit 1
      fi

      echo "✓ MRAP Traffic dial submission complete."
EOT
  }


  depends_on = [
    aws_s3control_multi_region_access_point.dr_mrap
  ]
}
