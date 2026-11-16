# 清财

macOS 公司财务工作台，覆盖收支、报销、工资和对账。

## 本地构建

需要 macOS 14 或更新版本，以及 Xcode 命令行工具。运行 `bash scripts/build-app.sh`，在 `dist/` 中打开「清财.app」。运行 `swift run --build-system native QingcaiChecks` 可执行财务与网关测试。

应用支持生成虚构演示账套。本机模拟网关不会连接真实机构，模拟回执也不具备真实业务效力。网关接口定义见 [OpenAPI 规范](gateway/openapi.json)。
