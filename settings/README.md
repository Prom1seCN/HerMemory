# settings

- 非密钥设置的出厂模板，装在服务器 `~/.hermes/`，不进同步库；凭据永远只留 config.yaml / .env。
- 只放 Hermes 官方支持的配置键，不自研合并逻辑；与 config.yaml 重叠项以本目录模板为准，install.sh 装机时写入。

## v0.1.0 拆入

- [ ] 时区（Asia/Shanghai）
- [ ] 时间注入开关 `gateway.message_timestamps.enabled`（官方键，默认关，install.sh 置 true）
- [ ] 搜索通道（国内默认源）
- [ ] 同步配置模板（凭据留空）
