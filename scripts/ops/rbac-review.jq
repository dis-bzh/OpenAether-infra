# The RBAC review, as data: one line per (binding, subject), tab-separated:
#   scope  namespace  binding  role  subject-kind  subject  verdict
# verdict is "-" or a comma list of: HUMAN (a User/Group that is not a built-in system: identity),
# ANON (system:anonymous / system:unauthenticated is bound), ADMIN (cluster-admin through a binding that is not
# on the allowlist). The allowlist is passed as --argjson allow {"exact":[…],"prefixes":[…]} and is the same one
# cluster-security-tests.sh 3.7 uses. A binding with no subjects still gets a line, so it is reviewed too.
def allowed($name): ($allow.exact | index($name)) != null or any($allow.prefixes[]; . as $p | $name | startswith($p));
# The two ClusterRoleBindings of the apps platform-rbac brick, for named people's client certificates (kubeconfig-new.sh):
# EXACTLY this binding name, this role and this one group. Anything else bound to oa:admins / oa:readers, or another
# subject on these names, is still flagged.
def platform($scope; $name; $role; $s):
  $scope == "cluster" and $s.kind == "Group" and
  (($name == "oa-admins" and $role == "cluster-admin" and $s.name == "oa:admins") or
   ($name == "oa-readers" and $role == "view" and $s.name == "oa:readers"));
.items[]
| (if .kind == "ClusterRoleBinding" then "cluster" else "namespace" end) as $scope
| .metadata as $m
| .roleRef.name as $role
| ((.subjects // [{"kind": "-", "name": "(no subject)"}])[])
| . as $s
| [ (if ($s.kind == "User" or $s.kind == "Group") and ($s.name | startswith("system:") | not)
        and (platform($scope; $m.name; $role; $s) | not) then "HUMAN" else empty end),
    # The stock Kubernetes binding that lets anyone read /healthz, /livez, /readyz and /version: present on every cluster (seen
    # flagged on a real OVH and Scaleway cluster). Only that binding to that role is exempt; anything else bound to
    # system:anonymous / system:unauthenticated stays flagged.
    (if ($s.name == "system:anonymous" or $s.name == "system:unauthenticated")
        and ($m.name == "system:public-info-viewer" and $role == "system:public-info-viewer" | not) then "ANON" else empty end),
    (if $role == "cluster-admin" and (allowed($m.name) | not) and (platform($scope; $m.name; $role; $s) | not) then "ADMIN" else empty end)
  ] as $flags
| [$scope, ($m.namespace // "-"), $m.name, $role, $s.kind,
   (if $s.namespace then "\($s.namespace)/\($s.name)" else $s.name end),
   (if ($flags | length) == 0 then "-" else $flags | join(",") end)]
| @tsv
