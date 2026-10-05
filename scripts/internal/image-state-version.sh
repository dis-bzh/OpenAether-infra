#!/usr/bin/env bash
# What a talos-image state holds, from `tofu state pull` on stdin, read off its objects (the root output
# image_name is rewritten by a FAILED apply): line 1 the versions they name, line 2 any deposed/tainted addresses.
# Empty = no managed object. Exit 1 = an object carries no readable version, so what it holds is unknown.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

# A version is the "-vX.Y.Z…" tail of an artifact name; Proxmox's file name drops the "v".
if ! out="$(jq -r '
  def nz: if . == null or . == "" then "unreadable" else . end;
  def ver: (. // "" | capture("-(?<v>v[0-9].*)$").v) // "unreadable";
  [.resources[]? | select(.mode == "managed") | . as $r | $r.instances[]? | {a: "\($r.type).\($r.name)", m: ($r.module // ""), i: .}] as $o
  | if ($o | length) == 0 then empty else
    ([$o[] | select(.i.deposed != null or .i.status == "tainted") | (if .m == "" then "" else "\(.m)." end) + .a] | unique) as $bad
    | ([$o[] | .i.attributes as $at |
        if   (.a == "terraform_data.build_and_upload" or .a == "terraform_data.build")
          then ($at.triggers_replace.value.version | nz)
        elif (.a == "outscale_image.talos") then ($at.image_name | ver)
        elif (.a == "scaleway_instance_image.talos" or .a == "openstack_images_image_v2.talos") then ($at.name | ver)
        elif (.a == "proxmox_virtual_environment_download_file.talos")
          then ((($at.file_name // "") | capture("^talos-(?<v>[0-9][^-]*)-nocloud").v | "v" + .) // "unreadable")
        else empty end] | unique) as $vs
    | if   ($vs | length) == 0 then error("none of its objects is an image or its build")
      elif ($vs | index("unreadable")) != null then error("an object names no readable version")
      else ($vs | join(" ")), (if ($bad | length) > 0 then ($bad | join(" ")) else empty end) end
    end' 2>&1)"; then
  printf '✗ cannot tell what this image state holds: %s\n' "$(sed -E 's/^jq: error[^)]*\): //' <<<"$out")" >&2
  exit 1
fi
[ -z "$out" ] || printf '%s\n' "$out"
