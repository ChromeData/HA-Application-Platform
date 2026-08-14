# Lab Notes, 13 Highly Available Application Platform

Running log. Built across sessions.

---

### Session 1: remote state and the network

**Remote state first, before anything else.** Every solo portfolio project runs
local state, and it works right up until a second engineer exists. Then two
applies race and the last write silently wins, and the state file, which holds
every credential the config touched in plain text, is sitting in somebody's
home directory.

So: S3 bucket, versioned and encrypted, with a DynamoDB table holding the lock.
Bootstrap is its own root with local state, because you cannot store the
backend's state in the backend it is creating.

Details worth keeping:

- `prevent_destroy` on the state bucket. It is the record of what exists in the
  account; losing it means reconciling live infrastructure by hand.
- A bucket policy denying any request where `aws:SecureTransport` is false.
  State is the one object guaranteed to contain secrets, so it should never
  move over plain HTTP.
- `PAY_PER_REQUEST` on the lock table. A lock is a few writes a day, and
  provisioned capacity bills hourly for nothing.
- The hash key MUST be named `LockID`. Terraform requires that exact
  attribute and a different name fails at init with an unhelpful error.

**Proved the lock actually blocks**, rather than assuming it. Wrote a lock item
into DynamoDB by hand to simulate a teammate mid-apply, then ran a plan:

```
Error: Error acquiring the state lock
Lock Info: ... "Who":"teammate@laptop"
```

Deleted the item, plan ran clean. That is the entire value of remote state,
demonstrated in about thirty seconds.

**The network.** Two availability zones, because an AZ is the failure domain: a
separate physical facility with its own power. One subnet in one AZ is the most
common reason a "highly available" design is not.

Availability zones are queried from the API rather than hardcoded, because
`us-east-1a` is not the same building for two different accounts. AWS shuffles
the mapping per account.

Private subnets have no default route at all, same as lab 12. Nothing here
needs outbound internet, which also avoids a NAT gateway at roughly $32 a
month. And the AWS default security group is stripped from the start, since
lab 12's verifier already taught me it ships wide open.

**Typo caught before it reached AWS:** wrote `count front = 0` on the public
subnet. `terraform validate` rejected it. That is the argument for validating
in CI rather than finding out at apply time.

Cost so far: effectively zero. S3 holding 20KB, a DynamoDB table taking a few
writes, and free networking primitives.

---

### Session 2: compute, and the design conflict I built for myself

Load balancer across both AZs, autoscaling group of two in the private subnets,
health checks driving replacement.

**Every instance failed its health check forever.** Zero healthy targets after
six minutes, ALB returning 502.

The cause was mine. `user_data` ran `dnf install -y nginx`, and the private
subnets have no route off the network, by design, from session 1. Package repos
unreachable, install hangs, nothing ever listens on port 80.

That is the real conflict: I built the network for isolation and then wrote a
deploy that assumes internet access. It shows up constantly in actual
environments and the instinct is always to punch a hole.

Two ways out. A NAT gateway, about $32 a month, which puts an outbound path
back into a tier that is supposed to have none. Or stop needing the internet:
Amazon Linux 2023 ships Python, so it can serve the page with nothing
downloaded. Took the second. Cheaper and a better posture, which is usually how
that trade lands.

Other choices worth recording:

- `health_check_type = "ELB"` on the autoscaling group, not the default EC2.
  EC2 only asks whether the instance is running, so a host whose web server has
  died stays in service indefinitely. ELB means the group replaces anything the
  balancer will not send traffic to, which is the behaviour people assume they
  already have.
- Health thresholds are asymmetric on purpose: two successes to come back,
  three failures to go out. Slow to trust, quick to evict.
- `http_tokens = "required"`, forcing IMDSv2. A server side request forgery in
  the app can reach the metadata endpoint and steal the instance role under
  IMDSv1. v2 needs a PUT for a token first, which a blind SSRF cannot do.
- The AMI is looked up, not pinned. An AMI id is regional and gets replaced
  constantly.

---

### Session 3: broke it on purpose

Terminated a live instance and polled every ten seconds. Traffic moved to the
surviving AZ, the autoscaling group launched a replacement, and it was serving
about sixty seconds later.

**11 requests served, 1 failed.**

The failure is the finding. The health check runs every 15 seconds and needs 3
consecutive failures before the balancer stops routing to a dead target, so
there is a window of up to 45 seconds where traffic still goes to something
that is gone. Tightening the interval shrinks the window and raises the odds a
briefly slow instance gets evicted for nothing. No setting removes it. Closing
it properly takes client retries, or connection draining with a lifecycle hook
so the instance leaves the pool before it dies rather than after.

Highly available means automatic recovery without a human. It does not mean
zero dropped requests, and a two AZ setup does not give you zero downtime no
matter what the diagram implies.

**A false positive I nearly shipped.** The first run of the chaos test grabbed
`Instances[0]` from the autoscaling group and terminated it. Every request
succeeded, and it looked like a clean pass. That instance was already
terminated, a stale entry from the earlier replacement. The test killed
something dead and produced exactly the output a successful test produces.

Caught it by checking `LifecycleState` instead of trusting the list. The real
run is the one above, which is why it has a failure in it.

Full output in `findings/chaos-test-real-aws.txt`.

---
