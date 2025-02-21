# SAP备份

# 定义变量
SYNC_DIR="/hana/temp/sync"
SYNC_GROUP="hanasync"
SYNC_USER="hanasync"
SAP_USER="prdadm"

# 同步目录创建
sudo mkdir -p ${SYNC_DIR}

# Step1 创建专用用户组 
sudo groupadd ${SYNC_GROUP}
sudo useradd ${SYNC_USER}
sudo passwd ${SYNC_USER}

# Step2 添加目标用户到组 
sudo usermod -aG ${SYNC_GROUP} ${SYNC_USER}
sudo usermod -aG ${SYNC_GROUP} ${SAP_USER}
sudo usermod -aG ${SYNC_GROUP} root

# Step3 设置目录权限  rwxr-x---
sudo chgrp ${SYNC_GROUP} ${SYNC_DIR} && \
sudo chmod 770 ${SYNC_DIR}

# Step4 配置权限继承（新建文件自动继承组权限）
sudo chmod g+s ${SYNC_DIR}
# 组的读写
sudo chmod g+wx ${SYNC_DIR}

# prdadm用户的umask 0027，用户不会继承目录的写权限，需要把同步目录修改成sap用户
chown -R ${SAP_USER}:${SYNC_GROUP} ${SYNC_DIR}