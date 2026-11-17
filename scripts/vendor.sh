#!/usr/bin/env bash
#
# vendor.sh - Vendor an extension's declared dependencies
#
# Reads an extension's `_extensions/<name>/_dependencies.yml`, fetches each
# declared file at the version it names, verifies its checksum, and writes
# it alongside its licence. Refuses to guess when a repository declares
# nothing.
#
# Usage:
#   vendor.sh [--repository <dir>] <mode>
#
# Modes:
#   --sync                   Fetch and verify every declared dependency, and
#                            remove a vendored file no longer declared.
#   --check                  Report whether declared dependencies are up to date.
#   --update [source]        Update one or all sources to their latest version.
#   --set <source>=<version> Pin one source to an explicit version.
#   --declare <file>         Declare one file against the catalogued source that
#                            publishes it, fetch it, and print the source it
#                            belongs to. Repeatable.
#   --read                   Diagnostic: print every declared record and exit.
#
# Options:
#   -r, --repository <dir>  Repository to operate on (default: the working directory).
#   -h, --help              Display this help message.
#
# Environment:
#   VENDOR_SOURCES          The catalogue `--declare` reads
#                           (default: `sources.list` beside this script).
#   VENDOR_LATEST_VERSION   The version `--check` and `--update` treat as the
#                           latest, instead of asking the origin.
#
# @license MIT
# @copyright 2026 Mickaël Canouil
# @author Mickaël Canouil
#

set -euo pipefail

# This script needs bash 4.4. Associative arrays and `${name,,}` arrived in
# 4.0, and expanding an empty array under `set -u` stopped being an error in
# 4.4. macOS ships bash 3.2 as `/bin/bash`, where every mode dies with
# `declare: -A: invalid option` before it reads a single manifest.
if [[ -z "${BASH_VERSINFO[0]:-}" ]] ||
	((BASH_VERSINFO[0] < 4)) ||
	((BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)); then
	printf 'Error: vendor.sh needs bash 4.4 or newer, and this is bash %s. macOS ships bash 3.2 as /bin/bash: install a newer one with Homebrew, brew install bash, and run the script with that.\n' \
		"${BASH_VERSION:-unknown}" >&2
	exit 1
fi

# The two globs in this script both walk a vendor directory looking for what
# is already written there. The published file-key grammar accepts a leading
# dot, so `.luacheckrc` and `.editorconfig` are ordinary vendored names, and
# a bare `*` cannot see them. Without this, every guard over that directory
# is blind to exactly the names it must protect.
shopt -s dotglob

# The catalogue `--declare` reads lives beside this script, so a checkout of
# the repository carries the sources it knows about.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

usage() {
	cat <<'EOF'
Usage: vendor.sh [--repository <dir>] <mode>

Modes:
  --sync                   Fetch and verify every declared dependency, and
                           remove a vendored file no longer declared.
  --check                  Report whether declared dependencies are up to date.
  --update [source]        Update one or all sources to their latest version.
  --set <source>=<version> Pin one source to an explicit version.
  --declare <file>         Declare one file against the catalogued source that
                           publishes it, fetch it, and print the source it
                           belongs to. Repeatable.
  --read                   Diagnostic: print every declared record and exit.

Options:
  -r, --repository <dir>  Repository to operate on (default: the working directory).
  -h, --help              Display this help message.
EOF
}

log_error() {
	printf 'Error: %s\n' "$*" >&2
}

log_warning() {
	printf 'Warning: %s\n' "$*" >&2
}

# Every temporary path this run created. A Ctrl-C during a slow fetch used
# to leave the staging directory behind, and the next run cannot tell one of
# those from its own.
declare -a SCRATCH_PATHS=()
SCRATCH_PATH=""

# new_scratch_dir, new_scratch_file
#
# Create a temporary path, record it, and name it in SCRATCH_PATH. Neither
# prints the path: a command substitution would run them in a subshell,
# where the record would be lost and the path would leak.
#
# The template is explicit so the path lands under TMPDIR on every platform,
# and so a leftover names the script that made it. macOS `mktemp -d` with no
# template ignores TMPDIR.
new_scratch_dir() {
	SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/vendor.XXXXXXXX")"
	SCRATCH_PATHS+=("${SCRATCH_PATH}")
}

new_scratch_file() {
	SCRATCH_PATH="$(mktemp "${TMPDIR:-/tmp}/vendor.XXXXXXXX")"
	SCRATCH_PATHS+=("${SCRATCH_PATH}")
}

cleanup_scratch() {
	local path
	for path in "${SCRATCH_PATHS[@]}"; do
		rm -rf "${path}"
	done
	SCRATCH_PATHS=()
}

# on_signal <signal>
#
# Cleans up, then re-raises the signal, so the exit status still reports an
# interrupted run rather than an ordinary failure.
on_signal() {
	cleanup_scratch
	trap - "$1"
	kill -"$1" "$$"
}

trap cleanup_scratch EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# find_manifests <repository>
#
# Prints one path per line, sorted, for every manifest under the
# repository. Both layouts are searched: `_extensions/<name>/` in a
# development tree, and `_extensions/<owner>/<name>/` where Quarto installs
# a published extension. A repository holding both must not have one of
# them silently ignored.
#
# A repository with no `_extensions` directory prints nothing and returns 0,
# so a caller under `set -e` sees empty output rather than a killed script.
#
# Every other failure propagates. A directory that cannot be read is not
# the same fact as a repository that declares nothing: --check would report
# a source as current and --update would do nothing, both of them silently,
# if this function reported an unreadable tree as an empty one.
find_manifests() {
	find_in_extensions "$1" -name '_dependencies.yml'
}

# find_in_extensions <repository> <find expression>...
#
# Prints one path per line, sorted, for everything under the repository's
# extensions that the expression matches. The two layouts and the depths they
# sit at are stated here and nowhere else, so every search of the tree agrees
# on what an extension is.
find_in_extensions() {
	local repository="$1"
	shift
	[[ -d "${repository}/_extensions" ]] || return 0
	find "${repository}/_extensions" -mindepth 2 -maxdepth 3 "$@" | sort
}

# manifest_list <repository>
#
# Prints every manifest the repository declares. Refuses, naming the file
# it looked for, when the repository declares none: the script guesses at
# nothing. A tree that cannot be searched is reported as the failure it is,
# and never as a repository that declares nothing.
manifest_list() {
	local repository="$1"
	local manifests status=0
	manifests="$(find_manifests "${repository}")" || status=$?

	if [[ "${status}" -ne 0 ]]; then
		log_error "could not search ${repository}/_extensions for manifests"
		return "${status}"
	fi

	if [[ -z "${manifests}" ]]; then
		log_error "this repository declares no vendored dependency: looked for _extensions/<name>/_dependencies.yml and _extensions/<owner>/<name>/_dependencies.yml"
		return 1
	fi

	printf '%s\n' "${manifests}"
}

# find_extension_dirs <repository>
#
# Prints one path per line, sorted, for every extension under the repository,
# named by the `_extension.yml` each one carries.
find_extension_dirs() {
	find_in_extensions "$1" -name '_extension.yml'
}

