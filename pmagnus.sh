#!/usr/bin/bash

# Author : Adrian K. (https://github.com/adriankubinyete)
# Organization : Phonevox (https://github.com/phonevox)

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
_LOG_FILE="./teste.log"
_LOG_LEVEL=3 # 0:test, 1:trace, 2:debug, 3:info, 4:warn, 5:error, 6:fatal
_LOG_ROTATE_PERIOD=7

# Versioning 
REPO_OWNER="phonevox"
REPO_NAME="pmagnus"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"
ZIP_URL="$REPO_URL/archive/refs/heads/main.zip"
APP_VERSION="v$(grep '"version"' $CURRDIR/lib/version.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')"

# === FLAG GENERATION ===
source "$CURRDIR/lib/ezflags.sh"
source "$CURRDIR/lib/uzful.sh"

# Script flags
add_flag "b" "backup" "Faz um backup do seu MagnusBilling" bool
add_flag "i" "import" "Importa um arquivo de backup do MagnusBilling para o seu servidor atual" string
add_flag "y" "accept" "Assume 'sim' para todas interações e roda de forma não-interativa" bool

# Version flags
add_flag "v" "version" "Show app version and exit" bool
add_flag "upd:HIDDEN" "update" "Update this script to the newest version" bool
add_flag "fu:HIDDEN" "force-update" "Force the update even if its in the same version" bool

# === GENERATING ===
set_description "Esse script é utilizado tanto para fazer um backup do MagnusBilling, quanto para importar um arquivo de backup."
set_usage "bash $FULL_SCRIPT_PATH [flags]"
parse_flags $@

# ==============================================================================================================
# VERSION CONTROL, UPDATES

function check_for_updates() {
    local FORCE_UPDATE="false"; if [[ -n "$1" ]]; then FORCE_UPDATE="true"; fi
    local CURRENT_VERSION=$APP_VERSION
    local LATEST_VERSION="$(curl -s https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tags | grep '"name":' | head -n 1 | sed 's/.*"name": "\(.*\)",/\1/')"

    # its the same version
    if ! version_is_greater "$LATEST_VERSION" "$CURRENT_VERSION"; then
        echo "$(colorir verde "You are using the latest version. ($CURRENT_VERSION)")"
        if ! $FORCE_UPDATE; then exit 1; fi
    else
        echo "You are not using the latest version. (CURRENT: '$CURRENT_VERSION', LATEST: '$LATEST_VERSION')"
    fi

    echo "Do you want to download the latest version from source? ($(colorir azul "$CURRENT_VERSION") -> $(colorir azul "$LATEST_VERSION")) ($(colorir verde y)/$(colorir vermelho n))"
    read -r _answer 
    if ! [[ "$_answer" == "y" ]]; then
        echo "Exiting..."
        exit 1
    fi
    update_all_files
    exit 0
}

# needs curl and unzip installed
function update_all_files() {
    local INSTALL_DIR=$CURRDIR
    local REPO_NAME=$REPO_NAME
    local ZIP_URL=$ZIP_URL

    echo "- Creating temp dir"
    tmp_dir=$(mktemp -d) # NOTE(adrian): this is not dry-able. dry will actually make change in the system just as this tmp folder.
    
    echo "- Downloading repository zip to '$tmp_dir/repo.zip'"
    srun "curl -L \"$ZIP_URL\" -o \"$tmp_dir/repo.zip\""

    echo "- Unzipping '$tmp_dir/repo.zip' to '$tmp_dir'"
    srun "unzip -qo \"$tmp_dir/repo.zip\" -d \"$tmp_dir\""

    echo "- Copying files from '$tmp_dir/$REPO_NAME-main' to '$INSTALL_DIR'"
    srun "cp -r \"$tmp_dir/$REPO_NAME-main/\"* \"$INSTALL_DIR/\""
    
    echo "- Updating permissions on '$INSTALL_DIR'"
    srun "find \"$INSTALL_DIR\" -type f -name \"*.sh\" -exec chmod +x {} \;"

    # cleaning
    echo "- Cleaning up"
    srun "rm -rf \"$tmp_dir\""
    echo "--- UPDATE FINISHED ---"
}


function version_is_greater() {
    # ignore metadata
    ver1=$(echo "$1" | grep -oE '^[vV]?[0-9]+\.[0-9]+\.[0-9]+')
    ver2=$(echo "$2" | grep -oE '^[vV]?[0-9]+\.[0-9]+\.[0-9]+')
    
    # remove "v" prefix
    ver1="${ver1#v}"
    ver2="${ver2#v}"

    # gets major, minor and patch
    IFS='.' read -r major1 minor1 patch1 <<< "$ver1"
    IFS='.' read -r major2 minor2 patch2 <<< "$ver2"

    # compares major, then minor, then patch
    if (( major1 > major2 )); then
        return 0
    elif (( major1 < major2 )); then
        return 1
    elif (( minor1 > minor2 )); then
        return 0
    elif (( minor1 < minor2 )); then
        return 1
    elif (( patch1 > patch2 )); then
        return 0
    else
        return 1
    fi
}

# === COISAS DO MEU SCRIPT ===

