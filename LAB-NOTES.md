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
