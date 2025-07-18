#!/bin/bash

# Script to analyze CentOS Stream RPM packages for Testing Farm usage
# Checks for .fmf files in each repository

set -euo pipefail

# Configuration
GITLAB_URL="https://gitlab.com"
GROUP_PATH="redhat/centos-stream/rpms"
OUTPUT_FILE="testing_farm_packages.json"
TEMP_DIR=$(mktemp -d)
RESULTS_FILE="$TEMP_DIR/results.txt"

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Check dependencies
check_dependencies() {
    echo "Checking dependencies..."
    local missing_deps=()
    
    for cmd in curl jq bc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}"
        echo "Please install: ${missing_deps[*]}"
        exit 1
    fi
    echo "Dependencies OK"
}

# Get group ID for the CentOS Stream RPMs group
get_group_id() {
    local encoded_path
    encoded_path=$(echo "$GROUP_PATH" | sed 's|/|%2F|g')
    
    echo "Getting group ID for $GROUP_PATH..." >&2
    echo "Encoded path: $encoded_path" >&2
    
    local response
    response=$(curl -s "$GITLAB_URL/api/v4/groups/$encoded_path")
    local curl_exit_code=$?
    
    if [ $curl_exit_code -ne 0 ]; then
        echo "Error: Failed to fetch group information (curl exit code: $curl_exit_code)" >&2
        exit 1
    fi
    
    echo "Got response, parsing JSON..." >&2
    local group_id
    group_id=$(echo "$response" | jq -r '.id' 2>/dev/null)
    
    if [ "$group_id" = "null" ] || [ -z "$group_id" ]; then
        echo "Error: Could not get group ID for $GROUP_PATH" >&2
        echo "Response: $response" >&2
        exit 1
    fi
    
    echo "Found group ID: $group_id" >&2
    echo "$group_id"
}

# Get all projects in the group
get_all_projects() {
    local group_id=$1
    local page=1
    local per_page=100
    local all_projects="$TEMP_DIR/all_projects.json"
    
    echo "[]" > "$all_projects"
    
    echo "Fetching all projects..." >&2
    
    while true; do
        local url="$GITLAB_URL/api/v4/groups/$group_id/projects"
        local params="page=$page&per_page=$per_page&simple=true&archived=false"
        
        local page_projects
        page_projects=$(curl -s "$url?$params")
        
        # Check if we got valid JSON
        if ! echo "$page_projects" | jq empty 2>/dev/null; then
            echo "Error: Invalid JSON response from GitLab API" >&2
            echo "Response: $page_projects" >&2
            exit 1
        fi
        
        local count
        count=$(echo "$page_projects" | jq length 2>/dev/null || echo "0")
        
        if [ -z "$count" ] || [ "$count" -eq 0 ]; then
            break
        fi
        
        # Merge with existing projects
        jq -s '.[0] + .[1]' "$all_projects" <(echo "$page_projects") > "$TEMP_DIR/merged.json"
        mv "$TEMP_DIR/merged.json" "$all_projects"
        
        echo "Fetched $count projects from page $page" >&2
        
        ((page++))
        sleep 0.1  # Rate limiting
    done
    
    local total_count
    total_count=$(jq length "$all_projects")
    echo "Total projects found: $total_count" >&2
    
    if [ "$total_count" -eq 0 ]; then
        echo "No projects found. This might be a permission issue or the group doesn't exist." >&2
        exit 1
    fi
    
    echo "$all_projects"
}

# Check if a project has .fmf files
check_fmf_files() {
    local project_id=$1
    local project_name=$2
    
    local url="$GITLAB_URL/api/v4/projects/$project_id/repository/tree"
    local params="recursive=true&per_page=100"
    
    local files
    files=$(curl -s "$url?$params" 2>/dev/null)
    
    # Check if we got valid JSON
    if ! echo "$files" | jq empty 2>/dev/null; then
        return 1
    fi
    
    # Check for .fmf files or directories
    local fmf_count
    fmf_count=$(echo "$files" | jq '[.[] | select(.name | endswith(".fmf") or . == ".fmf")] | length' 2>/dev/null || echo "0")
    
    [ "$fmf_count" -gt 0 ]
}

# Analyze all packages
analyze_packages() {
    echo "Starting package analysis..."
    
    echo "About to call get_group_id..."
    local group_id
    group_id=$(get_group_id)
    echo "Got group_id: $group_id"
    
    echo "Getting projects list..."
    local projects_file
    projects_file=$(get_all_projects "$group_id")
    
    local total_projects
    total_projects=$(jq length "$projects_file")
    
    echo "Analyzing $total_projects packages for Testing Farm usage..."
    echo "=========================================="
    
    # Initialize results
    echo "[]" > "$RESULTS_FILE"
    
    local current=0
    local testing_farm_count=0
    
    # Process each project
    if [ "$total_projects" -eq 0 ]; then
        echo "No projects to analyze"
        return
    fi
    
    while IFS= read -r project; do
        ((current++))
        
        local project_name
        local project_id
        local project_url
        
        project_name=$(echo "$project" | jq -r '.name')
        project_id=$(echo "$project" | jq -r '.id')
        project_url=$(echo "$project" | jq -r '.web_url')
        
        printf "[%d/%d] Analyzing %s... " "$current" "$total_projects" "$project_name"
        
        if check_fmf_files "$project_id" "$project_name"; then
            echo "✓ Uses Testing Farm"
            ((testing_farm_count++))
            
            # Add to results
            local new_entry
            new_entry=$(jq -n --arg name "$project_name" --arg id "$project_id" --arg url "$project_url" \
                '{name: $name, id: ($id | tonumber), web_url: $url}')
            
            jq ". += [$new_entry]" "$RESULTS_FILE" > "$TEMP_DIR/updated_results.json"
            mv "$TEMP_DIR/updated_results.json" "$RESULTS_FILE"
        else
            echo "✗ No Testing Farm usage detected"
        fi
        
        sleep 0.1  # Rate limiting
    done < <(jq -c '.[]' "$projects_file")
    
    # Output final results
    output_results "$total_projects" "$testing_farm_count"
}

# Output the analysis results
output_results() {
    local total_projects=$1
    local testing_farm_count=$2
    
    echo
    echo "============================================================"
    echo "ANALYSIS RESULTS"
    echo "============================================================"
    echo "Total packages analyzed: $total_projects"
    echo "Packages using Testing Farm: $testing_farm_count"
    
    if [ "$total_projects" -gt 0 ]; then
        local percentage
        percentage=$(echo "scale=1; $testing_farm_count * 100 / $total_projects" | bc -l)
        echo "Percentage: $percentage%"
    fi
    
    if [ "$testing_farm_count" -gt 0 ]; then
        echo
        echo "Packages using Testing Farm:"
        echo "----------------------------------------"
        
        jq -r '.[] | "• \(.name)\n  URL: \(.web_url)"' "$RESULTS_FILE"
    fi
    
    # Create final output file
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    jq -n \
        --arg total "$total_projects" \
        --arg timestamp "$timestamp" \
        --slurpfile packages "$RESULTS_FILE" \
        '{
            total_packages: ($total | tonumber),
            testing_farm_packages: $packages[0],
            analysis_date: $timestamp
        }' > "$OUTPUT_FILE"
    
    echo
    echo "Results saved to $OUTPUT_FILE"
}

# Main execution
main() {
    echo "CentOS Stream RPM Package Testing Farm Analysis"
    echo "==============================================="
    
    check_dependencies
    analyze_packages
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi