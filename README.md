# CentOS Stream RPM Testing Farm Analyzer

This project analyzes all CentOS Stream RPM packages to identify which ones use Testing Farm for testing.

## Overview

The script examines all repositories in the [CentOS Stream RPMs GitLab group](https://gitlab.com/redhat/centos-stream/rpms/) and checks for the presence of `.fmf` files, which indicate Testing Farm usage.

## Prerequisites

- `curl` - for GitLab API calls
- `jq` - for JSON processing
- `bc` - for percentage calculations

## Usage

```bash
# Make the script executable
chmod +x analyze_centos_rpm_packages.sh

# Run the analysis
./analyze_centos_rpm_packages.sh
```

The script will:
1. Fetch all repositories from the CentOS Stream RPMs group
2. Check each repository for `.fmf` files indicating Testing Farm usage
3. Display progress and results
4. Save detailed results to `testing_farm_packages.json`

## Analyzing Results

After running the script, you can analyze the results using `jq`:

```bash
# Count total packages using Testing Farm
jq '.testing_farm_packages | length' testing_farm_packages.json

# Calculate percentage of packages using Testing Farm
echo "scale=1; $(jq '.testing_farm_packages | length' testing_farm_packages.json) * 100 / $(jq '.total_packages' testing_farm_packages.json)" | bc -l

# List package names using Testing Farm
jq -r '.testing_farm_packages[].name' testing_farm_packages.json

# Get URLs for packages using Testing Farm
jq -r '.testing_farm_packages[] | "\(.name): \(.web_url)"' testing_farm_packages.json
```

## Output Format

The script generates `testing_farm_packages.json` with the following structure:

```json
{
  "total_packages": 4442,
  "testing_farm_packages": [
    {
      "name": "package-name",
      "id": 12345,
      "web_url": "https://gitlab.com/redhat/centos-stream/rpms/package-name"
    }
  ],
  "analysis_date": "2025-07-18 12:34:56"
}
```

## How It Works

1. **Group Discovery**: Retrieves the GitLab group ID for `redhat/centos-stream/rpms`
2. **Repository Enumeration**: Fetches all projects in the group using pagination
3. **Testing Farm Detection**: Checks each repository's file tree for `.fmf` files
4. **Result Compilation**: Collects and formats results with package metadata

## Rate Limiting

The script includes built-in rate limiting (0.1 second delays) to avoid overwhelming the GitLab API.

## Example Results

Based on recent analysis:
- **Total packages:** 4,442
- **Using Testing Farm:** 1,388 (31.2%)

This indicates that approximately one-third of CentOS Stream RPM packages are configured for Testing Farm integration.