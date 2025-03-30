#!/bin/bash

: << SCRIPT_HEADER
SYNOPSIS
Lists available Edge plugins.

DESCRIPTION
Retrieves the plugins currently configured for Edge, displaying version and status.

FUNCTIONALITY
On-demand

OUTPUTS
Name                                 Type               Description
------------------------------------------------------------------------------------------------------------------------
MicrosoftEdgePluginsCount            Int                Number of Edge plugins installed
MicrosoftEdgePluginsNames            StringList         Edge plugins names, followed by version and status (Enabled, Disabled or N/A)

FURTHER INFORMATION
A Edge browser which version is higher than 65 must be installed.
Edge installation comes with default extensions that are hidden to the user. However, the Remote Action's output will list them.
These extensions may be, but not limited to:
    - Edge Media Router
    - GMail
    - Google Drive
    - YouTube
    - Edge Web Store Payments.

NOTES
Context:            user
Version:            1.1.1.3 - MacOS adaptation
                    1.1.1.2 - Updated the output MicrosoftEdgePluginsName to set as "-" when empty
                    1.1.1.1 - Added not null check before output
                    1.1.1.0 - Removed the default execution triggers for API and Manual
                    1.1.0.0 - Deprecating Python in favour of OSAScript
                    1.0.2.0 - Added OS information to the name of the Remote Action
                    1.0.1.0 - Fixed python version used in the Remote Action
                    1.0.0.0 - Initial release
Last Modified:      2025/03/30  18:21:47
Author:             Laurent Taupiac (Nexthink adaptation)
SCRIPT_HEADER

. "${NEXTHINK}"/bash/nxt_ra_script_output.sh

export PATH='/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin'

# NXT_OUTPUTS_BEGIN
output_edge_plugins_count=0
output_edge_plugins_names=()
# NXT_OUTPUTS_END

# CONSTANTS_DEFINITION
readonly MINIMUM_MACOS_VERSION=(10 13)
readonly ROOT_USER_EUID=0

readonly EDGE_APP_DIR='/Applications/Microsoft Edge.app'
readonly EDGE_DEFAULT_PROFILE_PATH="/Users/$USER/Library/Application Support/Microsoft Edge/Default"
readonly EDGE_PREFERENCES_FILE="$EDGE_DEFAULT_PROFILE_PATH/Preferences"
readonly EDGE_SECURE_PREFERENCES_FILE="$EDGE_DEFAULT_PROFILE_PATH/Secure Preferences"
readonly EDGE_EXTENSIONS_DIR="$EDGE_DEFAULT_PROFILE_PATH/Extensions"

# CONSTANTS_MANAGEMENT
function get_edge_app_dir {
    echo "$EDGE_APP_DIR"
}

function get_edge_preferences_file {
    echo "$EDGE_PREFERENCES_FILE"
}

function get_edge_secure_preferences_file {
    echo "$EDGE_SECURE_PREFERENCES_FILE"
}

function get_edge_extensions_dir {
    echo "$EDGE_EXTENSIONS_DIR"
}

function main {
    test_macos_version
    test_running_as_user
    test_browser_version

    update_edge_plugins
    update_engine_output_variables
}

# COMMON_FUNCTIONS_BEGIN
function test_macos_version {
    current_version="$(get_macos_version)"
    if [[ ${current_version} =~ ^([0-9]{2})\.([0-9]{1,2}) ]]; then
        major_version="${BASH_REMATCH[1]}"
        minor_version="${BASH_REMATCH[2]}"
        if (( major_version <= MINIMUM_MACOS_VERSION[0] &&
              minor_version < MINIMUM_MACOS_VERSION[1] )); then
            exit_with_error "Unsupported macOS version: ${current_version}"
        fi
    else
        exit_with_error "The macOS version format is invalid: ${current_version}"
    fi
}

function get_macos_version {
    /usr/bin/sw_vers -productVersion
}

function test_running_as_user {
    (( $(get_current_user_uid) != ROOT_USER_EUID )) || \
        exit_with_error 'This remote action can only be run as user (non-root)'
}

function get_current_user_uid {
    echo "$EUID"
}

function exit_with_error () {
    call_context=$(caller)
    line_number="${call_context%% *}"

    nxt_write_output_error "Line ${line_number}: $1"
    exit 1
}

function test_directory_exists () {
    local path="$1"

    if [[ ! -d "$path" ]]; then
        exit_with_error "Directory: '$path' is not accessible or it does not exist"
    fi
}

