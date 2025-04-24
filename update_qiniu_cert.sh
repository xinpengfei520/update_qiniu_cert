#!/bin/bash

# 确保脚本在出错时终止
set -e
set -o pipefail

################### Usage ############################
# 编辑 crontab                                 
# > crontab -e                                
# 添加以下内容（每天凌晨1点执行）
# > 0 1 * * * /path/to/update_qiniu_cert.sh
# 七牛证书接口文档：https://developer.qiniu.com/fusion/8593/interface-related-certificate
# 查看日志命令：cat /var/log/qiniu_cert_update.log
####################################################

# 配置信息
QINIU_ACCESS_KEY="xxx"
QINIU_SECRET_KEY="xxx"
DOMAIN="domain.example.com"
CERT_ID_FILE="/path/to/qiniu_cert_id"
LOG_FILE="/var/log/qiniu_cert_update.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# 添加一个新的函数来处理时间戳转换
format_timestamp() {
    local timestamp=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        date -r "$timestamp" '+%Y-%m-%d %H:%M:%S'
    else
        # Linux
        date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S'
    fi
}

# 获取七牛云证书信息
get_cert_info() {
    local cert_id=$1
    local url="https://api.qiniu.com/sslcert/$cert_id"
    local path="/sslcert/$cert_id"
    local method="GET"
    local host="api.qiniu.com"
    
    # 生成待签名的原始字符串 - 使用$'\n'创建实际换行符
    local signing_str="$method $path"$'\n'"Host: $host"$'\n\n'
    
    # 使用HMAC-SHA1计算签名
    local sign=$(echo -n "$signing_str" | openssl sha1 -hmac $QINIU_SECRET_KEY -binary | base64 -w 0)
    
    # URL安全的Base64编码
    local encoded_sign=$(echo "$sign" | tr "+/" "-_")
    
    # 生成管理凭证
    local auth="Qiniu $QINIU_ACCESS_KEY:$encoded_sign"
    
    # 记录认证信息
    log "获取证书信息 - URL: $url"
    log "获取证书信息 - 签名字符串: $(echo "$signing_str" | xxd -p)"
    log "获取证书信息 - AUTH: $auth"
    
    # 发送请求并保存响应
    local response=$(curl -s -H "Authorization: $auth" -H "Host: $host" "$url")
    
    # 记录响应信息
    log "获取证书信息 - 响应: $response"
    
    # 如果响应是JSON格式，则格式化输出
    if command -v jq &> /dev/null; then
        if echo "$response" | jq empty 2>/dev/null; then
            local formatted_response=$(echo "$response" | jq '.')
            log "获取证书信息 - 格式化响应:"
            log "$formatted_response"
        fi
    fi
    
    # 返回响应
    echo "$response"
}

# 上传新证书到七牛云
upload_cert() {
    local cert_file=$1
    local key_file=$2
    local cert_name="cert_$(date '+%Y%m%d')"
    local tmp_file=$(mktemp)
    
    # 检查jq是否安装
    if ! command -v jq &> /dev/null; then
        log "错误: 需要安装jq才能正确处理JSON"
        exit 1
    fi
    
    # 使用jq正确处理JSON和证书内容
    # 可能不需要传递 domain 参数，现在没有试
    jq -n --arg name "$cert_name" \
          --arg domain "$DOMAIN" \
          --arg pri "$(cat $key_file)" \
          --arg ca "$(cat $cert_file)" \
          '{name: $name, common_name: $domain, pri: $pri, ca: $ca}' > "$tmp_file"
    
    local data=$(cat "$tmp_file")
    
    local url="https://api.qiniu.com/sslcert"
    local path="/sslcert"
    local method="POST"
    local host="api.qiniu.com"
    local content_type="application/json"
    
    # 计算请求体的SHA1哈希
    local body_hash=$(sha1sum "$tmp_file" | cut -d ' ' -f1)
    
    # 生成待签名的原始字符串 - 使用$'\n'创建实际换行符
    local signing_str="$method $path"$'\n'"Host: $host"$'\n'"Content-Type: $content_type"$'\n\n'"$body_hash"
    
    # 使用HMAC-SHA1计算签名
    local sign=$(echo -n "$signing_str" | openssl sha1 -hmac $QINIU_SECRET_KEY -binary | base64 -w 0)
    
    # URL安全的Base64编码
    local encoded_sign=$(echo "$sign" | tr "+/" "-_")
    
    # 生成管理凭证
    local auth="Qiniu $QINIU_ACCESS_KEY:$encoded_sign"
    
    # 记录认证信息
    log "上传证书 - URL: $url"
    log "上传证书 - 签名字符串: $(echo "$signing_str" | xxd -p)"
    log "上传证书 - AUTH: $auth"
    log "上传证书 - DATA长度: $(wc -c < "$tmp_file")字节"
    log "上传证书 - BODY_HASH: $body_hash"
    
    # 发送请求
    local response=$(curl -s -X $method -H "Authorization: $auth" -H "Content-Type: $content_type" -H "Host: $host" -d @"$tmp_file" "$url")
    
    # 清理临时文件
    rm -f "$tmp_file"
    
    # 记录响应
    log "上传证书 - 响应: $response"
    
    # 从响应中提取证书ID
    echo "$response" | jq -r '.certID // empty'
}

