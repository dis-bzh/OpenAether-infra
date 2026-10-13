# The RBAC review, as data: one line per (binding, subject), tab-separated:
#   scope  namespace  binding  role  subject-kind  subject  verdict
# verdict is "-" or a comma list of: HUMAN (a User/Group that is not a built-in system: identity),
# ANON (system:anonymous / system:unauthenticated is bound), ADMIN (cluster-admin through a binding that is not
# on the allowlist). The allowlist is passed as --argjson allow {"exact":[…],"prefixes":[…]} and is the same one
# cluster-security-tests.sh 3.7 uses. A binding with no subjects still gets a line, so it is reviewed too.
def allowed($name): ($allow.exact | index($name)) != null or any($allow.prefixes[]; . as $p | $name | startswith($p));
.items[]
| (if .kind == "ClusterRoleBinding" then "cluster" else "namespace" end) as $scope
| .metadata as $m
| .roleRef.name as $role
| ((.subjects // [{"kind": "-", "name": "(no subject)"}])[])
| . as $s
| [ (if ($s.kind == "User" or $s.kind == "Group") and ($s.name | startswith("system:") | not) then "HUMAN" else empty end),
    (if $s.name == "system:anonymous" or $s.name == "system:unauthenticated" then "ANON" else empty end),
    (if $role == "cluster-admin" and (allowed($m.name) | not) then "ADMIN" else empty end)
  ] as $flags
| [$scope, ($m.namespace // "-"), $m.name, $role, $s.kind,
   (if $s.namespace then "\($s.namespace)/\($s.name)" else $s.name end),
   (if ($flags | length) == 0 then "-" else $flags | join(",") end)]
| @tsv
