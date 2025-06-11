#!/usr/bin/env bash

# 禅道API获取bug数脚本 - 适用于禅道开源版18.7
# 使用方法: ./zentao.sh -u 禅道URL -a 账号 -p 密码 [-c 应用代号 -k 应用密钥] [-P 产品ID] [-s 状态] [--all_product_id]

set -e

# 默认参数
STATUS="active"
CURL_OPTS="-s"
ALL_PRODUCT_ID=false
PAGE_LIMIT=20  # 每页默认显示数量
ASSIGNED_TO=""  # 默认不按指派人过滤
RESOLVED_BY=""  # 默认不按解决人过滤
RESOLUTION_FIXED=false # 默认不过滤resolution
OPENED_AFTER_DATE="" # 默认不过滤创建日期
TMUX_ENV=false  # 默认不设置tmux环境变量

# 函数：显示帮助信息
show_help() {
    echo "使用方法: $0 [选项...]"
    echo "选项:"
    echo "  -u URL       禅道URL，例如：http://zentao.example.com"
    echo "  -a 账号      登录用户名"
    echo "  -p 密码      登录密码"
    echo "  -c 代号      应用代号（免密登录）"
    echo "  -k 密钥      应用密钥（免密登录）"
    echo "  -P 产品ID    产品ID，不提供则获取所有产品"
    echo "  -s 状态      bug状态：active=未解决, resolved=已解决, closed=已关闭, all=全部"
    echo "  -i ID        指定bug ID获取详情"
    echo "  -l 数量      每页显示的记录数量（默认20）"
    echo "  --all_product_id 仅显示所有产品ID，不获取bug信息"
    echo "  --assigned_to 用户名 只显示指派给指定用户的未解决bug (默认status=active)"
    echo "  --resolvedBy 用户名 只显示由指定用户解决的bug (默认status=all)"
    echo "  --resolutionByFixed 只显示解决方案为已解决的bug,过滤掉无法复现、重复bug等方案的bug，默认不启用,和 resolvedBy 配合使用"
    echo "  --opened-after YYYY-MM-DD 只显示在此日期之后创建的bug"
    echo "  --tmux_env   将bug数量设置为tmux环境变量"
    echo "  -h           显示此帮助信息"
    exit 1
}

# 解析命令行参数
while [ $# -gt 0 ]; do
    case "$1" in
        -u) URL="$2"; shift 2 ;;
        -a) ACCOUNT="$2"; shift 2 ;;
        -p) PASSWORD="$2"; shift 2 ;;
        -c) CODE="$2"; shift 2 ;;
        -k) KEY="$2"; shift 2 ;;
        -P) PRODUCT="$2"; shift 2 ;;
        -s) STATUS="$2"; shift 2 ;;
        -i) BUG_ID="$2"; shift 2 ;;
        -l) PAGE_LIMIT="$2"; shift 2 ;;
        --all_product_id) ALL_PRODUCT_ID=true; shift ;;
        --assigned_to) ASSIGNED_TO="$2"; STATUS="active"; shift 2 ;;
        --resolvedBy) RESOLVED_BY="$2"; STATUS="all"; shift 2 ;;
        --resolutionByFixed) RESOLUTION_FIXED=true; shift ;;
        --opened-after)
            OPENED_AFTER_DATE="$2"
            if ! [[ "$OPENED_AFTER_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                echo "错误: --opened-after 日期格式无效. 请使用 YYYY-MM-DD 格式." >&2
                show_help
            fi
            shift 2
            ;;
        --tmux_env) TMUX_ENV=true; shift ;;
        -h) show_help ;;
        -*) echo "无效选项: $1" >&2; show_help ;;
        *) shift ;;
    esac
done

# 检查必需参数
if [ -z "$URL" ] || [ -z "$ACCOUNT" ] || [ -z "$PASSWORD" ]; then
    echo "错误: URL、账号和密码为必填参数"
    show_help
fi

# 移除URL尾部斜杠
URL=${URL%/}

# token缓存文件
TOKEN_CACHE_FILE="$HOME/.zentao_tokens"

