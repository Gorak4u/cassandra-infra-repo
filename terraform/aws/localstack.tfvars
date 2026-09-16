# ===========================================================================
# LocalStack -- apply the whole stack against a mock, with no AWS account
# ===========================================================================
# See var.aws_endpoint_url. This exercises the RESOURCE GRAPH; it does not
# build a node. LocalStack's EC2 instances are mock records, not VMs.
#
# Easiest path:
#   ./test-with-localstack.sh
#
# Manual path:
#   docker run -d --name localstack -p 4566:4566 \
#     -e SERVICES=ec2,iam,secretsmanager,sts,s3,kms localstack/localstack:3
#   export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
#   # backend=false skips the S3 backend block: LocalStack's S3 works too, but
#   # is not needed to test the resource graph.
#   terraform init -backend=false
#   terraform workspace new ls-dc_east 2>/dev/null || terraform workspace select ls-dc_east
#   terraform apply -var-file=localstack.tfvars
aws_endpoint_url = "http://localhost:4566"

region      = "us-east-1"
customer    = "amex"
environment = "nonprod"
datacenter  = "dc_east"
products    = ["cassandra"]

dns_domain    = "lab.pfpt"
puppet_server = "pm1.lab.pfpt"

# One of the AMIs LocalStack ships. Irrelevant to the mock -- it is recorded
# and never booted -- but it must EXIST or RunInstances is refused.
ami_id = "ami-1e749f67"

# Create everything, to exercise the widest path.
create_vpc            = true
vpc_cidr              = "10.80.0.0/16"
availability_zones    = ["us-east-1a", "us-east-1b", "us-east-1c"]
create_nat_gateway    = true
create_security_group = true
create_iam_role       = true
attach_ssm_policy     = true

join_secret_id  = "amex/nonprod/puppet-join-secret"
join_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:amex/nonprod/puppet-join-secret-gUZuwA"

data_volume_size_gb = 20

# LocalStack's ModifyInstanceAttribute is a no-op, so this cannot be verified
# here. It defaults TRUE and stays true in the real tfvars.
disable_api_termination = false
