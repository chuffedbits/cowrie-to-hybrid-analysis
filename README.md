# cowrie-to-hybrid-analysis

A small helper for submitting Cowrie honeypot downloads to Hybrid Analysis.

It accepts one sample or many samples, checks Hybrid Analysis for an existing report first, then submits missing samples for public sandbox analysis.

## What It Does

`ha-submit-cowrie-download.sh` will:

- accept a Cowrie download file path
- accept a SHA256 hash from Cowrie’s `downloads/` directory
- accept many hashes or paths as command-line arguments
- accept a newline-delimited list with `--list`
- accept hashes or paths from stdin
- check Hybrid Analysis for an existing report
- optionally submit the sample if no report exists
- save local metadata and API responses per sample

Results are written under:

```text
/opt/<yourFolder>/results/<sha256>/
```

# Requirements
Tested on Ubuntu/Debian-style systems.

## Required tools:

```
sudo apt-get update
sudo apt-get install -y curl jq file coreutils
```

You also need:

- a Cowrie honeypot with downloaded samples
- a Hybrid Analysis API key
- a Hybrid Analysis environment ID

**NOTE: This script submits to Hybrid Analysis as public scans. Do not submit anything you are not comfortable sharing publicly.**

# Expected Cowrie Layout

By default, the script expects Cowrie downloads here:
```
/home/cowrie/cowrie/var/lib/cowrie/downloads
```

Cowrie usually stores downloaded samples by SHA256 hash, for example:
```
/home/cowrie/cowrie/var/lib/cowrie/downloads/<SHA256>
```

You can override the downloads directory with:

```
DOWNLOAD_DIR="/path/to/downloads" sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh ...
```

# Install

Create a working directory:
```
sudo mkdir -p /opt/<yourFolder>/results
sudo chmod 750 /opt/<yourFolder>
```

Install the script:
```
sudo install -m 750 ha-submit-cowrie-download.sh /opt/<yourFolder>/ha-submit-cowrie-download.sh
```

Create the environment file:

```
sudo tee /opt/<yourFolder>/ha.env >/dev/null <<'EOF'
HA_API_KEY="PASTE_YOUR_HYBRID_ANALYSIS_API_KEY_HERE"
HA_ENVIRONMENT_ID="330"
EOF
```

```
sudo chmod 600 /opt/<yourFolder>/ha.env
```

**NOTE: Environment ID 330 is commonly used for Linux Ubuntu 24.04 64-bit in Hybrid Analysis, but confirm the environment you want in your HA account.**

## Usage

Submit One Sample by Full Path
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh \
  /home/cowrie/cowrie/var/lib/cowrie/downloads/<SHA256>
```

Submit One Sample by Hash
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh \
  <SHA256>
```

When given a hash, the script looks for the sample at:
```
$DOWNLOAD_DIR/<hash>
```

Batch Submit Multiple Hashes
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes \
  <SHA256> \
  <SHA256>
```

Batch Submit from a File

Create a newline-delimited list:
```
cat >/tmp/cowrie-hashes.txt <<'EOF'
<SHA256>
<SHA256>
EOF
```

Submit:
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes --list /tmp/cowrie-hashes.txt
```

Batch Submit from Stdin
```
printf '%s\n' \
  <SHA256> \
  <SHA256> \
| sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes -
```

Submit Everything in Cowrie Downloads

*Use this carefully. It will attempt every SHA256-looking filename in the downloads directory.
```
sudo find /home/cowrie/cowrie/var/lib/cowrie/downloads -maxdepth 1 -type f -printf '%f\n' \
  | grep -E '^[a-fA-F0-9]{64}$' \
  | sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes -
Options
--yes, -y   Submit without prompting when no existing HA report is found.
--force     Submit even if an existing HA report is found.
--list      Read hashes/paths from a newline-delimited file.
-h, --help  Show usage help.
```

# Checking Results