# 从缓存获取token
get_cached_token() {
    local url_hash=$(echo -n "$URL$ACCOUNT" | md5sum | cut -d' ' -f1)
    
    # 检查缓存文件是否存在
    if [ -f "$TOKEN_CACHE_FILE" ]; then
        # 查找匹配的token记录
        local token_line=$(grep "^$url_hash:" "$TOKEN_CACHE_FILE")
        
        if [ -n "$token_line" ]; then
            # 提取token
            local token=$(echo "$token_line" | cut -d':' -f2)
            
            # 验证token是否有效
            if verify_token "$token"; then
                echo "$token"
                return 0
            else
                # token无效，删除缓存记录
                sed -i "/^$url_hash:/d" "$TOKEN_CACHE_FILE"
            fi
        fi
    fi
    
    return 1
}

# 验证token是否有效
verify_token() {
    local token=$1
    local response
    
    # 发送一个简单请求来验证token (获取产品列表)
    response=$(curl $CURL_OPTS -o /dev/null -w "%{http_code}" \
        -H "Token: $token" \
        "$URL/api.php/v1/products" 2>/dev/null)
    
    # 检查返回状态码，200表示成功
    if [ "$response" = "200" ]; then
        return 0
    else
        return 1
    fi
}

# 保存token到缓存
save_token_to_cache() {
    local token=$1
    local url_hash=$(echo -n "$URL$ACCOUNT" | md5sum | cut -d' ' -f1)
    
    # 如果缓存文件不存在，创建它
    touch "$TOKEN_CACHE_FILE"
    
    # 删除旧的记录
    sed -i "/^$url_hash:/d" "$TOKEN_CACHE_FILE"
    
    # 添加新记录
    echo "$url_hash:$token:$(date +%s)" >> "$TOKEN_CACHE_FILE"
    
    # 确保文件权限正确 (只有当前用户可读写)
    chmod 600 "$TOKEN_CACHE_FILE"
}

