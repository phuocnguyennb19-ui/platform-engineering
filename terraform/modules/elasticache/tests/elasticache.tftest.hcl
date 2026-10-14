mock_provider "aws" {}

variables {
  name                   = "platform-dev-redis"
  description            = "platform-dev cache"
  engine_version         = "7.1"
  node_type              = "cache.t4g.small"
  parameter_group_family = "redis7"
  subnet_group_name      = "platform-dev-cache"
  security_group_ids     = ["sg-0123456789abcdef0"]
}

# Encryption is on both ways by default. A cache holding session data is as sensitive as the
# database it fronts, and transit encryption cannot be turned on later without a replacement.
run "encryption_is_on_by_default_both_ways" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.this.at_rest_encryption_enabled
    error_message = "at-rest encryption must default on"
  }

  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled
    error_message = "transit encryption must default on"
  }
}

# kms_key_id must not be set when at-rest encryption is off: the pair is rejected at apply, which
# is the slowest place to find out.
run "the_kms_key_follows_at_rest_encryption" {
  command = plan
  variables {
    at_rest_encryption_enabled = false
    kms_key_arn                = "arn:aws:kms:ap-southeast-1:111122223333:key/abcd-1234"
  }

  assert {
    condition     = aws_elasticache_replication_group.this.kms_key_id == null
    error_message = "a key must not be sent when at-rest encryption is off"
  }
}

# Cluster mode decides which sizing fields are legal; the module picks one set, so a caller cannot
# send both and have AWS reject the pair. Only the set that is written is assertable at plan: the
# other is Optional+Computed, so Terraform reports it unknown rather than null.
run "cluster_mode_off_sizes_by_cache_clusters" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.this.num_cache_clusters == 2
    error_message = "with cluster mode off the group is sized by num_cache_clusters"
  }
}

run "cluster_mode_on_sizes_by_shards" {
  command = plan
  variables {
    cluster_mode_enabled    = true
    num_node_groups         = 3
    replicas_per_node_group = 1
  }

  assert {
    condition     = aws_elasticache_replication_group.this.num_node_groups == 3 && aws_elasticache_replication_group.this.replicas_per_node_group == 1
    error_message = "with cluster mode on the group is sized by shards and replicas"
  }
}

# Multi-AZ without automatic failover is not a configuration AWS accepts, and the caller should not
# have to know that.
run "multi_az_is_forced_off_without_automatic_failover" {
  command = plan
  variables {
    automatic_failover_enabled = false
    multi_az_enabled           = true
  }

  assert {
    condition     = !aws_elasticache_replication_group.this.multi_az_enabled
    error_message = "multi-AZ requires automatic failover; the module must not pass the rejected pair through"
  }
}

# A snapshot window is only meaningful while snapshots are retained; the module drops it at zero
# retention. Only the retained case is assertable at plan — snapshot_window is Optional+Computed,
# so the dropped one reads as unknown rather than null.
run "the_snapshot_window_is_passed_through_while_snapshots_are_retained" {
  command = plan
  variables {
    snapshot_retention_limit = 7
    snapshot_window          = "03:00-04:00"
  }

  assert {
    condition     = aws_elasticache_replication_group.this.snapshot_window == "03:00-04:00"
    error_message = "the window the caller chose must reach the replication group"
  }

  assert {
    condition     = aws_elasticache_replication_group.this.snapshot_retention_limit == 7
    error_message = "the retention the caller chose must reach the replication group"
  }
}

run "backups_are_retained_by_default" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.this.snapshot_retention_limit > 0
    error_message = "the default must retain snapshots: a cache is a restore target after a failover"
  }
}

# The parameter group name carries the family with dots stripped, because ElastiCache rejects them.
run "the_parameter_group_name_strips_the_family_dots" {
  command = plan
  variables {
    parameter_group_family = "redis7.x"
  }

  assert {
    condition     = aws_elasticache_parameter_group.this.name == "platform-dev-redis-redis7x"
    error_message = "dots are not legal in a parameter group name"
  }
}
