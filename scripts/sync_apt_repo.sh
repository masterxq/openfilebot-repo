#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_REPO:?SOURCE_REPO must be set}"
: "${KEEP_VERSIONS:=5}"
: "${APT_GPG_PRIVATE_KEY:?APT_GPG_PRIVATE_KEY must be set}"
: "${APT_GPG_PASSPHRASE:?APT_GPG_PASSPHRASE must be set}"
: "${APT_GPG_KEY_ID:?APT_GPG_KEY_ID must be set}"

ROOT_DIR="$(pwd)"
WORK_DIR="${ROOT_DIR}/work"
OUT_DIR="${ROOT_DIR}/public"
APT_DIR="${OUT_DIR}/apt"

rm -rf "${WORK_DIR}" "${OUT_DIR}"
mkdir -p "${WORK_DIR}" "${APT_DIR}" "${APT_DIR}/pool/stable" "${APT_DIR}/pool/testing" "${APT_DIR}/keyrings"

# Import signing key for Release/InRelease generation.
export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
printf '%s' "${APT_GPG_PRIVATE_KEY}" | gpg --batch --import

# Export public key in both armored and dearmored form for apt clients.
gpg --batch --yes --output "${APT_DIR}/keyrings/openfilebot-archive-keyring.gpg" --export "${APT_GPG_KEY_ID}"
gpg --batch --yes --armor --output "${APT_DIR}/keyrings/openfilebot-archive-keyring.asc" --export "${APT_GPG_KEY_ID}"

RELEASES_JSON="${WORK_DIR}/releases.json"
gh api "repos/${SOURCE_REPO}/releases?per_page=100" > "${RELEASES_JSON}"

# stable: final releases only, testing: both final + prerelease. Keep only latest N each.
jq -r --argjson keep "${KEEP_VERSIONS}" '
  [ .[] | select(.draft == false and .prerelease == false) ]
  | sort_by(.published_at) | reverse | .[:$keep] | .[].tag_name
' "${RELEASES_JSON}" > "${WORK_DIR}/stable-tags.txt"

jq -r --argjson keep "${KEEP_VERSIONS}" '
  [ .[] | select(.draft == false) ]
  | sort_by(.published_at) | reverse | .[:$keep] | .[].tag_name
' "${RELEASES_JSON}" > "${WORK_DIR}/testing-tags.txt"

if [[ ! -s "${WORK_DIR}/stable-tags.txt" && ! -s "${WORK_DIR}/testing-tags.txt" ]]; then
  echo "No non-draft releases found in ${SOURCE_REPO}."
  exit 1
fi

download_release_debs() {
  local tag="$1"
  local target="$2"
  local dl_dir="${WORK_DIR}/downloads/${tag}"

  mkdir -p "${dl_dir}" "${target}"

  if gh release download "${tag}" -R "${SOURCE_REPO}" -p "*.deb" -D "${dl_dir}" 2>/dev/null; then
    shopt -s nullglob
    local files=("${dl_dir}"/*.deb)
    if (( ${#files[@]} > 0 )); then
      cp -f "${dl_dir}"/*.deb "${target}/"
      echo "Imported ${#files[@]} .deb assets from ${tag} into $(basename "${target}")"
    else
      echo "No .deb assets in ${tag}"
    fi
    shopt -u nullglob
  else
    echo "Skipping ${tag} (download failed or no matching assets)"
  fi
}

while IFS= read -r tag; do
  [[ -n "${tag}" ]] || continue
  download_release_debs "${tag}" "${APT_DIR}/pool/stable"
done < "${WORK_DIR}/stable-tags.txt"

while IFS= read -r tag; do
  [[ -n "${tag}" ]] || continue
  download_release_debs "${tag}" "${APT_DIR}/pool/testing"
done < "${WORK_DIR}/testing-tags.txt"

generate_dist() {
  local dist="$1"
  local pool_dir="${APT_DIR}/pool/${dist}"
  local dists_root="${APT_DIR}/dists/${dist}"
  local component_dir="${dists_root}/main"

  mkdir -p "${component_dir}"

  local arches=""
  if compgen -G "${pool_dir}/*.deb" > /dev/null; then
    arches="$(for deb in "${pool_dir}"/*.deb; do dpkg-deb -f "${deb}" Architecture; done | sort -u | xargs)"
  fi

  if [[ -z "${arches}" ]]; then
    echo "No packages found for ${dist}; creating empty metadata"
    arches="amd64"
  fi

  for arch in ${arches}; do
    local arch_dir="${component_dir}/binary-${arch}"
    mkdir -p "${arch_dir}"
    apt-ftparchive -a "${arch}" packages "${pool_dir}" > "${arch_dir}/Packages"
    gzip -n -9 -f -c "${arch_dir}/Packages" > "${arch_dir}/Packages.gz"
  done

  apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=OpenFileBot" \
    -o "APT::FTPArchive::Release::Label=OpenFileBot" \
    -o "APT::FTPArchive::Release::Suite=${dist}" \
    -o "APT::FTPArchive::Release::Codename=${dist}" \
    -o "APT::FTPArchive::Release::Architectures=${arches}" \
    -o "APT::FTPArchive::Release::Components=main" \
    release "${dists_root}" > "${dists_root}/Release"

  gpg --batch --yes --pinentry-mode loopback --passphrase "${APT_GPG_PASSPHRASE}" --default-key "${APT_GPG_KEY_ID}" \
    --armor --detach-sign --output "${dists_root}/Release.gpg" "${dists_root}/Release"

  gpg --batch --yes --pinentry-mode loopback --passphrase "${APT_GPG_PASSPHRASE}" --default-key "${APT_GPG_KEY_ID}" \
    --clearsign --output "${dists_root}/InRelease" "${dists_root}/Release"
}

generate_dist stable
generate_dist testing

cat > "${OUT_DIR}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>OpenFileBot APT Repository</title>
</head>
<body>
  <h1>OpenFileBot APT Repository</h1>
  <p>Use the instructions from the source project README to configure apt sources.</p>
  <ul>
    <li><a href="./apt/">APT root</a></li>
    <li><a href="./apt/keyrings/openfilebot-archive-keyring.asc">ASCII public key</a></li>
    <li><a href="./apt/keyrings/openfilebot-archive-keyring.gpg">GPG public keyring</a></li>
  </ul>
</body>
</html>
HTML

touch "${OUT_DIR}/.nojekyll"
