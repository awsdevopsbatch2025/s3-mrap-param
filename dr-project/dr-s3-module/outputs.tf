# ---------------------------------------------------
# Outputs: Values passed back to the Root Module
# ---------------------------------------------------

# 1. Output the ARN of the newly created DR bucket (needed by the Primary CRR config)
output "s3_bucket_arn" {
  description = "The ARN of the newly created DR S3 bucket."
  # FIX: Changed resource name from dr_bucket to dr
  value       = aws_s3_bucket.dr.arn
}

# 2. Output the ID (name) of the newly created DR bucket (useful for reference)
output "s3_bucket_id" {
  description = "The ID/Name of the newly created DR S3 bucket."
  # FIX: Changed resource name from dr_bucket to dr
  value       = aws_s3_bucket.dr.id
}

# 3. Output the IAM role ARN for replication (needed by the Primary CRR config)
output "replication_iam_role_arn" {
  description = "The ARN of the IAM role used by the DR bucket for replication."
  value       = aws_iam_role.replication_role.arn
}

# 4. Output the global MRAP alias (needed for client access)
output "mrap_alias" {
  description = "The Multi-Region Access Point alias used for global client access."
  # FIX: Changed attribute name to the correct 'alias'
  value       = aws_s3control_multi_region_access_point.dr_mrap.alias
}
