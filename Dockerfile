FROM eceasy/cli-proxy-api:latest
LABEL "language"="docker"

RUN apk add --no-cache dcron jq curl netcat-openbsd bash

ENV TZ=Asia/Shanghai

EXPOSE 8317

RUN mkdir -p /var/log

RUN cat > /root/get_management_key.sh << 'EOF'
#!/bin/bash
# 获取 MANAGEMENT_PASSWORD，优先使用环境变量，否则从配置文件读取
# 支持的配置文件位置: /data/config/config.yaml, /data/config.yaml

if [ -n "${MANAGEMENT_PASSWORD:-}" ]; then
    echo "$MANAGEMENT_PASSWORD"
else
    # 定义可能的配置文件位置
    CONFIG_PATHS=(
        "/data/config/config.yaml"
        "/data/config.yaml"
    )
    
    for CONFIG_FILE in "${CONFIG_PATHS[@]}"; do
        if [ -f "$CONFIG_FILE" ]; then
            SECRET_KEY=$(grep -A 2 "remote-management:" "$CONFIG_FILE" 2>/dev/null | grep "secret-key:" | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'")
            if [ -n "$SECRET_KEY" ]; then
                echo "$SECRET_KEY"
                return 0
            fi
        fi
    done
    
    echo ""
fi
EOF

RUN cat > /root/export_usage.sh << 'EOF'
#!/bin/bash
# export_usage.sh - 导出使用数据到统一文件

set -euo pipefail

# 配置
API_BASE_URL="${API_BASE_URL:-http://localhost:8317}"
DATA_DIR="/data"
EXPORT_FILE="${DATA_DIR}/usage_data.json"
BACKUP_FILE="${EXPORT_FILE}.bak"
TEMP_FILE="${EXPORT_FILE}.tmp"

# 获取 MANAGEMENT_PASSWORD
MANAGEMENT_PASSWORD=$(bash /root/get_management_key.sh)

# 检查环境变量
if [ -z "$MANAGEMENT_PASSWORD" ]; then
    echo "错误: 未设置 MANAGEMENT_PASSWORD 环境变量，也未在配置文件中找到 secret-key"
    exit 1
fi

# 创建数据目录
mkdir -p "$DATA_DIR"

# 如果文件存在，先备份
if [ -f "$EXPORT_FILE" ]; then
    echo "备份现有文件..."
    cp "$EXPORT_FILE" "$BACKUP_FILE"
fi

# 导出数据到临时文件
echo "正在导出使用数据..."
echo "目标文件: $EXPORT_FILE"

HTTP_CODE=$(curl -X GET "${API_BASE_URL}/v0/management/usage/export" \
    -H "Authorization: Bearer ${MANAGEMENT_PASSWORD}" \
    -o "$TEMP_FILE" \
    -w "%{http_code}" \
    -s)

echo "HTTP Status: $HTTP_CODE"

# 检查是否成功
if [ "$HTTP_CODE" = "200" ] && [ -f "$TEMP_FILE" ]; then
    # 验证 JSON 格式（如果安装了 jq）
    if command -v jq >/dev/null 2>&1; then
        if jq empty "$TEMP_FILE" 2>/dev/null; then
            mv "$TEMP_FILE" "$EXPORT_FILE"
            echo "✅ 导出成功！"
        else
            echo "❌ 导出的数据格式无效"
            rm -f "$TEMP_FILE"
            # 恢复备份
            if [ -f "$BACKUP_FILE" ]; then
                mv "$BACKUP_FILE" "$EXPORT_FILE"
                echo "已恢复之前的备份"
            fi
            exit 1
        fi
    else
        # 没有 jq，直接移动
        mv "$TEMP_FILE" "$EXPORT_FILE"
        echo "✅ 导出成功！"
    fi
    
    FILE_SIZE=$(stat -f%z "$EXPORT_FILE" 2>/dev/null || stat -c%s "$EXPORT_FILE" 2>/dev/null)
    FILE_SIZE_KB=$((FILE_SIZE / 1024))
    echo "文件位置: $EXPORT_FILE"
    echo "文件大小: ${FILE_SIZE_KB}KB (${FILE_SIZE} bytes)"
    echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # 删除临时备份
    rm -f "$BACKUP_FILE"
    
    # 显示文件内容预览
    if command -v jq >/dev/null 2>&1; then
        echo -e "\n文件内容预览:"
        jq '.' "$EXPORT_FILE" | head -n 20
    fi
else
    echo "❌ 导出失败"
    rm -f "$TEMP_FILE"
    # 恢复备份
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$EXPORT_FILE"
        echo "已恢复之前的备份"
    fi
    exit 1
fi

EOF

RUN cat > /root/import_usage.sh << 'EOF'
#!/bin/bash
# import_usage.sh - 从统一文件导入使用数据

set -euo pipefail

# 配置
API_BASE_URL="${API_BASE_URL:-http://localhost:8317}"
DATA_DIR="/data"
IMPORT_FILE="${DATA_DIR}/usage_data.json"

# 获取 MANAGEMENT_PASSWORD
MANAGEMENT_PASSWORD=$(bash /root/get_management_key.sh)

# 检查环境变量
if [ -z "$MANAGEMENT_PASSWORD" ]; then
    echo "错误: 未设置 MANAGEMENT_PASSWORD 环境变量，也未在配置文件中找到 secret-key"
    exit 1
fi

# 如果提供了参数，使用指定文件
if [ -n "${1:-}" ]; then
    IMPORT_FILE="$1"
fi

# 检查文件是否存在
if [ ! -f "$IMPORT_FILE" ]; then
    echo "错误: 找不到导入文件: $IMPORT_FILE"
    echo ""
    echo "用法:"
    echo "  $0                    # 导入默认文件 ${DATA_DIR}/usage_data.json"
    echo "  $0 /path/to/file.json # 导入指定文件"
    exit 1
fi

# 验证 JSON 格式（如果安装了 jq）
if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$IMPORT_FILE" 2>/dev/null; then
        echo "❌ 文件格式无效: $IMPORT_FILE"
        exit 1
    fi
fi

FILE_SIZE=$(stat -f%z "$IMPORT_FILE" 2>/dev/null || stat -c%s "$IMPORT_FILE" 2>/dev/null)
FILE_SIZE_KB=$((FILE_SIZE / 1024))

echo "正在导入使用数据..."
echo "文件: $IMPORT_FILE"
echo "大小: ${FILE_SIZE_KB}KB (${FILE_SIZE} bytes)"

# 导入数据
RESPONSE=$(curl -X POST "${API_BASE_URL}/v0/management/usage/import" \
    -H "Authorization: Bearer ${MANAGEMENT_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d @"$IMPORT_FILE" \
    -w "\n%{http_code}" \
    -s)

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo "HTTP Status: $HTTP_CODE"

if [ -n "$BODY" ]; then
    echo "响应:"
    if command -v jq >/dev/null 2>&1; then
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
    else
        echo "$BODY"
    fi
fi

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ 导入成功！"
    echo "导入时间: $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo "❌ 导入失败"
    exit 1
fi
EOF

RUN cat > /root/cleanup-logs.sh << 'EOF'
#!/bin/bash

# 日志清理脚本 - 删除超过7天的日志文件
# 使用方法: ./cleanup-logs.sh

LOG_DIR="/data/logs"
DAYS=7
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$TIMESTAMP] 开始清理日志文件..."
echo "目录: $LOG_DIR"
echo "清理规则: 删除超过 $DAYS 天的文件"

# 检查目录是否存在
if [ ! -d "$LOG_DIR" ]; then
    echo "⚠️  日志目录不存在: $LOG_DIR"
    exit 0
fi

# 统计删除前的文件数
BEFORE=$(find "$LOG_DIR" -type f 2>/dev/null | wc -l)
echo "清理前文件数: $BEFORE"

# 删除超过7天的日志文件
find "$LOG_DIR" -type f -mtime +$DAYS -delete 2>/dev/null || true

# 统计删除后的文件数
AFTER=$(find "$LOG_DIR" -type f 2>/dev/null | wc -l)
DELETED=$((BEFORE - AFTER))

echo "清理后文件数: $AFTER"
echo "已删除文件数: $DELETED"
echo "[$TIMESTAMP] 清理完成！"
EOF

RUN cat > /root/start.sh << 'EOF'
#!/bin/bash

# 启动主应用（后台运行）
/CLIProxyAPI/CLIProxyAPIPlus --config /data/config.yaml &
MAIN_PID=$!

# 等待主程序启动成功（等待 8317 端口就绪）
echo "等待主程序启动..."
sleep 5
for i in $(seq 1 30); do
    if nc -z localhost 8317 2>/dev/null; then
        echo "✅ 主程序已启动成功"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ 主程序启动超时"
        exit 1
    fi
    sleep 1
done

# 运行 import_usage.sh 脚本（仅当 usage_data.json 存在时）
if [ -f "/root/import_usage.sh" ] && [ -f "/data/usage_data.json" ]; then
    echo "检测到 usage_data.json，运行 import_usage.sh..."
    /root/import_usage.sh
else
    if [ ! -f "/data/usage_data.json" ]; then
        echo "⚠️  usage_data.json 不存在，跳过 import_usage.sh"
    fi
fi

# 运行 cleanup-logs.sh 脚本
if [ -f "/root/cleanup-logs.sh" ]; then
    echo "运行 cleanup-logs.sh..."
    /root/cleanup-logs.sh
fi

# 设置定时任务
echo "*/2 * * * * /root/export_usage.sh >> /var/log/usage_export.log 2>&1" | crontab -

# 启动 cron 服务（后台运行）
crond -f -l 2 &

# 等待主程序
wait $MAIN_PID
EOF

RUN chmod +x /root/get_management_key.sh /root/export_usage.sh /root/import_usage.sh /root/cleanup-logs.sh /root/start.sh


CMD ["/bin/bash", "/root/start.sh"]
