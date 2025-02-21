#!/bin/bash
# saphana_db_backup.sh

# crontab -e示例配置
# 每周日0点执行全备
# run by root user 
# 事实上是使用devadm用户执行,需要注意执行的权限问题
# 00 0 * * * su - devadm -c "/hana/saphana_db_backup.sh all >> /hana/temp/sync/hana_db_backup_job.log 2>&1"

#  /bin/bash /hana/saphana_db_backup.sh all|full_hdb|incremental_hdb|full_systemdb|file_system

# 调整备份策略，如果今日有多个备份文件，只保存最新的文件,如果有多日的，删除今天以前的所有备份
# 此脚本只用于暂时保存数据库备份文件，外部同步工具需要及时把对应目录的文件同步到其他地方。
# 调整脚本，在调用full_hdb后继续调用full_systemdb
# 在备份时，每次备份都产生多个文件，需要把文件名的时间戳修改成目录名，比如每次备份时创建一个新的目录保存备份文件，在删除旧的备份数据时，
# 只保留当天最后一次备份的目录，删除当天旧的跟之前旧的目录

# 基础配置
# 数据库备份目录
base_dir=/hana/temp/sync/hana_db_backup

# HANA用户存储密钥
SYSDB_STORE_KEY="BKSYSDB"
TENENTDB_STORE_KEY="BKDEVDB"
# 备份的思路是通过 SYSDB 备份SYSTEMDB，通过SYSTEMDB 备份TENENTDB
# 一次全量备份SYSTEMDB，一次全量备份TENENTDB
TENENTDB="DEV"

# 创建备份目录结构
mkdir -p "$base_dir/$TENENTDB/full" \
         "$base_dir/$TENENTDB/incremental" \
         "$base_dir/$TENENTDB/differential" \
         "$base_dir/SYSTEMDB/full"


TIMESTAMP=$(date +%Y_%m_%d-%H_%M_%S)

# 日志记录
echo "[$(date)] 脚本由用户 $(whoami) 执行，操作类型: $1" >> "$base_dir/backup.log"

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
    echo "[$(date)] 开始 $TENENTDB 全量备份..." >> "$base_dir/backup.log"
    
    hdbsql -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA FOR $TENENTDB USING FILE ('$backup_dir','${TENENTDB}_FULL_$TIMESTAMP') COMMENT 'Daily Full Backup'"
    
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
    echo "[$(date)] 开始 $TENENTDB 增量备份..." >> "$base_dir/backup.log"
    
    hdbsql -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA INCREMENTAL FOR $TENENTDB USING FILE ('$backup_dir','${TENENTDB}_INCR_$TIMESTAMP') COMMENT 'Daily Incremental'"
    
    # 清理增量备份目录
    cleanup_backup_dirs "$base_dir/$TENENTDB/incremental"

    # 差异备份HDB
    diff_dir="$base_dir/$TENENTDB/differential/$TIMESTAMP"
    mkdir -p "$diff_dir"
    echo "[$(date)] 开始 $TENENTDB 差异备份..." >> "$base_dir/backup.log"
    
    hdbsql -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA DIFFERENTIAL FOR $TENENTDB USING FILE ('$diff_dir','${TENENTDB}_DIFF_$TIMESTAMP') COMMENT 'Daily Differential'"
    
    # 清理差异备份目录
    cleanup_backup_dirs "$base_dir/$TENENTDB/differential"
}

# SYSTEMDB全量备份函数
full_backup_systemdb() {
    backup_dir="$base_dir/SYSTEMDB/full/$TIMESTAMP"
    mkdir -p "$backup_dir"
    echo "[$(date)] 开始 SYSTEMDB 全量备份..." >> "$base_dir/backup.log"
    
    hdbsql -U "$SYSDB_STORE_KEY" -d SYSTEMDB -x \
        "BACKUP DATA FOR SYSTEMDB USING FILE ('$backup_dir','SYSTEMDB_FULL_$TIMESTAMP') COMMENT 'Weekly SYSTEMDB Backup'"
    
    # 清理SYSTEMDB备份目录
    cleanup_backup_dirs "$base_dir/SYSTEMDB/full"
}

case "$1" in
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
    echo "[$(date)] $1 备份成功完成" >> "$base_dir/backup.log"
else
    echo "[$(date)] 错误: $1 备份失败!" >> "$base_dir/backup.log"
    exit 1
fi