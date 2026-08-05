# SillyTavern-Termux
SillyTavern Termux 一键安装与版本管理脚本。

管理菜单支持安装、修复、启动、自动更新，以及切换局域网访问。

开启局域网访问后，SillyTavern 会使用自带的 `listen` 与白名单模式监听网络，并自动放行 IPv4 私有网段。其他设备可通过 `http://手机局域网IP:8000` 访问。未启用账号或其他认证时，请只在可信网络中使用此模式。
