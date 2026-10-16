"""provider-contract.md § 4, "Security groups": no inbound rule may be open to
the whole Internet by a LITERAL range.

CKV_OA_2 cannot cover Outscale (its security groups have no default-policy
attribute), so a hand-written `ip_range = "0.0.0.0/0"` on an Inbound rule would
pass the hard gate unseen. Admin and LB ranges here come from variables
(`var.admin_ip` is allowed to hold /0 by an explicit, documented choice made in
tfvars, not in code); a literal /0 in the module is always a mistake.
Egress rules are out of scope: a /0 there is the normal internet path.
"""

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


class InboundNoWorldOpen(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name="Outscale inbound security group rule must not use a literal /0 range",
            id="CKV_OA_3",
            categories=[CheckCategories.NETWORKING],
            supported_resources=["outscale_security_group_rule"],
        )

    def scan_resource_conf(self, conf):
        flow = conf.get("flow")
        if not flow or flow[0] != "Inbound":
            return CheckResult.PASSED
        ranges = conf.get("ip_range") or []
        for r in ranges:
            # A string literal ending in /0 (0.0.0.0/0, ::/0, any-address/0);
            # a variable reference is a string like "var.x" and does not match.
            if isinstance(r, str) and r.endswith("/0"):
                return CheckResult.FAILED
        return CheckResult.PASSED


check = InboundNoWorldOpen()
