# SSH Keys and Access

> **This file is canonical.** There is a companion Claude doc for reading and
> commenting — <https://claude.ai/code/artifact/57126e89-c676-43e6-b119-5144ab7c4122> —
> but it is a convenience copy. When the two disagree, this one is right, because
> it is reviewed in the same pull request as the code it describes. Change this
> file first, then bring the doc across.

How people and machines authenticate to the Cassandra estate — `cassandra-infra-repo`
and `cassandra-control-repo`.

## How access works today

Three separate things have to be true before you get a shell, and they fail
differently. Most confusion here comes from mistaking one for another.

**Reachability — can you open a connection?** The nodes have no public IP, sit in
a private subnet, and the security group opens 8140, 7000–7001, 7199 and 9042.
**Port 22 is not open, and does not need to be.** SSH reaches a node through the
SSM tunnel: the SSM agent connects to `127.0.0.1:22` on the instance itself, so the
traffic never crosses the network interface and the security group never evaluates
it. No bastion, no jump host, nothing listening.

**Authentication — who are you?** Two layers, and you need both. IAM decides
whether you may open a tunnel at all (`ssm:StartSession`, scopeable by the
`pp_environment` tag Terraform writes on every instance). Your SSH key decides who
you are once the tunnel is up; keys come from the control repo via Puppet, one
account per person.

**Privilege — what can you do?** A shell, and nothing more.
`profile_ssh_access_pfpt::sudo_users` is empty at the common layer on purpose: root
on every node including production is not an estate-wide default.

The useful consequence is that these are two independent locks. Revoking someone's
IAM access shuts them out immediately even if their key is still on disk; removing
their key shuts them out even if they keep IAM. The IAM half is the one that
revokes instantly.

## One-time setup on your laptop

Three things, once.

**1. AWS CLI, signed in.** Whatever your org uses — SSO is the norm. Check with
`aws sts get-caller-identity`.