# strip_quotes <value>
#
# Removes a single pair of surrounding quotes from a scalar, if present.
# Both quote styles are legal YAML, the schema accepts both, and the schema
# file itself uses single quotes. Leaves the value unchanged otherwise.
strip_quotes() {
	local value="$1"
	if [[ "${#value}" -ge 2 ]] && [[ "${value}" == \"*\" || "${value}" == \'*\' ]]; then
		value="${value:1:-1}"
	fi
	printf '%s' "${value}"
}

# strip_comment <value>
#
# Removes a trailing comment, introduced by a space and a `#`, from a
# scalar. A quoted scalar ends at its closing quote, so a `#` inside the
# quotes is part of the value and everything after the quote is a comment.
#
# Only the keys whose value cannot hold a `#` go through this: `schema`,
# `version`, `licence`, `runtime` and `sha256`. `origin`, `fetch` and
# `licence-url` keep whatever follows the colon, because a URL holds a `#`
# legitimately.
strip_comment() {
	local value="$1" quote rest
	if [[ "${value}" == \"* || "${value}" == \'* ]]; then
		quote="${value:0:1}"
		rest="${value:1}"
		if [[ "${rest}" == *"${quote}"* ]]; then
			printf '%s' "${quote}${rest%%"${quote}"*}${quote}"
			return 0
		fi
	fi
	if [[ "${value}" == *" #"* ]]; then
		value="${value%%" #"*}"
		value="${value%"${value##*[![:space:]]}"}"
	fi
	printf '%s' "${value}"
}

# plain_scalar <value>
#
# Reads a scalar that cannot legitimately hold a `#`: the trailing comment
# goes, then the surrounding quotes.
plain_scalar() {
	strip_quotes "$(strip_comment "$1")"
}

# read_manifest <path>
#
# Parses a `_dependencies.yml` manifest and prints one tab-separated record
# per line. Each record names its own kind, so a reader classifies it by
# what it is rather than by guessing from a key name:
#
#   meta<TAB>source<TAB>key<TAB>value
#   file<TAB>source<TAB>name<TAB>sha256<TAB>runtime
#
# A source carrying a file called `version` or `origin` is therefore read
# as the file it is. An unknown source key is passed through, and an
# unknown block is skipped whole, since the format warns on one rather than
# rejecting it. A line that is only a comment is skipped, so a comment
# inside a `files:` block cannot become a file nothing can fetch.
#
# Exits 1, naming the offending line, when the manifest is malformed: a
# schema other than 1, a file key containing `/`, a `sha256` that is not 64
# hexadecimal characters, or a file entry carrying no `sha256` at all. The
# last of those is what a flow-style entry, `logging.lua: {sha256: ...}`,
# parses as. This reader handles block style only, and a manifest it cannot
# read fully is refused rather than half read: a mode acting on a file
# whose checksum went missing is the silent wrong answer.
read_manifest() {
	local path="$1"
	local -a stack_indent=(-1)
	local -a stack_ctx=("root")
	local source_name="" file_name="" file_sha256="" file_runtime=""
	local file_lineno=0
	local lineno=0

	flush_file() {
		if [[ -n "${file_name}" ]]; then
			if [[ -z "${file_sha256}" ]]; then
				log_error "${path}:${file_lineno}: ${file_name}: a file entry must carry a sha256"
				return 1
			fi
			printf 'file\t%s\t%s\t%s\t%s\n' "${source_name}" "${file_name}" "${file_sha256}" "${file_runtime}"
			file_name="" file_sha256="" file_runtime=""
		fi
	}

	while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
		lineno=$((lineno + 1))

		local stripped="${raw_line#"${raw_line%%[![:space:]]*}"}"
		[[ -z "${stripped}" ]] && continue
		# A whole-line comment carries no structure, at any indentation.
		# A trailing comment goes only from the keys whose value cannot
		# hold a `#`: see `strip_comment`.
		[[ "${stripped}" == "#"* ]] && continue
		local indent=$((${#raw_line} - ${#stripped}))

		local top=$((${#stack_indent[@]} - 1))
		while ((top > 0)) && ((indent <= stack_indent[top])); do
			if [[ "${stack_ctx[top]}" == "file" ]]; then
				flush_file || return 1
			fi
			unset 'stack_indent[top]' 'stack_ctx[top]'
			top=$((top - 1))
		done
		local parent="${stack_ctx[top]}"

		local key="${stripped%%:*}"
		local value_raw="${stripped#*:}"
		value_raw="${value_raw#"${value_raw%%[![:space:]]*}"}"
		value_raw="${value_raw%"${value_raw##*[![:space:]]}"}"
		local value
		value="$(strip_quotes "${value_raw}")"

		case "${parent}" in
		root)
			case "${key}" in
			schema)
				local schema_value
				schema_value="$(plain_scalar "${value_raw}")"
				if [[ "${schema_value}" != "1" ]]; then
					log_error "${path}:${lineno}: unsupported manifest schema version: ${schema_value}"
					return 1
				fi
				;;
			sources)
				# A sources key carries no value, so a trailing comment on
				# its line is a comment and nothing else. Anything left is
				# flow style, which this reader does not handle. Pushing a
				# block context over it would read the whole manifest as
				# empty and sync nothing, successfully.
				local sources_value="${value%%#*}"
				sources_value="${sources_value%"${sources_value##*[![:space:]]}"}"
				if [[ -n "${sources_value}" ]]; then
					log_error "${path}:${lineno}: sources must open a block, one source key per line, found a mapping on the same line: ${sources_value}"
					return 1
				fi
				stack_indent+=("${indent}")
				stack_ctx+=("sources")
				;;
			*) : ;;
			esac
			;;
		sources)
			source_name="${key}"
			stack_indent+=("${indent}")
			stack_ctx+=("source")
			;;
		source)
			if [[ "${key}" == "files" ]]; then
				# A files key carries no value, so a trailing comment on
				# its line is a comment and nothing else.
				local files_value="${value%%#*}"
				files_value="${files_value%"${files_value##*[![:space:]]}"}"
				if [[ -n "${files_value}" ]]; then
					log_error "${path}:${lineno}: files must open a block, one file key per line, found a mapping on the same line: ${files_value}"
					return 1
				fi
				stack_indent+=("${indent}")
				stack_ctx+=("files")
			elif [[ -n "${value}" ]]; then
				case "${key}" in
				version | licence)
					# Neither can hold a `#`, so what follows one is a
					# comment. Keeping it corrupts the value, and the
					# writer then stores the corruption.
					printf 'meta\t%s\t%s\t%s\n' "${source_name}" "${key}" "$(plain_scalar "${value_raw}")"
					;;
				*)
					printf 'meta\t%s\t%s\t%s\n' "${source_name}" "${key}" "${value}"
					;;
				esac
			else
				# A key with no scalar value opens a block this schema does
				# not define. Skip the whole subtree rather than read its
				# children as keys of the source.
				stack_indent+=("${indent}")
				stack_ctx+=("ignored")
			fi
			;;
		files)
			case "${key}" in
			*/*)
				log_error "${path}:${lineno}: a file key must not contain a path separator: ${key}"
				return 1
				;;
			esac
			file_name="${key}"
			file_sha256=""
			file_runtime=""
			file_lineno="${lineno}"
			stack_indent+=("${indent}")
			stack_ctx+=("file")
			;;
		file)
			case "${key}" in
			sha256)
				# 64 hexadecimal characters cannot hold a `#`, so what
				# follows one is a comment.
				local sha_value
				sha_value="$(plain_scalar "${value_raw}")"
				if [[ ! "${sha_value}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
					log_error "${path}:${lineno}: ${file_name}: sha256 must be exactly 64 hexadecimal characters, found: ${sha_value}"
					return 1
				fi
				file_sha256="${sha_value}"
				;;
			runtime)
				# The schema publishes an enum for this key, so a kept
				# trailing comment would store a value it rejects.
				file_runtime="$(plain_scalar "${value_raw}")"
				;;
			*) : ;;
			esac
			;;
		*) : ;;
		esac
	done <"${path}"

	while ((${#stack_indent[@]} > 1)); do
		local top=$((${#stack_indent[@]} - 1))
		if [[ "${stack_ctx[top]}" == "file" ]]; then
			flush_file || return 1
		fi
		unset 'stack_indent[top]' 'stack_ctx[top]'
	done
}

# carries_tag_prefix <prefix> <version>
#
# Reports whether a version already holds the prefix that would be put in front
# of it. That is what a record written while the version field held the whole
# tag looks like, and building the tag from it asks for the prefix twice. Every
# path that takes a version checks this, because the failure it prevents is a
# fetch that names an address rather than the reason for it.
carries_tag_prefix() {
	local prefix="${1:-}" version="$2"
	[[ -n "${prefix}" && "${prefix}" != "-" && "${version}" == "${prefix}"* ]]
}

# tag_prefix_error <prefix> <version>
#
# Prints the advice for a version that already carries its prefix, naming the
# version to declare instead. One wording, so the four paths that can take a
# stale version all say the same thing.
tag_prefix_error() {
	local prefix="$1" version="$2" bare
	bare="${version#"${prefix}"}"
	# A version that is the prefix and nothing else leaves nothing to advise,
	# so it says what the field is for rather than naming an empty version.
	if [[ -z "${bare}" ]]; then
		printf 'version %s is the tag-prefix %s and nothing else. A tag-prefix builds the tag from the version, so the version field must name a version.' \
			"${version}" "${prefix}"
		return 0
	fi
	printf 'version %s already carries the tag-prefix %s. A tag-prefix builds the tag from the version, so declare version %s instead.' \
		"${version}" "${prefix}" "${bare}"
}

# release_tag <prefix> <version>
#
# Prints the tag of a release. A `tag-prefix` declares that the tag is the
# prefix followed by the version, so the version field of a source holds a
# version and every template resolves against the tag this builds. A source
# that declares no prefix names its releases by version alone, and the tag and
# the version are then the same string, which is why an unprefixed source is
# unaffected by any of this.
#
# `-` reads as no prefix, the same way it does everywhere else a prefix is read.
release_tag() {
	local prefix="${1:-}" version="$2"
	[[ "${prefix}" == "-" ]] && prefix=""
	printf '%s%s' "${prefix}" "${version}"
}

# resolve_url <template> <origin> <version> <file>
#
# Substitutes `{origin}`, `{version}` and `{file}` into a URL template.
# The substitution is a literal string replacement: a template never runs
# as code, so a manifest cannot use it to inject a command.
resolve_url() {
	local template="$1" origin="$2" version="$3" file="$4"
	local url="${template//\{origin\}/${origin}}"
	url="${url//\{version\}/${version}}"
	url="${url//\{file\}/${file}}"
	printf '%s' "${url}"
}

# fetch_to <url> <destination>
#
# Fetches a URL to a local path. `curl`'s `file://` handling is the same
# code path as its `https://` handling, so this one function serves both a
# real download and the offline `file://` fixtures the test suite uses.
#
# Every fetch names a deadline and a retry count. Without them one hung
# connection stalls a sweep of forty repositories for as long as the host
# keeps the socket open, and a single dropped packet fails a whole run.
fetch_to() {
	local url="$1" destination="$2"
	curl --fail --silent --show-error --location \
		--connect-timeout 30 --max-time 300 \
		--retry 3 --retry-delay 2 \
		--output "${destination}" -- "${url}"
}

# file_mode <path>
#
# Prints a file's permission bits as octal digits, using whichever of the
# GNU and BSD `stat` is present. Prints nothing when neither can tell, so a
# caller decides what to do rather than acting on a guess.
#
# Each probe is captured and then checked against what a mode looks like,
# never trusted for having exited 0. GNU's `-f` means `--file-system` and
# takes no format, so `stat -f '%Lp' FILE` prints a block of filesystem
# facts on standard output while erroring about `%Lp`. Accepting that as a
# mode is how a manifest would end up at whatever `chmod` made of it.
file_mode() {
	local path="$1" mode

	mode="$(stat -c '%a' "${path}" 2>/dev/null)" || mode=""
	if [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
		printf '%s' "${mode}"
		return 0
	fi

	mode="$(stat -f '%Lp' "${path}" 2>/dev/null)" || mode=""
	if [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
		printf '%s' "${mode}"
		return 0
	fi

	return 0
}

# compute_sha256 <path>
#
# Prints the lower-case hexadecimal SHA-256 digest of a file, using
# whichever of `shasum` or `sha256sum` is available.
compute_sha256() {
	local path="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "${path}" | cut -d ' ' -f 1
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "${path}" | cut -d ' ' -f 1
	else
		log_error "no sha256 utility found: install shasum or sha256sum"
		return 1
	fi
}

# The records of the manifest currently loaded. `load_manifest` fills them,
# `--set` and `--update` amend them, and `write_manifest` emits them again.
# A source is keyed by name; a file is keyed by its source and its name,
# joined with a tab, because bash has no nested array.
declare -a MANIFEST_SOURCES=()
declare -A MANIFEST_META=()
declare -A MANIFEST_META_KEYS=()
declare -A MANIFEST_FILES=()
declare -A MANIFEST_SHA=()
declare -A MANIFEST_RUNTIME=()
declare -a RECORD_FIELDS=()

# split_record <record>
#
# Splits a tab-separated record into RECORD_FIELDS, keeping every empty
# field. `read -a` cannot do this: a tab is IFS whitespace, so a run of
# tabs collapses into one delimiter and an empty field disappears. A file
# whose `runtime` is absent would then have its checksum read as its
# runtime.
split_record() {
	local record="$1"
	RECORD_FIELDS=()
	while [[ "${record}" == *$'\t'* ]]; do
		RECORD_FIELDS+=("${record%%$'\t'*}")
		record="${record#*$'\t'}"
	done
	RECORD_FIELDS+=("${record}")
}

# remember_source <source>
#
# Appends a source to MANIFEST_SOURCES the first time it is seen, so the
# order of declaration survives.
remember_source() {
	local source="$1" known
	for known in "${MANIFEST_SOURCES[@]}"; do
		[[ "${known}" == "${source}" ]] && return 0
	done
	MANIFEST_SOURCES+=("${source}")
}

# reset_manifest_records
#
# Empties the record store. Every writer of the store starts here, so a
# manifest can never be written from records another one left behind.
reset_manifest_records() {
	MANIFEST_SOURCES=()
	MANIFEST_META=()
	MANIFEST_META_KEYS=()
	MANIFEST_FILES=()
	MANIFEST_SHA=()
	MANIFEST_RUNTIME=()
}

# load_manifest <path>
#
# Reads one manifest into the record store, replacing whatever it held.
# A record is classified by the kind it carries, never by its key name, so
# a source that ships a file called `version.lua` keeps it.
#
# The records are collected before any of them is stored, so a manifest
# that is malformed part way through fails here rather than loading the
# part that came first. A mode acting on half a manifest is the silent
# wrong answer this script exists to avoid.
load_manifest() {
	local path="$1"
	local records status=0
	records="$(read_manifest "${path}")" || status=$?
	if [[ "${status}" -ne 0 ]]; then
		return "${status}"
	fi

	reset_manifest_records

	local record kind source
	while IFS= read -r record; do
		[[ -z "${record}" ]] && continue
		split_record "${record}"
		kind="${RECORD_FIELDS[0]}"
		source="${RECORD_FIELDS[1]}"
		remember_source "${source}"
		case "${kind}" in
		meta)
			set_source_meta "${source}" "${RECORD_FIELDS[2]}" "${RECORD_FIELDS[3]}"
			;;
		file)
			set_source_file "${source}" "${RECORD_FIELDS[2]}" "${RECORD_FIELDS[3]}" "${RECORD_FIELDS[4]}"
			;;
		*) : ;;
		esac
	done <<<"${records}"

	# A version that already carries the prefix is a manifest written while the
	# version field held the whole tag. Building the tag from it asks for the
	# prefix twice, and the fetch that follows fails naming an address rather
	# than the reason for it, so it is refused as the manifest is read. Every
	# mode that reads a manifest passes through here, which the shape check
	# does not: that one runs before a manifest is written.
	local prefix version
	for source in "${MANIFEST_SOURCES[@]}"; do
		prefix="$(source_meta "${source}" tag-prefix)"
		version="$(source_meta "${source}" version)"
		if carries_tag_prefix "${prefix}" "${version}"; then
			log_error "${path}: ${source}: $(tag_prefix_error "${prefix}" "${version}")"
			return 1
		fi
	done
}

# source_meta <source> <key>
#
# Prints one source-level value, or nothing when the source does not
# declare that key.
source_meta() {
	printf '%s' "${MANIFEST_META["$1"$'\t'"$2"]:-}"
}

# set_source_meta <source> <key> <value>
#
# Records one source-level value. The key is remembered as well as the value,
# because the shape check reads the key list to know what a source declares,
# and the writer reads it to know what to write back.
set_source_meta() {
	local source="$1" key="$2" value="$3"
	MANIFEST_META["${source}"$'\t'"${key}"]="${value}"
	MANIFEST_META_KEYS["${source}"]="${MANIFEST_META_KEYS["${source}"]:-}${key}"$'\n'
}

# set_source_file <source> <name> <sha256> <runtime>
#
# Records one declared file. The tab-joined keys the store uses are written
# here and nowhere else, so the encoding is one fact rather than several.
#
# A name already in the list is recorded once, and its checksum and runtime are
# replaced. A caller that records the same file twice is stating the same fact
# again, which is what a file replaced by its published copy does when the digest the origin serves
# replaces the digest the local copy had. Listing it twice would make the
# fold-collision check report the file as colliding with itself, and that check
# must go on seeing a real collision between two spellings.
set_source_file() {
	local source="$1" name="$2" sha256="$3" runtime="$4"
	case $'\n'"${MANIFEST_FILES["${source}"]:-}" in
	*$'\n'"${name}"$'\n'*) : ;;
	*) MANIFEST_FILES["${source}"]="${MANIFEST_FILES["${source}"]:-}${name}"$'\n' ;;
	esac
	MANIFEST_SHA["${source}"$'\t'"${name}"]="${sha256}"
	MANIFEST_RUNTIME["${source}"$'\t'"${name}"]="${runtime}"
}

# source_file_names <source>
#
# Prints the files a source declares, one per line, in declaration order.
source_file_names() {
	printf '%s' "${MANIFEST_FILES["$1"]:-}"
}

# check_no_fold_collision <label> <source>
#
# Refuses a source that declares two files whose names differ only in case.
# Only one of the two can ever be written, so the tree would disagree with
# the manifest on a case-insensitive filesystem and hold a file the
# manifest does not describe on a case-sensitive one.
#
# Both the fetching path and the writing path apply this one rule, so the
# script can never write a manifest it would then refuse to sync.
check_no_fold_collision() {
	local label="$1" source="$2"
	local -A seen=()
	local name folded

	while IFS= read -r name; do
		[[ -z "${name}" ]] && continue
		folded="${name,,}"
		if [[ -n "${seen["${folded}"]:-}" ]]; then
			log_error "${label}: declares two files whose names differ only in case, and only one of them can be written: ${seen["${folded}"]} and ${name}"
			return 1
		fi
		seen["${folded}"]="${name}"
	done <<<"$(source_file_names "${source}")"
}

# fetch_licence <source> <version> <destination>
#
# Fetches a source's licence to a path. The address comes from the source's
# own `licence-url` template when it declares one, and otherwise from the
# `{origin}/raw/{version}/LICENSE` a `github.com` origin serves.
#
# A licence that cannot be fetched fails the caller. The framework's
# conformance layer fails an extension whose vendored licence is absent, so
# writing the files without it produces a repository that cannot pass.
fetch_licence() {
	local source="$1" version="$2" destination="$3"
	local origin template url
	origin="$(source_meta "${source}" origin)"
	template="$(source_meta "${source}" licence-url)"
	[[ -z "${template}" ]] && template='{origin}/raw/{version}/LICENSE'
	url="$(resolve_url "${template}" "${origin}" \
		"$(release_tag "$(source_meta "${source}" tag-prefix)" "${version}")" "LICENSE")"

	if ! fetch_to "${url}" "${destination}"; then
		log_error "${source}: could not fetch the licence from ${url}"
		return 1
	fi
}

# vendor_source <extension_dir> <source> <version> <checksums> <label>
#
# Fetches every file a source declares at one version, plus its licence,
# into a scratch directory, and only once the lot has arrived does it move
# them into `<extension_dir>/_vendor/<source>/`.
#
# `checksums` is `verify` to require each file to match the digest the
# manifest declares, which is what --sync does, or `record` to store the
# digest of what the origin served, which is what --set and --update do at
# a version no digest is known for yet. Either way nothing is moved until
# every file has arrived, so a fetch that fails leaves the vendor directory
# and the record store exactly as they were.
#
# `label` names the manifest in the warnings the run prints, so one run names
# an extension the same way throughout.
#
# A source that declares its own licence file, under any spelling of
# `LICENSE` that would land on the same path, keeps it: no separate licence
# is fetched, and the declared file is verified against its recorded
# checksum like any other. The comparison ignores case, because a
# case-insensitive filesystem gives `LICENSE` and `license` one path and a
# case-sensitive one does not, and a vendored tree must be the same on
# both.
#
# The source's own directory is left holding exactly what the manifest
# describes: a regular file the manifest no longer declares is removed.
# Nothing outside `<extension_dir>/_vendor/<source>/` is ever touched.
vendor_source() {
	local extension_dir="$1" source="$2" version="$3" checksums="$4" label="$5"

	local origin fetch_template
	origin="$(source_meta "${source}" origin)"
	fetch_template="$(source_meta "${source}" fetch)"

	if [[ -z "${fetch_template}" ]]; then
		log_error "${source}: declares no fetch template, so its files cannot be fetched"
		return 1
	fi
	if [[ -z "${version}" ]]; then
		log_error "${source}: declares no version"
		return 1
	fi

	check_no_fold_collision "${source}" "${source}" || return 1

	local -a names=()
	local name declared_licence=""
	while IFS= read -r name; do
		[[ -z "${name}" ]] && continue
		if [[ "${name,,}" == "license" ]]; then
			declared_licence="${name}"
		fi
		names+=("${name}")
	done <<<"$(source_file_names "${source}")"

	if [[ "${#names[@]}" -eq 0 ]]; then
		log_error "${source}: declares no file"
		return 1
	fi

	# The declared files and the licence stage in separate directories, so
	# the licence can never land on a file that has already been fetched
	# and verified.
	local staging
	new_scratch_dir
	staging="${SCRATCH_PATH}"
	# shellcheck disable=SC2064 # staging is fixed at trap-set time, by design.
	trap "rm -rf '${staging}'" RETURN
	local files_staging="${staging}/files" licence_staging="${staging}/licence"
	mkdir -p "${files_staging}" "${licence_staging}"

	# The tag is the same for every file of a source, so it is built once here
	# rather than in the loop below.
	local tag
	tag="$(release_tag "$(source_meta "${source}" tag-prefix)" "${version}")"

	local -A fetched=()
	local url actual expected
	for name in "${names[@]}"; do
		url="$(resolve_url "${fetch_template}" "${origin}" "${tag}" "${name}")"
		if ! fetch_to "${url}" "${files_staging}/${name}"; then
			log_error "${source}: could not fetch ${name} from ${url}"
			return 1
		fi

		actual="$(compute_sha256 "${files_staging}/${name}")"
		if [[ "${checksums}" == "verify" ]]; then
			expected="${MANIFEST_SHA["${source}"$'\t'"${name}"]:-}"
			if [[ "${actual,,}" != "${expected,,}" ]]; then
				log_error "${source}: ${name}: checksum mismatch: expected ${expected}, got ${actual}"
				return 1
			fi
		fi
		fetched["${name}"]="${actual,,}"
	done

	if [[ -z "${declared_licence}" ]]; then
		fetch_licence "${source}" "${version}" "${licence_staging}/LICENSE" || return 1
	fi

	local vendor_dir="${extension_dir}/_vendor/${source}"
	mkdir -p "${vendor_dir}"

	# What is about to be written, keyed by the folded name, so an entry
	# already there under a different spelling can be found.
	local -A targets=()
	for name in "${names[@]}"; do
		targets["${name,,}"]="${name}"
	done
	if [[ -z "${declared_licence}" ]]; then
		targets["license"]="LICENSE"
	fi

	# A destination that is not a regular file cannot be replaced. `mv`
	# would put the file inside a directory, so the manifest would name a
	# file the tree does not have, and the removal below would fail with a
	# bare `rm:` message. Refuse first, before anything is written.
	local existing base
	for existing in "${vendor_dir}"/*; do
		[[ -e "${existing}" ]] || continue
		base="${existing##*/}"
		[[ -n "${targets["${base,,}"]:-}" ]] || continue
		if [[ -d "${existing}" ]]; then
			log_error "${source}: ${base}: a directory is at ${existing}, where a file must be written: remove it, or the vendored tree cannot match the manifest"
			return 1
		fi
		if [[ ! -f "${existing}" ]]; then
			log_error "${source}: ${base}: ${existing} is not a regular file, so it cannot be replaced by one"
			return 1
		fi
	done

	# Bring the source's own directory back to exactly what the manifest
	# describes. Two entries go, and nothing outside this directory is ever
	# touched: `_vendor/<source>/` holds what this source publishes and
	# nothing a repository wrote itself.
	#
	# The first is an entry that differs only in case from one about to be
	# written. A move onto it would keep the old directory entry on a
	# case-insensitive filesystem, and leave the old file beside the new
	# one on a case-sensitive filesystem. Either way the tree would stop
	# matching the manifest, and the two filesystems would stop matching
	# each other.
	#
	# The second is an entry the manifest no longer declares. Writing every
	# declared file says nothing about a file that was dropped from `files:`,
	# so the run would verify each digest and exit 0 over a tree carrying an
	# orphan. The exit code could then no longer tell a matching tree from
	# one that is wrong.
	#
	# Only a regular file is removed. This script writes nothing else here,
	# so anything else is a human's, and deleting it is not this mode's call.
	for existing in "${vendor_dir}"/*; do
		[[ -e "${existing}" ]] || continue
		base="${existing##*/}"
		if [[ -z "${targets["${base,,}"]:-}" ]]; then
			[[ -f "${existing}" ]] || continue
			rm -f "${existing}"
			printf '%s: %s: removed, because the manifest no longer declares it\n' \
				"${source}" "${base}"
		elif [[ "${base}" != "${targets["${base,,}"]}" ]]; then
			rm -f "${existing}"
		fi
	done

	for name in "${names[@]}"; do
		mv "${files_staging}/${name}" "${vendor_dir}/${name}"
	done
	if [[ -z "${declared_licence}" ]]; then
		mv "${licence_staging}/LICENSE" "${vendor_dir}/LICENSE"
	fi

	for name in "${names[@]}"; do
		report_siblings "${label}" "${extension_dir}" "${source}" "${name}"
	done

	if [[ "${checksums}" == "record" ]]; then
		for name in "${names[@]}"; do
			MANIFEST_SHA["${source}"$'\t'"${name}"]="${fetched["${name}"]}"
		done
	fi
}

# count_source_files <source>
#
# Prints how many files a source declares.
count_source_files() {
	local name count=0
	while IFS= read -r name; do
		[[ -z "${name}" ]] && continue
		count=$((count + 1))
	done <<<"$(source_file_names "$1")"
	printf '%s' "${count}"
}

# report_source_files <label> <source> <verb> <version>
#
# Says what one source got, naming how many files and at which version.
# Silence must not be the output of both a success and a run that did nothing,
# because an exit code alone cannot then tell the two apart.
report_source_files() {
	local label="$1" source="$2" verb="$3" version="$4"
	local count plural="s"
	count="$(count_source_files "${source}")"
	[[ "${count}" -eq 1 ]] && plural=""
	printf '%s: %s: %s %s file%s at %s\n' \
		"${label}" "${source}" "${verb}" "${count}" "${plural}" "${version}"
}

# require_sources <manifest>
#
# Refuses a manifest whose source set is empty, naming it. A manifest that
# declares nothing is a defect: a typed key, a flow-style block this reader
# does not handle, or an empty file. An extension with no manifest at all is
# a different fact, and is still skipped.
require_sources() {
	local manifest="$1"
	if [[ "${#MANIFEST_SOURCES[@]}" -eq 0 ]]; then
		log_error "${manifest}: declares no source: expected a sources block, one source key per line"
		return 1
	fi
}

# sync_manifest <manifest>
#
# Fetches and verifies every source one manifest declares, at the version
# it declares, and removes a vendored file the manifest no longer declares.
# Writes no manifest: --sync never changes what a repository says it depends
# on.
#
# A source that arrived says so, naming itself and how many files it wrote.
# Silence must not be the output of both a success and a run that did
# nothing, because an exit code alone cannot then tell the two apart.
sync_manifest() {
	local manifest="$1"
	local extension_dir
	extension_dir="$(cd "$(dirname "${manifest}")" && pwd)"

	load_manifest "${manifest}" || return 1
	require_sources "${manifest}" || return 1

	local source version status=0
	for source in "${MANIFEST_SOURCES[@]}"; do
		version="$(source_meta "${source}" version)"
		if ! vendor_source "${extension_dir}" "${source}" "${version}" verify "${manifest}"; then
			status=1
			continue
		fi
		report_source_files "${manifest}" "${source}" wrote "${version}"
	done

	return "${status}"
}

# yaml_scalar <key> <value>
#
# Prints one value as YAML. `version` and `sha256` are always quoted, so a
# release tag such as `1.10` cannot be read back as a number, and anything
# that is not a plain word is quoted too.
yaml_scalar() {
	local key="$1" value="$2"
	if [[ "${key}" == "version" || "${key}" == "sha256" ]] ||
		[[ ! "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		printf '"%s"' "${value}"
	else
		printf '%s' "${value}"
	fi
}

# The grammars the published format itself constrains, quoted here exactly
# as `dependencies-schema.yml` publishes them, so a refusal can name what
# would be accepted. Nothing narrower than these may refuse a manifest: the
# format is public, and a manifest the framework validates must round-trip
# through this writer unchanged.
readonly SOURCE_KEY_GRAMMAR='^[a-z][a-z0-9-]*$'
readonly FILE_KEY_GRAMMAR='^[A-Za-z0-9._-]+$'

# The values the format's `runtime` enum accepts. A manifest naming anything
# else is one the conformance layer rejects.
readonly KNOWN_RUNTIMES='any pandoc'

# The keys the format defines inside a source. Anything else is the author's
# own, and the format warns on one rather than rejecting it.
readonly KNOWN_SOURCE_KEYS='origin fetch version licence licence-url tag-prefix'

# is_known_source_key <key>
#
# Reports whether the format defines a key inside a source.
is_known_source_key() {
	case " ${KNOWN_SOURCE_KEYS} " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# check_source_shape <path> <source>
#
# Reports whether one source could be written back in the published format:
# its key matches the grammar the schema publishes for a `sources` key, it
# declares `origin`, `fetch`, `version` and `licence`, no value of a key the
# format defines holds a character that would need escaping, each file it
# declares matches the grammar the schema publishes for a `files` key and
# carries no path separator, and no two of those names differ only in case.
#
# The schema constrains no key INSIDE a source, so neither does this. An
# unrecognised one is the author's own: `write_manifest` preserves it, or
# drops it with a warning when it cannot be written back safely.
check_source_shape() {
	local path="$1" source="$2"
	local key value name

	check_no_fold_collision "${path}: ${source}" "${source}" || return 1

	if [[ ! "${source}" =~ ${SOURCE_KEY_GRAMMAR} ]]; then
		log_error "${path}: ${source}: a source key must match ${SOURCE_KEY_GRAMMAR}, found: ${source}"
		return 1
	fi

	for key in origin fetch version licence; do
		if [[ -z "$(source_meta "${source}" "${key}")" ]]; then
			log_error "${path}: ${source} declares no ${key}"
			return 1
		fi
	done

	while IFS= read -r key; do
		[[ -z "${key}" ]] && continue
		is_known_source_key "${key}" || continue
		value="$(source_meta "${source}" "${key}")"
		if [[ "${value}" == *[\"\\]* ]]; then
			log_error "${path}: ${source}: ${key} holds a quote or a backslash: ${value}"
			return 1
		fi
	done <<<"${MANIFEST_META_KEYS["${source}"]:-}"

	if [[ -z "${MANIFEST_FILES["${source}"]:-}" ]]; then
		log_error "${path}: ${source} declares no file"
		return 1
	fi

	while IFS= read -r name; do
		[[ -z "${name}" ]] && continue
		case "${name}" in
		*/*)
			log_error "${path}: ${source}: ${name}: a file key must not contain a path separator"
			return 1
			;;
		esac
		if [[ ! "${name}" =~ ${FILE_KEY_GRAMMAR} ]]; then
			log_error "${path}: ${source}: ${name}: a file key must match ${FILE_KEY_GRAMMAR}"
			return 1
		fi
	done <<<"${MANIFEST_FILES["${source}"]}"
}

# check_records <path>
#
# Reports whether the whole record store could be written back in the
# published format: every source in the shape above, and a real checksum
# against every file each one declares. The format is public and the
# framework validates it independently, so the writer refuses rather than
# emitting a file that validation would then reject.
#
# --set and --update run this over the whole manifest before they move a
# single file. Checking only the source being moved is not enough: the
# writer emits every source, so a sibling that could not be written would
# block the rewrite after the moved files were already installed, leaving
# the tree and the manifest disagreeing.
check_records() {
	local path="$1"

	if [[ "${#MANIFEST_SOURCES[@]}" -eq 0 ]]; then
		log_error "${path}: declares no source"
		return 1
	fi

	local source name sha
	for source in "${MANIFEST_SOURCES[@]}"; do
		check_source_shape "${path}" "${source}" || return 1

		while IFS= read -r name; do
			[[ -z "${name}" ]] && continue
			sha="${MANIFEST_SHA["${source}"$'\t'"${name}"]:-}"
			if [[ ! "${sha}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
				log_error "${path}: ${source}: ${name}: sha256 must be exactly 64 hexadecimal characters, found: ${sha}"
				return 1
			fi
		done <<<"${MANIFEST_FILES["${source}"]}"
	done
}

# replace_file <temporary> <path>
#
# Puts a file written elsewhere in place of another, atomically and at the
# mode the destination had.
#
# mktemp creates at 0600 and a move carries that mode over, which would ship
# a file only its owner can read, and git records no such change. A
# destination that did not exist yet gets 0644.
replace_file() {
	local temporary="$1" path="$2"
	local mode=""

	if [[ -e "${path}" ]]; then
		mode="$(file_mode "${path}")"
	fi
	if ! chmod "${mode:-644}" "${temporary}"; then
		log_error "${path}: could not set the mode of the new file, so it was not written"
		return 1
	fi
	mv "${temporary}" "${path}"
}

# write_manifest <path>
#
# Regenerates the manifest from the record store: `schema`, then each
# source in sorted order, then each file in sorted order. It writes to a
# temporary file and moves it into place, so an interrupted run cannot
# leave a truncated manifest behind. It writes nothing at all when a record
# would not satisfy the published format.
#
# A hand-written comment does not survive, because the writer emits the
# records rather than editing the text.
write_manifest() {
	local path="$1"
	check_records "${path}" || return 1

	local temporary
	new_scratch_file
	temporary="${SCRATCH_PATH}"
	# shellcheck disable=SC2064 # temporary is fixed at trap-set time, by design.
	trap "rm -f '${temporary}'" RETURN

	local source key value name
	{
		printf 'schema: 1\n'
		printf 'sources:\n'
		while IFS= read -r source; do
			printf '  %s:\n' "${source}"
			# The list the format defines, read from the one place that holds
			# it. A second copy here drifts: a key only in that list is read
			# and then silently dropped on the next write, and a key only here
			# is written and then warned about as one the format does not
			# define.
			for key in ${KNOWN_SOURCE_KEYS}; do
				value="$(source_meta "${source}" "${key}")"
				[[ -z "${value}" ]] && continue
				printf '    %s: %s\n' "${key}" "$(yaml_scalar "${key}" "${value}")"
			done
			# A key the format does not define is the author's own, so it
			# is written back rather than quietly lost. One that cannot be
			# emitted as a plain YAML pair is dropped instead, named in a
			# warning, because a manifest the framework would reject is
			# worse than a manifest missing a key nothing reads.
			while IFS= read -r key; do
				[[ -z "${key}" ]] && continue
				is_known_source_key "${key}" && continue
				value="$(source_meta "${source}" "${key}")"
				if [[ ! "${key}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "${value}" == *[\"\\]* ]]; then
					log_warning "${path}: ${source}: dropping ${key}, which this format does not define and cannot be written back safely"
					continue
				fi
				printf '    %s: %s\n' "${key}" "$(yaml_scalar "${key}" "${value}")"
			done < <(printf '%s' "${MANIFEST_META_KEYS["${source}"]:-}" | sort -u)
			printf '    files:\n'
			while IFS= read -r name; do
				[[ -z "${name}" ]] && continue
				printf '      %s:\n' "${name}"
				printf '        sha256: %s\n' "$(yaml_scalar sha256 "${MANIFEST_SHA["${source}"$'\t'"${name}"]}")"
				value="${MANIFEST_RUNTIME["${source}"$'\t'"${name}"]:-}"
				[[ -n "${value}" ]] && printf '        runtime: %s\n' "$(yaml_scalar runtime "${value}")"
			done < <(printf '%s' "${MANIFEST_FILES["${source}"]}" | sort -u)
		done < <(printf '%s\n' "${MANIFEST_SOURCES[@]}" | sort)
	} >"${temporary}"

	replace_file "${temporary}" "${path}"
}

# prefixed_latest_tag <repository> <prefix>
#
# Prints the newest published tag of a repository carrying a prefix, or nothing
# when it cannot be told. The origin's own latest release is the wrong answer
# for a prefixed source, because it is a release of the other kind, so every
# published tag is listed and the newest carrying the prefix wins.
#
# Drafts and pre-releases are both excluded, which is what makes this agree with
# the unprefixed branch. `gh` shows a draft to anyone who can push, and a draft
# carries a tag name before any tag exists, so a release that failed part way
# would otherwise offer a version that was never published. A host never calls a
# pre-release its latest release, so reading tags must not promote one either,
# and version order would: `2.0.0-rc1` sorts above `1.9.0`.
#
# The limit bounds how many releases of the other kind may sit above the newest
# one carrying the prefix. An origin that publishes an editor extension often
# and a module rarely is the case this exists for, so it is set well past the
# gap those two rates produce.
prefixed_latest_tag() {
	local repository="$1" prefix="$2"
	local listed tag matching=""

	listed="$(gh release list --repo "${repository}" \
		--exclude-drafts --exclude-pre-releases --limit 200 \
		--json tagName --jq '.[].tagName' 2>/dev/null)" || return 0

	# The prefix is matched as text, not as a pattern, so a prefix holding a
	# `.` or a `*` cannot match a tag it does not name.
	while IFS= read -r tag; do
		[[ "${tag}" == "${prefix}"* ]] || continue
		matching+="${tag}"$'\n'
	done <<<"${listed}"

	# Version order, and not the order the host listed them in: 2.10.0 is newer
	# than 2.9.0 and loses under a plain sort. An empty list prints nothing.
	printf '%s' "${matching}" | sort -V | tail -n 1
}

# latest_version <origin> [prefix]
#
# Prints the newest release tag an origin publishes, or nothing when it
# cannot be told. `VENDOR_LATEST_VERSION` wins, which is the seam the
# offline test suite uses and the way to drive a host this script does not
# know. A `github.com` origin is asked through `gh`. Anything else prints
# nothing, and the caller reports that it cannot tell rather than claiming
# the source is current.
#
# `prefix` is the source's `tag-prefix`, and it names the kind of release to
# read when an origin publishes more than one. Without it the origin is asked
# which release it calls latest, which is the answer that honours a release
# marked not-latest, and that is why a source declaring no prefix must not be
# answered by reading tags.
latest_version() {
	local origin="$1" prefix="${2:-}"

	# `-` reads as none here as well as in the catalogue. A manifest is
	# hand-editable, and the convention is documented without naming one file,
	# so an author can reasonably write it in either. Taken literally it is a
	# prefix that matches no tag, and the source would report that it cannot
	# tell the latest version with nothing pointing at the cause.
	[[ "${prefix}" == "-" ]] && prefix=""

	if [[ -n "${VENDOR_LATEST_VERSION:-}" ]]; then
		printf '%s' "${VENDOR_LATEST_VERSION}"
		return 0
	fi

	case "${origin}" in
	https://github.com/* | http://github.com/*)
		local repository="${origin#*github.com/}"
		repository="${repository%.git}"
		repository="${repository%/}"
		command -v gh >/dev/null 2>&1 || return 0

		if [[ -z "${prefix}" ]]; then
			gh release view --repo "${repository}" --json tagName --jq .tagName 2>/dev/null || return 0
			return 0
		fi
		# The prefix comes back off, because a caller compares this against
		# the version a source declares and stores it there when it moves. The
		# tag is built again from the prefix wherever an address is needed.
		local newest
		newest="$(prefixed_latest_tag "${repository}" "${prefix}")"
		printf '%s' "${newest#"${prefix}"}"
		;;
	*) return 0 ;;
	esac
}

# cmd_sync <repository>
#
# Syncs every manifest the repository declares. A manifest that fails does
# not end the run: the extensions after it are still fetched, and the ones
# that failed are named again at the end. A run that stopped at the first
# bad manifest left the rest neither fetched nor mentioned, which a
# migration would read as a repository that was done.
cmd_sync() {
	local repository="$1"
	local manifests manifest
	manifests="$(manifest_list "${repository}")" || return 1

	local -a unsynced=()
	while IFS= read -r manifest; do
		[[ -z "${manifest}" ]] && continue
		if ! sync_manifest "${manifest}"; then
			unsynced+=("${manifest#"${repository}"/}")
		fi
	done <<<"${manifests}"

	if [[ "${#unsynced[@]}" -gt 0 ]]; then
		log_error "these extensions were not synced: ${unsynced[*]}"
		return 1
	fi
}

# cmd_check <repository>
#
# Reports every source whose declared version is not the latest its origin
# publishes, naming both versions, and every source whose latest version
# cannot be told. Writes nothing, and exits 0 either way: being behind is
# information for a scheduled job to act on, not a failure of the
# repository.
cmd_check() {
	local repository="$1"
	local manifests manifest
	manifests="$(manifest_list "${repository}")" || return 1

	local behind=0 unknown=0 status=0
	local label source declared latest
	while IFS= read -r manifest; do
		if ! load_manifest "${manifest}"; then
			status=1
			continue
		fi
		if ! require_sources "${manifest}"; then
			status=1
			continue
		fi
		label="${manifest#"${repository}"/}"
		for source in "${MANIFEST_SOURCES[@]}"; do
			declared="$(source_meta "${source}" version)"
			latest="$(latest_version "$(source_meta "${source}" origin)" \
				"$(source_meta "${source}" tag-prefix)")"
			if [[ -z "${latest}" ]]; then
				printf '%s: %s: cannot tell the latest version, declared %s\n' "${label}" "${source}" "${declared}"
				unknown=$((unknown + 1))
			elif [[ "${latest}" != "${declared}" ]]; then
				printf '%s: %s: declared %s, latest %s\n' "${label}" "${source}" "${declared}" "${latest}"
				behind=$((behind + 1))
			fi
		done
	done <<<"${manifests}"

	if [[ "${behind}" -eq 0 && "${unknown}" -eq 0 && "${status}" -eq 0 ]]; then
		printf 'Every declared source is at the latest version its origin publishes.\n'
	fi

	# A source that is behind is not a failure, so the exit code reports
	# only a manifest that could not be read.
	return "${status}"
}

# move_sources <repository> <wanted> <version>
#
# Moves one named source, or every source when the name is empty, to a
# version. An empty version asks each origin for its latest release, which
# is what --update does.
#
# A source is fetched and verified in full before anything is written, and
# the manifest is regenerated only after the files it names are on disk. A
# fetch that fails therefore leaves the manifest exactly as it was: a
# manifest recording a version whose files were never written is worse than
# no change at all.
move_sources() {
	local repository="$1" wanted="$2" version="$3"
	local manifests manifest
	manifests="$(manifest_list "${repository}")" || return 1

	local matched=0 status=0 skipped=0
	local extension_dir changed source target
	while IFS= read -r manifest; do
		if ! load_manifest "${manifest}"; then
			status=1
			skipped=1
			continue
		fi

		# Every source is checked, not only the one being moved, and
		# before anything is fetched or installed. The writer emits the
		# whole manifest, so a sibling that could not be written back
		# would refuse the rewrite after the moved files were already in
		# place, leaving the tree and the manifest disagreeing.
		if ! check_records "${manifest}"; then
			status=1
			skipped=1
			continue
		fi

		extension_dir="$(cd "$(dirname "${manifest}")" && pwd)"
		changed=0

		for source in "${MANIFEST_SOURCES[@]}"; do
			[[ -n "${wanted}" && "${source}" != "${wanted}" ]] && continue
			matched=1

			target="${version}"
			if [[ -z "${target}" ]]; then
				target="$(latest_version "$(source_meta "${source}" origin)" \
					"$(source_meta "${source}" tag-prefix)")"
				if [[ -z "${target}" ]]; then
					log_error "${source}: cannot tell the latest version: name one with --set ${source}=<version>"
					status=1
					continue
				fi
				if [[ "${target}" == "$(source_meta "${source}" version)" ]]; then
					printf '%s: already at %s\n' "${source}" "${target}"
					continue
				fi
			fi

			if [[ "${target}" == *[\"\\]* || "${target}" == *[[:space:]]* ]]; then
				log_error "${source}: a version must not hold a quote, a backslash or a space: ${target}"
				status=1
				continue
			fi

			# --set is where a person types the value, so it is the entry path
			# most likely to carry a tag. The guard on the manifest cannot see
			# it: this value goes to the fetch without the manifest being read
			# again.
			if carries_tag_prefix "$(source_meta "${source}" tag-prefix)" "${target}"; then
				log_error "${source}: $(tag_prefix_error "$(source_meta "${source}" tag-prefix)" "${target}")"
				status=1
				continue
			fi

			if ! vendor_source "${extension_dir}" "${source}" "${target}" record "${manifest}"; then
				status=1
				continue
			fi
			MANIFEST_META["${source}"$'\t'"version"]="${target}"
			changed=1
			printf '%s: moved to %s\n' "${source}" "${target}"
		done

		if [[ "${changed}" -eq 1 ]]; then
			write_manifest "${manifest}" || status=1
		fi
	done <<<"${manifests}"

	# A manifest that was skipped has already said why. Its sources were
	# never examined, so the name asked for may well be declared in it and
	# reporting it as undeclared would be wrong.
	if [[ -n "${wanted}" && "${matched}" -eq 0 && "${skipped}" -eq 0 ]]; then
		log_error "no source named ${wanted} is declared in this repository"
		return 1
	fi

	return "${status}"
}

# cmd_update <repository> [source]
#
# Moves one source, or every source, to the latest version its origin
# publishes, then records what was written.
cmd_update() {
	local repository="$1" wanted="${2:-}"
	move_sources "${repository}" "${wanted}" ""
}

# cmd_set <repository> <source>=<version>
#
# Moves one source to the version named on the command line, which is both
# how a version is pinned and how one is rolled back.
cmd_set() {
	local repository="$1" argument="${2:-}"

	if [[ "${argument}" != *=* ]]; then
		log_error "--set expects <source>=<version>, for example: --set quarto-lua-modules=1.0.0"
		return 2
	fi

	local source="${argument%%=*}" version="${argument#*=}"
	if [[ -z "${source}" || -z "${version}" ]]; then
		log_error "--set expects <source>=<version>, for example: --set quarto-lua-modules=1.0.0"
		return 2
	fi

	move_sources "${repository}" "${source}" "${version}"
}

# The catalogue of sources `--declare` publishes files from. It is read from a
# file rather than built in, so a new upstream release is a change to data
# instead of a change to code.
declare -a CATALOGUE_SOURCES=()
declare -A CATALOGUE_ORIGIN=()
declare -A CATALOGUE_FETCH=()
declare -A CATALOGUE_VERSION=()
declare -A CATALOGUE_LICENCE=()
declare -A CATALOGUE_LICENCE_URL=()
declare -A CATALOGUE_TAG_PREFIX=()
declare -A CATALOGUE_FILES=()
declare -A CATALOGUE_RUNTIME=()
declare -A CATALOGUE_MATCHES=()

# read_catalogue <path>
#
# Reads the catalogue into the store above. Three record kinds, one per line,
# fields separated by whitespace:
#
#   source <name> <origin> <fetch> <version> <licence> <licence-url or -> [tag-prefix]
#   file <source> <name> [runtime]
#   match <source> <version>
#
# A `match` record names an older release the catalogue recognises as well as the
# pinned one, and is repeatable per source. A release stamps its own version
# into the files it publishes, so a copy vendored at one release checksums
# differently at the next, and a catalogue that named the pinned release alone
# would match nothing at all.
#
# Nothing needs quoting, because every field the published manifest format
# allows is free of whitespace by its own grammars. A line this reader cannot
# understand is refused, naming it: a catalogue read as knowing about nothing
# would report every module in a repository as first party and exit 0.
read_catalogue() {
	local path="$1"

	if [[ ! -f "${path}" ]]; then
		log_error "no source catalogue at ${path}: --declare publishes each file from the sources one names"
		return 1
	fi

	CATALOGUE_SOURCES=()
	CATALOGUE_ORIGIN=()
	CATALOGUE_FETCH=()
	CATALOGUE_VERSION=()
	CATALOGUE_LICENCE=()
	CATALOGUE_LICENCE_URL=()
	CATALOGUE_TAG_PREFIX=()
	CATALOGUE_FILES=()
	CATALOGUE_RUNTIME=()
	CATALOGUE_MATCHES=()

	local lineno=0 line kind
	local name origin fetch version licence licence_url tag_prefix
	local source runtime extra
	while IFS= read -r line || [[ -n "${line}" ]]; do
		lineno=$((lineno + 1))
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -z "${line}" || "${line}" == "#"* ]] && continue

		read -r kind _ <<<"${line}"

		case "${kind}" in
		source)
			read -r _ name origin fetch version licence licence_url tag_prefix extra <<<"${line}"
			if [[ -z "${licence_url}" || -n "${extra}" ]]; then
				log_error "${path}:${lineno}: a source record is: source <name> <origin> <fetch> <version> <licence> <licence-url or -> [tag-prefix]"
				return 1
			fi
			if [[ ! "${name}" =~ ${SOURCE_KEY_GRAMMAR} ]]; then
				log_error "${path}:${lineno}: a source name must match ${SOURCE_KEY_GRAMMAR}, found: ${name}"
				return 1
			fi
			if [[ -n "${CATALOGUE_ORIGIN["${name}"]:-}" ]]; then
				log_error "${path}:${lineno}: ${name} is declared twice"
				return 1
			fi
			CATALOGUE_SOURCES+=("${name}")
			CATALOGUE_ORIGIN["${name}"]="${origin}"
			CATALOGUE_FETCH["${name}"]="${fetch}"
			CATALOGUE_VERSION["${name}"]="${version}"
			CATALOGUE_LICENCE["${name}"]="${licence}"
			[[ "${licence_url}" != "-" ]] && CATALOGUE_LICENCE_URL["${name}"]="${licence_url}"
			# The last field is optional, so a record that omits it reads as a
			# source whose origin publishes one kind of release. `-` reads the
			# same way: the field before it spells "none" that way, so an
			# author will spell it that way here too, and taken literally it
			# would be a prefix that matches no tag and a source that reports
			# it cannot tell the latest version.
			[[ -n "${tag_prefix}" && "${tag_prefix}" != "-" ]] &&
				CATALOGUE_TAG_PREFIX["${name}"]="${tag_prefix}"
			if carries_tag_prefix "${tag_prefix}" "${version}"; then
				log_error "${path}:${lineno}: ${name}: $(tag_prefix_error "${tag_prefix}" "${version}")"
				return 1
			fi
			;;
		file)
			read -r _ source name runtime extra <<<"${line}"
			if [[ -z "${name}" || -n "${extra}" ]]; then
				log_error "${path}:${lineno}: a file record is: file <source> <name> [runtime]"
				return 1
			fi
			if [[ -z "${CATALOGUE_ORIGIN["${source}"]:-}" ]]; then
				log_error "${path}:${lineno}: ${source} is not a source this catalogue declares yet"
				return 1
			fi
			if [[ ! "${name}" =~ ${FILE_KEY_GRAMMAR} ]]; then
				log_error "${path}:${lineno}: a file name must match ${FILE_KEY_GRAMMAR}, found: ${name}"
				return 1
			fi
			if [[ -n "${CATALOGUE_RUNTIME["${source}"$'\t'"${name}"]:-}" ]]; then
				log_error "${path}:${lineno}: ${source} declares ${name} twice"
				return 1
			fi
			case " ${KNOWN_RUNTIMES} " in
			*" ${runtime:-any} "*) : ;;
			*)
				log_error "${path}:${lineno}: a runtime is one of ${KNOWN_RUNTIMES}, found: ${runtime}"
				return 1
				;;
			esac
			CATALOGUE_FILES["${source}"]="${CATALOGUE_FILES["${source}"]:-}${name}"$'\n'
			CATALOGUE_RUNTIME["${source}"$'\t'"${name}"]="${runtime:-any}"
			;;
		match)
			read -r _ source version extra <<<"${line}"
			if [[ -z "${version}" || -n "${extra}" ]]; then
				log_error "${path}:${lineno}: a match record is: match <source> <version>"
				return 1
			fi
			if [[ -z "${CATALOGUE_ORIGIN["${source}"]:-}" ]]; then
				log_error "${path}:${lineno}: ${source} is not a source this catalogue declares yet"
				return 1
			fi
			# A matched release takes the prefix as the pinned one does. A
			# stale version here is worse than in a source record, because
			# A matched release that cannot be fetched is tolerated, so this would
			# quietly index less than this file claims.
			if carries_tag_prefix "${CATALOGUE_TAG_PREFIX["${source}"]:-}" "${version}"; then
				log_error "${path}:${lineno}: ${source}: $(tag_prefix_error "${CATALOGUE_TAG_PREFIX["${source}"]}" "${version}")"
				return 1
			fi
			# The pinned version is indexed whatever this file says, so naming
			# it here states the same fact twice.
			if [[ "${version}" == "${CATALOGUE_VERSION["${source}"]}" ]]; then
				log_error "${path}:${lineno}: ${source} pins ${version}, which the source already pins, so matching it again says nothing"
				return 1
			fi
			case $'\n'"${CATALOGUE_MATCHES["${source}"]:-}" in
			*$'\n'"${version}"$'\n'*)
				log_error "${path}:${lineno}: ${source} matches ${version} twice"
				return 1
				;;
			esac
			CATALOGUE_MATCHES["${source}"]="${CATALOGUE_MATCHES["${source}"]:-}${version}"$'\n'
			;;
		*)
			log_error "${path}:${lineno}: a record is a source, a file or a match, found: ${kind}"
			return 1
			;;
		esac
	done <"${path}"

	if [[ "${#CATALOGUE_SOURCES[@]}" -eq 0 ]]; then
		log_error "${path}: declares no source, so --declare has nothing to publish"
		return 1
	fi

	local source
	for source in "${CATALOGUE_SOURCES[@]}"; do
		if [[ -z "${CATALOGUE_FILES["${source}"]:-}" ]]; then
			log_error "${path}: ${source} declares no file"
			return 1
		fi
	done
}

# report_siblings <label> <extension_dir> <source> <name>
#
# Warns about each sibling a vendored module loads that is not beside it. A
# module that cannot load a sibling fails at render time, and a filter that
# fails to load still exits zero, which is the failure the test framework
# exists to catch. Saying so here costs one read of a file already on disk.
report_siblings() {
	local label="$1" extension_dir="$2" source="$3" name="$4"
	local vendor_dir="${extension_dir}/_vendor/${source}"
	local sibling
	while IFS= read -r sibling; do
		[[ -z "${sibling}" ]] && continue
		[[ -e "${vendor_dir}/${sibling}" ]] && continue
		log_warning "${label}: ${source}: ${name} loads the sibling ${sibling}, which is not in _vendor/${source}/, so the vendored module will not find it"
	done < <(grep -oE "load_sibling\([\"'][^\"']+[\"']\)" "${vendor_dir}/${name}" 2>/dev/null |
		sed -E "s/^load_sibling\([\"']//; s/[\"']\)\$//" | sort -u)
}

# declare_catalogue_meta <source>...
#
# Records the source-level values the catalogue holds for each named source.
# Every writer of a manifest runs this, so an extension declared by --declare
# and one updated by --sync carry the same fields.
declare_catalogue_meta() {
	local source
	for source in "$@"; do
		set_source_meta "${source}" origin "${CATALOGUE_ORIGIN["${source}"]}"
		set_source_meta "${source}" fetch "${CATALOGUE_FETCH["${source}"]}"
		set_source_meta "${source}" version "${CATALOGUE_VERSION["${source}"]}"
		set_source_meta "${source}" licence "${CATALOGUE_LICENCE["${source}"]}"
		if [[ -n "${CATALOGUE_LICENCE_URL["${source}"]:-}" ]]; then
			set_source_meta "${source}" licence-url "${CATALOGUE_LICENCE_URL["${source}"]}"
		fi
		# Nothing reads the catalogue again once a manifest exists: --check and
		# --update read the manifest. A prefix left here would be lost for
		# every extension this script creates, and each one would then read the
		# wrong kind of release from an origin that publishes two.
		if [[ -n "${CATALOGUE_TAG_PREFIX["${source}"]:-}" ]]; then
			set_source_meta "${source}" tag-prefix "${CATALOGUE_TAG_PREFIX["${source}"]}"
		fi
	done
}

# The checksum a declared file starts from. A first manifest is written before
# anything is fetched, and nothing can know what an origin will serve, so the
# fetch that follows records the digest that arrived. It is 64 hexadecimal
# characters because the published format accepts nothing else, and it is
# obviously not a digest so a manifest left at this stage cannot be mistaken
# for a verified one.
readonly BOOTSTRAP_SHA256='0000000000000000000000000000000000000000000000000000000000000000'

# catalogue_publishers <file>
#
# Prints every catalogued source that publishes a file name, one per line.
catalogue_publishers() {
	local wanted="$1" source name
	for source in "${CATALOGUE_SOURCES[@]}"; do
		while IFS= read -r name; do
			# A loop whose last body command is a failed test reports that
			# status as its own, and this function runs inside a command
			# substitution under `set -e`, where a source publishing anything
			# after the wanted name would end the run without a word.
			if [[ "${name}" == "${wanted}" ]]; then
				printf '%s\n' "${source}"
			fi
		done <<<"${CATALOGUE_FILES["${source}"]:-}"
	done
}

# manifest_source_declaring <file>
#
# Prints the source the record store declares a file name under, or nothing
# when no source declares it. The first match wins, because a manifest
# declaring one name under two sources is refused before it is written.
manifest_source_declaring() {
	local wanted="$1" source
	for source in "${MANIFEST_SOURCES[@]}"; do
		if [[ -n "${MANIFEST_SHA["${source}"$'\t'"${wanted}"]:-}" ]]; then
			printf '%s' "${source}"
			return 0
		fi
	done
}

# cmd_declare <repository> <file>...
#
# Declares each named file in the repository's extension, against the source
# the catalogue says publishes it, and fetches what it declared. This is how a
# scaffolder starts an extension from the names its template requires: the
# catalogue grammar and the manifest format both live here, so the caller
# names files and reads back where they landed.
#
# One `source<TAB>file` pair is printed per line, after the fetch, so the
# caller can point each require at the vendored path. Nothing else tells it
# which of two catalogued sources published a file.
#
# A file no catalogued source publishes is named and left out: a template's
# first Lua file must not become a blocking dependency on the catalogue. A file
# more than one source publishes is refused, because nothing can tell which of
# them the extension means and a manifest that guessed would vendor one
# source's file under another source's name.
cmd_declare() {
	local repository="$1" named="$1"
	shift

	if ! repository="$(cd "${repository}" 2>/dev/null && pwd)"; then
		log_error "no such directory: ${named}"
		return 1
	fi

	read_catalogue "${VENDOR_SOURCES:-${SCRIPT_DIR}/sources.list}" || return 1

	local extensions status=0
	extensions="$(find_extension_dirs "${repository}")" || status=$?
	if [[ "${status}" -ne 0 ]]; then
		log_error "could not search ${repository}/_extensions for extensions"
		return "${status}"
	fi
	if [[ -z "${extensions}" ]]; then
		log_error "this repository holds no extension to declare anything in: looked for _extensions/<name>/_extension.yml and _extensions/<owner>/<name>/_extension.yml"
		return 1
	fi

	local -a extension_dirs=()
	local path
	while IFS= read -r path; do
		[[ -z "${path}" ]] && continue
		extension_dirs+=("${path%/*}")
	done <<<"${extensions}"

	# A declared file belongs to one extension, and one chosen by sort order is
	# the silent wrong answer: the manifest would land beside a filter that
	# never asked for it, and the filter that did would load nothing.
	if [[ "${#extension_dirs[@]}" -gt 1 ]]; then
		local -a named_dirs=()
		for path in "${extension_dirs[@]}"; do
			named_dirs+=("${path#"${repository}"/}")
		done
		log_error "this repository holds more than one extension, and a declared file belongs to one of them: ${named_dirs[*]}"
		return 1
	fi

	local extension_dir="${extension_dirs[0]}"
	local manifest="${extension_dir}/_dependencies.yml"

	# The fetch below reads every manifest in the repository, and this mode
	# chose one extension. A manifest outside it would be moved to the version
	# this run declared, by a run that never claimed to touch it.
	local other_manifest
	while IFS= read -r other_manifest; do
		[[ -z "${other_manifest}" ]] && continue
		[[ "${other_manifest%/*}" == "${extension_dir}" ]] && continue
		log_error "${other_manifest#"${repository}"/}: a manifest outside the extension this mode writes into, so nothing here can declare anything"
		return 1
	done < <(find_manifests "${repository}")

	# A manifest states everything the extension depends on, so a declaration
	# adds to what it already holds. Starting from an empty store would write a
	# manifest naming this command line alone, and the fetch that follows would
	# remove every file declared before it and report that as a success.
	if [[ -e "${manifest}" ]]; then
		load_manifest "${manifest}" || return 1
	else
		reset_manifest_records
	fi

	# The sources the manifest already declares, as a string, because the tests
	# below ask about membership rather than order.
	local source declared=$'\n'
	for source in "${MANIFEST_SOURCES[@]}"; do
		declared+="${source}"$'\n'
	done

	# A source the manifest did not declare takes its values from the
	# catalogue. One it did declare keeps them: the version it pins and the
	# address it names are a human's statement, and a declaration that
	# overwrote them would roll the extension back without a word.
	local -a new_sources=() fetch_sources=()
	local -a declared_pairs=()
	local file owners other recorded fetching=$'\n' paired=$'\n'
	for file in "$@"; do
		owners="$(catalogue_publishers "${file}")"
		if [[ -z "${owners}" ]]; then
			log_warning "${file}: no catalogued source publishes it, so it was left undeclared"
			continue
		fi
		if [[ "${owners}" == *$'\n'* ]]; then
			log_error "${file}: more than one catalogued source publishes it, so nothing can tell which one this extension means: ${owners//$'\n'/ }"
			return 1
		fi

		# The manifest can hold an ambiguity the catalogue cannot see: a source
		# written by hand, for an origin the catalogue does not name, that
		# already publishes this file. Declaring it again would vendor the same
		# module twice, under two sources, and every require would point at one
		# copy while the other sat beside it.
		other="$(manifest_source_declaring "${file}")"
		if [[ -n "${other}" && "${other}" != "${owners}" ]]; then
			log_error "${file}: ${other} already declares it, so declaring it again under ${owners} would vendor the same file twice"
			return 1
		fi

		# One pair per file, however often the command line names it. A caller
		# reading the same pair twice builds the same rewrite twice.
		case "${paired}" in
		*$'\n'"${owners}"$'\t'"${file}"$'\n'*) continue ;;
		esac
		paired+="${owners}"$'\t'"${file}"$'\n'
		declared_pairs+=("${owners}"$'\t'"${file}")

		# A file already declared keeps the digest recorded for it, so a second
		# declaration neither refetches it nor reports it as unverified. The
		# bootstrap value is not such a digest: it is what a run whose fetch
		# failed left behind, and reading it as one would report the file as
		# declared while nothing had ever fetched it. A digest recorded for a
		# file that is not on disk says what the file should be, not that it is
		# there, so that one is fetched too.
		recorded="${MANIFEST_SHA["${owners}"$'\t'"${file}"]:-}"
		if [[ -n "${recorded}" && "${recorded}" != "${BOOTSTRAP_SHA256}" ]] &&
			[[ -f "${extension_dir}/_vendor/${owners}/${file}" ]]; then
			continue
		fi

		case "${declared}" in
		*$'\n'"${owners}"$'\n'*) : ;;
		*)
			new_sources+=("${owners}")
			declared+="${owners}"$'\n'
			;;
		esac
		case "${fetching}" in
		*$'\n'"${owners}"$'\n'*) : ;;
		*)
			fetch_sources+=("${owners}")
			fetching+="${owners}"$'\n'
			;;
		esac

		remember_source "${owners}"
		set_source_file "${owners}" "${file}" "${BOOTSTRAP_SHA256}" \
			"${CATALOGUE_RUNTIME["${owners}"$'\t'"${file}"]}"
	done

	if [[ "${#declared_pairs[@]}" -eq 0 ]]; then
		log_warning "no catalogued source publishes what was named, so the manifest was left alone"
		return 0
	fi

	# Everything named is already declared, so there is nothing to write and
	# nothing to fetch. The caller still needs to know where each file landed.
	if [[ "${#fetch_sources[@]}" -gt 0 ]]; then
		declare_catalogue_meta "${new_sources[@]}"
		write_manifest "${manifest}" || return 1

		# The progress belongs to the person reading the run, and standard
		# output carries the pairs alone, so a caller can read them without
		# knowing what else this script prints.
		for source in "${fetch_sources[@]}"; do
			move_sources "${repository}" "${source}" "$(source_meta "${source}" version)" >&2 ||
				return 1
		done
	fi

	printf '%s\n' "${declared_pairs[@]}"
}

# cmd_read <repository>
#
# Diagnostic mode: prints every record from every declared manifest, then
# exits. Not a public mode; the test suite uses it to exercise read_manifest
# without depending on --sync being implemented.
cmd_read() {
	local repository="$1"
	local manifests manifest
	manifests="$(manifest_list "${repository}")" || return 1

	while IFS= read -r manifest; do
		read_manifest "${manifest}"
	done <<<"${manifests}"
}

main() {
	local repository
	repository="$(pwd)"
	local mode=""
	local mode_arg=""
	local -a declare_arguments=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-r | --repository)
			repository="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--sync | --check | --read)
			mode="${1#--}"
			shift
			;;
		--update)
			mode="update"
			# The source name is optional, so an option that follows
			# --update belongs to the command line, not to this mode.
			if [[ $# -gt 1 && "$2" != -* ]]; then
				mode_arg="$2"
				shift
			fi
			shift
			;;
		--set)
			mode="set"
			mode_arg="${2:-}"
			[[ $# -gt 1 ]] && shift
			shift
			;;
		--declare)
			mode="declare"
			# Repeatable, because a template names as many shared modules as it
			# needs and every one of them belongs in the same manifest.
			#
			# An option here is the mode the person asked for and did not get.
			# Filed as a file name it would warn that nothing publishes it and
			# exit 0, so the run they wanted would be dropped as a success.
			if [[ $# -lt 2 || "$2" == -* ]]; then
				log_error "--declare expects a file name, for example: --declare logging.lua"
				usage >&2
				exit 2
			fi
			declare_arguments+=("$2")
			shift 2
			;;
		*)
			log_error "unknown option: $1"
			usage >&2
			exit 2
			;;
		esac
	done

	if [[ -z "${mode}" ]]; then
		log_error "no mode given"
		usage >&2
		exit 2
	fi

	# A file named for a run that is no longer declaring anything is a file
	# nothing would fetch, and the run would exit 0 having ignored it.
	if [[ "${#declare_arguments[@]}" -gt 0 && "${mode}" != "declare" ]]; then
		log_error "--declare names what that mode declares, and this run is --${mode}"
		usage >&2
		exit 2
	fi

	# A source and version named for a mode that moves neither is a move
	# nobody makes. --set and --update read it; every other mode would exit 0
	# having ignored what the person typed.
	if [[ -n "${mode_arg}" && "${mode}" != "set" && "${mode}" != "update" ]]; then
		log_error "--set and --update name the source they move, and this run is --${mode}"
		usage >&2
		exit 2
	fi

	case "${mode}" in
	declare) cmd_declare "${repository}" "${declare_arguments[@]}" ;;
	sync) cmd_sync "${repository}" ;;
	check) cmd_check "${repository}" ;;
	update) cmd_update "${repository}" "${mode_arg}" ;;
	set) cmd_set "${repository}" "${mode_arg}" ;;
	read) cmd_read "${repository}" ;;
	esac
}

main "$@"
