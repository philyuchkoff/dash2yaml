#!/bin/bash

# dashtoyaml.sh - Converts Grafana JSON dashboard to YAML format for kube-prometheus-stack
# with support for prefixes, suffixes, and folders

#=======================
### HOW TO USE ###
#=======================
## Basic usage
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml
#
## With prefix and suffix for UID
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml --prefix prod_ --suffix _v1
#
## With folder specification
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml --folder "Production Dashboards"
#
## With label replacement and reporter fix
#./dashtoyaml.sh istio-dashboard.json dashboards/istio.yaml --replace-labels --fix-reporter
#
## Full set of options
#./dashtoyaml.sh dashboard.json dashboards/my.yaml \
#  --prefix stage_ \
#  --suffix _2024 \
#  --folder "Stage Dashboards" \
#  --datasource "Prometheus" \
#  --replace-labels \
#  --fix-reporter
#
## Force UID (without adding walkthrough panel)
#./dashtoyaml.sh dashboard.json dashboards/my.yaml --uid custom-uid --no-walkthrough

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display help
usage() {
    echo -e "${BLUE}Usage:${NC} $0 <input.json> <output.yaml> [options]"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  --prefix TEXT       Add prefix to UID"
    echo "  --suffix TEXT       Add suffix to UID"
    echo "  --folder NAME       Specify folder for dashboard (added as comment)"
    echo "  --datasource NAME   Datasource name (default: Prometheus)"
    echo "  --uid NAME          Force specific UID"
    echo "  --help              Show this help"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml --prefix prod --folder 'Production Dashboards'"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml --datasource 'MyPrometheus'"
    exit 0
}

# Parse arguments
INPUT_JSON=""
OUTPUT_YAML=""
UID_PREFIX=""
UID_SUFFIX=""
FOLDER_NAME=""
DATASOURCE_NAME="Prometheus"
FORCED_UID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            UID_PREFIX="$2"
            shift 2
            ;;
        --suffix)
            UID_SUFFIX="$2"
            shift 2
            ;;
        --folder)
            FOLDER_NAME="$2"
            shift 2
            ;;
        --datasource)
            DATASOURCE_NAME="$2"
            shift 2
            ;;
        --uid)
            FORCED_UID="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            if [ -z "$INPUT_JSON" ]; then
                INPUT_JSON="$1"
            elif [ -z "$OUTPUT_YAML" ]; then
                OUTPUT_YAML="$1"
            else
                echo -e "${RED}Error: Unknown argument $1${NC}"
                usage
            fi
            shift
            ;;
    esac
done

# Check arguments
if [ -z "$INPUT_JSON" ] || [ -z "$OUTPUT_YAML" ]; then
    echo -e "${RED}Error: Input and output files are required${NC}"
    usage
fi

# Check if input file exists
if [ ! -f "$INPUT_JSON" ]; then
    echo -e "${RED}Error: File $INPUT_JSON not found${NC}"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed. Install jq:${NC}"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    echo "  CentOS/RHEL: sudo yum install jq"
    echo "  MacOS: brew install jq"
    exit 1
fi

echo -e "${GREEN}🔧 Processing dashboard...${NC}"
echo -e "${BLUE}   Input file:${NC} $INPUT_JSON"
echo -e "${BLUE}   Output file:${NC} $OUTPUT_YAML"
echo ""

# Create temporary file for processed JSON
TEMP_JSON=$(mktemp)

# Copy source JSON to temporary file
cp "$INPUT_JSON" "$TEMP_JSON"