function make_version_comparison () {
    local compared="$1"
    local operator="$2"
    local comparator="$3"

    if [[ ! $operator =~ \<|\>|== ]]; then
        return 1
    fi

    local relationship="$(get_version_relationship "$compared" "$comparator")"

    if [[ "$relationship" == "$operator" ]]; then
        return 0
    fi

    return 1
}

function get_version_relationship () {
    local compared="$1"
    local comparator="$2"
    local relationship='=='

    if [[ "$compared" == "$comparator" ]]
    then
        echo "$relationship"
        return 0
    fi

    local IFS=.
    local i compared_arr=($compared) comparator_arr=($comparator)

    for (( i=${#compared_arr[@]}; i<${#comparator_arr[@]}; i++ ))
    do
        compared_arr[i]=0
    done

    for (( i=0; i<${#compared_arr[@]}; i++ ))
    do
        if [[ -z ${comparator_arr[i]} ]]
        then
            comparator_arr[i]=0
        fi

        if (( compared_arr[i] > comparator_arr[i] ))
        then
            relationship='>'
            break
        fi

        if (( compared_arr[i] < comparator_arr[i] ))
        then
            relationship='<'
            break
        fi
    done

    echo "$relationship"
}

function get_json_value {
    local json_data="$1"
    local json_key="$2"
    local json_is_file=${3:-isnotfile}
    local json_value

    if [[ -z $1 ]] || [[ -z $2 ]];then
        exit_with_error "$INPUT_ERROR" "You must provide at least two valid arguments: get_json_value \$data \$key"
    fi

    if [[ $json_is_file == "isfile" ]];then
        if [[ ! -f "$json_data" ]];then
            exit_with_error "$INPUT_ERROR" "$json_data file does not exist"
        fi
        json_data=$(/bin/cat "$json_data")
    fi

    json_value=$(JSON="$json_data" /usr/bin/osascript -l 'JavaScript' \
                                   -e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
                                   -e "JSON.parse(env).$json_key")
    echo "$json_value"
}
# COMMON_FUNCTIONS_END

# EDGE_BROWSER_MANAGEMENT
function test_browser_version {
    local edge_app_dir="$(get_edge_app_dir)"
    test_directory_exists "$edge_app_dir"

    local version="$(get_edge_version "$edge_app_dir")"

    if [[ -z "$version" ]]; then
        exit_with_error 'Edge version not found'
    fi

    if make_version_comparison "$version" '<' '65'; then
        exit_with_error 'This script is compatible with Edge 65 onwards'
    fi
}

function get_edge_version () {
    local edge_app_dir="$1"
    local version="$(get_version_from_plist "$edge_app_dir")"

    if [[ "$version" =~ [0-9]{2}.[0-9]{1,4}.[0-9]{1,4}.[0-9]{1,4} ]]; then
        echo "$version"
    fi
}

function get_version_from_plist () {
    local edge_app_dir="$1"

    /usr/bin/plutil -extract CFBundleShortVersionString xml1 -o - "$edge_app_dir/Contents/Info.plist" | \
    /usr/bin/xmllint --xpath '//string/text()' -
}

# EDGE_PLUGINS_MANAGEMENT
function update_edge_plugins {
    local edge_extensions_dir="$(get_edge_extensions_dir)"
    if [[ ! -d "$edge_extensions_dir" ]]; then
        exit_with_error "Could not obtain plugins information: The path '$edge_extensions_dir' does not exist"
    fi

    local IFS=$'\n'
    for plugin_path in $(get_plugin_paths "$edge_extensions_dir"); do
        output_edge_plugins_count="$((output_edge_plugins_count + 1))"
        update_plugin_details "$plugin_path"
    done

    if (( output_edge_plugins_count == 0 )); then
        nxt_write_output_error 'There are no plugins installed on Edge'
    fi
}

function get_plugin_paths () {
    local path="$1"

    /usr/bin/find "$path" -type d -maxdepth 1 -regex '.*/[a-z]\{32\}'
}

function update_plugin_details () {
    local plugin_path="$1"
    local last_version_path="$(get_plugin_last_version_path "$plugin_path")"
    local plugin_id="${plugin_path##*/}"

    if [[ -n $last_version_path ]]; then
        local plugin_name

        if plugin_name="$(get_plugin_name "$last_version_path")"; then
            local plugin_status="$(get_plugin_status "$plugin_id")"
            local version="$(get_clean_version_from_path "$last_version_path")"

            output_edge_plugins_names+=("$plugin_name $version; $plugin_status")
        else
            nxt_write_output_error "Error while retrieving plugin name for plugin ID $plugin_id: $plugin_name"
        fi
    else
        nxt_write_output_error "Error while retrieving version path for plugin with ID '$plugin_id'"
    fi
}

function get_plugin_status () {
    local plugin_id="$1"
    local status_value="$(get_plugin_status_by_id "$plugin_id")"
    local status_string="$(get_status_str "$status_value")"

    if [[ "$status_string" == 'N/A' ]]; then
        nxt_write_output_error "Could not retrieve status for plugin ID $plugin_id"
    fi

    echo "$status_string"
}

function get_plugin_status_by_id () {
    local plugin_id="$1"
    local state=''
    local extensions_json_path="$(get_edge_preferences_file)"

    if [[ -f "$extensions_json_path" ]]; then
        state="$(get_json_value "$extensions_json_path" "extensions.settings.$plugin_id.state" "isfile")"
    fi

    if [[ -z "$state" ]]; then
        extensions_json_path="$(get_edge_secure_preferences_file)"
        if [[ -f "$extensions_json_path" ]]; then
            state="$(get_json_value "$extensions_json_path" "extensions.settings.$plugin_id.state" "isfile")"
        fi
    fi

    echo "$state"
}

function get_status_str () {
    local status="$1"

    case "$status" in
        '0')
            echo 'Disabled'
            ;;
        '1')
            echo 'Enabled'
            ;;
        *)
            echo 'N/A'
            ;;
    esac
}

function get_plugin_last_version_path () {
    local path="$1"
    local last_version_path=''
    local last_version_to_compare=''
    local IFS=$'\n'

    for version_dir in $(get_plugin_version_directories "$path"); do
        if [[ -z "$last_version_to_compare" ]]; then
            last_version_path="$version_dir"
            last_version_to_compare="$(get_clean_version_from_path "$version_dir")"
            continue
        fi

        local current_version="$(get_clean_version_from_path "$version_dir")"

        if make_version_comparison "$current_version" '>' "$last_version_to_compare"; then
            last_version_path="$version_dir"
            last_version_to_compare="$current_version"
        fi
    done

    if [[ -z "$last_version_path" ]]; then
        nxt_write_output_error "Could not detect any version installed in plugin path $path"
    fi

    echo "$last_version_path"
}

function get_clean_version_from_path () {
    local path="$1"
    local version="${path##*/}"

    echo "${version/_/.}"
}

function get_plugin_version_directories () {
    local plugin_path="$1"

    /usr/bin/find "$plugin_path" -type d -maxdepth 1 -regex '.*/[0-9]\{1,6\}.[0-9]\{1,6\}.*'
}

function get_plugin_name () {
    local version_path="$1"
    local manifest_json_path="$version_path/manifest.json"
    local name="$(get_json_value "$manifest_json_path" "name" "isfile")"

    if [[ -z "$name" ]]; then
        echo 'Could not get name from manifest.json'
        return 1
    elif [[ $name =~ __MSG_*_ ]]; then
        local locale="$(get_json_value "$manifest_json_path" "default_locale" "isfile")"

        if [[ -z "$locale" ]]; then
            echo 'Could not get default_locale from manifest.json'
            return 1
        fi

        local localized_json_path="$version_path/_locales/$locale/messages.json"

        if ! name="$(get_name_from_locale_json "$localized_json_path" "$name")"; then
            echo "Could not get display name from '$locale' messages.json"
            return 1
        fi
    fi

    echo "$name"
}

function get_name_from_locale_json () {
    local json_path="$1"
    local name="$2"
    local label_name="$(get_label_name "$name")"

    if [[ -z "$label_name" ]]; then
        return 1
    fi

    local locale_json_name="$(get_json_value "$json_path" "$label_name.message" "isfile")"

    if [[ -z "$locale_json_name" ]]; then
        return 1
    fi

    echo "$locale_json_name"
}

function get_label_name () {
    local name="$1"
    local clean_label="${name##*MSG_}"

    echo "${clean_label%%__}"
}

# NXT_OUTPUT_MANAGEMENT
function update_engine_output_variables {
    if [[ -z "$output_edge_plugins_count" ]]; then
        output_edge_plugins_count=0
    fi
    if [[ -z "$output_edge_plugins_names" ]]; then
        output_edge_plugins_names+=("-")
    fi

    nxt_write_output_uint32 'MicrosoftEdgePluginsCount' "$output_edge_plugins_count"
    nxt_write_output_string_list 'MicrosoftEdgePluginsNames' "${output_edge_plugins_names[@]}"
}

main >&2; exit $?
