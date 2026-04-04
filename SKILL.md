---
name: remote-compose-deploy
description: 用于远程 Compose 部署的技能。适用于已有或需要初始化 `deploy-configs/{module}-{env}.json` 配置的场景。收到明确部署指令，且用户已明确给出 `module + env` 或 `ConfigPath`、同时配置完整时，直接执行 skill 内置统一入口脚本；仅在模块、环境、动作或必填配置缺失时才询问。支持本地构建产物上传、远端 repo-sync、Docker Compose 或 Podman Compose 重启/重建，以及长时间构建时的日志心跳、超时控制和复用已有 artifact。
---

# 远程 Compose 部署

这个 skill 用于初始化部署配置，并执行可重复的远程部署脚本。

## 环境与平台限制

- **支持平台**：适用于 Windows PowerShell 环境。
- **必要依赖**：依赖 `Posh-SSH` 模块进行远程连接和文件传输。如果未安装，需在 PowerShell 中通过 `Install-Module -Name Posh-SSH` 进行安装。

## 决策顺序

1. 先判断用户意图，再决定是否执行脚本。
2. 若用户明确要求“部署 / 启动 / 重启 / rebuild / restart / 执行部署”，这是执行意图：
   - 只有在用户已明确给出 `module + env`，或显式给出 `ConfigPath`，且配置已完整可用时，才直接执行，不做重复确认。
   - 若缺少模块或环境中的任一项，即使当前只有一个候选配置，也先进入检查 / 询问流程，不要直接执行部署。
3. 若用户明确要求“初始化部署配置 / 新建部署配置”，这是初始化意图：
   - 直接使用 `-Init` 生成配置模板，再补齐缺失字段。
4. 若用户没有直接要求执行，只是提到模块、环境、配置或部署方式，这是检查意图：
   - 先检查已有配置或列出候选配置。
   - 这也包括“只给了模块但没给环境”“只说部署一下但没明确目标”“只提到配置名或部署方式但没有明确要求执行”。
   - 若检查不通过，再询问，不要直接执行部署。
5. 默认使用统一入口：
   - `./scripts/deploy.ps1`（相对于当前 skill 根目录）
6. 不要根据多个历史脚本名去猜“应该运行哪个脚本”。
7. 脚本层只认统一入口 `./scripts/deploy.ps1`，差异全部体现在 `deploy-configs/*.json`。
8. 任何时候，优先匹配配置文件，而不是猜测模块别名、服务别名或脚本别名。
9. 本文档中的 `./scripts/...`、`./assets/...`、`./references/...` 都表示“相对于当前 skill 根目录”的路径，不依赖 skill 被放在 `skills/` 目录下。
10. 若脚本需要读取目标仓库根目录下的 `deploy-configs/`，则应从目标仓库根目录执行，或显式传入 `-ProjectRoot <repo-root>`；不要把 `./scripts/...` 误解为目标仓库根目录下的公共脚本。

## 配置解析规则

1. 如果用户显式给出 `ConfigPath`，优先使用该路径。
2. 若用户同时给出模块和环境：
   - 直接查找 `deploy-configs/<module>-<env>.json`
   - 若用户意图是执行，且配置存在，则直接执行
   - 若配置不存在，提示用户改为初始化或补充正确配置，不要自动猜测
3. 若用户只给出模块：
   - 先查找 `deploy-configs/<module>-*.json`
   - 若只有一个匹配配置，将其作为唯一候选配置用于检查或展示
   - 若当前是执行意图，也仍要先询问用户是否就是该环境，不要直接部署
   - 若有多个匹配配置，只列出候选环境并询问用户选哪个环境
   - 若没有匹配配置，提示用户补充环境，必要时使用 `-Init`
4. 若用户没有给出模块：
   - 先看 `deploy-configs/*.json`
   - 若只有一个配置，可将其作为唯一候选配置用于检查或展示
   - 若当前是执行意图，也仍要先让用户明确模块和环境，或显式确认该配置路径，不要直接部署
   - 其他情况列出候选配置，让用户选择或补充模块和环境
5. 如果配置里已经有 `compose.action`、`deployment.mode`、`compose.targetScope` 和目标服务，不要重复询问。
6. 优先使用 SSH key 认证。只有在 key 不可用时才回退到密码环境变量。
7. 不主动要求用户再次确认“是否执行”，除非当前输入含糊不清，或者将要修改已有配置。

## 配置约定

1. 默认配置目录是项目根目录下的 `deploy-configs/`。
2. 默认命名规则：
   - `deploy-configs/<module>-<env>.json`
3. 示例：
   - `deploy-configs/ai-system-dev.json`
   - `deploy-configs/ai-write-prod.json`
4. 当用户说“部署 ai-system 到 dev”时，默认对应：
   - `./scripts/deploy.ps1 -Module ai-system -Env dev`
5. 如果同一个模块存在多个配置变体，仍优先遵循 `<module>-<env>.json`；只有无法唯一定位时才询问。