# Function: fix template variables from [[var]] to $var format
fix_template_variables() {
    local file="$1"
    
    echo -e "  ${GREEN}✔${NC} Converting template variables from [[var]] to \$var..."
    
    # Create temporary Python script for processing
    local python_script="/tmp/fix_vars_$$.py"
    
    cat > "$python_script" << 'PYTHON_EOF'
import json
import re
import sys

file_path = sys.argv[1]

with open(file_path, 'r') as f:
    data = json.load(f)

def fix_vars(obj):
    if isinstance(obj, dict):
        return {k: fix_vars(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [fix_vars(item) for item in obj]
    elif isinstance(obj, str):
        # Replace [[var]] with $var
        # Use raw string for proper handling
        return re.sub(r'\[\[([^\]]+)\]\]', r'$\1', obj)
    else:
        return obj

data = fix_vars(data)

with open(file_path + '.tmp', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYTHON_EOF
    
    python3 "$python_script" "$file"
    
    mv "$file.tmp" "$file"
    rm -f "$python_script"
}

# Function: fix datasource in targets (extended version)
fix_datasources() {
    local file="$1"
    local ds_name="$2"
    
    echo -e "  ${GREEN}✔${NC} Fixing datasource references to '$ds_name'..."
    
    jq --arg ds_name "$ds_name" --arg ds_uid "$ds_name" '
    # Function to create correct datasource object
    def fix_ds:
        if type == "string" then
            # Handle string datasource references
            if . == "${datasource}" or . == "$datasource" or 
               . == "${DS_PROMETHEUS}" or . == "$DS_PROMETHEUS" or
               . == "prometheus" or . == "Prometheus" then
                {
                    "uid": $ds_uid,
                    "type": "prometheus",
                    "name": $ds_name
                }
            else
                .
            end
        elif type == "object" then
            # Handle datasource object
            if .uid == "${datasource}" or .uid == "$datasource" or 
               .uid == "${DS_PROMETHEUS}" or .uid == "$DS_PROMETHEUS" or
               .uid == "prometheus" or .uid == "Prometheus" or
               (.uid == null and .type == "prometheus") then
                {
                    "uid": $ds_uid,
                    "type": "prometheus",
                    "name": $ds_name
                }
            else
                .
            end
        else
            .
        end;
    
    # Recursively process all datasource occurrences
    def recursive_fix:
        walk(
            if type == "object" then
                if has("datasource") then
                    .datasource = (.datasource | fix_ds)
                end
            else
                .
            end
        );
    
    recursive_fix
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Function: set UID
set_uid() {
    local file="$1"
    local uid="$2"
    
    echo -e "  ${GREEN}✔${NC} Setting UID: $uid"
    
    jq --arg uid "$uid" '.uid = $uid' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Function: add annotation with folder
add_folder_annotation() {
    local file="$1"
    local folder="$2"
    
    echo -e "  ${GREEN}✔${NC} Adding folder annotation '$folder'..."
    
    # Add comment in YAML instead of annotation in JSON
    # JSON annotations may be overwritten
}

# Function: add instruction panel
add_walkthrough_panel() {
    local file="$1"
    local title="$2"
    
    echo -e "  ${GREEN}✔${NC} Adding Dashboard Walkthrough panel..."
    
    # Check if instruction panel already exists
    if jq -e '.panels[] | select(.title=="Dashboard Walkthrough")' "$file" > /dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠ Walkthrough panel already exists, skipping${NC}"
        return
    fi
    
    jq --arg title "$title" '
    .panels = [
        {
            "id": 100,
            "title": "Dashboard Walkthrough",
            "type": "text",
            "gridPos": {
                "h": 3,
                "w": 24,
                "x": 0,
                "y": 0
            },
            "options": {
                "content": "# 🏥 " + $title + "\n\n**What this dashboard shows:**\n\n**How to read:** Hover over panel title for description of causes and actions.\n\n**Version:** kube-prometheus-stack v85.0.2 (KSM v2.14+)",
                "mode": "markdown"
            },
            "pluginVersion": "12.2.1"
        }
    ] + .panels
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    
    # Shift y coordinates of all panels
    jq '
    def shift_y(amount):
        if .gridPos and .gridPos.y then
            .gridPos.y += amount
        else
            .
        end;
    
    .panels |= map(shift_y(3))
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Function: convert JSON to YAML
convert_to_yaml() {
    local input="$1"
    local output="$2"
    local title=$(jq -r '.title // "untitled"' "$input")
    local uid=$(jq -r '.uid // ( .title | gsub(" "; "-") | ascii_downcase )' "$input")
    
    {
        echo "# $(basename "$output")"
        echo "# Automatically generated from $(basename "$INPUT_JSON")"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        
        # Add folder information as comment
        if [ -n "$FOLDER_NAME" ]; then
            echo "# Folder: $FOLDER_NAME"
        fi
        
        # Add datasource information
        echo "# Datasource: $DATASOURCE_NAME"
        echo "# yamllint disable-line-length"
        echo ""
        echo "---"  # Document start for yamllint
        echo ""
        
        echo "title: $title"
        echo "uid: $uid"
        echo "version: $(jq -r '.version // 1' "$input")"
        
        echo "tags:"
        jq -r '.tags // [] | .[]' "$input" | while read -r tag; do
            echo "  - $tag"
        done
        
        echo "time:"
        echo "  from: $(jq -r '.time.from // "now-6h"' "$input")"
        echo "  to: $(jq -r '.time.to // "now"' "$input")"
        echo "timepicker: {}"
        
        echo "schemaVersion: $(jq -r '.schemaVersion // 36' "$input")"
        echo "style: $(jq -r '.style // "dark"' "$input")"
        echo "editable: $(jq -r '.editable // true' "$input")"
        echo "graphTooltip: $(jq -r '.graphTooltip // 0' "$input")"
        
        local refresh_val=$(jq -r '.refresh // ""' "$input")
        if [ -n "$refresh_val" ] && [ "$refresh_val" != "null" ]; then
            echo "refresh: $refresh_val"
        fi
        
        local timezone=$(jq -r '.timezone // ""' "$input")
        if [ -n "$timezone" ] && [ "$timezone" != "null" ]; then
            echo "timezone: $timezone"
        fi
        
        echo "annotations:"
        jq -c '.annotations // {list:[]}' "$input" | jq '.' | sed 's/^/  /'
        
        echo "panels:"
        jq -c '.panels // []' "$input" | jq '.' | while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo "  $line"
            fi
        done
        
        echo "templating:"
        echo "  list:"
        local templating_list=$(jq -c '.templating.list // []' "$input")
        if [ "$templating_list" != "[]" ]; then
            jq -c '.templating.list[]' "$input" 2>/dev/null | while read -r item; do
                if [ -n "$item" ] && [ "$item" != "null" ]; then
                    echo "    - name: $(echo "$item" | jq -r '.name // "unnamed"')"
                    echo "      type: $(echo "$item" | jq -r '.type // "query"')"
                    
                    # Check all important fields
                    local all_value=$(echo "$item" | jq -r '.allValue // ""' 2>/dev/null)
                    if [ -n "$all_value" ] && [ "$all_value" != "null" ]; then
                        echo "      allValue: $all_value"
                    fi
                    
                    local current=$(echo "$item" | jq -c '.current // {}' 2>/dev/null)
                    if [ "$current" != "{}" ]; then
                        echo "      current: $current"
                    fi
                    
                    local datasource=$(echo "$item" | jq -c '.datasource // {}' 2>/dev/null)
                    if [ "$datasource" != "{}" ]; then
                        echo "      datasource: $datasource"
                    fi
                    
                    local definition=$(echo "$item" | jq -r '.definition // ""' 2>/dev/null)
                    if [ -n "$definition" ] && [ "$definition" != "null" ]; then
                        echo "      definition: $definition"
                    fi
                    
                    echo "      hide: $(echo "$item" | jq -r '.hide // 0')"
                    echo "      includeAll: $(echo "$item" | jq -r '.includeAll // false')"
                    echo "      label: $(echo "$item" | jq -r '.label // ""')"
                    echo "      multi: $(echo "$item" | jq -r '.multi // false')"
                    
                    options=$(echo "$item" | jq -c '.options // []' 2>/dev/null)
                    if [ "$options" != "[]" ]; then
                        echo "      options: $options"
                    fi
                    
                    # Check type for correct query handling
                    local item_type=$(echo "$item" | jq -r '.type // "query"')
                    if [ "$item_type" == "query" ]; then
                        # For query type, the query field is an object
                        local query_obj=$(echo "$item" | jq -c '.query // {}')
                        if [ "$query_obj" != "{}" ] && [ "$query_obj" != "null" ]; then
                            # Check if there is a query subfield in the query object
                            local nested_query=$(echo "$item" | jq -r '.query.query // ""' 2>/dev/null)
                            local ref_id=$(echo "$item" | jq -r '.query.refId // ""' 2>/dev/null)
                            if [ -n "$nested_query" ] && [ "$nested_query" != "null" ]; then
                                echo "      query:"
                                echo "        query: $nested_query"
                                if [ -n "$ref_id" ] && [ "$ref_id" != "null" ]; then
                                    echo "        refId: $ref_id"
                                fi
                            else
                                # Output the entire object
                                echo "      query: $query_obj"
                            fi
                        fi
                    else
                        # For other types, query may be a string
                        local query=$(echo "$item" | jq -r '.query // ""' 2>/dev/null)
                        if [ -n "$query" ] && [ "$query" != "null" ]; then
                            echo "      query: $query"
                        fi
                    fi
                    
                    echo "      refresh: $(echo "$item" | jq -r '.refresh // 1')"
                    
                    local regex=$(echo "$item" | jq -r '.regex // ""' 2>/dev/null)
                    if [ -n "$regex" ] && [ "$regex" != "null" ]; then
                        echo "      regex: $regex"
                    fi
                    
                    local sort=$(echo "$item" | jq -r '.sort // 0' 2>/dev/null)
                    echo "      sort: $sort"
                    
                    echo "      skipUrlSync: false"
                    echo "      useTags: $(echo "$item" | jq -r '.useTags // false')"
                    
                fi
            done
        else
            echo "    []"
        fi
        
    } > "$output"
}

# Execute functions
fix_template_variables "$TEMP_JSON"
fix_datasources "$TEMP_JSON" "$DATASOURCE_NAME"

if [ -n "$FORCED_UID" ]; then
    set_uid "$TEMP_JSON" "$FORCED_UID"
elif [ -n "$UID_PREFIX" ] || [ -n "$UID_SUFFIX" ]; then
    CURRENT_UID=$(jq -r '.uid // ( .title | gsub(" "; "-") | ascii_downcase )' "$TEMP_JSON")
    NEW_UID="${UID_PREFIX}${CURRENT_UID}${UID_SUFFIX}"
    set_uid "$TEMP_JSON" "$NEW_UID"
fi

    # Add instruction panel (optional, can be disabled)
    # add_walkthrough_panel "$TEMP_JSON" "$TITLE"

convert_to_yaml "$TEMP_JSON" "$OUTPUT_YAML"

# Cleanup
rm -f "$TEMP_JSON"

# Format via yq (if installed)
if command -v yq &> /dev/null; then
    echo -e "  ${GREEN}✔${NC} Formatting YAML via yq..."
    yq eval -P "$OUTPUT_YAML" -o yaml > "${OUTPUT_YAML}.tmp" 2>/dev/null && mv "${OUTPUT_YAML}.tmp" "$OUTPUT_YAML"
fi

# Replace single quotes with double quotes for variables in expr fields
echo -e "  ${GREEN}✔${NC} Fixing quotes in expr fields..."

python_script="/tmp/fix_quotes_$$.py"

cat > "$python_script" << 'PYTHON_SCRIPT'
import re
import sys

output_file = sys.argv[1]

with open(output_file, 'r') as f:
    content = f.read()

# Replace single quotes with double quotes for variables in expr lines
lines = content.split('\n')
result = []
for line in lines:
    if 'expr:' in line:
        # Replace '$var' with "$var" for known variables
        line = re.sub(r"'(\$client_id)'", r'"\1"', line)
        line = re.sub(r"'(\$instance)'", r'"\1"', line)
        line = re.sub(r"'(\$aggr_criteria)'", r'"\1"', line)
        line = re.sub(r"'(\$topic)'", r'"\1"', line)
    result.append(line)

with open(output_file, 'w') as f:
    f.write('\n'.join(result))
PYTHON_SCRIPT

python3 "$python_script" "$OUTPUT_YAML"
rm -f "$python_script"

echo ""
echo -e "${GREEN}✅ Dashboard successfully converted!${NC}"
echo -e "${BLUE}   Input file:${NC} $INPUT_JSON"
echo -e "${BLUE}   Output file:${NC} $OUTPUT_YAML"