# 检查证书是否过期
check_cert_expiry() {
    local cert_id=$1
    local cert_info=$(get_cert_info $cert_id)
    
    # 使用jq正确解析JSON
    if command -v jq &> /dev/null; then
        # 首先检查API响应是否成功
        local response_code=$(echo "$cert_info" | jq -r '.code')
        local response_error=$(echo "$cert_info" | jq -r '.error')
        
        if [ "$response_code" != "200" ]; then
            log "获取证书信息失败 - 错误代码: $response_code"
            log "错误信息: $response_error"
            return 1
        fi
        
        # 从cert对象中获取过期时间
        local not_after=$(echo "$cert_info" | jq -r '.cert.not_after')
        local current_time=$(date +%s)
        
        # 格式化时间以便记录
        local expire_time=$(format_timestamp "$not_after")
        local current_formatted=$(format_timestamp "$current_time")
        
        log "证书过期时间: $expire_time"
        log "当前时间: $current_formatted"
        
        # 如果证书将在 10 天内过期,则返回 1
        local days_before_expiry=$(( (not_after - current_time) / 86400 ))
        log "距离过期还有 $days_before_expiry 天"
        
        if [ $((not_after - current_time)) -lt 864000 ]; then
            log "证书将在10天内过期"
            return 1
        fi
        
        log "证书仍在有效期内"
        return 0
    else
        log "错误: 需要安装jq才能正确处理JSON"
        exit 1
    fi
}

# 获取七牛云证书列表
get_cert_list() {
    local query="limit=100"
    local url="https://api.qiniu.com/sslcert?$query"
    local path="/sslcert"
    local method="GET"
    local host="api.qiniu.com"
    
    # 生成待签名的原始字符串 - 使用$'\n'创建实际换行符
    local signing_str="$method $path?$query"$'\n'"Host: $host"$'\n\n'
    
    # 使用HMAC-SHA1计算签名
    local sign=$(echo -n "$signing_str" | openssl sha1 -hmac $QINIU_SECRET_KEY -binary | base64 -w 0)
    
    # URL安全的Base64编码
    local encoded_sign=$(echo "$sign" | tr "+/" "-_")
    
    # 生成管理凭证
    local auth="Qiniu $QINIU_ACCESS_KEY:$encoded_sign"
    
    # 记录认证信息
    log "获取证书列表 - URL: $url"
    log "获取证书列表 - 签名字符串: $(echo "$signing_str" | xxd -p)"
    log "获取证书列表 - AUTH: $auth"
    
    # 发送请求
    local response=$(curl -s -H "Authorization: $auth" -H "Host: $host" "$url")
    
    # 记录响应的前200个字符（避免日志过大）
    log "获取证书列表 - 响应前200字符: $(echo "$response" | head -c 200)..."
    
    echo "$response"
}

# 从证书列表中查找指定域名的证书ID
find_cert_id_by_domain() {
    local domain=$1
    local cert_list=$2
    local current_time=$(date +%s)
    
    # 使用jq解析JSON，过滤域名并按创建时间排序
    if command -v jq &> /dev/null; then
        # 将多行jq命令合并为单行
        local cert_info=$(echo "$cert_list" | jq -r --arg domain "$domain" --arg time "$current_time" '.certs[] | select(.common_name == $domain and (.not_after | tonumber) > ($time | tonumber)) | {certid: .certid, create_time: .create_time, not_after: .not_after}' | jq -s 'sort_by(.create_time) | reverse | .[0]')
        
        if [ -n "$cert_info" ] && [ "$cert_info" != "null" ]; then
            # 记录找到的证书信息
            local create_timestamp=$(echo "$cert_info" | jq -r '.create_time')
            local expire_timestamp=$(echo "$cert_info" | jq -r '.not_after')
            local cert_id=$(echo "$cert_info" | jq -r '.certid')
            
            # 使用新的格式化函数
            local create_time=$(format_timestamp "$create_timestamp")
            local expire_time=$(format_timestamp "$expire_timestamp")
            
            log "找到有效证书:"
            log "证书ID: $cert_id"
            log "创建时间: $create_time"
            log "过期时间: $expire_time"
            
            # 返回证书ID
            echo "$cert_id"
            return
        fi
    else
        log "错误: 需要安装jq才能正确处理JSON"
        exit 1
    fi
    
    # 如果没有找到符合条件的证书，返回空字符串
    echo ""
}

