#!/usr/bin/env bash

set -euo pipefail

# Resolve the highest GA (generally available) stream tag for a SUSE BCI image,
# skipping beta / tech-preview streams.
#
# Argument:
#   <image-ref>   e.g. registry.suse.com/bci/bci-base
#
# The registry's `latest` tag points at the previous GA major (currently 15.7),
# so it cannot be used to track the 16.x line. Instead we enumerate the bare
# `X.Y` stream tags and pick the highest one whose image config labels mark it
# as GA:
#   GA:   com.suse.supportlevel = l3           and com.suse.eula = sle-bci
#   BETA: com.suse.supportlevel = techpreview  and com.suse.eula = sle-beta
#
# A stream is treated as GA only when supportlevel != techpreview AND
# eula != sle-beta. Missing/unknown labels are treated as NON-GA (skipped) to
# stay on the safe side. Prints the selected stream tag (e.g. "16.0") to stdout.

if (( $# != 1 )); then
  echo "usage: $0 <image-ref>" >&2
  exit 2
fi

ref="$1"
registry="registry.suse.com"
# Strip an optional registry.suse.com/ prefix to get the repository path.
repo="${ref#${registry}/}"

api_authorize="https://scc.suse.com/api/registry/authorize"
service="SUSE Linux Docker Registry"

token="$(curl -fsSL --get \
  --data-urlencode "service=${service}" \
  --data-urlencode "scope=repository:${repo}:pull" \
  "${api_authorize}" | jq -r '.token')"

if [[ -z "${token}" || "${token}" == "null" ]]; then
  echo "failed to obtain registry token for ${repo}" >&2
  exit 1
fi

auth=(-H "Authorization: Bearer ${token}")
accept_index='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
accept_manifest='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# Bare X.Y stream tags, sorted DESCENDING by numeric major then minor.
streams=()
while IFS= read -r stream_tag; do
  [[ -n "${stream_tag}" ]] && streams+=("${stream_tag}")
done < <(
  curl -fsSL "${auth[@]}" "https://${registry}/v2/${repo}/tags/list" \
    | jq -r '.tags[]' \
    | grep -E '^[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1nr -k2,2nr
)

if (( ${#streams[@]} == 0 )); then
  echo "no bare stream tags found for ${repo}" >&2
  exit 1
fi

resolve_labels() {
  # Print "supportlevel<TAB>eula" for the amd64 image of the given stream tag.
  local tag="$1" index amd64_digest manifest config_digest
  index="$(curl -fsSL "${auth[@]}" -H "Accept: ${accept_index}" \
    "https://${registry}/v2/${repo}/manifests/${tag}")"

  # If it's a manifest list/index, pick the linux/amd64 manifest; otherwise the
  # response is already a single-arch manifest.
  amd64_digest="$(jq -r '
    if .manifests then
      (.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest)
    else empty end' <<<"${index}" | head -n1)"

  if [[ -n "${amd64_digest}" ]]; then
    manifest="$(curl -fsSL "${auth[@]}" -H "Accept: ${accept_manifest}" \
      "https://${registry}/v2/${repo}/manifests/${amd64_digest}")"
  else
    manifest="${index}"
  fi

  config_digest="$(jq -r '.config.digest' <<<"${manifest}")"
  if [[ -z "${config_digest}" || "${config_digest}" == "null" ]]; then
    return 1
  fi

  curl -fsSL -L "${auth[@]}" "https://${registry}/v2/${repo}/blobs/${config_digest}" \
    | jq -r '.config.Labels as $l
        | [($l["com.suse.supportlevel"] // ""), ($l["com.suse.eula"] // "")]
        | @tsv'
}

for tag in "${streams[@]}"; do
  if labels="$(resolve_labels "${tag}")"; then
    supportlevel="$(cut -f1 <<<"${labels}")"
    eula="$(cut -f2 <<<"${labels}")"
    if [[ -n "${supportlevel}" && "${supportlevel}" != "techpreview" \
          && -n "${eula}" && "${eula}" != "sle-beta" ]]; then
      echo "selected GA stream ${tag} (supportlevel=${supportlevel}, eula=${eula})" >&2
      echo "${tag}"
      exit 0
    fi
    echo "skipping non-GA stream ${tag} (supportlevel=${supportlevel:-unknown}, eula=${eula:-unknown})" >&2
  else
    echo "skipping stream ${tag} (could not resolve labels)" >&2
  fi
done

echo "no GA stream tag found for ${repo}" >&2
exit 1
