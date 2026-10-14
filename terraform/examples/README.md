# Examples

How to call every module in this library. Each snippet lists **only the required
inputs** — everything else has a default in the module's `variables.tf`, so start
here and add options as you need them.

A runnable, wired-together stack lives in [`complete/`](complete/) — read that one
to see how the modules feed each other. The snippets below are per-module reference.

Generated from `modules/*/variables.tf`. If a snippet disagrees with the module,
the module wins.

Modules are sourced by relative path inside this repository (`../../modules/<name>` from a stack); there are no tags to pin.

| Module | Inputs | Required | |
|---|---|---|---|
| [`acm`](#acm) | 8 | 2 |  |
| [`alb`](#alb) | 26 | 4 |  |
| [`cloudwatch`](#cloudwatch) | 10 | 1 |  |
| [`dynamodb`](#dynamodb) | 3 | 1 |  |
| [`ec2`](#ec2) | 7 | 2 |  |
| [`ecr`](#ecr) | 5 | 1 |  |
| [`ecs-cluster`](#ecs-cluster) | 14 | 1 |  |
| [`ecs-service`](#ecs-service) | 41 | 5 |  |
| [`eks`](#eks) | 23 | 4 |  |
| [`elasticache`](#elasticache) | 27 | 3 |  |
| [`iam`](#iam) | 12 | 1 |  |
| [`kms`](#kms) | 3 | 1 |  |
| [`lambda`](#lambda) | 6 | 1 |  |
| [`rds`](#rds) | 36 | 6 |  |
| [`route53`](#route53) | 7 | 1 |  |
| [`s3`](#s3) | 10 | 1 |  |
| [`secrets_manager`](#secrets_manager) | 3 | 1 |  |
| [`security-groups`](#security-groups) | 20 | 3 |  |
| [`sns`](#sns) | 3 | 1 |  |
| [`sqs`](#sqs) | 3 | 1 |  |
| [`vpc`](#vpc) | 25 | 2 |  |
| [`waf`](#waf) | 8 | 1 |  |

---

## acm

```hcl
module "acm" {
  source = "../../modules/acm"

  domain_name = "api.example.com"
  zone_id     = module.route53.zone_id

  tags        = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `domain_name` | `string` | Primary domain for the certificate, e.g. "app.example.com" or "*.example.com". |
| `zone_id` | `string` | Route53 hosted zone ID where the DNS validation records are written. Comes from the route53 mod… |

## alb

```hcl
module "alb" {
  source = "../../modules/alb"

  name               = "${local.name_prefix}-alb"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.ecs_sg_id]

  tags               = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Load balancer name. Must be 32 characters or fewer — AWS rejects longer names, and the error ar… |
| `vpc_id` | `string` | VPC the load balancer and its target groups live in. From the foundation: module.vpc.vpc_id. |
| `subnet_ids` | `list(string)` | Subnets to place the load balancer in — at least two, in different AZs. Public subnets for an i… |
| `security_group_ids` | `list(string)` | Security groups for the load balancer. From module.security_groups.alb_sg_id. |

## cloudwatch

```hcl
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  name = "${local.name_prefix}-cloudwatch"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix, conventionally "<project>-<environment>". |

## dynamodb

```hcl
module "dynamodb" {
  source = "../../modules/dynamodb"

  name_prefix = local.name_prefix

  tables = {
    orders = {
      hash_key   = "pk"
      attributes = [{ name = "pk", type = "S" }]
    }
  }

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name_prefix` | `string` | Table names become "<name_prefix>-<key>". |

## ec2

```hcl
module "ec2" {
  source = "../../modules/ec2"

  name               = "${local.name_prefix}-ec2"
  security_group_ids = [module.security_groups.ecs_sg_id]

  tags               = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix. Each instance is named "<name>-<key>". |
| `security_group_ids` | `list(string)` | Security groups applied to every instance. From module.security_groups.ec2_sg_id. |

## ecr

```hcl
module "ecr" {
  source = "../../modules/ecr"

  name = "${local.name_prefix}-ecr"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix. Repository names become "<name>/<key>" unless use_name_prefix is false. |

## ecs-cluster

```hcl
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  cluster_name = "${local.name_prefix}-ecscluster"

  tags         = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `cluster_name` | `string` | ECS cluster name, conventionally "<project>-<environment>-ecs". |

## ecs-service

```hcl
module "ecs_service" {
  source = "../../modules/ecs-service"

  name               = "${local.name_prefix}-ecsservice"
  cluster_arn        = module.ecs_cluster.arn
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.ecs_sg_id]
  containers         = {
    api = {
      image     = "111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/api:v1.4.2"
      essential = true
      port_mappings = [{ containerPort = 8080, protocol = "tcp" }]
    }
  }

  tags               = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Service name, conventionally "<project>-<environment>-<app>". Also the task definition family. |
| `cluster_arn` | `string` | ECS cluster the service runs in. From the foundation: module.ecs_cluster.arn. |
| `subnet_ids` | `list(string)` | Subnets the task ENIs are created in. Private subnets only — see assign_public_ip in main.tf fo… |
| `security_group_ids` | `list(string)` | Security groups attached to the task ENIs. From module.security_groups.ecs_sg_id. This module n… |
| `containers` | `map(object` |  |

## eks

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "${local.name_prefix}-eks"
  kubernetes_version = "1.31"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  tags               = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `cluster_name` | `string` | EKS cluster name. |
| `kubernetes_version` | `string` | Kubernetes minor version, e.g. "1.31". EKS supports a narrow window of versions; a cluster left… |
| `vpc_id` | `string` | VPC the cluster runs in. From the foundation: module.vpc.vpc_id. This module never creates a VP… |
| `subnet_ids` | `list(string)` | Subnets for the node groups and the cluster ENIs. Private subnets: module.vpc.private_subnet_id… |

## elasticache

```hcl
module "elasticache" {
  source = "../../modules/elasticache"

  name               = "${local.name_prefix}-elasticache"
  subnet_group_name  = module.vpc.elasticache_subnet_group_name
  security_group_ids = [module.security_groups.ecs_sg_id]

  tags               = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Replication group identifier, e.g. "dev-redis". |
| `subnet_group_name` | `string` | ElastiCache subnet group. From module.vpc.elasticache_subnet_group_name, which spans the databa… |
| `security_group_ids` | `list(string)` | Security groups for the cache nodes. From module.security_groups.elasticache_sg_id. |

## iam

```hcl
module "iam" {
  source = "../../modules/iam"

  name = "${local.name_prefix}-iam"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix for every role and policy, conventionally "<project>-<environment>". |

## kms

```hcl
module "kms" {
  source = "../../modules/kms"

  name = "${local.name_prefix}-kms"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix, conventionally "<project>-<environment>". Aliases become alias/<name>-<key>. |

## lambda

```hcl
module "lambda" {
  source = "../../modules/lambda"

  name = "${local.name_prefix}-lambda"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix. Each function is named "<name>-<key>". |

## rds

```hcl
module "rds" {
  source = "../../modules/rds"

  identifier           = "${local.name_prefix}-rds"
  engine_version       = "16.4"
  family               = "postgres16"
  major_engine_version = "16"
  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ids   = [module.security_groups.ecs_sg_id]

  tags                 = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `identifier` | `string` | DB instance identifier, e.g. "dev-postgres". |
| `engine_version` | `string` | Engine version, e.g. "16.4" for PostgreSQL or "8.0.39" for MySQL. |
| `family` | `string` | Parameter group family, e.g. "postgres16" or "mysql8.0". Must match engine_version's major — a … |
| `major_engine_version` | `string` | Major engine version for the option group, e.g. "16" or "8.0". |
| `db_subnet_group_name` | `string` | DB subnet group. From module.vpc.database_subnet_group_name. Those subnets have no internet gat… |
| `security_group_ids` | `list(string)` | Security groups for the instance. From module.security_groups.rds_sg_id, which allows the datab… |

## route53

```hcl
module "route53" {
  source = "../../modules/route53"

  zone_name = "example.com"

  tags      = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `zone_name` | `string` | Hosted zone name, e.g. "example.com". Used to create the zone when create_zone is true, and to … |

## s3

```hcl
module "s3" {
  source = "../../modules/s3"

  name = "${local.name_prefix}-artifacts"

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Bucket name. Globally unique; the caller decides it. |

## secrets_manager

```hcl
module "secrets_manager" {
  source = "../../modules/secrets_manager"

  name_prefix = local.name_prefix

  secrets = {
    stripe-api-key = {}
  }

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name_prefix` | `string` | Secret names become "<name_prefix>/<key>"; values are set out of band. |

## security-groups

```hcl
module "security_groups" {
  source = "../../modules/security-groups"

  name           = "${local.name_prefix}-securitygroups"
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  tags           = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix for every security group, conventionally "<project>-<environment>". |
| `vpc_id` | `string` | VPC the security groups belong to. Comes from the foundation: module.vpc.vpc_id. |
| `vpc_cidr_block` | `string` | VPC CIDR. Used only where a security group reference is impossible — ALB egress to targets, who… |

## sns

```hcl
module "sns" {
  source = "../../modules/sns"

  name_prefix = local.name_prefix

  topics = {
    orders = {}
  }

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name_prefix` | `string` | Topic names become "<name_prefix>-<key>". |

## sqs

```hcl
module "sqs" {
  source = "../../modules/sqs"

  name_prefix = local.name_prefix

  queues = {
    orders = { dead_letter = {} }
  }

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name_prefix` | `string` | Queue names become "<name_prefix>-<key>". |

## vpc

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = "10.0.0.0/16"

  tags       = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Name prefix for the VPC and every subnet, route table and gateway inside it. Conventionally "<p… |
| `cidr_block` | `string` | IPv4 CIDR for the VPC. A /16 gives the default subnet layout room to grow; anything smaller tha… |

## waf

```hcl
module "waf" {
  source = "../../modules/waf"

  name = local.name_prefix

  associate_resource_arns = { alb = module.alb.arn }

  tags = local.tags
}
```

| Required input | Type | Purpose |
|---|---|---|
| `name` | `string` | Web ACL name. |