# 主函数
main() {
    log "开始检查证书状态..."
    
    # 检查依赖工具
    for cmd in certbot jq curl openssl xxd; do
        if ! command -v $cmd &> /dev/null; then
            log "错误: $cmd 未安装"
            exit 1
        fi
    done
    
    # 验证服务器时间是否准确
    log "当前服务器时间: $(date)"
    
    local cert_id=""
    
    # 检查证书ID文件是否存在
    if [ ! -f $CERT_ID_FILE ]; then
        log "证书ID文件不存在，可能是首次执行"
        
        # 获取证书列表
        log "获取证书列表..."
        local cert_list=$(get_cert_list)
        
        # 使用jq检查响应状态
        if ! command -v jq &> /dev/null; then
            log "错误: 需要安装jq才能正确处理JSON"
            exit 1
        fi
        
        # 检查响应是否成功 (code == 0 表示成功)
        local response_code=$(echo "$cert_list" | jq -r '.code')
        local response_error=$(echo "$cert_list" | jq -r '.error')
        
        if [ "$response_code" != "0" ]; then
            log "错误: 获取证书列表失败"
            log "错误代码: $response_code"
            log "错误信息: $response_error"
            log "返回结果: $cert_list"
            exit 1
        fi
        
        # 检查是否有证书数据
        local certs_count=$(echo "$cert_list" | jq '.certs | length')
        if [ "$certs_count" -eq 0 ]; then
            log "警告: 未找到任何证书"
        else
            log "成功获取证书列表，共有 $certs_count 个证书"
        fi
        
        # 从列表中查找域名对应的证书ID
        cert_id=$(find_cert_id_by_domain "$DOMAIN" "$cert_list")
        
        # 如果找不到证书ID
        if [ -z "$cert_id" ]; then
            log "警告: 未找到域名 $DOMAIN 对应的证书"
            log "需要首次生成证书并上传"
            
            # 生成新证书
            local cert_dir="/etc/letsencrypt/live/$DOMAIN"
            if [ ! -d $cert_dir ]; then
                log "使用certbot生成新证书..."
                certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
                if [ $? -ne 0 ]; then
                    log "错误: 生成新证书失败"
                    exit 1
                fi
            fi
            
            # 上传新证书
            log "上传证书到七牛云..."
            cert_id=$(upload_cert "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem")
            if [ -z "$cert_id" ]; then
                log "错误: 上传新证书失败"
                exit 1
            fi
            
            # 保存证书ID
            echo "$cert_id" > "$CERT_ID_FILE"
            log "证书ID已保存: $cert_id"
            exit 0
        else
            # 保存找到的证书ID
            echo "$cert_id" > "$CERT_ID_FILE"
            log "找到域名 $DOMAIN 对应的证书ID: $cert_id，已保存"
        fi
    else
        # 从文件中读取证书ID
        cert_id=$(cat "$CERT_ID_FILE")
        log "从文件中读取证书ID: $cert_id"
    fi
    
    # 检查证书是否过期
    log "检查证书是否过期..."
    if check_cert_expiry "$cert_id"; then
        log "证书未过期,无需更新"
        exit 0
    fi
    
    log "证书即将过期,开始更新..."
    
    # 生成新证书
    local cert_dir="/etc/letsencrypt/live/$DOMAIN"
    if [ ! -d $cert_dir ]; then
        certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
        if [ $? -ne 0 ]; then
            log "错误: 生成新证书失败"
            exit 1
        fi
    else
        # 如果证书目录已存在，尝试更新
        certbot renew --cert-name $DOMAIN --non-interactive
        if [ $? -ne 0 ]; then
            log "错误: 更新证书失败"
            exit 1
        fi
    fi
    
    # 上传新证书
    log "上传更新后的证书到七牛云..."
    local new_cert_id=$(upload_cert "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem")
    if [ -z "$new_cert_id" ]; then
        log "错误: 上传新证书失败"
        exit 1
    fi
    
    # 更新证书ID文件
    echo "$new_cert_id" > "$CERT_ID_FILE"
    
    log "证书更新成功,新证书ID: $new_cert_id"
}

# 执行主函数
main 