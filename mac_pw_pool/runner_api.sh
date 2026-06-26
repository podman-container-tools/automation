
# This library provides GitHub Actions runner API operations.
# Intended to be sourced by other scripts in this directory.
# Requires:
#   - $GITHUB_TOKEN environment variable
#   - pw_lib.sh to be sourced first (for msg/warn functions and $DH_REQ_VAL)

# Global associative arrays for runner state
declare -A runner_ids
declare -A runner_statuses

# Get a runner registration token from GitHub
# Returns token on stdout, or returns 1 on failure
# Token expires after 1 hour and is used once during runner registration
get_registration_token() {
    local api_response=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/orgs/podman-container-tools/actions/runners/registration-token)

    local http_code=$(echo "$api_response" | tail -n1)
    local response_body=$(echo "$api_response" | head -n-1)

    if [[ "$http_code" != "201" ]]; then
        local error_msg=$(echo "$response_body" | jq -r '.message // "Unknown error"')
        warn "Failed to get registration token (HTTP $http_code): $error_msg"
        return 1
    fi

    local token=$(echo "$response_body" | jq -r '.token')
    if [[ -z "$token" ]] || [[ "$token" == "null" ]]; then
        warn "Failed to extract token from GitHub API response"
        return 1
    fi

    echo "$token"
    return 0
}

# Create the runner group in GitHub Actions (idempotent)
# Returns 0 on success, 1 on failure
create_runner_group() {
    local runner_group="$DH_REQ_VAL"

    # Try to create the runner group (idempotent - 422 means it already exists)
    local create_response=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/podman-container-tools/actions/runner-groups" \
        -d "{\"name\":\"$runner_group\",\"visibility\":\"all\",\"allows_public_repositories\":true}")

    local http_code=$(echo "$create_response" | tail -n1)
    local response_body=$(echo "$create_response" | head -n-1)

    if [[ "$http_code" == "201" ]]; then
        msg "Created runner group '$runner_group' with public repository access"
        return 0
    elif [[ "$http_code" == "409" ]] || [[ "$http_code" == "422" ]]; then
        # Group already exists - this is normal and expected on subsequent runs
        # GitHub returns 409 (Conflict) for duplicate names
        return 0
    else
        local error_msg=$(echo "$response_body" | jq -r '.message // "Unknown error"')
        warn "Failed to ensure runner group '$runner_group' (HTTP $http_code): $error_msg"
        return 1
    fi
}

# Fetch all runners from GitHub API
# Returns 0 on success, 1 on API failure
# Populates global arrays: runner_ids, runner_statuses (idempotent - safe to call multiple times)
fetch_all_runners() {
    # Already fetched - skip
    [[ ${#runner_ids[@]} -gt 0 ]] && return 0

    # Get all runners for the organization
    local runners_response=$(curl -sS -w "\n%{http_code}" -X GET \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/podman-container-tools/actions/runners?per_page=100")

    local http_code=$(echo "$runners_response" | tail -n1)
    local response_body=$(echo "$runners_response" | head -n-1)

    if [[ "$http_code" != "200" ]]; then
        local error_msg=$(echo "$response_body" | jq -r '.message // "Unknown error"')
        warn "Failed to list runners (HTTP $http_code): $error_msg"
        return 1
    fi

    # Parse all runners into global arrays
    # Use prefixed variable names to avoid polluting outer scope
    local _name _id _status
    while IFS='|' read -r _name _id _status; do
        runner_ids["$_name"]="$_id"
        runner_statuses["$_name"]="$_status"
    done < <(echo "$response_body" | jq -r '.runners[]? | "\(.name)|\(.id)|\(.status)"')

    return 0
}

# Find which group a runner belongs to by querying all runner groups
# Args: $1 = runner_name
# Returns: group name on stdout, empty if not found in any group
# The runner_group_name field in /actions/runners is unreliable (often null),
# so we query the runner-groups endpoint which is authoritative.
get_runner_group() {
    local runner_name="$1"

    local groups_response=$(curl -sS -w "\n%{http_code}" -X GET \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/podman-container-tools/actions/runner-groups")

    local groups_http_code=$(echo "$groups_response" | tail -n1)
    local groups_body=$(echo "$groups_response" | head -n-1)

    if [[ "$groups_http_code" != "200" ]]; then
        local error_msg=$(echo "$groups_body" | jq -r '.message // "Unknown error"')
        warn "Failed to list runner groups (HTTP $groups_http_code): $error_msg"
        return 1
    fi

    # Check each group to find where this runner is registered
    while IFS='|' read -r group_id group_name; do
        local group_runners_response=$(curl -sS -w "\n%{http_code}" -X GET \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/orgs/podman-container-tools/actions/runner-groups/${group_id}/runners")

        local gr_http_code=$(echo "$group_runners_response" | tail -n1)
        local gr_body=$(echo "$group_runners_response" | head -n-1)

        if [[ "$gr_http_code" == "200" ]]; then
            if echo "$gr_body" | jq -e ".runners[]? | select(.name == \"$runner_name\")" > /dev/null 2>&1; then
                echo "$group_name"
                return 0
            fi
        fi
    done < <(echo "$groups_body" | jq -r '.runner_groups[]? | "\(.id)|\(.name)"')

    # Not found in any group
    echo "Default"
    return 0
}

# Remove a runner from GitHub
# Args: $1 = runner_name, $2 = runner_id
# Returns 0 on success, 1 on failure
remove_runner() {
    local runner_name="$1"
    local runner_id="$2"

    local delete_response=$(curl -sS -w "\n%{http_code}" -X DELETE \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/podman-container-tools/actions/runners/$runner_id")

    local delete_code=$(echo "$delete_response" | tail -n1)

    if [[ "$delete_code" == "204" ]]; then
        msg "Successfully removed runner '$runner_name' (ID: $runner_id)"
        # Update global cache to reflect deletion
        unset runner_ids["$runner_name"]
        unset runner_statuses["$runner_name"]
        return 0
    else
        warn "Failed to remove runner '$runner_name' (HTTP $delete_code)"
        return 1
    fi
}

# Check and fix runner group conflict for a specific runner
# Args: $1 = runner_name
# Returns 0 if safe to proceed, 1 if unresolvable conflict exists
# Prerequisite: fetch_all_runners must be called first to populate global arrays
# See: https://github.com/actions/runner/issues/3585
# The --replace flag ignores --runnergroup, so we must handle runners
# that exist in different groups. We auto-remove offline ones as a workaround.
check_runner_conflict() {
    local runner_name="$1"
    local target_group="$DH_REQ_VAL"

    # Runner doesn't exist - safe to proceed
    [[ -z "${runner_ids[$runner_name]}" ]] && return 0

    local runner_id="${runner_ids[$runner_name]}"
    local runner_status="${runner_statuses[$runner_name]}"

    # Find which group this runner belongs to
    local existing_group
    existing_group=$(get_runner_group "$runner_name") || return 1

    # Runner in correct group - safe to proceed
    [[ "$existing_group" == "$target_group" ]] && return 0

    # Runner in wrong group - try to fix based on status
    case "$runner_status" in
        offline|disabled)
            msg "Removing $runner_status runner '$runner_name' from wrong group '$existing_group'"
            remove_runner "$runner_name" "$runner_id"
            ;;
        *)
            warn "Runner '$runner_name' is $runner_status in group '$existing_group' (target: '$target_group')"
            return 1
            ;;
    esac
}
