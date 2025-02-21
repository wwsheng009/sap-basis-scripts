#!/bin/bash
# vi /hana/saphana_dir_backup.sh
# chmod +x /hana/saphana_dir_backup.sh

# run for every day
# crontab -e
# run by root user
# 00 0 * * * /hana/saphana_dir_backup.sh >> /hana/temp/sync/hana_dir_backup_job.log  2>&1

# 定义备份目录列表
BACKUP_DIRS=(
    "/home"
    "/etc"
    "/usr/sap"
    "/sapmnt/"
)

# 备份存放的根目录
BACKUP_ROOT="/hana/temp/sync/sap_dir_backup"

# 日志文件路径
LOG_FILE="$BACKUP_ROOT/backup.log"

# 当前日期用于命名备份子目录
CURRENT_DATE=$(date +%Y%m%d)

VIRTUAL_IP="172.18.3.83"

# 记录日志的函数
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp - $message" >> "$LOG_FILE"
    echo "$message"
}

# 检查用户权限
check_root_user() {
    if [ "$(id -u)" -ne 0 ]; then
        log_message "Error: This script must be run as root user"
        exit 1
    fi
}

# 初始化备份环境
init_backup_env() {
    # 确保备份根目录存在
    mkdir -p "$BACKUP_ROOT"

    # 检查备份目录和保存目录是否有冲突
    for DIR in "${BACKUP_DIRS[@]}"; do
        if [[ "$DIR" == "$BACKUP_ROOT"* ]] || [[ "$BACKUP_ROOT/$CURRENT_DATE" == "$DIR"* ]]; then
            log_message "Error: Conflict detected between backup directory $DIR and backup save location $BACKUP_ROOT/$CURRENT_DATE"
            exit 1
        fi
    done
}

# 定义一个函数来清理目录名中的特殊字符
sanitize_filename() {
    # 先删除尾部的 / 号
    local clean_name="${1%/}"
    # 删除开头的 / 号
    clean_name="${clean_name#/}"
    # 将路径中的斜杠替换为下划线，并替换其他特殊字符
    echo "$clean_name" | sed -e 's|/|_|g' -e 's/[^A-Za-z0-9._-]/_/g' -e 's/_*$//'
}

# 检查服务器是否存在特定的虚拟IP地址，判断是不是主节点
check_primary_node() {
    # 如果未配置虚拟IP，跳过检查
    if [ -z "$VIRTUAL_IP" ]; then
        log_message "[$(date)] 警告: 未配置虚拟IP，跳过主节点检查"
        return 0
    fi

    # 检查虚拟IP是否存在于网络接口
    if ! ip addr show | grep -q "inet ${VIRTUAL_IP}/"; then
        log_message "[$(date)] 错误: 当前节点未配置虚拟IP ${VIRTUAL_IP}，不是主节点"
        exit 1
    fi

    # 验证虚拟IP是否可用
    if ! ping -c 1 -W 1 "${VIRTUAL_IP}" >/dev/null 2>&1; then
        log_message "[$(date)] 错误: 虚拟IP ${VIRTUAL_IP} 不可访问"
        exit 1
    fi
}

# 执行备份操作
perform_backup() {
    local dir="$1"
    # 检查目录是否存在
    if [[ ! -d "$dir" ]]; then
        log_message "Warning: Source directory $dir does not exist. Skipping this directory."
        return 1
    fi

    # 计算目录大小
    local dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)

    # 清理目录名中的特殊字符
    local sanitized_dir_name=$(sanitize_filename "$dir")

    # 压缩文件名
    local backup_file="$BACKUP_ROOT/$CURRENT_DATE/${sanitized_dir_name}_$CURRENT_DATE.tar.gz"

    log_message "Size of $dir: $dir_size"

    # 创建备份子目录
    mkdir -p "$(dirname "$backup_file")"

    # 执行备份并压缩
    log_message "Backing up $dir to $backup_file"
    tar -czf "$backup_file" "$dir" 2>> "$LOG_FILE"

    if [ $? -eq 0 ]; then
        local backup_size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
        log_message "Backup of $dir completed successfully. Size: $backup_size"
        return 0
    else
        log_message "Error backing up $dir. Check $LOG_FILE for details."
        return 1
    fi
}

# 清理旧的备份文件
cleanup_old_backups() {
    local today=$(date "+%Y%m%d")
    local backup_dates=($(find "$BACKUP_ROOT" -maxdepth 1 -type d -name '[0-9]*' | sort -r))

    for date_dir in "${backup_dates[@]}"; do
        local date=$(basename "$date_dir")
        if [ "$date" -lt "$today" ]; then
            log_message "Removing old backup directory $date_dir"
            rm -rf "$date_dir"
        elif [ "$date" -eq "$today" ]; then
            cleanup_today_backups "$date_dir"
        fi
    done
}

# 清理今天的备份文件，只保留最新的
cleanup_today_backups() {
    local date_dir="$1"
    for sanitized_dir in $(find "$date_dir" -type f -name '*.tar.gz' | sed 's/_[0-9]*.tar.gz//' | sort -u); do
        local files=($(find "$date_dir" -type f -name "$(basename $sanitized_dir)*.tar.gz" -printf '%T@ %p\n' | sort -n | awk '{print $2}'))
        if [ ${#files[@]} -gt 1 ]; then
            for ((i = 0; i < ${#files[@]} - 1; i++)); do
                log_message "Removing old backup file ${files[$i]}"
                rm -f "${files[$i]}"
            done
        fi
    done
}

# 主要执行流程
main() {
    check_primary_node
    check_root_user
    init_backup_env

    # 清理旧的备份
    cleanup_old_backups

    # 执行备份操作
    local backup_failed=0
    for dir in "${BACKUP_DIRS[@]}"; do
        perform_backup "$dir" || backup_failed=1
    done



    if [ $backup_failed -eq 0 ]; then
        log_message "SAP DIR Backup process completed successfully."
    else
        log_message "SAP DIR Backup process completed with some errors. Check the log for details."
        exit 1
    fi
}

# 执行主函数
main