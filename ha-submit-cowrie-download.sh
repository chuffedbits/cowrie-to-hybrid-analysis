#!/usr/bin/env bash
set -u
set -o pipefail

ENV_FILE="/opt/<yourFolder>/ha.env"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/home/cowrie/cowrie/var/lib/cowrie/downloads}"
RESULTS_DIR="${RESULTS_DIR:-/opt/<yourFolder>/results}"
AUTO_YES=false
FORCE=false
LIST_FILE=""

usage() {
  cat <<USAGE
Usage:
  sudo $0 [--yes] [--force] <hash-or-file> [hash-or-file...]
  sudo $0 [--yes] --list hashes.txt
  printf '%s\n' <hashes> | sudo $0 [--yes] -

Examples:
  sudo $0 <SHA256hash>
  sudo $0 --yes hash1 hash2 /path/to/sample
  sudo $0 --yes --list /tmp/hashes.txt
  sudo awk '{print \$9}' downloads-ls.txt | sudo $0 --yes -

Options:
  --yes      Submit without prompting when no existing HA report is found.
  --force    Submit even if an existing HA report is found.
  --list     Read hashes/paths from a newline-delimited file.
  -h,--help  Show this help.
USAGE
}

die() {
  echo "[!] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

trim_line() {
  local line="$1"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
  printf '%s' "$line"
}

is_sha256() {
  [[ "$1" =~ ^[A-Fa-f0-9]{64}$ ]]
}

load_env() {
  [ -r "$ENV_FILE" ] || die "Cannot read $ENV_FILE. Run with sudo or fix permissions."

  set -a
  source "$ENV_FILE"
  set +a

  [ -n "${HA_API_KEY:-}" ] || die "HA_API_KEY is missing in $ENV_FILE"
  [ -n "${HA_ENVIRONMENT_ID:-}" ] || die "HA_ENVIRONMENT_ID is missing in $ENV_FILE"
}

resolve_sample() {
  local input="$1"

  if [ -f "$input" ]; then
    printf '%s' "$input"
    return 0
  fi

  if is_sha256 "$input" && [ -f "$DOWNLOAD_DIR/$input" ]; then
    printf '%s' "$DOWNLOAD_DIR/$input"
    return 0
  fi

  return 1
}

ha_get_summary() {
  local sha256="$1"
  local out="$2"

  curl -sS \
    -H "api-key: $HA_API_KEY" \
    -H "User-Agent: Falcon" \
    -H "accept: application/json" \
    "https://hybrid-analysis.com/api/v2/report/${sha256}:${HA_ENVIRONMENT_ID}/summary" \
    -o "$out"
}

ha_submit_file() {
  local sample="$1"
  local sha256="$2"
  local out="$3"

  curl -sS \
    -H "api-key: $HA_API_KEY" \
    -H "User-Agent: Falcon" \
    -H "accept: application/json" \
    -F "file=@${sample};type=application/octet-stream" \
    -F "environment_id=${HA_ENVIRONMENT_ID}" \
    "https://hybrid-analysis.com/api/v2/submit/file" \
    -o "$out"
}

prompt_submit() {
  local sha256="$1"

  if [ "$AUTO_YES" = true ]; then
    return 0
  fi

  printf '[?] Submit %s to Hybrid Analysis? Type yes, all, or skip: ' "$sha256" >&2
  read -r answer

  case "$answer" in
    yes)
      return 0
      ;;
    all)
      AUTO_YES=true
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

process_one() {
  local input="$1"
  local sample
  local sha256
  local result_dir
  local check_json
  local submit_json
  local meta_txt
  local file_type

  if ! sample="$(resolve_sample "$input")"; then
    echo "[!] Skipping: cannot resolve to file or Cowrie download hash: $input"
    return 1
  fi

  sha256="$(sha256sum "$sample" | awk '{print $1}')"
  result_dir="$RESULTS_DIR/$sha256"
  check_json="$result_dir/check.json"
  submit_json="$result_dir/submit.json"
  meta_txt="$result_dir/meta.txt"

  mkdir -p "$result_dir"

  echo "===== $sha256 ====="
  echo "[+] Sample: $sample"
  echo "[+] SHA256: $sha256"

  file_type="$(file -b "$sample" || true)"
  echo "[+] Type: $file_type"

  {
    echo "sample=$sample"
    echo "sha256=$sha256"
    echo "environment_id=$HA_ENVIRONMENT_ID"
    echo "file_type=$file_type"
    echo "checked_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta_txt"

  echo "[+] Checking Hybrid Analysis for existing report..."
  if ! ha_get_summary "$sha256" "$check_json"; then
    echo "[!] HA check request failed. See: $check_json"
  fi

  if jq -e '.sha256? or .state? or .verdict? or .threat_score?' "$check_json" >/dev/null 2>&1; then
    echo "[+] Existing HA report found:"
    jq '{sha256, state, verdict, threat_score, analysis_start_time, analysis_finished_time}' "$check_json"

    if [ "$FORCE" != true ]; then
      echo "[+] Skipping submit because report exists. Use --force to submit anyway."
      return 0
    fi

    echo "[+] --force set, continuing to submit anyway."
  else
    echo "[+] No existing environment-specific HA report found."
    jq -r '.message? // empty' "$check_json" 2>/dev/null | sed 's/^/[HA] /' || true
  fi

  if ! prompt_submit "$sha256"; then
    echo "[+] Skipped by user."
    return 0
  fi

  echo "[+] Submitting file..."
  if ! ha_submit_file "$sample" "$sha256" "$submit_json"; then
    echo "[!] Submit request failed. See: $submit_json"
    return 1
  fi

  echo "[+] Submit response:"
  jq . "$submit_json" 2>/dev/null || cat "$submit_json"

  if jq -e '.job_id? and .submission_id?' "$submit_json" >/dev/null 2>&1; then
    echo "[+] Saved results in $result_dir"
    return 0
  fi

  echo "[!] Submission may have failed or returned a non-job response. See: $submit_json"
  return 1
}

need_cmd curl
need_cmd jq
need_cmd sha256sum
need_cmd file
load_env

inputs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)
      AUTO_YES=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --list)
      LIST_FILE="${2:-}"
      [ -n "$LIST_FILE" ] || die "--list requires a file path"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -)
      while IFS= read -r line; do
        line="$(trim_line "$line")"
        [ -n "$line" ] && inputs+=("$line")
      done
      shift
      ;;
    *)
      inputs+=("$1")
      shift
      ;;
  esac
done

if [ -n "$LIST_FILE" ]; then
  [ -r "$LIST_FILE" ] || die "Cannot read list file: $LIST_FILE"
  while IFS= read -r line; do
    line="$(trim_line "$line")"
    [ -n "$line" ] && inputs+=("$line")
  done < "$LIST_FILE"
fi

if [ "${#inputs[@]}" -eq 0 ] && [ ! -t 0 ]; then
  while IFS= read -r line; do
    line="$(trim_line "$line")"
    [ -n "$line" ] && inputs+=("$line")
  done
fi

[ "${#inputs[@]}" -gt 0 ] || {
  usage
  exit 1
}

failures=0

for input in "${inputs[@]}"; do
  if ! process_one "$input"; then
    failures=$((failures + 1))
  fi
  echo
  sleep 8
done

if [ "$failures" -gt 0 ]; then
  echo "[!] Completed with $failures failure(s)."
  exit 1
fi

echo "[+] Completed successfully."
EOF
