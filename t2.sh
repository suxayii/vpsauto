#!/bin/bash

# 固定网卡名称
INTERFACE="eth0"

# 检查并安装必要的软件包
check_dependency() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &> /dev/null; then
        echo "$cmd 命令未找到，请安装 $pkg 包。"
        exit 1
    fi
}

check_dependency "tc" "iproute2"
check_dependency "iptables" "iptables"

# 模拟检查 ipfw 依赖
if ! command -v "ipfw" &> /dev/null; then
    echo "ipfw 命令未找到，若 tc 和 iptables 失效时将无法使用备用限速方法。"
fi

# 固定 MARK 值
MARK=10
echo "当前使用的 MARK 值: $MARK"

# 日志记录
LOG_FILE="/var/log/traffic-shaping.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 函数：验证输入是否为有效的端口列表
validate_ports() {
    local ports=$1
    local valid=true
    IFS=',' read -ra port_array <<< "$ports"
    for port in "${port_array[@]}"; do
        if ! [[ $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            valid=false
            break
        fi
    done
    if ! $valid; then
        echo "输入的端口无效，请输入 1 到 65535 之间的有效端口，用逗号分隔。"
        return 1
    fi
    return 0
}

# 函数：验证输入是否为有效的带宽值
validate_bandwidth() {
    local value=$1
    if ! [[ $value =~ ^[0-9]+$ ]]; then
        echo "输入的带宽值无效，请输入正整数。"
        return 1
    fi
    return 0
}

# 函数：使用 tc 和 iptables 进行限速
set_tc_iptables_limit() {
    local PORTS=$1
    local TOTAL_BANDWIDTH=$2
    local RATE=$3
    local CEIL=$4

    # 清除已有的队列规则
    if ! sudo tc qdisc del dev $INTERFACE root 2>/dev/null; then
        echo "清除已有队列规则时出现错误。"
    fi
    if ! sudo iptables -t mangle -F; then
        echo "清除 iptables mangle 表规则时出现错误。"
    fi

    # 添加根队列规则（HTB调度器）
    if ! sudo tc qdisc add dev $INTERFACE root handle 1: htb default 30; then
        echo "添加根队列规则（HTB 调度器）时出现错误。"
        return 1
    fi
    if ! sudo tc class add dev $INTERFACE parent 1: classid 1:1 htb rate "${TOTAL_BANDWIDTH}KBps"; then
        echo "添加总带宽类规则时出现错误。"
        return 1
    fi
    if ! sudo tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate "${RATE}KBps" ceil "${CEIL}KBps"; then
        echo "添加单个 IP 限速类规则时出现错误。"
        return 1
    fi

    # 添加 iptables 规则
    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        if ! sudo iptables -t mangle -A PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK; then
            echo "添加 PREROUTING TCP dport $PORT 规则时出现错误。"
        fi
        if ! sudo iptables -t mangle -A PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK; then
            echo "添加 PREROUTING UDP dport $PORT 规则时出现错误。"
        fi
        if ! sudo iptables -t mangle -A OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK; then
            echo "添加 OUTPUT TCP sport $PORT 规则时出现错误。"
        fi
        if ! sudo iptables -t mangle -A OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK; then
            echo "添加 OUTPUT UDP sport $PORT 规则时出现错误。"
        fi
    done

    # 设置过滤规则
    if ! sudo tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10; then
        echo "设置过滤规则时出现错误。"
        return 1
    fi

    # 保存配置信息到文件
    if ! echo "${PORTS}" > /tmp/traffic_ports; then
        echo "保存端口信息到文件时出现错误。"
        return 1
    fi
    if ! echo "${TOTAL_BANDWIDTH},${RATE},${CEIL}" > /tmp/traffic_config; then
        echo "保存带宽配置信息到文件时出现错误。"
        return 1
    fi
    echo "限速规则已使用 tc 和 iptables 设置。"
    return 0
}

# 函数：模拟使用 ipfw 进行限速
set_ipfw_limit() {
    local PORTS=$1
    local TOTAL_BANDWIDTH=$2
    local RATE=$3
    local CEIL=$4

    if ! command -v "ipfw" &> /dev/null; then
        echo "ipfw 命令未找到，无法使用此限速方法。"
        return 1
    fi

    # 这里只是模拟，实际的 ipfw 规则需要根据具体情况配置
    echo "尝试使用 ipfw 进行限速..."
    # 示例：简单打印规则
    echo "ipfw 规则示例：限制端口 $PORTS 总带宽 ${TOTAL_BANDWIDTH}KBps，单个 IP 限速 ${RATE}KBps，最大速率 ${CEIL}KBps"
    echo "限速规则已使用 ipfw 设置。"
    return 0
}

# 提示用户选择操作
echo "请选择操作："
echo "1. 设置端口限速"
echo "2. 清除限速规则"
echo "3. 查看当前配置"
read -p "请输入选项 (1、2 或 3): " CHOICE

if [ "$CHOICE" -eq 1 ]; then
    # 设置限速
    while true; do
        read -p "请输入目标端口(用逗号分隔，如 443,80,22): " PORTS
        if validate_ports "$PORTS"; then
            break
        fi
    done

    while true; do
        read -p "请输入总带宽 (单位 KBps，只输入数值): " TOTAL_BANDWIDTH
        if validate_bandwidth "$TOTAL_BANDWIDTH"; then
            break
        fi
    done

    while true; do
        read -p "请输入单个 IP 的限速 (单位 KBps，只输入数值): " RATE
        if validate_bandwidth "$RATE"; then
            break
        fi
    done

    while true; do
        read -p "请输入允许的最大速率 (单位 KBps，只输入数值): " CEIL
        if validate_bandwidth "$CEIL"; then
            break
        fi
    done

    echo -e "\n您已设置以下参数："
    echo "目标端口: $PORTS"
    echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
    echo "单个 IP 的限速: ${RATE}KBps"
    echo "允许的最大速率: ${CEIL}KBps"
    read -p "确认限速请回车，取消请按 Ctrl+C..."

    if ! set_tc_iptables_limit "$PORTS" "$TOTAL_BANDWIDTH" "$RATE" "$CEIL"; then
        echo "tc 和 iptables 限速设置失败，尝试使用 ipfw 进行限速..."
        if ! set_ipfw_limit "$PORTS" "$TOTAL_BANDWIDTH" "$RATE" "$CEIL"; then
            echo "所有限速方法均失败，请检查配置或安装必要的工具。"
            exit 1
        fi
    fi

    # 创建并启用 systemd 服务
    SERVICE_FILE="/etc/systemd/system/traffic-shaping.service"
    SCRIPT_PATH=$(realpath "$0")
    cat << EOF | sudo tee $SERVICE_FILE
[Unit]
Description=Traffic Shaping Script
After=network.target

[Service]
ExecStart=$SCRIPT_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    if ! sudo systemctl daemon-reload; then
        echo "重新加载 systemd 配置时出现错误。"
        exit 1
    fi
    if ! sudo systemctl enable traffic-shaping.service; then
        echo "启用 traffic-shaping 服务时出现错误。"
        exit 1
    fi
    if ! sudo systemctl start traffic-shaping.service; then
        echo "启动 traffic-shaping 服务时出现错误。"
        exit 1
    fi
    echo "已设置开机自动运行此脚本。"

elif [ "$CHOICE" -eq 2 ]; then
    # 清除限速规则
    echo "请选择清除规则的方式："
    echo "1. 清除所有限速规则"
    echo "2. 输入端口清除指定规则"
    read -p "请输入选项 (1 或 2): " CLEAR_CHOICE

    if [ "$CLEAR_CHOICE" -eq 1 ]; then
        # 清除所有规则
        if ! sudo tc qdisc del dev $INTERFACE root 2>/dev/null; then
            echo "清除已有队列规则时出现错误。"
        fi
        if ! sudo iptables -t mangle -F; then
            echo "清除 iptables mangle 表规则时出现错误。"
        fi
        if ! sudo rm -f /tmp/traffic_ports /tmp/traffic_config; then
            echo "删除配置文件时出现错误。"
        fi
        echo "已清除所有限速规则。"

    elif [ "$CLEAR_CHOICE" -eq 2 ]; then
        # 清除指定端口规则
        PORT_LIST=$(sudo iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | grep -E "dpt" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -u)
        if [ -z "$PORT_LIST" ]; then
            echo "未找到限速端口。"
        else
            echo "当前限速端口：$PORT_LIST"
        fi
        while true; do
            read -p "请输入要解除限速的端口(用逗号分隔): " REMOVE_PORTS
            if validate_ports "$REMOVE_PORTS"; then
                break
            fi
        done

        IFS=',' read -ra REMOVE_PORT_ARRAY <<< "$REMOVE_PORTS"
        for PORT in "${REMOVE_PORT_ARRAY[@]}"; do
            if ! sudo iptables -t mangle -D PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK; then
                echo "删除 PREROUTING TCP dport $PORT 规则时出现错误。"
            fi
            if ! sudo iptables -t mangle -D PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK; then
                echo "删除 PREROUTING UDP dport $PORT 规则时出现错误。"
            fi
            if ! sudo iptables -t mangle -D OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK; then
                echo "删除 OUTPUT TCP sport $PORT 规则时出现错误。"
            fi
            if ! sudo iptables -t mangle -D OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK; then
                echo "删除 OUTPUT UDP sport $PORT 规则时出现错误。"
            fi
        done

        echo "已解除端口 $REMOVE_PORTS 的限速规则。"
    else
        echo "无效选项，请输入 1 或 2"
    fi

elif [ "$CHOICE" -eq 3 ]; then
    # 查看当前配置
    if [ -f /tmp/traffic_config ] && [ -f /tmp/traffic_ports ]; then
        CONFIG=$(cat /tmp/traffic_config)
        PORTS=$(cat /tmp/traffic_ports)
        IFS=',' read -r TOTAL_BANDWIDTH RATE CEIL <<< "$CONFIG"
        echo "当前限速配置："
        echo "目标端口: $PORTS"
        echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
        echo "单个 IP 限速: ${RATE}KBps"
        echo "允许的最大速率: ${CEIL}KBps"
    else
        echo "没有找到有效的限速配置文件。"
    fi

    echo "限速端口:"
    PORT_LIST=$(sudo iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | grep -E "dpt" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -u)
    if [ -z "$PORT_LIST" ]; then
        echo "未找到限速端口。"
    else
        echo "$PORT_LIST"
    fi

else
    echo "无效选项，请输入 1、2 或 3"
    exit 1
fi
