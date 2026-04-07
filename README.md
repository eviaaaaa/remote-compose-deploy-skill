# remote-compose-deploy

一个用于远程 Compose 部署的 Codex Skill，适合按 `module + env` 管理部署配置，并通过统一入口脚本完成初始化、构建、上传、远端同步和服务重启。

## 特性

- 统一入口：使用 `scripts/deploy.ps1` 处理初始化、列配置和执行部署
- 配置驱动：默认读取 `deploy-configs/<module>-<env>.json`
- 支持两种部署模式：`artifact` 和 `repo-sync`
- 支持多种 Compose 命令探测：`docker compose`、`podman compose`、`docker-compose`、`podman-compose`
- 支持按整个项目或指定服务执行 `restart` / `rebuild`
- 支持本地构建心跳、空闲超时、构建超时和复用已有产物
- 支持部署后输出 `compose ps` 并执行可选健康检查

## 目录结构

```text
remote-compose-deploy/
├─ assets/
│  └─ deploy-config.template.json
├─ agents/
│  └─ openai.yaml
├─ references/
│  └─ session-example.md
├─ scripts/
│  ├─ build-upload-and-deploy-compose-service.ps1
│  └─ deploy.ps1
├─ LICENSE
├─ README.md
└─ SKILL.md
```

## 运行要求

- Windows PowerShell
- PowerShell 模块：`Posh-SSH`
- 可访问目标服务器的 SSH 凭据

如果本机尚未安装 `Posh-SSH`，脚本会尝试自动安装；也可以手动执行：

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser
```

## 快速开始

### 1. 初始化配置

```powershell
.\scripts\deploy.ps1 -Module ai-system -Env dev -Init
```

这会生成默认配置文件：

```text
deploy-configs/ai-system-dev.json
```

也可以直接指定配置路径：

```powershell
.\scripts\deploy.ps1 -ConfigPath .\deploy-configs\ai-system-dev.json -Init
```

### 2. 编辑配置

模板文件位于：

[`assets/deploy-config.template.json`](/D:/Binary/skills/remote-compose-deploy/assets/deploy-config.template.json)

核心字段包括：

- `deployment.mode`：`artifact` 或 `repo-sync`
- `build.*`：本地构建工作目录、命令、超时和日志心跳
- `artifact.*`：本地产物路径、远端上传路径、是否复用已有产物
- `remote.*`：远端主机、端口、用户名和认证信息
- `repoSync.*`：远端仓库目录和拉取命令
- `compose.*`：远端 compose 工作目录、动作、作用范围和服务名
- `healthCheck.*`：部署后健康检查

### 3. 执行部署

按模块和环境执行：

```powershell
.\scripts\deploy.ps1 -Module ai-system -Env dev
```

按配置路径执行：

```powershell
.\scripts\deploy.ps1 -ConfigPath .\deploy-configs\ai-system-dev.json
```

## 常用命令

列出当前可用配置：

```powershell
.\scripts\deploy.ps1 -ListConfigs
```

跳过本地构建：

```powershell
.\scripts\deploy.ps1 -Module ai-system -Env dev -SkipBuild
```

优先复用已有产物：

```powershell
.\scripts\deploy.ps1 -Module ai-system -Env dev -ReuseArtifact
```

## 配置说明

### artifact 模式

适用于本地构建后，将产物上传到远端，再执行 Compose 重启或重建。

必填重点：

- `build`
- `artifact.localPath`
- `artifact.remotePath`
- `compose.workdir`
- `compose.action`

### repo-sync 模式

适用于远端仓库直接拉取代码，然后执行 Compose 重启或重建。

必填重点：

- `repoSync.workdir`
- `compose.workdir`
- `compose.action`

可选：

- `repoSync.pullCommand`，例如 `git pull --ff-only`

## Compose 行为

- `compose.action` 仅支持 `restart` 或 `rebuild`
- `compose.targetScope` 仅支持 `project` 或 `services`
- 当 `targetScope = services` 时，`compose.services` 必须填写精确服务名
- 当 `targetScope = project` 时，`compose.services` 应保持为空

## 约定

- 默认配置目录为项目根目录下的 `deploy-configs/`
- 默认命名规则为 `deploy-configs/<module>-<env>.json`
- 优先使用 SSH key 认证，密码仅作为回退方案
- 配置缺失关键字段时不应猜测，需先补齐再执行

## 参考

- Skill 定义：[`SKILL.md`](/D:/Binary/skills/remote-compose-deploy/SKILL.md)
- 会话示例：[`references/session-example.md`](/D:/Binary/skills/remote-compose-deploy/references/session-example.md)
- 入口脚本：[`scripts/deploy.ps1`](/D:/Binary/skills/remote-compose-deploy/scripts/deploy.ps1)

## License

本项目基于 MIT License 发布，见 [`LICENSE`](/D:/Binary/skills/remote-compose-deploy/LICENSE)。

## 友链

- [linux.do](https://linux.do)