List saved submission responses:
```
sudo find /opt/<yourFolder>/results -maxdepth 2 -type f -name 'submit.json' -print
```

Pretty-print all submissions:
```
sudo find /opt/<yourFolder>/results -maxdepth 2 -type f -name 'submit.json' \
  -exec sh -c 'echo "===== $1 ====="; jq . "$1"' _ {} \;
```

A successful submission usually includes:
```
{
  "job_id": "...",
  "submission_id": "...",
  "environment_id": 330,
  "sha256": "..."
}
```

# Poll Hybrid Analysis Reports

Once submissions are queued, poll report summaries:
```
sudo bash -c '
set -a
source /opt/<yourFolder>/ha.env
set +a

for submit in /opt/<yourFolder>/results/*/submit.json; do
  hash="$(jq -r ".sha256 // empty" "$submit")"
  env_id="$(jq -r ".environment_id // env.HA_ENVIRONMENT_ID" "$submit")"

  [ -z "$hash" ] && continue

  echo "===== $hash / env $env_id ====="
  curl -s \
    -H "api-key: $HA_API_KEY" \
    -H "User-Agent: Falcon" \
    -H "accept: application/json" \
    "https://hybrid-analysis.com/api/v2/report/${hash}:${env_id}/summary" \
  | jq "{sha256, state, verdict, threat_score, analysis_start_time, analysis_finished_time, error: .message}"
  echo
done
'
```

Useful states:
```
SUCCESS       report is ready
IN_PROGRESS   analysis is still running
not found      not analyzed yet, wrong environment, or submission failed
```

Example Workflow
```
sudo ls -lh /home/cowrie/cowrie/var/lib/cowrie/downloads
sudo find /home/cowrie/cowrie/var/lib/cowrie/downloads -maxdepth 1 -type f -printf '%f\n' \
  | grep -E '^[a-fA-F0-9]{64}$' \
  > /tmp/cowrie-hashes.txt
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes --list /tmp/cowrie-hashes.txt
sudo find /opt/<yourFolder>/results -maxdepth 2 -type f -name 'submit.json' \
  -exec sh -c 'echo "===== $1 ====="; jq . "$1"' _ {} \;
```

# Troubleshooting
| "*I only see old results*"

Check whether new submit.json files exist:
```
sudo find /opt/<yourFolder>/results -maxdepth 2 -type f -name 'submit.json' -print
```

If not, the script probably did not submit the new files. Re-run without suppressing output:
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh --yes --list /tmp/cowrie-hashes.txt
```

| "*Permission denied reading Cowrie downloads*"

Cowrie download files are often owned by the cowrie user and not world-readable.

Run with sudo:
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh <hash>
```
| "*Permission denied reading /opt/<yourFolder>/ha.env*"

The env file should be readable only by root.

Run with sudo:
```
sudo /opt/<yourFolder>/ha-submit-cowrie-download.sh <hash>
```
| "*No existing report found, but I know it exists*"

Hybrid Analysis reports are environment-specific. The script checks:

<sha256>:<HA_ENVIRONMENT_ID>

If the sample was analyzed in another environment, this environment-specific lookup may not find it.

| "*The script exits quickly*"

That can happen if:
- all samples already have reports
- inputs did not resolve to files
- `--yes` was not used and prompts were skipped
- API returned an error

Check each sample folder:
```
sudo find /opt/<yourFolder>/results -maxdepth 2 -type f -name 'check.json' \
  -exec sh -c 'echo "===== $1 ====="; jq . "$1"' _ {} \;
```

# Security Notes

- Hybrid Analysis public scans are public. Treat submissions as shared intelligence.
- Do not submit private, sensitive, or third-party confidential files.
- Keep /opt/<yourFolder>/ha.env locked down with chmod 600.
- Implement outbound firewall controls on honeypot VMs so malware cannot freely call home.
- Do not execute Cowrie downloads on the honeypot host!

# License
MIT
