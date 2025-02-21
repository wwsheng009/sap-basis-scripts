#!/bin/bash
# vi /hana/saphana_db_backup.sh
# chmod +x saphana_db_backup.sh

# crontab -e示例配置
# 每周日0点执行全备
# run by root user 
# 事实上是使用数据库adm用户执行,需要注意执行的权限问题
# 00 0 * * * su - prdadm -c "/hana/saphana_db_backup.sh all >> /hana/temp/sync/hana_db_backup_job.log 2>&1"

# /hana/saphana_db_backup.sh all
# /hana/saphana_db_backup.sh full_systemdb
# /hana/saphana_db_backup.sh all|full_hdb|incremental_hdb|full_systemdb

# 基础配置
# 数据库备份目录
base_dir=/hana/temp/sync/hana_db_backup

# HANA用户存储密钥,可使用命令hdbuserstore LIST 查看
SYSDB_STORE_KEY="BKSYSDB"
TENENTDB_STORE_KEY="BKPRDDB"

TENENTDB="PRD"
# HANA主节点虚拟IP
VIRTUAL_IP="172.18.3.20"
MASTER_HOST="saphanaprd" #主节点IP,备份只能在主节点上执行

# 日志文件路径
LOG_FILE="$base_dir/backup.log"

# 时间戳格式
TIMESTAMP=$(date +%Y_%m_%d-%H_%M_%S)

# 日志记录函数
log_message() {
    local level=$1
    local message=$2
    local dir_to_list=$3
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    echo "[$level] $message"
    
    # 如果提供了目录参数，则列出该目录下的文件信息
    if [ -n "$dir_to_list" ] && [ -d "$dir_to_list" ]; then
        echo "\n备份文件信息:" >> "$LOG_FILE"
        ls -lrt "$dir_to_list" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    fi
}

# 检查目录是否存在并创建
check_and_create_dir() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        if [[ $? -ne 0 ]]; then
            log_message "ERROR" "无法创建目录: $dir"
            exit 1
        fi
    fi
}

# 检查磁盘空间
check_disk_space() {
    local dir=$1
    local min_space=100 # 最小剩余空间（GB）
    
    local available_space=$(df -BG "$dir" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_space -lt $min_space ]]; then
        log_message "ERROR" "磁盘空间不足，可用空间: ${available_space}G，需要至少: ${min_space}G"
        return 1
    fi
    return 0
}

# 初始化备份环境
initialize_backup() {
    # 创建必要的目录
    check_and_create_dir "$base_dir"
    check_and_create_dir "$base_dir/$TENENTDB/full"
    check_and_create_dir "$base_dir/$TENENTDB/incremental"
    check_and_create_dir "$base_dir/$TENENTDB/differential"
    check_and_create_dir "$base_dir/SYSTEMDB/full"
    
    # 检查磁盘空间
    if ! check_disk_space "$base_dir"; then
        exit 1
    fi
    
    log_message "INFO" "备份环境初始化完成"
}

# 检查用户权限函数
check_user_permission() {
    # 日志记录
    log_message "INFO" "脚本由用户 $(whoami) 执行，操作类型: $1"

    current_user=$(whoami)
    
    # 检查用户是否以adm结尾
    if [[ "$current_user" == *adm ]]; then
        return 0
    fi
    
    # 检查用户是否属于sapsys组
    if groups | grep -q "\bsapsys\b"; then
        return 0
    fi
    # 其它用户报错
    log_message "ERROR" "用户 $current_user 没有执行权限，需要是sapsys组成员或用户名以adm结尾"
    exit 1
}

# 检查服务器是否为主节点
check_primary_node() {
    # 如果未配置虚拟IP，跳过检查
    if [ -z "$VIRTUAL_IP" ]; then
        log_message "WARNING" "未配置虚拟IP，跳过主节点检查"
        return 0
    fi
    
    # 检查虚拟IP是否存在于网络接口
    if ! ip addr show | grep -q "inet ${VIRTUAL_IP}/"; then
        log_message "ERROR" "当前节点未配置虚拟IP ${VIRTUAL_IP}，不是主节点"
        exit 1
    fi

    # 验证虚拟IP是否可用
    if ! ping -c 1 -W 1 "${VIRTUAL_IP}" >/dev/null 2>&1; then
        log_message "ERROR" "虚拟IP ${VIRTUAL_IP} 不可访问"
        exit 1
    fi
}

# 清理备份目录函数（保留当天最新目录）
cleanup_backup_dirs() {
    local backup_root="$1"
    # 获取今日日期范围
    local today_start=$(date -d "today 00:00:00" +%s)
    local today_end=$(date -d "today 23:59:59" +%s)

    # 删除非今日目录
    find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
        -exec sh -c '
            dir_timestamp=$(stat -c %Y "$0");
            if [ "$dir_timestamp" -lt '"$today_start"' ] || [ "$dir_timestamp" -gt '"$today_end"' ]; then
                rm -rf "$0"
            fi
        ' {} \;

    # 保留最新的今日目录
    local latest_dir=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
        -newermt "@$today_start" ! -newermt "@$today_end" \
        -printf "%T@ %p\n" | sort -nr | head -1 | cut -d' ' -f2-)

    if [ -n "$latest_dir" ]; then
        find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
            -newermt "@$today_start" ! -newermt "@$today_end" \
            -not -path "$latest_dir" -exec rm -rf {} +
    fi
}

