# ---------------------------------------------------
# Outputs: Key details required after deployment
# ---------------------------------------------------

# Output the Multi-Region Access Point (MRAP) alias for client application access.
# This alias is the single, global endpoint for both primary and DR buckets.
output "mrap_aliases" {
  description = "The global endpoint alias (MRAP ARN) for each Multi-Region Access Point."
  value       = { for k, v in module.dr_s3_setup : k => v.mrap_alias }
}

# Output the ARN of the IAM Role created in the DR region, which is used by the
# primary bucket for replication permissions.
output "replication_roles" {
  description = "The ARN of the replication IAM role created by each module instance (used by the Primary bucket)."
  value       = { for k, v in module.dr_s3_setup : k => v.replication_iam_role_arn }
}

# Output the name of each newly created DR S3 bucket.
output "dr_bucket_names" {
  description = "The name of each DR S3 bucket created in us-east-2."
  value       = { for k, v in module.dr_s3_setup : k => v.s3_bucket_id }
}