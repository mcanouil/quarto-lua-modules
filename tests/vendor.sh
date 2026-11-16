#!/usr/bin/env bash
#
# Tests for scripts/vendor.sh. Every test runs offline: the origin is a local
# directory laid out like a release, read through a file:// address.
#
# Run it directly, from any directory:
#
#     tests/vendor.sh
#
# @license MIT
# @copyright 2026 Mickaël Canouil
# @author Mickaël Canouil

set -euo pipefail

# vendor.sh needs bash 4.4, so this suite does too.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] ||
	((BASH_VERSINFO[0] < 4)) ||
	((BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)); then
	printf 'Error: the test suite needs bash 4.4 or newer, and this is bash %s.\n' \
		"${BASH_VERSION:-unknown}" >&2
	exit 1
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VENDOR="${TESTS_DIR}/../scripts/vendor.sh"
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

check() {
	local name="$1" status="$2"
	if [[ "${status}" == "0" ]]; then
		passed=$((passed + 1))
		printf 'ok   %s\n' "${name}"
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n' "${name}"
	fi
}

# A release of the fixture module: its bytes and its licence, at one version.
publish() {
	local version="$1" body="$2"
	mkdir -p "${WORK}/upstream/releases/download/${version}" "${WORK}/upstream/raw/${version}"
	printf '%s\n' "${body}" >"${WORK}/upstream/releases/download/${version}/string.lua"
	printf 'MIT License\n' >"${WORK}/upstream/raw/${version}/LICENSE"
}

digest() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

publish 1.0.0 'return {version = 1}'
publish 2.0.0 'return {version = 2}'

cat >"${WORK}/sources.list" <<EOF
source demo file://${WORK}/upstream {origin}/releases/download/{version}/{file} 1.0.0 MIT -
file demo string.lua
EOF

# An extension that declares the 1.0.0 release, with the checksum of that file.
repo="${WORK}/repo"
ext="${repo}/_extensions/owner/ext"
mkdir -p "${ext}"
write_manifest() {
	local version="$1" sha="$2"
	cat >"${ext}/_dependencies.yml" <<EOF
schema: 1
sources:
  demo:
    origin: "file://${WORK}/upstream"
    fetch: "{origin}/releases/download/{version}/{file}"
    version: "${version}"
    licence: MIT
    files:
      string.lua:
        sha256: "${sha}"
        runtime: any
EOF
}
sha_v1="$(digest "${WORK}/upstream/releases/download/1.0.0/string.lua")"
sha_v2="$(digest "${WORK}/upstream/releases/download/2.0.0/string.lua")"
write_manifest 1.0.0 "${sha_v1}"

# --sync writes the declared file and its licence, and verifies the checksum.
if "${VENDOR}" --repository "${repo}" --sync >/dev/null 2>&1 &&
	cmp -s "${ext}/_vendor/demo/string.lua" "${WORK}/upstream/releases/download/1.0.0/string.lua" &&
	[[ -f "${ext}/_vendor/demo/LICENSE" ]]; then
	check "sync writes the declared file and its licence" 0
else
	check "sync writes the declared file and its licence" 1
fi

# --sync refuses a file whose checksum does not match the manifest.
write_manifest 1.0.0 "$(printf '0%.0s' {1..64})"
if output="$("${VENDOR}" --repository "${repo}" --sync 2>&1)"; then
	check "sync refuses a checksum that does not match" 1
elif [[ "${output}" == *"string.lua"* ]]; then
	check "sync refuses a checksum that does not match" 0
else
	check "sync refuses a checksum that does not match" 1
fi
write_manifest 1.0.0 "${sha_v1}"

# --read prints one record per declared file.
if "${VENDOR}" --repository "${repo}" --read 2>/dev/null | grep -q "^file	demo	string.lua	${sha_v1}"; then
	check "read prints the declared file record" 0
else
	check "read prints the declared file record" 1
fi

# --check reports a source behind the version the origin publishes.
if VENDOR_LATEST_VERSION=2.0.0 "${VENDOR}" --repository "${repo}" --check 2>&1 |
	grep -q "demo: declared 1.0.0, latest 2.0.0"; then
	check "check reports a source behind its latest version" 0
else
	check "check reports a source behind its latest version" 1
fi

# --update moves the manifest to the new release, and a later sync verifies it.
if VENDOR_LATEST_VERSION=2.0.0 "${VENDOR}" --repository "${repo}" --update demo >/dev/null 2>&1 &&
	grep -q "version: \"2.0.0\"" "${ext}/_dependencies.yml" &&
	"${VENDOR}" --repository "${repo}" --sync >/dev/null 2>&1 &&
	cmp -s "${ext}/_vendor/demo/string.lua" "${WORK}/upstream/releases/download/2.0.0/string.lua"; then
	check "update moves the manifest and the next sync verifies it" 0
else
	check "update moves the manifest and the next sync verifies it" 1
fi
write_manifest 2.0.0 "${sha_v2}"

# --declare names a file against the catalogue and records it in the manifest.
declare_repo="${WORK}/declare-repo"
mkdir -p "${declare_repo}/_extensions/owner/fresh"
cat >"${declare_repo}/_extensions/owner/fresh/_extension.yml" <<'EOF'
title: Fresh
version: 1.0.0
EOF
if VENDOR_SOURCES="${WORK}/sources.list" "${VENDOR}" --repository "${declare_repo}" --declare string.lua >/dev/null 2>&1 &&
	grep -q "string.lua:" "${declare_repo}/_extensions/owner/fresh/_dependencies.yml"; then
	check "declare records a catalogued file in the manifest" 0
else
	check "declare records a catalogued file in the manifest" 1
fi

# A missing mode is refused, with usage.
if "${VENDOR}" --repository "${repo}" >/dev/null 2>&1; then
	check "a run with no mode is refused" 1
else
	check "a run with no mode is refused" 0
fi

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
