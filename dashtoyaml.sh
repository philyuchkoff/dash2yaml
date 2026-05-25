#!/bin/bash

# dashtoyaml.sh - Конвертирует JSON дашборд Grafana в YAML формат для kube-prometheus-stack
# с поддержкой префиксов, суффиксов и папок

#=======================
### КАК ПОЛЬЗОВАТЬСЯ ###
#=======================
## Базовое использование
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml
#
## С префиксом и суффиксом для UID
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml --prefix prod_ --suffix _v1
#
## С указанием папки
#./dashtoyaml.sh dashboard.json dashboards/dashboard.yaml --folder "Production Dashboards"
#
## С заменой лейблов и reporter
#./dashtoyaml.sh istio-dashboard.json dashboards/istio.yaml --replace-labels --fix-reporter
#
## Полный набор опций
#./dashtoyaml.sh dashboard.json dashboards/my.yaml \
#  --prefix stage_ \
#  --suffix _2024 \
#  --folder "Stage Dashboards" \
#  --datasource "Prometheus" \
#  --replace-labels \
#  --fix-reporter
#
## Принудительная установка UID (без добавления панели инструкции)
#./dashtoyaml.sh dashboard.json dashboards/my.yaml --uid custom-uid --no-walkthrough

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция вывода справки
usage() {
    echo -e "${BLUE}Использование:${NC} $0 <input.json> <output.yaml> [options]"
    echo ""
    echo -e "${BLUE}Опции:${NC}"
    echo "  --prefix TEXT       Добавить префикс к UID"
    echo "  --suffix TEXT       Добавить суффикс к UID"
    echo "  --folder NAME       Указать папку для дашборда (добавляется в комментарий)"
    echo "  --datasource NAME   Имя datasource (по умолчанию: Prometheus)"
    echo "  --uid NAME          Принудительно установить UID"
    echo "  --help              Показать эту справку"
    echo ""
    echo -e "${BLUE}Примеры:${NC}"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml --prefix prod --folder 'Production Dashboards'"
    echo "  $0 dashboard.json dashboards/my-dashboard.yaml --datasource 'MyPrometheus'"
    exit 0
}

# Парсинг аргументов
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
                echo -e "${RED}Ошибка: Неизвестный аргумент $1${NC}"
                usage
            fi
            shift
            ;;
    esac
done

# Проверка аргументов
if [ -z "$INPUT_JSON" ] || [ -z "$OUTPUT_YAML" ]; then
    echo -e "${RED}Ошибка: Необходимо указать входной и выходной файлы${NC}"
    usage
fi

# Проверка существования входного файла
if [ ! -f "$INPUT_JSON" ]; then
    echo -e "${RED}Ошибка: Файл $INPUT_JSON не найден${NC}"
    exit 1
fi

# Проверка наличия jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Ошибка: jq не установлен. Установите jq:${NC}"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    echo "  CentOS/RHEL: sudo yum install jq"
    echo "  MacOS: brew install jq"
    exit 1
fi

echo -e "${GREEN}🔧 Обработка дашборда...${NC}"
echo -e "${BLUE}   Входной файл:${NC} $INPUT_JSON"
echo -e "${BLUE}   Выходной файл:${NC} $OUTPUT_YAML"
echo ""

# Создаем временный файл для обработанного JSON
TEMP_JSON=$(mktemp)

# Копируем исходный JSON во временный файл
cp "$INPUT_JSON" "$TEMP_JSON"

