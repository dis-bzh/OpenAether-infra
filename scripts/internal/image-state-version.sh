#!/usr/bin/env bash
# Prints the Talos version the objects of a talos-image state HOLD, from `tofu state pull` on stdin.
# Empty output = no managed object in it. Exit 1 = refused, with the reason on stderr.
#
# Read from the objects' own attributes, never from the root output image_name: an output that
# depends only on a variable is rewritten by a FAILED apply while the state still holds the old
# image (measured), and copying such a state carries its deposed objects, which the next plan
# destroys. So a deposed or tainted object, or two objects naming different versions, refuses.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }

# A version is the "-vX.Y.Z…" tail of an artifact name; Proxmox's file name drops the "v".
if ! out="$(jq -r '
  def ver: (. // "" | capture("-(?<v>v[0-9].*)$").v) // "unreadable";
  [.resources[]? | select(.mode == "managed") | . as $r | $r.instances[]? | {a: "\($r.type).\($r.name)", i: .}] as $o
  | if ($o | length) == 0 then empty else
    ([$o[] | select(.i.deposed != null or .i.status == "tainted") | .a] | unique) as $bad
    | ([$o[] | .i.attributes as $at |
        if   (.a == "terraform_data.build_and_upload" or .a == "terraform_data.build")
          then ($at.triggers_replace.value.version // "unreadable")
        elif (.a == "outscale_image.talos") then ($at.image_name | ver)
        elif (.a == "scaleway_instance_image.talos" or .a == "openstack_images_image_v2.talos") then ($at.name | ver)
        elif (.a == "proxmox_virtual_environment_download_file.talos")
          then ((($at.file_name // "") | capture("^talos-(?<v>[0-9][^-]*)-nocloud").v | "v" + .) // "unreadable")
        else empty end] | unique) as $vs
    | if   ($bad | length) > 0 then error("it holds a deposed or tainted object (\($bad | join(", "))): finish or clear it with a normal apply on the code that built it")
      elif ($vs | length) != 1 or $vs[0] == "unreadable" then error("its objects name \($vs | join(" and ")) (\"unreadable\" = no version in the attribute)")
      else $vs[0] end
    end' 2>&1)"; then
  printf '✗ this image state is not moved: %s\n' "$(sed -E 's/^jq: error[^)]*\): //' <<<"$out")" >&2
  exit 1
fi
[ -z "$out" ] || printf '%s\n' "$out"