function exportar_backup () {
    read -p "Digite o usuário do banco: " USER_DO_BANCO
    read -p "Digite a senha do banco: " SENHA_DO_BANCO
    echo

    local NOME_ARQUIVO_SAIDA="backup-pmagnus.$(date +%d-%m-%Y).tgz"
    local TMP_DIR=$(mktemp -d)
    echo "- Criando backup em: $(colorir "azul" "$TMP_DIR")"

    echo "- Exportando banco de dados..."
    mkdir -p "$TMP_DIR/tmp"
    mysqldump -u"$USER_DO_BANCO" -p"$SENHA_DO_BANCO" mbilling > "$TMP_DIR/tmp/base.sql"

    echo "- Copiando áudios da URA..."
    mkdir -p "$TMP_DIR/tmp"
    cp -r /usr/local/src/magnus/sounds "$TMP_DIR/tmp/audios-ura"

    echo "- Copiando configurações do Asterisk..."
    mkdir -p "$TMP_DIR/etc"
    cp -r /etc/asterisk "$TMP_DIR/etc/asterisk"

    echo "- Compactando tudo em $NOME_ARQUIVO_SAIDA..."
    tar -czf "$NOME_ARQUIVO_SAIDA" -C "$TMP_DIR" .

    echo "- Limpando diretório temporário..."
    rm -rf "$TMP_DIR"
}


function importar_backup () {
    local BACKUP_FILE="$1"
    local TMP_DIR=$(mktemp -d)
    
    read -p "Digite o usuário do banco: " USER_DO_BANCO
    read -p "Digite a senha do banco: " SENHA_DO_BANCO
    echo

    echo "- Extraindo arquivo de backup para '$(colorir "azul" "$TMP_DIR")'..."

    if ! tar -xzvf "$BACKUP_FILE" -C "$TMP_DIR" &> /dev/null; then
        echo "$(colorir "vermelho" "ERRO: Falha ao extrair o arquivo de backup.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    # Caminhos esperados
    local DB_DUMP="$TMP_DIR/tmp/base.sql"
    local AST_DIR="$TMP_DIR/etc/asterisk"
    local URA_DIR="$TMP_DIR/tmp/audios-ura"
    local UPDATE_SCRIPT="/var/www/html/mbilling/protected/commands/update.sh"

    # Verificações
    if [[ ! -f "$DB_DUMP" ]]; then
        echo "$(colorir "vermelho" "ERRO: Dump do banco de dados não encontrado em '$DB_DUMP'.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if [[ ! -d "$AST_DIR" ]]; then
        echo "$(colorir "vermelho" "ERRO: Diretório com configurações do Asterisk não encontrado em '$AST_DIR'.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if [[ ! -d "$URA_DIR" ]]; then
        echo "$(colorir "vermelho" "ERRO: Diretório com áudios da URA não encontrado em '$URA_DIR'.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if [[ ! -x "$UPDATE_SCRIPT" ]]; then
        echo "$(colorir "vermelho" "ERRO: Script de atualização '$UPDATE_SCRIPT' não encontrado ou não executável.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if systemctl is-active --quiet asterisk; then
        echo "- Serviço asterisk ativo via systemd"
    elif /etc/init.d/asterisk status &> /dev/null; then
        echo "- Serviço asterisk ativo via init.d"
    else
        echo "$(colorir "vermelho" "ERRO: Serviço 'asterisk' não está ativo.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "$(colorir "verde" "Todos os arquivos e pré-requisitos foram verificados com sucesso. Iniciando restauração...")"
    if ! hasFlag "y"; then
        read -p "Tem certeza que quer importar o backup '$(colorir "azul" "$BACKUP_FILE")'? ($(colorir "verde" "s")/$(colorir "vermelho" "n")) " CONFIRMACAO
        if [[ "$CONFIRMACAO" != [sS] ]]; then
            echo "Importação cancelada pelo usuário."
            rm -rf "$TMP_DIR"
            exit 0
        fi
    fi

    echo "- Importando banco de dados..."
    if ! mysql -u"$USER_DO_BANCO" -p"$SENHA_DO_BANCO" mbilling < "$DB_DUMP"; then
        echo "$(colorir "vermelho" "ERRO: Falha ao importar o banco de dados. Verifique usuário, senha e conexão.")"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "- Copiando configurações do Asterisk..."
    cp -av "$AST_DIR/"* /etc/asterisk/

    echo "- Restaurando áudios da URA..."
    cp -av "$URA_DIR/"* /usr/local/src/magnus/sounds/

    echo "- Atualizando o MagnusBilling..."
    bash "$UPDATE_SCRIPT"

    echo "- Reiniciando o Asterisk..."
    systemctl restart asterisk

    echo "- Limpando pasta temporária..."
    rm -rf "$TMP_DIR"
}




# runtime

function main () {
    if [[ "$EUID" -ne 0 ]]; then
        echo "$(colorir "vermelho" "ERRO: este script precisa ser executado como root.")"
        exit 1
    fi

    if hasFlag "b"; then 
        echo "> Gerando backup..."
        exportar_backup
        echo "> $(colorir "verde" "Backup gerado com sucesso")!"
        exit 0
    fi

    if hasFlag "i"; then 
        BACKUP_FILE=$(getFlag "i")

        if ! tar -tzf "$BACKUP_FILE" &> /dev/null; then
            echo "$(colorir "vermelho" "ERRO: '$BACKUP_FILE' não é um arquivo .tar.gz válido ou está corrompido.")"
            exit 1
        fi

        echo "> Importando backup $(colorir "azul" "$BACKUP_FILE")..."
        importar_backup "$BACKUP_FILE"

        echo "> $(colorir "verde" "Backup importado com sucesso")!"
        exit 0
    fi
    
    print_usage
}

main