# 获取令牌（API v1方式）
get_token() {
    # 先尝试从缓存获取有效token
    local cached_token
    cached_token=$(get_cached_token)
    
    if [ -n "$cached_token" ]; then
        echo "使用缓存的token" >&2
        echo "$cached_token"
        return 0
    fi
    
    # 如果没有有效的缓存token，则重新获取
    local response
    response=$(curl $CURL_OPTS -X POST \
        -H "Content-Type: application/json" \
        -d "{\"account\":\"$ACCOUNT\",\"password\":\"$PASSWORD\"}" \
        "$URL/api.php/v1/tokens")
    
    # 检查是否成功并提取token
    if echo "$response" | grep -q "token"; then
        local new_token
        new_token=$(echo "$response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        
        # 保存token到缓存
        save_token_to_cache "$new_token"
        
        echo "$new_token"
    else
        echo "获取令牌失败: $response" >&2
        return 1
    fi
}

# 免密登录
api_login() {
    local timestamp=$(date +%s)
    local token=$(echo -n "${CODE}${KEY}${timestamp}" | md5sum | cut -d' ' -f1)
    local login_url="${URL}/api.php?m=user&f=apilogin&account=${ACCOUNT}&code=${CODE}&time=${timestamp}&token=${token}"
    
    local response
    response=$(curl $CURL_OPTS "$login_url")
    
    # 检查登录结果
    if [[ "$response" == *"成功"* ]] || [[ "$response" == *"success"* ]]; then
        return 0
    else
        echo "免密登录失败: $response" >&2
        return 1
    fi
}

# 获取单个bug详情
get_bug_detail() {
    local token=$1
    local bug_id=$2
    
    local response
    response=$(curl $CURL_OPTS \
        -H "Token: $token" \
        "$URL/api.php/v1/bugs/$bug_id")
    
    echo "$response"
}

# 获取所有产品列表
get_all_products() {
    local token=$1
    
    local api_url="$URL/api.php/v1/products"
    echo "获取产品列表: $api_url" >&2
    
    local response
    response=$(curl $CURL_OPTS \
        -H "Token: $token" \
        "$api_url")
    
    # 提取产品ID列表
    echo "$response" | jq -r '.products[] | .id'
}
# 获取bug列表（支持分页）
get_bugs() {
    local token=$1
    local specific_product=$2
    local page=$3  # 页码参数
    local all_bugs="{\"bugs\":[],\"total\":0,\"limit\":$PAGE_LIMIT,\"page\":1}"
    local current_page=1
    local total_pages=1
    local params_base=""
    
    # 如果未指定页码，默认为第一页
    if [ -z "$page" ]; then
        page=1
    fi
    
    # 添加产品过滤条件
    if [ -n "$specific_product" ]; then
        params_base="?product=$specific_product"
    else
        params_base="?"
    fi
    
    # 添加limit参数
    if [[ "$params_base" == "?" ]]; then
        params_base="?limit=$PAGE_LIMIT"
    else
        params_base="${params_base}&limit=$PAGE_LIMIT"
    fi
    
    # 添加页码参数
    params_base="${params_base}&page=$page"
    # Always fetch all bugs from the API, client-side will filter if needed based on global STATUS
    params_base="${params_base}&status=all"
    
    # 构建API URL
    local api_url="$URL/api.php/v1/bugs${params_base}"
    echo "调用API: $api_url" >&2
    
    local response
    response=$(curl $CURL_OPTS \
        -H "Token: $token" \
        "$api_url")
    
    # 检查响应是否为有效JSON且非空
    if [ -z "$response" ]; then
        echo "{\"error\":\"API返回空响应\",\"bugs\":[],\"total\":0,\"limit\":$PAGE_LIMIT,\"page\":$page}" | jq .
        return
    fi

    
    echo "$response" | jq .
}


# 处理单个产品的bug数据
process_bugs_data() {
    local bugs_data=$1
    local product_id=$2
    local status=$3
    local assigned_to=$4
    local resolved_by_user=$5 # New parameter for resolvedBy
    local resolution_fixed_flag=$6 # New parameter for resolutionByFixed
    local opened_after_date_param=$7 # New parameter for openedDate filtering
    local bug_count_return=0  # 返回bug计数
    
    # 使用jq提取bug数量和必要信息
    if command -v jq >/dev/null 2>&1; then
        # 检查API响应中是否包含错误信息
        if echo "$bugs_data" | jq -e '.error' > /dev/null 2>&1; then
            local error_msg=$(echo "$bugs_data" | jq -r '.error')
            echo "获取产品 $product_id 的bug失败: $error_msg" >&2
            return 1
        fi
        
        # 状态文本映射
        local status_text
        case "$status" in
            active) status_text="未解决" ;;
            resolved) status_text="已解决" ;;
            closed) status_text="已关闭" ;;
            all) status_text="全部" ;;
            *) status_text="$status" ;;
        esac
        
        local product_text="产品ID:$product_id"
        local total=$(echo "$bugs_data" | jq '.total')
        local limit=$(echo "$bugs_data" | jq '.limit')
        local pages=$(( (total + limit - 1) / limit ))
        
        # 根据状态进行客户端过滤
        local filtered_bugs
        local bug_count
        
        if [ "$status" = "all" ]; then
            # 全部状态，直接使用total
            bug_count=$total
            filtered_bugs=$(echo "$bugs_data" | jq '.bugs')
        else
            # 其他状态，需要在客户端过滤
            filtered_bugs=$(echo "$bugs_data" | jq --arg status "$status" '.bugs | map(select(.status == $status))')
            bug_count=$(echo "$filtered_bugs" | jq 'length')
        fi
        
        # 如果指定了assignedTo，进一步过滤
        if [ -n "$assigned_to" ]; then
            filtered_bugs=$(echo "$filtered_bugs" | jq --arg assigned "$assigned_to" 'map(select(.assignedTo.account == $assigned))')
            bug_count=$(echo "$filtered_bugs" | jq 'length')
            status_text="${status_text}且指派给 $assigned_to"
        fi
        
                # 如果指定了resolvedBy，进一步过滤
                if [ -n "$resolved_by_user" ]; then
                    # Filter for bugs where resolvedBy is not null and resolvedBy.account matches
                    filtered_bugs=$(echo "$filtered_bugs" | jq --arg resolved_by "$resolved_by_user" 'map(select(.resolvedBy.account == $resolved_by))')
                    bug_count=$(echo "$filtered_bugs" | jq 'length')
                    status_text="${status_text}且由 $resolved_by_user 解决"
                fi

                # 如果指定了resolutionByFixed，进一步过滤
                if [ "$resolution_fixed_flag" = true ]; then
                    filtered_bugs=$(echo "$filtered_bugs" | jq 'map(select(.resolution == "fixed"))')
                    bug_count=$(echo "$filtered_bugs" | jq 'length')
                    status_text="${status_text}且resolution为fixed"
                fi

                # 如果指定了opened-after，进一步过滤
                if [ -n "$opened_after_date_param" ]; then
                    # openedDate is like "YYYY-MM-DD HH:MM:SS", we only need the date part
                    filtered_bugs=$(echo "$filtered_bugs" | jq --arg opened_after "$opened_after_date_param" 'map(select(.openedDate and ((.openedDate | sub(" .*"; "")) > $opened_after)))')
                    bug_count=$(echo "$filtered_bugs" | jq 'length')
                    status_text="${status_text}且在 $opened_after_date_param 之后创建"
                fi
        
        echo "$product_text 的 $status_text Bug数量: $bug_count (总记录: $total，每页: $limit，共 $pages 页)"
        bug_count_return=$bug_count  # 保存bug计数用于返回
        
        # 打印每条bug的ID和标题（只显示过滤后的结果）
        if [ "$bug_count" -gt 0 ]; then
            echo "Bug列表："
            # 将每个bug的id、title、status和resolution打印为一行
            echo "$filtered_bugs" | jq -r '.[] | "ID: \(.id) | 标题: \(.title) | 状态: \(.status) | Resolution: \(.resolution)"'
            echo ""
        fi
    else
        echo "警告: 未安装jq工具，无法解析JSON响应"
        echo "$bugs_data"
        bug_count_return=0
    fi
    
    # 返回处理的bug数量（使用echo命令并确保只返回数字）
    echo "$bug_count_return"
}

