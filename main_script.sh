

BASE_DIR="$(realpath "$(dirname "$0")")"
REPO_DIR="$BASE_DIR/Zapret-Discord-youtube-linux"
REPO_URL="https://github.com/Flowseal/zapret-discord-youtube"
NFQWS_PATH="$BASE_DIR/nfqws"
CONF_FILE="$BASE_DIR/conf.env"
STOP_SCRIPT="$BASE_DIR/stop_and_clean_nft.sh"


DEBUG=false
NOINTERACTIVE=false
QUIET=false
cd
_term() {
    sudo /usr/bin/env bash $STOP_SCRIPT
}
trap _term SIGINT


log() {
    if ! $QUIET; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}


debug_log() { :; }


handle_error() {
    echo "[ОШИБКА] $1" >&2
    exit 1
}


check_dependencies() {
    local deps=("git" "nft" "grep" "sed")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            handle_error "Не установлена утилита $dep"
        fi
    done
}


load_config() {
    [ -f "$CONF_FILE" ] || handle_error "Нет файла конфига!"
    source "$CONF_FILE"
    if [ -z "$interface" ] || [ -z "$auto_update" ] || [ -z "$strategy" ]; then
        handle_error "В конфиге не хватает обязательных параметров"
    fi
}


setup_repository() {
    if [ -d "$REPO_DIR" ]; then
        if $NOINTERACTIVE && [ "$auto_update" != "true" ]; then
            return
        fi
        read -p "Репа уже есть. Обновить? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]] || $NOINTERACTIVE && [ "$auto_update" == "true" ]; then
            rm -rf "$REPO_DIR"
        else
            return
        fi
    fi

    git clone "$REPO_URL" "$REPO_DIR" || handle_error "Ошибка клонирования"
    cd "$REPO_DIR" && git checkout dcdb0a3dce0675e3ac8d226a238865e060f8c6be && cd ..
    chmod +x "$BASE_DIR/rename_bat.sh"
    rm -rf "$REPO_DIR/.git"
    "$BASE_DIR/rename_bat.sh" || handle_error "Ошибка переименования"
}

find_bat_files() {
    find "." -type f -name "$1" -print0
}

select_strategy() {
    cd "$REPO_DIR" || handle_error "Не перейти в $REPO_DIR"

    if $NOINTERACTIVE; then
        [ -f "$strategy" ] || handle_error "Файл стратегии $strategy не найден"
        parse_bat_file "$strategy"
        cd ..
        return
    fi

    local IFS=$'\n'
    local bat_files=($(find_bat_files "general*.bat" | xargs -0 -n1 echo) $(find_bat_files "discord.bat" | xargs -0 -n1 echo))

    [ ${#bat_files[@]} -eq 0 ] && cd .. && handle_error "Нет .bat файлов"

    echo "Доступные стратегии:"
    select strategy in "${bat_files[@]}"; do
        [ -n "$strategy" ] && break
        echo "Неверный выбор."
    done

    parse_bat_file "$REPO_DIR/$strategy"
    cd ..
}

parse_bat_file() {
    local file="$1"
    local queue_num=0
    local bin_path="bin/"
    while IFS= read -r line; do
        [[ "$line" =~ ^[:space:]*:: || -z "$line" ]] && continue
        [[ "$line" =~ ^set[[:space:]]+BIN=%~dp0bin\\ ]] && continue
        line="${line//%BIN%/$bin_path}"
        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]](.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"
            nfqws_args="${nfqws_args//%LISTS%/lists/}"
            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            nfqws_params+=("$nfqws_args")
            ((queue_num++))
        fi
    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')
}

setup_nftables() {
    local interface="$1"
    local table_name="inet zapretunix"
    local chain_name="output"
    local rule_comment="Added by zapret script"

    if sudo nft list tables | grep -q "$table_name"; then
        sudo nft flush chain $table_name $chain_name
        sudo nft delete chain $table_name $chain_name
        sudo nft delete table $table_name
    fi

    sudo nft add table $table_name
    sudo nft add chain $table_name $chain_name { type filter hook output priority 0\; }

    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule $table_name $chain_name oifname \"$interface\" ${nft_rules[$queue_num]} comment \"$rule_comment\" ||
        handle_error "Ошибка добавления правила nftables $queue_num"
    done
}

start_nfqws() {
    sudo pkill -f nfqws
    cd "$REPO_DIR" || handle_error "Не перейти в $REPO_DIR"
    for queue_num in "${!nfqws_params[@]}"; do
        eval "sudo $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}" ||
        handle_error "Ошибка запуска nfqws $queue_num"
    done
}

main() {
    while [[ "$1" =~ ^- ]]; do
        case "$1" in
            -debug) DEBUG=true ;;
            -nointeractive) NOINTERACTIVE=true ;;
            -quiet) QUIET=true ;;
        esac
        shift
    done

    $NOINTERACTIVE && load_config

    check_dependencies
    setup_repository

    if $NOINTERACTIVE; then
        select_strategy
        setup_nftables "$interface"
    else
        select_strategy
        interfaces=($(ls /sys/class/net))
        [ ${#interfaces[@]} -eq 0 ] && handle_error "Интерфейсы не найдены"
        echo "Доступные интерфейсы:"
        select interface in "${interfaces[@]}"; do
            [ -n "$interface" ] && break
            echo "Неверный выбор."
        done
        setup_nftables "$interface"
    fi

    start_nfqws
    echo "✅ Всё готово."
}

main "$@"

sleep infinity &
wait

