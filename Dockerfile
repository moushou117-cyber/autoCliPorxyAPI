FROM eceasy/cli-proxy-api:latest
LABEL "language"="docker"

RUN apk add --no-cache dcron jq curl netcat-openbsd bash findutils

ENV TZ=Asia/Shanghai

EXPOSE 8317

RUN mkdir -p /var/log

RUN cat > /root/get_management_key.sh << 'EOF'
#!/bin/bash
# 获取 MANAGEMENT_PASSWORD
if [ -n "${MANAGEMENT_PASSWORD:-}" ]; then
    echo "$MANAGEMENT_PASSWORD"
else
    CONFIG_PATHS=("/data/config/config.yaml" "/data/config.yaml")
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
set -euo pipefail
API_BASE_URL="${API_BASE_URL:-http://localhost:8317}"
DATA_DIR="/data"
EXPORT_FILE="${DATA_DIR}/usage_data.json"
BACKUP_FILE="${EXPORT_FILE}.bak"
TEMP_FILE="${EXPORT_FILE}.tmp"
MANAGEMENT_PASSWORD=$(bash /root/get_management_key.sh)

if [ -z "$MANAGEMENT_PASSWORD" ]; then
    echo "错误: 未设置 MANAGEMENT_PASSWORD"
    exit 1
fi

mkdir -p "$DATA_DIR"
if [ -f "$EXPORT_FILE" ]; then cp "$EXPORT_FILE" "$BACKUP_FILE"; fi

HTTP_CODE=$(curl -X GET "${API_BASE_URL}/v0/management/usage/export" \
    -H "Authorization: Bearer ${MANAGEMENT_PASSWORD}" \
    -o "$TEMP_FILE" -w "%{http_code}" -s)

if [ "$HTTP_CODE" = "200" ] && [ -f "$TEMP_FILE" ]; then
    mv "$TEMP_FILE" "$EXPORT_FILE"
    echo "✅ 导出成功！"
    rm -f "$BACKUP_FILE"
else
    echo "❌ 导出失败"
    rm -f "$TEMP_FILE"
    if [ -f "$BACKUP_FILE" ]; then mv "$BACKUP_FILE" "$EXPORT_FILE"; fi
    exit 1
fi
EOF

RUN cat > /root/import_usage.sh << 'EOF'
#!/bin/bash
set -euo pipefail
API_BASE_URL="${API_BASE_URL:-http://localhost:8317}"
DATA_DIR="/data"
IMPORT_FILE="${DATA_DIR}/usage_data.json"
MANAGEMENT_PASSWORD=$(bash /root/get_management_key.sh)

if [ -z "$MANAGEMENT_PASSWORD" ]; then echo "错误: 未设置密码"; exit 1; fi
if [ -n "${1:-}" ]; then IMPORT_FILE="$1"; fi
if [ ! -f "$IMPORT_FILE" ]; then echo "错误: 找不到文件 $IMPORT_FILE"; exit 1; fi

RESPONSE=$(curl -X POST "${API_BASE_URL}/v0/management/usage/import" \
    -H "Authorization: Bearer ${MANAGEMENT_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d @"$IMPORT_FILE" -w "\n%{http_code}" -s)

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
if [ "$HTTP_CODE" = "200" ]; then echo "✅ 导入成功！"; else echo "❌ 导入失败"; exit 1; fi
EOF

RUN cat > /root/cleanup-logs.sh << 'EOF'
#!/bin/bash
LOG_DIR="/data/logs"
DAYS=7
if [ ! -d "$LOG_DIR" ]; then exit 0; fi
find "$LOG_DIR" -type f -mtime +$DAYS -delete 2>/dev/null || true
EOF

RUN cat > /root/start.sh << 'EOF'
#!/bin/bash

# --- 智能启动逻辑 ---
echo "正在寻找主程序..."
# 自动在系统中寻找名为 CLIProxyAPI 开头的可执行文件
MAIN_PROGRAM=$(find / -name "CLIProxyAPI*" -type f -perm +0111 2>/dev/null | head -n 1)

if [ -z "$MAIN_PROGRAM" ]; then
    # 如果上面没找到，尝试放宽条件找
    MAIN_PROGRAM=$(find / -name "CLIProxyAPI*" -type f 2>/dev/null | head -n 1)
fi

if [ -z "$MAIN_PROGRAM" ]; then
    echo "❌ 严重错误：找不到主程序文件！请检查基础镜像。"
    echo "当前目录结构预览："
    ls -R /CLIProxyAPI 2>/dev/null || ls -lh /
    exit 1
fi

echo "✅ 找到主程序: $MAIN_PROGRAM"
# 启动主应用（后台运行）
$MAIN_PROGRAM --config /data/config.yaml &
MAIN_PID=$!

echo "等待主程序启动..."
sleep 5
for i in $(seq 1 30); do
    if nc -z localhost 8317 2>/dev/null; then
        echo "✅ 主程序已启动成功"
        break
    fi
    sleep 1
done

if [ -f "/root/import_usage.sh" ] && [ -f "/data/usage_data.json" ]; then /root/import_usage.sh; fi
if [ -f "/root/cleanup-logs.sh" ]; then /root/cleanup-logs.sh; fi

echo "*/2 * * * * /root/export_usage.sh >> /var/log/usage_export.log 2>&1" | crontab -
crond -f -l 2 &
wait $MAIN_PID
EOF

RUN chmod +x /root/get_management_key.sh /root/export_usage.sh /root/import_usage.sh /root/cleanup-logs.sh /root/start.sh

CMD ["/bin/bash", "/root/start.sh"]
