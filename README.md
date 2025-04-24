# update_qiniu_cert
Update Qiniu OSS https cert with Let's Encrypt automatically.

## Usage

编辑 crontab                                 
> crontab -e                                
添加以下内容（每天凌晨1点执行）
> 0 1 * * * /path/to/update_qiniu_cert.sh

七牛证书接口文档：https://developer.qiniu.com/fusion/8593/interface-related-certificate
查看日志命令：cat /var/log/qiniu_cert_update.log


# 配置信息
QINIU_ACCESS_KEY="xxx"
QINIU_SECRET_KEY="xxx"
DOMAIN="domain.example.com"
CERT_ID_FILE="/path/to/qiniu_cert_id"
LOG_FILE="/var/log/qiniu_cert_update.log"

替换为你自己的。

默认是 10 天内到期会自动更新，可根据自己需求调整。

因为使用 Let's Encrypt，所以需要提前安装。

脚本依赖 jq 解析 json，curl 发送请求，执行脚本前需要确认已安装。

如果执行不成功，可通过日志查看原因。