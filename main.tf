data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  helm_history_bucket_name = "helm-history-${data.aws_caller_identity.current.account_id}-${substr(sha256("${var.cluster_name}-${var.aws_region}"), 0, 8)}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs            = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.public_subnets
  control_plane_subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    testing_nodes = {
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
      subnet_ids     = module.vpc.public_subnets
    }
  }

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true
}

resource "helm_release" "test_namespace_baseline" {
  name             = "test-namespace-baseline"
  chart            = "${path.module}/charts/namespace-baseline"
  namespace        = "workload-test-2"
  create_namespace = true
  wait             = false
  values = [
    file("${path.module}/charts/namespace-baseline/values.yaml")
  ]
  depends_on = [module.eks]
}

data "aws_iam_policy_document" "helm_history_uploader_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:cronjob-report:helm-history-uploader"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "helm_history_uploader" {
  name               = substr("${var.cluster_name}-helm-history-uploader", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.helm_history_uploader_trust.json
}

data "aws_iam_policy_document" "helm_history_s3_write" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.helm_history.arn}/*"]
  }
}

resource "aws_iam_role_policy" "helm_history_s3_write" {
  name   = "write-helm-history-to-s3"
  role   = aws_iam_role.helm_history_uploader.id
  policy = data.aws_iam_policy_document.helm_history_s3_write.json
}

resource "aws_s3_bucket" "helm_history" {
  bucket = local.helm_history_bucket_name
}

resource "aws_s3_bucket_public_access_block" "helm_history" {
  bucket                  = aws_s3_bucket.helm_history.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "helm_history" {
  bucket = aws_s3_bucket.helm_history.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "helm_history" {
  bucket = aws_s3_bucket.helm_history.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "helm_release" "helm_history_report" {
  name             = "helm-history-report"
  chart            = "${path.module}/charts/helm-history-report"
  namespace        = "cronjob-report"
  create_namespace = true
  wait             = false

  values = [
    yamlencode({
      history = {
        targetNamespace = "workload-test-2"
        releaseName     = "test-namespace-baseline"
      }
      storage = {
        bucketName = aws_s3_bucket.helm_history.bucket
        region     = var.aws_region
      }
      serviceAccount = {
        uploaderRoleArn = aws_iam_role.helm_history_uploader.arn
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_iam_role_policy.helm_history_s3_write,
    aws_s3_bucket_public_access_block.helm_history,
    aws_s3_bucket_ownership_controls.helm_history,
    aws_s3_bucket_server_side_encryption_configuration.helm_history,
    helm_release.test_namespace_baseline,
  ]
}
