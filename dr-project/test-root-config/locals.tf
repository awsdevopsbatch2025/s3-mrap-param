locals {
  # This configuration map defines all the S3 buckets we need to mirror, 
  # including their source (primary) and destination (DR) regions/names.
  dr_bucket_configurations = {
    # Key: A unique identifier for the loop (e.g., a short functional name)
    "marketing-reports" = {
      primary_region      = "us-east-1"
      dr_region           = "us-east-2" # Matches the 'dr' provider alias
      primary_bucket_name = "my-dr-test-bkt"
      dr_bucket_name      = "my-dr-test-bkt-dr"
    }
    # IMPORTANT: You will add your remaining 98 bucket entries here,
    # following the same structure.
  }
}