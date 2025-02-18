provider "aws" {
  region = local.region
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

locals {
  name            = "vc-${basename(path.cwd)}"
  cluster_version = "1.31"
  region          = "us-east-1"

  tags = {
    Test       = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "../.."

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  # Disable the default self-managed addons to avoid the penalty of adopting them later
  bootstrap_self_managed_addons = false

  # Addons will be provisioned net new via the EKS addon API
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
        }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    example = {
      instance_types = ["m6i.large"]

      min_size     = 2
      max_size     = 5
      desired_size = 2
    }
  }

  tags = local.tags
}

resource "kubectl_manifest" "eni_config" {
  count = length(aws_subnet.custom_network)

  yaml_body = yamlencode({
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = aws_subnet.custom_network[count.index].availability_zone
    }
    spec = {
      securityGroups = [
        module.eks.cluster_primary_security_group_id,
        module.eks.node_security_group_id,
      ]
      subnet = aws_subnet.custom_network[count.index].id
    }
  })
}

################################################################################
# VPC
################################################################################

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  tags = local.tags
}

################################################################################
# Custom Networking
################################################################################

locals {
  custom_network_vpc_cidr = "10.99.0.0/16"

  custom_network_subnets = [for k, v in local.azs : cidrsubnet(local.custom_network_vpc_cidr, 4, k)]
}

resource "aws_vpc_ipv4_cidr_block_association" "custom_network" {
  vpc_id     = module.vpc.vpc_id
  cidr_block = local.custom_network_vpc_cidr
}

resource "aws_subnet" "custom_network" {
  count = length(local.custom_network_subnets)

  vpc_id     = module.vpc.vpc_id
  cidr_block = element(local.custom_network_subnets, count.index)

  tags = merge(
    local.tags,
    {
      # Tag for subnet discovery
      "kubernetes.io/role/cni"          = 1
      "kubernetes.io/role/internal-elb" = 1
    }
  )

  depends_on = [
    aws_vpc_ipv4_cidr_block_association.custom_network
  ]
}

resource "aws_route_table_association" "custom_network" {
  count = length(local.custom_network_subnets)

  subnet_id      = element(aws_subnet.custom_network[*].id, count.index)
  route_table_id = element(module.vpc.private_route_table_ids, 0)

  depends_on = [
    aws_vpc_ipv4_cidr_block_association.custom_network
  ]
}
