# Throttle.sh

**一键设置和管理 VPS 端口带宽限速的脚本**

## 功能介绍

- 设置端口带宽限速
  - 支持多个端口同时限速
  - 可配置总带宽、单 IP 限速、最大速率
- 支持查看当前限速配置
  - 显示已设置限速的端口
  - 总带宽、单 IP 限速、最大速率等详细信息
- 支持一键清除所有限速规则或按端口选择清除
- 自动化流量管理，操作简单高效

## 安装 & 使用

1. 下载脚本：

   ```bash
   bash <(curl -Ls https://raw.githubusercontent.com/suxayii/vpsauto/refs/heads/master/Throttle.sh)