## 初始化规则

1. 如果用户明确要“初始化部署配置”，使用：
   - `./scripts/deploy.ps1 -Module <module> -Env <env> -Init`
2. 初始化时才询问这些信息：
   - 部署模式：`artifact` 或 `repo-sync`
   - Compose 范围：整个项目还是指定服务
   - 构建命令与工作目录
   - artifact 本地路径与远端路径
   - repo-sync 的远端仓库目录与拉取命令
   - 远端主机、用户名、认证方式
   - Compose 工作目录
   - 健康检查方式
3. 若 `compose.targetScope` 是 `services`，保存精确服务名。
4. 若 `compose.targetScope` 是 `project`，保持 `compose.services` 为空。

## 初始化命令的用途

1. 初始化命令只负责生成配置模板，不负责执行部署。
2. 初始化入口存在的目的，是把“创建配置”和“执行部署”拆成两个明确动作：
   - `-Init` 负责从模板生成 `deploy-configs/*.json`
   - 普通执行负责读取现有配置并部署
3. 这样可以避免 agent 在缺配置时一边猜字段一边直接部署。
4. 当用户只是要新建配置，或当前配置不存在时，优先走初始化入口，而不是手写 JSON 或直接部署。

## 执行入口

优先使用以下入口，而不是让模型自行拼接底层脚本：

- 运行已有配置：
  - `./scripts/deploy.ps1 -Module <module> -Env <env>`
- 运行指定配置：
  - `./scripts/deploy.ps1 -ConfigPath <path>`
- 初始化默认命名配置：
  - `./scripts/deploy.ps1 -Module <module> -Env <env> -Init`
- 初始化指定路径配置：
  - `./scripts/deploy.ps1 -ConfigPath <path> -Init`
- 列出当前可用配置：
  - `./scripts/deploy.ps1 -ListConfigs`
- 跳过构建直接部署：
  - `./scripts/deploy.ps1 -Module <module> -Env <env> -SkipBuild`
- 优先复用已有产物：
  - `./scripts/deploy.ps1 -Module <module> -Env <env> -ReuseArtifact`

底层执行脚本：
- `./scripts/build-upload-and-deploy-compose-service.ps1`

## 构建阶段规则

1. 构建命令仍通过英文脚本执行，避免编码和命令兼容问题。
2. 长时间构建时，脚本应输出心跳和最近日志，而不是静默等待。
3. 使用配置项控制构建监控：
   - `build.timeoutSec`
   - `build.idleTimeoutSec`
   - `build.heartbeatSec`
   - `build.logTailLines`
4. `artifact.reuseLatestArtifact` 为 `true` 时，如果本地 artifact 已存在，可直接复用并跳过构建。
5. `-SkipBuild` 的优先级高于普通构建逻辑。

## 配置规则

1. `deployment.mode` 必须是 `artifact` 或 `repo-sync`。
2. `artifact` 模式必须提供：
   - `build`
   - `artifact.localPath`
   - `artifact.remotePath`
3. `repo-sync` 模式必须提供：
   - `repoSync.workdir`
   - 可选 `repoSync.pullCommand`
4. `compose.action` 必须是 `restart` 或 `rebuild`。
5. `compose.targetScope` 必须是 `project` 或 `services`。
6. 若 `compose.targetScope` 为 `services`，`compose.services` 必须包含远端 compose 文件中的精确服务名。
7. 若 `compose.targetScope` 为 `project`，保持 `compose.services` 为空。
8. `artifact.localPath` 可以是绝对路径，也可以是相对于 `build.workdir` 的路径。
9. `artifact.remotePath` 必须是远端完整文件路径。
10. Compose 命令自动按以下顺序探测：
    - `docker compose`
    - `podman compose`
    - `docker-compose`
    - `podman-compose`
11. **路径配置原则**：如果要对外发布，模板里最好的导向是——本地工作区相关的路径一律默认相对路径，服务器和系统级别的路径使用绝对路径示例。

## 校验要求

1. `artifact` 模式下，构建完成后必须确认本地 artifact 存在。
2. `repo-sync` 模式下，必须先确认远端 `git pull` 成功，再执行 compose 操作。
3. 若目标是指定服务，必须先校验服务名是否存在于远端 `compose config --services`。
4. 执行后必须输出 `compose ps` 结果。
5. 若配置缺失关键字段，不要猜测；应提示补齐后再执行。
6. 若启用了健康检查，健康检查失败则视为部署失败。

## 结果汇报

结果中至少包含：

- 部署模式
- 是否执行了本地 build 或远端 repo-sync
- 上传的 artifact 路径或 repo-sync 目录与命令
- 探测到的 compose 命令
- 实际执行的 compose action
- 目标范围和服务名
- `compose ps` 输出
- 健康检查结果
- 需要后续处理的告警

## 参考

- 需要仓库内的具体会话示例时，读取 `references/session-example.md`
