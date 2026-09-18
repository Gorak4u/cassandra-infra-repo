# ===========================================================================
# terraform/aws/dns.tf -- private DNS for the estate
# ===========================================================================
# WHY THIS EXISTS, because the estate ran without it for a while and the
# failure was misread twice.
#
# Nothing here is cosmetic. Two separate mechanisms resolve estate hostnames
# by NAME and have no fallback to an address:
#
#   1. Every agent connects to its master as `server = <certname>` in
#      puppet.conf. With no zone the run dies before TLS with
#      "getaddrinfo: Name or service not known", which reads as a network or
#      firewall problem and is neither.
#
#   2. locals.tf sets wait_for = "<prefix><i-1>.<domain>" when a cluster is
#      serialized, so cass2 waits on cass1 BY NAME and cass3 on cass2. That is
#      how Cassandra's refusal to bootstrap concurrently is respected, and it
#      cannot work without resolution between nodes.
#
# The master papers over (1) for ITSELF with an /etc/hosts entry written by
# 30-role-puppetmaster.sh, because on that one host the name is by definition
# the local machine. No agent can do the same: it has no way to learn the
# master's address.
#
# bootstrap-account.sh upserts the master's A record, but only when a zone
# already exists -- it never creates one, and prints "add manually" otherwise.
# This file is what makes the zone exist.

# ---------------------------------------------------------------------------
# The zone
# ---------------------------------------------------------------------------
# PRIVATE, and associated with this VPC alone. The estate's domain is internal
# (nonprod.amex.internal): it must not be resolvable from the internet, and a
# public zone for a name you do not own would not work anyway.
#
# Records are managed here rather than by the nodes themselves. A node that
# registers its own DNS needs write access to the zone, which is a credential
# worth avoiding for a value Terraform already knows.
resource "aws_route53_zone" "private" {
  count = var.create_vpc && var.create_dns_zone ? 1 : 0

  name = local.domain

  vpc {
    vpc_id = aws_vpc.this[0].id
  }

  # The zone is not the nodes' data -- destroying the estate should take it
  # with them, otherwise a rebuild inherits stale records pointing at dead
  # addresses, which is worse than no records at all.
  force_destroy = true

  tags = merge(local.common_tags, { Name = local.domain })
}

# ---------------------------------------------------------------------------
# One A record per node
# ---------------------------------------------------------------------------
# The map key of local.nodes IS the certname, which IS the fully-qualified
# name every other part of the estate uses -- puppet.conf, wait_for, the
# master's dns_alt_names and its autosign_certname_pattern all spell it the
# same way. So the record name needs no construction here, and cannot drift
# from the certname by construction.
#
# for_each is gated on the VARIABLES rather than on the zone's id. Gating on
# aws_route53_zone.private[0].zone_id would make the for_each depend on a value
# unknown until apply, which Terraform rejects outright at plan time.
resource "aws_route53_record" "node" {
  for_each = (var.create_dns_zone || var.dns_zone_id != null) ? local.nodes : {}

  zone_id = var.dns_zone_id != null ? var.dns_zone_id : aws_route53_zone.private[0].zone_id
  name    = each.key
  type    = "A"

  # 60s deliberately, against the usual advice to raise TTLs. These addresses
  # change whenever an instance is replaced, which during a build is often, and
  # a resolver holding a five-minute record for a dead node produces agent runs
  # that fail against an address nothing is listening on. Query volume on an
  # estate this size is not worth optimising for.
  ttl = 60

  records = [aws_instance.node[each.key].private_ip]
}