# 主流程
main() {
    local token
    
    # 尝试免密登录，如果提供了应用代号和密钥
    if [ -n "$CODE" ] && [ -n "$KEY" ]; then
        if api_login; then
            echo "免密登录成功，获取令牌..."
        fi
    fi
    
    # 无论是否免密登录，都需要获取令牌用于API调用
    token=$(get_token)
    if [ -z "$token" ]; then
        exit 1
    fi

    # 只在非调试模式下显示token
    if [ "$CURL_OPTS" = "-s" ]; then
        echo "token = $token"
    fi
    
    # 如果指定了--all_product_id参数，只显示产品ID列表
    if [ "$ALL_PRODUCT_ID" = true ]; then
        echo "获取所有产品ID列表..."
        local all_products
        all_products=$(get_all_products "$token")
        
        # 检查是否成功获取产品列表
        if [ -z "$all_products" ] || [[ "$all_products" == *"error"* ]]; then
            echo "获取产品列表失败" >&2
            echo "$all_products" >&2
            exit 1
        fi
        
        echo "禅道系统中的所有产品ID："
        echo "$all_products" | tr '\n' ' '
        echo -e "\n"
        return
    fi
    
    # 如果指定了bug ID，则获取单个bug详情
    if [ -n "$BUG_ID" ]; then
        local bug_detail
        bug_detail=$(get_bug_detail "$token" "$BUG_ID")
        echo "$bug_detail" | jq .
        return
    fi
    
    # 查询bug列表
    local bugs_data
    local total_bug_count=0  # 用于累计bug总数
    
    # 如果指定了产品ID，直接查询该产品
    if [ -n "$PRODUCT" ]; then
        # 获取第1页数据并查看总页数
        bugs_data=$(get_bugs "$token" "$PRODUCT" 1)
        local product_bug_count
        product_bug_count=$(process_bugs_data "$bugs_data" "$PRODUCT" "$STATUS" "$ASSIGNED_TO" "$RESOLVED_BY" "$RESOLUTION_FIXED" "$OPENED_AFTER_DATE")
        # 确保我们只获取数字部分进行累加
        product_bug_count=$(echo "$product_bug_count" | grep -o '[0-9]*$')
        total_bug_count=$((total_bug_count + product_bug_count))
        
        # 获取总页数
        local total=$(echo "$bugs_data" | jq '.total')
        local limit=$(echo "$bugs_data" | jq '.limit')
        local total_pages=$(( (total + limit - 1) / limit ))
        
        # 如果有多页，自动遍历所有页面
        if [ "$total_pages" -gt 1 ]; then
            echo "共有 $total_pages 页数据，当前显示第1页"

            
            # 从第2页开始遍历剩余页面
            for ((page_num=2; page_num<=total_pages; page_num++)); do
                echo "正在获取第 $page_num 页..."
                bugs_data=$(get_bugs "$token" "$PRODUCT" "$page_num")
                local page_bug_count
                page_bug_count=$(process_bugs_data "$bugs_data" "$PRODUCT" "$STATUS" "$ASSIGNED_TO" "$RESOLVED_BY" "$RESOLUTION_FIXED" "$OPENED_AFTER_DATE")
                # 确保我们只获取数字部分进行累加
                page_bug_count=$(echo "$page_bug_count" | grep -o '[0-9]*$')
                total_bug_count=$((total_bug_count + page_bug_count))
            done
        fi
    else
        # 没有指定产品ID，先获取所有产品列表
        echo "未指定产品ID，获取所有产品..."
        local all_products
        all_products=$(get_all_products "$token")
        
        # 检查是否成功获取产品列表
        if [ -z "$all_products" ] || [[ "$all_products" == *"error"* ]]; then
            echo "获取产品列表失败" >&2
            echo "$all_products" >&2
            exit 1
        fi
        
        echo "找到以下产品ID："
        echo "$all_products" | tr '\n' ' '
        echo -e "\n"
        
        # 遍历每个产品ID
        for product_id in $all_products; do
            echo "========================="
            echo "处理产品ID: $product_id"
            echo "========================="
            
            # 获取第1页数据
            bugs_data=$(get_bugs "$token" "$product_id" 1)
            local product_bug_count
            product_bug_count=$(process_bugs_data "$bugs_data" "$product_id" "$STATUS" "$ASSIGNED_TO" "$RESOLVED_BY" "$RESOLUTION_FIXED" "$OPENED_AFTER_DATE") || continue
            # 确保我们只获取数字部分进行累加
            product_bug_count=$(echo "$product_bug_count" | grep -o '[0-9]*$')
            total_bug_count=$((total_bug_count + product_bug_count))
            
            # 获取总页数
            local total=$(echo "$bugs_data" | jq '.total')
            local limit=$(echo "$bugs_data" | jq '.limit')
            local total_pages=$(( (total + limit - 1) / limit ))
            
            # 如果有多页，自动遍历所有页面
            if [ "$total_pages" -gt 1 ]; then
                echo "产品 $product_id 共有 $total_pages 页数据，当前显示第1页"

                
                # 从第2页开始遍历剩余页面
                for ((page_num=2; page_num<=total_pages; page_num++)); do
                    echo "正在获取第 $page_num 页..."
                    bugs_data=$(get_bugs "$token" "$product_id" "$page_num")
                    local page_bug_count
                    page_bug_count=$(process_bugs_data "$bugs_data" "$product_id" "$STATUS" "$ASSIGNED_TO" "$RESOLVED_BY" "$RESOLUTION_FIXED" "$OPENED_AFTER_DATE") || break
                    # 确保我们只获取数字部分进行累加
                    page_bug_count=$(echo "$page_bug_count" | grep -o '[0-9]*$')
                    total_bug_count=$((total_bug_count + page_bug_count))
                done
            fi
        done
    fi
    
    # 显示bug总数统计信息
    # 状态文本映射
    local status_text
    case "$STATUS" in
        active) status_text="未解决" ;;
        resolved) status_text="已解决" ;;
        closed) status_text="已关闭" ;;
        all) status_text="全部" ;;
        *) status_text="$STATUS" ;;
    esac
    
    if [ -n "$ASSIGNED_TO" ]; then
        status_text="${status_text}且指派给 $ASSIGNED_TO"
    fi
    
    if [ -n "$RESOLVED_BY" ]; then
        status_text="${status_text}且由 $RESOLVED_BY 解决"
    fi

    if [ "$RESOLUTION_FIXED" = true ]; then
        status_text="${status_text}且resolution为fixed"
    fi

    if [ -n "$OPENED_AFTER_DATE" ]; then
        status_text="${status_text}且在 $OPENED_AFTER_DATE 之后创建"
    fi
    

    if [ -n "$PRODUCT" ]; then
        echo "统计结果：产品 $PRODUCT 的 $status_text Bug总数为 $total_bug_count"
        
        # 在统计结果后打印所有页面的bug详情
        echo ""
        echo "Bug列表详情："
        for ((page_num=1; page_num<=total_pages; page_num++)); do
            bugs_data=$(get_bugs "$token" "$PRODUCT" "$page_num")
            
            # 根据状态过滤bug
            local filtered_bugs
            if [ "$STATUS" = "all" ]; then
                filtered_bugs=$(echo "$bugs_data" | jq '.bugs')
            else
                filtered_bugs=$(echo "$bugs_data" | jq --arg status "$STATUS" '.bugs | map(select(.status == $status))')
            fi
            
            # 打印bug详情
            echo "$filtered_bugs" | jq -r '.[] | "ID: \(.id) | 标题: \(.title) | 状态: \(.status) | Resolution: \(.resolution)"'
        done
    else
        echo "=============================================="
        echo "统计结果：所有产品的 $status_text Bug总数为 $total_bug_count"
        echo "=============================================="
        # 只有在指定了--tmux_env参数时才设置tmux环境变量
        if [ "$TMUX_ENV" = true ]; then
            tmux set-environment -g ZENTAO_BUG_COUNT $total_bug_count
            echo "已设置tmux环境变量 ZENTAO_BUG_COUNT=$total_bug_count"
        fi
        
        # 打印所有产品的bug详情列表
        echo ""
        echo "所有产品Bug列表详情："
        for product_id in $all_products; do
            local product_total_pages=1
            
            # 获取该产品的总页数
            bugs_data=$(get_bugs "$token" "$product_id" 1)
            local total=$(echo "$bugs_data" | jq '.total')
            local limit=$(echo "$bugs_data" | jq '.limit')
            product_total_pages=$(( (total + limit - 1) / limit ))
            
            # 如果该产品有bug，显示产品ID
            if [ "$total" -gt 0 ]; then
                echo ""
                echo "产品ID: $product_id"
                echo "---------------"
            
                # 遍历所有页面
                for ((page_num=1; page_num<=product_total_pages; page_num++)); do
                    if [ "$page_num" -gt 1 ]; then
                        bugs_data=$(get_bugs "$token" "$product_id" "$page_num")
                    fi
                    
                    # 根据状态过滤bug
                    local filtered_bugs
                    if [ "$STATUS" = "all" ]; then
                        filtered_bugs=$(echo "$bugs_data" | jq '.bugs')
                    else
                        filtered_bugs=$(echo "$bugs_data" | jq --arg status "$STATUS" '.bugs | map(select(.status == $status))')
                    fi
                    
                    # 如果指定了assignedTo，进一步过滤
                    if [ -n "$ASSIGNED_TO" ]; then
                        filtered_bugs=$(echo "$filtered_bugs" | jq --arg assigned "$ASSIGNED_TO" 'map(select(.assignedTo.account == $assigned))')
                    fi
                    
                                        # 如果指定了resolvedBy，进一步过滤
                                        if [ -n "$RESOLVED_BY" ]; then
                                            filtered_bugs=$(echo "$filtered_bugs" | jq --arg resolved_by "$RESOLVED_BY" 'map(select(.resolvedBy.account == $resolved_by))')
                                        fi
                    
                                                            # 如果指定了resolutionByFixed，进一步过滤
                                                            if [ "$RESOLUTION_FIXED" = true ]; then
                                                                filtered_bugs=$(echo "$filtered_bugs" | jq 'map(select(.resolution == "fixed"))')
                                                            fi
                    
                                                            # 如果指定了opened-after，进一步过滤
                                                            if [ -n "$OPENED_AFTER_DATE" ]; then
                                                                filtered_bugs=$(echo "$filtered_bugs" | jq --arg opened_after "$OPENED_AFTER_DATE" 'map(select(.openedDate and ((.openedDate | sub(" .*"; "")) > $opened_after)))')
                                                            fi
                    
                    # 打印bug详情
                    echo "$filtered_bugs" | jq -r '.[] | "ID: \(.id) | 标题: \(.title) | 状态: \(.status) | Resolution: \(.resolution)"'
                done
            fi
        done
    fi
    echo "=============================================="
}

main
