output "cluster_name" {
  description = "EKS cluster identifier"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API Server URL"
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "VPC ID where cluster is hosted"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Command to configure kubectl credentials"
  value       = "aws eks --region ${var.aws_region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "helm_history_bucket_name" {
  description = "S3 bucket receiving Helm release history reports"
  value       = aws_s3_bucket.helm_history.bucket
}