# Функция: исправление переменных шаблона из формата [[var]] в формат $var
fix_template_variables() {
    local file="$1"
    
    echo -e "  ${GREEN}✔${NC} Конвертация переменных шаблона из [[var]] в \$var..."
    
    # Создаем временный скрипт Python для обработки
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
        # Заменяем [[var]] на $var
        # Используем raw string для правильной обработки
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

# Функция: исправление datasource в targets (расширенная версия)
fix_datasources() {
    local file="$1"
    local ds_name="$2"
    
    echo -e "  ${GREEN}✔${NC} Исправление datasource ссылок на '$ds_name'..."
    
    jq --arg ds_name "$ds_name" --arg ds_uid "$ds_name" '
    # Функция для создания правильного объекта datasource
    def fix_ds:
        if type == "string" then
            # Обработка строковых ссылок на datasource
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
            # Обработка объекта datasource
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
    
    # Рекурсивно обрабатываем все вхождения datasource
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

# Функция: установка UID
set_uid() {
    local file="$1"
    local uid="$2"
    
    echo -e "  ${GREEN}✔${NC} Установка UID: $uid"
    
    jq --arg uid "$uid" '.uid = $uid' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Функция: добавление аннотации с папкой
add_folder_annotation() {
    local file="$1"
    local folder="$2"
    
    echo -e "  ${GREEN}✔${NC} Добавление аннотации папки '$folder'..."
    
    # Добавляем комментарий в YAML, а не аннотацию в JSON
    # Аннотации в JSON могут быть перезаписаны
}

# Функция: добавление панели-инструкции
add_walkthrough_panel() {
    local file="$1"
    local title="$2"
    
    echo -e "  ${GREEN}✔${NC} Добавление панели Dashboard Walkthrough..."
    
    # Проверяем, есть ли уже панель с инструкцией
    if jq -e '.panels[] | select(.title=="Dashboard Walkthrough")' "$file" > /dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠ Панель Walkthrough уже существует, пропускаем${NC}"
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
                "content": "# 🏥 " + $title + "\n\n**Что показывает дашборд:**\n\n**Как читать:** Наведите на заголовок панели для описания причин и действий.\n\n**Версия:** kube-prometheus-stack v85.0.2 (KSM v2.14+)",
                "mode": "markdown"
            },
            "pluginVersion": "12.2.1"
        }
    ] + .panels
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    
    # Сдвигаем y координаты всех панелей
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

# Функция: конвертация JSON в YAML
convert_to_yaml() {
    local input="$1"
    local output="$2"
    local title=$(jq -r '.title // "untitled"' "$input")
    local uid=$(jq -r '.uid // ( .title | gsub(" "; "-") | ascii_downcase )' "$input")
    
    {
        echo "# $(basename "$output")"
        echo "# Автоматически сгенерировано из $(basename "$INPUT_JSON")"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        
        # Добавляем информацию о папке в комментарий
        if [ -n "$FOLDER_NAME" ]; then
            echo "# Папка: $FOLDER_NAME"
        fi
        
        # Добавляем информацию о datasource
        echo "# Datasource: $DATASOURCE_NAME"
        echo "# yamllint disable-line-length"
        echo ""
        echo "---"  # Document start для yamllint
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
                    
                    # Проверяем все важные поля
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
                    
                    # Проверяем тип для правильной обработки query
                    local item_type=$(echo "$item" | jq -r '.type // "query"')
                    if [ "$item_type" == "query" ]; then
                        # Для query типа поле query является объектом
                        local query_obj=$(echo "$item" | jq -c '.query // {}')
                        if [ "$query_obj" != "{}" ] && [ "$query_obj" != "null" ]; then
                            # Проверяем, есть ли подполе query в объекте query
                            local nested_query=$(echo "$item" | jq -r '.query.query // ""' 2>/dev/null)
                            local ref_id=$(echo "$item" | jq -r '.query.refId // ""' 2>/dev/null)
                            if [ -n "$nested_query" ] && [ "$nested_query" != "null" ]; then
                                echo "      query:"
                                echo "        query: $nested_query"
                                if [ -n "$ref_id" ] && [ "$ref_id" != "null" ]; then
                                    echo "        refId: $ref_id"
                                fi
                            else
                                # Выводим весь объект
                                echo "      query: $query_obj"
                            fi
                        fi
                    else
                        # Для других типов query может быть строкой
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

# Выполнение функций
fix_template_variables "$TEMP_JSON"
fix_datasources "$TEMP_JSON" "$DATASOURCE_NAME"

if [ -n "$FORCED_UID" ]; then
    set_uid "$TEMP_JSON" "$FORCED_UID"
elif [ -n "$UID_PREFIX" ] || [ -n "$UID_SUFFIX" ]; then
    CURRENT_UID=$(jq -r '.uid // ( .title | gsub(" "; "-") | ascii_downcase )' "$TEMP_JSON")
    NEW_UID="${UID_PREFIX}${CURRENT_UID}${UID_SUFFIX}"
    set_uid "$TEMP_JSON" "$NEW_UID"
fi

# Добавляем панель инструкции (опционально, можно отключить)
# add_walkthrough_panel "$TEMP_JSON" "$TITLE"

convert_to_yaml "$TEMP_JSON" "$OUTPUT_YAML"

# Очистка
rm -f "$TEMP_JSON"

# Форматирование через yq (если установлен)
if command -v yq &> /dev/null; then
    echo -e "  ${GREEN}✔${NC} Форматирование YAML через yq..."
    yq eval -P "$OUTPUT_YAML" -o yaml > "${OUTPUT_YAML}.tmp" 2>/dev/null && mv "${OUTPUT_YAML}.tmp" "$OUTPUT_YAML"
fi

# Замена одинарных кавычек на двойные для переменных в expr полях
echo -e "  ${GREEN}✔${NC} Исправление кавычек в expr полях..."

python_script="/tmp/fix_quotes_$$.py"

cat > "$python_script" << 'PYTHON_SCRIPT'
import re
import sys

output_file = sys.argv[1]

with open(output_file, 'r') as f:
    content = f.read()

# Заменяем одинарные кавычки на двойные для переменных в строках с expr
lines = content.split('\n')
result = []
for line in lines:
    if 'expr:' in line:
        # Заменяем '$var' на "$var" для известных переменных
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
echo -e "${GREEN}✅ Дашборд успешно сконвертирован!${NC}"
echo -e "${BLUE}   Входной файл:${NC} $INPUT_JSON"
echo -e "${BLUE}   Выходной файл:${NC} $OUTPUT_YAML"
