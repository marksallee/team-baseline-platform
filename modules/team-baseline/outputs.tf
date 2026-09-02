output "role_arn" {
  description = "ARN of the team's IAM role."
  value       = aws_iam_role.team.arn
}

output "bucket_names" {
  description = "Map of bucket short-name => actual bucket name as created."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "Map of bucket short-name => bucket ARN."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "public_bucket_names" {
  description = "Subset of bucket_names whose visibility is public - useful for a dashboard/audit of what's internet-readable."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket if var.buckets[k].visibility == "public" }
}