# 全量备份HDB函数
full_backup_hdb() {
    backup_dir="$base_dir/$TENENTDB/full/$TIMESTAMP"
    mkdir -p "$backup_dir"
    log_message "INFO" "开始 $TENENTDB 全量备份..."
    
    hdbsql -n "$MASTER_HOST" -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA FOR $TENENTDB USING FILE ('$backup_dir','${TENENTDB}_FULL_$TIMESTAMP') COMMENT 'Daily Full Backup'"
    
    # 记录备份文件信息
    log_message "INFO" "$TENENTDB 全量备份文件详情:" "$backup_dir"
    
    # 清理全量备份目录
    cleanup_backup_dirs "$base_dir/$TENENTDB/full"
    
    # 清空增量备份历史
    find "$base_dir/$TENENTDB/incremental" -mindepth 1 -delete
    find "$base_dir/$TENENTDB/differential" -mindepth 1 -delete
}

# 增量备份HDB函数
incremental_backup_hdb() {
    backup_dir="$base_dir/$TENENTDB/incremental/$TIMESTAMP"
    mkdir -p "$backup_dir"
    log_message "INFO" "开始 $TENENTDB 增量备份..."
    
    hdbsql -n "$MASTER_HOST" -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA INCREMENTAL FOR $TENENTDB USING FILE ('$backup_dir','${TENENTDB}_INCR_$TIMESTAMP') COMMENT 'Daily Incremental'"
    
    # 记录增量备份文件信息
    log_message "INFO" "$TENENTDB 增量备份文件详情:" "$backup_dir"
    
    # 清理增量备份目录
    cleanup_backup_dirs "$base_dir/$TENENTDB/incremental"

    # 差异备份HDB
    diff_dir="$base_dir/$TENENTDB/differential/$TIMESTAMP"
    mkdir -p "$diff_dir"
    log_message "INFO" "开始 $TENENTDB 差异备份..."
    
    hdbsql -n "$MASTER_HOST" -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA DIFFERENTIAL FOR $TENENTDB USING FILE ('$diff_dir','${TENENTDB}_DIFF_$TIMESTAMP') COMMENT 'Daily Differential'"
    
    # 记录差异备份文件信息
    log_message "INFO" "$TENENTDB 差异备份文件详情:" "$diff_dir"
    
    # 清理差异备份目录
    cleanup_backup_dirs "$base_dir/$TENENTDB/differential"
}

# SYSTEMDB全量备份函数
full_backup_systemdb() {
    backup_dir="$base_dir/SYSTEMDB/full/$TIMESTAMP"
    mkdir -p "$backup_dir"
    log_message "INFO" "开始 SYSTEMDB 全量备份..."
    
    hdbsql -n "$MASTER_HOST" -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA FOR SYSTEMDB USING FILE ('$backup_dir','SYSTEMDB_FULL_$TIMESTAMP') COMMENT 'Weekly SYSTEMDB Backup'"
    
    # 记录SYSTEMDB备份文件信息
    log_message "INFO" "SYSTEMDB 全量备份文件详情:" "$backup_dir"
    
    # 清理SYSTEMDB备份目录
    cleanup_backup_dirs "$base_dir/SYSTEMDB/full"
}
# 主函数
main() {
    # 检查命令行参数
    if [ $# -ne 1 ]; then
        echo "用法: $0 {all|full_hdb|incremental_hdb|full_systemdb}"
        exit 1
    fi
    
    local backup_type=$1
   # 检查主节点状态
    check_primary_node
    # 检查用户权限
    check_user_permission "$backup_type"
    # 初始化备份环境
    initialize_backup

    # 根据备份类型执行相应的备份操作
    case "$backup_type" in
        all)
            # 备份之前删除所有的数据，因为空间可能会不足
            rm -rf "$base_dir/$TENENTDB/full" "$base_dir/SYSTEMDB/full"
            full_backup_systemdb
            full_backup_hdb
            ;;
        full_hdb)
            full_backup_hdb
            ;;
        incremental_hdb)
            incremental_backup_hdb
            ;;
        full_systemdb)
            full_backup_systemdb
            ;;
        *)
            echo "用法: $0 {all|full_hdb|incremental_hdb|full_systemdb}"
            exit 1
            ;;
    esac

    # 检查备份结果
    if [ $? -eq 0 ]; then
        log_message "INFO" "$backup_type 备份成功完成"
        return 0
    else
        log_message "ERROR" "$backup_type 备份失败!"
        return 1
    fi
}

# 执行主函数
main "$@"