**2. The Session Manager plugin.** This is *separate* from the AWS CLI and is the
step people miss. Without it you get `SessionManagerPlugin is not found`. Install
it from [AWS's documented installer][ssm-plugin], then reopen your shell.

[ssm-plugin]: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

**3. An `~/.ssh/config` stanza**, so `ssh` and `scp` route through the tunnel:

```
Host i-* mi-*
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSH-Session --parameters 'portNumber=%p'"
```

Point `IdentityFile` at whichever key you registered in the control repo (see
**Joining** below).

**On Windows, use Git Bash, not PowerShell.** Everything here is bash. PowerShell
also writes UTF-16 when you redirect with `>>`, which silently corrupts config
files that tooling then reads as binary.

## Day to day

**Find the instance.** From `terraform/aws`:

```
terraform output nodes
terraform output puppetmaster
```

Both print instance IDs. Or filter by tag:
`aws ec2 describe-instances --filters Name=tag:pp_role,Values=puppetmaster`.

**A shell, no ssh client needed:**

```
aws ssm start-session --target i-0123456789abcdef0
```

You land as `ssm-user`; `sudo -i` for root.

**A shell as yourself, with your key:**

```
ssh i-0123456789abcdef0
```

**Copy a file off a node:**

```
scp i-0123456789abcdef0:/var/log/puppetlabs/puppetserver/puppetserver.log .
```

`rsync -e ssh`, `sftp` and VS Code Remote-SSH all work through the same stanza.

### What to look at when something is wrong

| Question | Command |
| --- | --- |
| Did first boot finish? | `sudo cat /var/lib/instance/user-data.done` — `status=ok` or it failed |
| What happened at boot? | `sudo tail -100 /var/log/cloud-init-output.log` |
| Is the agent converging? | `sudo /opt/puppetlabs/bin/puppet agent -t` |
| Is puppetserver up? | `sudo systemctl status puppetserver` |
| Did the code deploy? | `sudo ls /etc/puppetlabs/code/environments/main` |
| Are the timers armed? | `systemctl list-timers 'puppet-*'` |

On EC2 the boot log is cloud-init's, **not** `journalctl -u userdata` — that
systemd unit is the Docker lab's mechanism and does not exist here.

**If the node isn't in SSM at all**, that's egress, not the agent. Check with
`aws ssm describe-instance-information --filters "Key=InstanceIds,Values=i-..."` —
empty means it never registered. Then fall back to
`aws ec2 get-console-output --instance-id i-...`, which comes from the hypervisor
and works with no network on the box at all.

## Joining: getting your key onto the estate

Keys live in the control repo and reach every node through Puppet.
`profile_ssh_access_pfpt` is included from the product-agnostic baseline in
`manifests/site.pp`, so it applies to Cassandra, Jenkins and the master alike with
no per-product wiring.

**1. Generate a key pair.** Keep the private half on your machine and nowhere else.

```
ssh-keygen -t ed25519 -C "asmith@example.com"
```

**2. Open a pull request** against `data/common.yaml` in `cassandra-control-repo`:

```yaml
profile_ssh_access_pfpt::accounts:
  asmith:
    comment: 'Alice Smith <asmith@example.com>'
    keys:
      - 'ssh-ed25519 AAAAC3Nz... asmith@laptop'
```

Committing a **public** key exposes nothing — that is what public means. **The
review is the access-control decision**, which is the whole reason this beats
handing out a shared key.

**3. Get IAM.** The key is only half of it. You also need `ssm:StartSession` on the
instances you should reach — ask whoever administers your SSO. Scope it by tag
rather than granting the estate:

```json
{
  "Effect": "Allow",
  "Action": "ssm:StartSession",
  "Resource": "arn:aws:ec2:*:*:instance/*",
  "Condition": {
    "StringEquals": { "ssm:resourceTag/pp_environment": "nonprod" }
  }
}
```

**4. Wait for a Puppet run**, or force one. Nodes converge on their own schedule;
the master applies its own catalogue nightly at 03:20 via `puppet-agent-run.timer`.

### Sudo

Separate list, and deliberately not set estate-wide:

```yaml
profile_ssh_access_pfpt::sudo_users:
  - asmith
```

Put this at `data/customers/<customer>/<env>/common.yaml`, **never** in
`common.yaml`. It grants unrestricted `sudo ALL`, and setting it at the common
layer means a nonprod convenience is inherited into production root.

## Leaving: revoking access

> **Deleting someone's block does not revoke them.** Puppet only manages what the
> catalogue names. Drop a name from `accounts` and Puppet simply stops managing
> that account — the user, their home directory and their `authorized_keys` file
> all survive on every node, key included. You would think you had offboarded them
> and they would still have a shell.

**Do both:**

```yaml
profile_ssh_access_pfpt::accounts: {}          # their block deleted

profile_ssh_access_pfpt::absent_accounts:
  - asmith                                      # AND named here
```

`absent_accounts` is the half that actually locks the account. Names stay on that
list for as long as any node might still carry the account — a node rebuilt from a
fresh AMI never had it, but a long-lived one does until its next run. The home
directory is left in place deliberately: it holds shell history, which is evidence.

**Pull their IAM at the same time.** This is the half that takes effect immediately
— remove them from the SSO group granting `ssm:StartSession` and they cannot open a
tunnel, whatever is still on disk.

### For a compromised key, not a planned departure

Puppet is eventually-consistent: `runinterval` is 30 minutes, so a removed key
stays usable until each node's next run, longer if an agent is wedged. That is fine
for someone leaving on good terms and **not** fine for a leaked key.

In that case, cut the network path first — revoke the IAM permission — then let
Puppet catch up. Force convergence where it matters:

```
sudo /opt/puppetlabs/bin/puppet agent -t
```

## The machine keys

Four credentials exist that are not people. They are easy to confuse, and each
fails differently.

| Key | Who uses it | Lives in | Without it |
| --- | --- | --- | --- |
| Control repo deploy key | The master, at first boot | Secrets Manager, fetched by instance role | Master cannot clone; build fails |
| r10k key | The master, on every scheduled deploy | eyaml in the control repo | Merges never reach the master |
| EC2 key pair (`key_name`) | Break-glass ssh | `~/.ssh/<key_name>.pem`, created by `bootstrap-account.sh` | No fallback if Puppet-managed keys are absent |
| `cassy` key | CI, via `profile_cassy_access_pfpt` | Jenkins credential store | `cassy.sh` pipelines fail |

### Why the master needs two separate git keys

This is the non-obvious one. `30-role-puppetmaster.sh` fetches the deploy key from
Secrets Manager, clones with it, and then **scrubs it from disk** — deliberately,
so no root process keeps a standing read credential for the control repo.

So r10k starts with nothing. Against an SSH remote every scheduled deploy would
fail to authenticate, leaving a failed systemd unit nobody watches while the estate
quietly runs week-old code. `r10k_private_key` gives it its own copy, and
`puppetmaster_pfpt` fails the catalogue by name if a deploy schedule is set against
an SSH remote with no key.

### The failure that looks like something else

If the deploy key is missing, the clone fails with:

```
Cloning into '/etc/puppetlabs/code/environments/main'...
Host key verification failed.
```

**That is not a `known_hosts` problem.** With no key, `GIT_SSH_COMMAND` is never
set, so git runs without the `-o StrictHostKeyChecking=accept-new` that would have
accepted github.com's host key. A missing credential presenting as a host-key
error.

Three things to check, in order: the `control_repo_deploy_key_secret_id` tag on the
instance; the instance profile's `secretsmanager:GetSecretValue` on that secret —
note it is scoped by **ARN**, so setting only the secret *id* in tfvars builds a
role without the permission; and whether the AWS CLI is present, since Ubuntu
images do not ship it.

## Break-glass

The uncomfortable property of this design: **the mechanism that grants access is
the one that breaks.** If Puppet is wedged, the keys are stale or absent — and
Puppet is what would have fixed them. Same between an instance's first boot and its
first successful run.

In rough order of what to reach for:

**1. SSM Session Manager.** Independent of Puppet, sshd and the control repo. Works
whenever the agent is alive and has egress — which covers most of what people call
"I can't get in".

```
aws ssm start-session --target i-0123456789abcdef0
```

**2. The EC2 key pair.** `key_name` is set precisely for this. It's a shared key,
so it isn't the daily path, but it survives Puppet being broken.

**3. EC2 Serial Console.** Genuinely out-of-band — works when networking is
entirely gone and SSM is dark. It needs a user with a password set, so configure
that in Puppet *before* you need it. Untested here; worth a dry run.

**4. Replace the node.** Usually the right answer. If a node is sick enough that
SSM is down, terminate it — everything is in the control repo and a new one
converges in minutes. This is why `disable_api_termination = true` is set on the
*master* specifically: it is the one node that is not cheap to replace.

The complement to all of this is shipping logs off the box. Most debugging that
currently needs a shell wouldn't.

## Known gaps

Stated plainly so nobody discovers them at 2am.

**Revocation is not instant.** Up to 30 minutes for a key to disappear from a node,
longer if an agent is wedged. IAM revocation is the instant half; use it first when
it matters.

**Keys never expire.** Nothing ages a key out. An engineer's key is valid until
somebody removes it, so `accounts` needs a periodic read-through — the same
discipline as any access list. Short-lived certificates (Teleport, an SSH CA) are
the grown-up answer if the estate outgrows this.

**No recurring convergence is confirmed on non-master nodes.** `puppet.conf` sets
`runinterval = 30m`, but nothing in `user-data` enables the `puppet` **service**,
and it ships disabled on Ubuntu. If nothing turns it on, Cassandra and Jenkins
nodes converge once at boot and never again — which would mean key changes never
reach them. **This needs checking against a live node.** It may be intentional,
with runs driven by Rundeck or Jenkins.

**Code deployment to the master is manual.** `puppet-code-deploy.timer` ships
disabled because r10k has no credential until the eyaml ceremony is done. Until
then, a merge reaches the master only by hand:

```
sudo git -C /etc/puppetlabs/code/environments/main pull
sudo /opt/puppetlabs/bin/puppet agent -t
```

**SSM is a single point of failure for reachability.** No port 22 means no
independent network path. Mitigated by the break-glass options above, none of which
have been exercised in anger here.

**This is AWS-only.** `ssm:StartSession` does not exist elsewhere. If the estate
goes hybrid or multi-cloud, the transport needs rethinking — the key-distribution
half of this design carries over unchanged.
