# ash_analyzer

> Oracle ASH 历史性能 / 阻塞分析工具（单文件零依赖）
> 支持 RAC 与单实例 · 11.2.0.4 ~ 19c+ · `gv$ / v$ / dba_hist` / 导入表 · 当前版本 **v1.5**

## 目标

事后复盘数据库历史性能问题与阻塞问题——不需要问题发生时在场，凭 ASH 持久化数据还原：

1. 问题发生的**精确时间窗口**（活动会话突增）
2. **症状分类**（CPU / IO / 锁 / 集群等待）
3. **根阻塞者**（等待树的终极持有者 root blocker + 它自己在等什么 root_evt）
4. **完整阻塞链**（受害者 → … → 终点，跨实例可追）
5. **单会话停滞判定**（seq# 是否推进：不变 = hang，递进 = 在走只是慢）
6. 补充维度：热点对象、PGA/临时段、SQL 文本、长执行识别

**跨环境分析**：其他环境导出的 ASH 数据（CTAS/expdp/impdp 到本机）可直接分析——表/视图名手动指定、列布局自动识别、DBID 差异自动提示、对象名 / SQL 文本 / 用户名经映射表（`-objmap / -sqlmap / -usermap`）解析。

方法论来源：MOS 经典 ASH 六步分析法 + 实战脚本集（root blocker connect-by 等待树、sql_exec_id 长执行、阻塞链逐层穿透）。

## 部署

单文件（`ash_analyzer`），仅依赖 bash + sqlplus + awk/sed（无其他依赖），scp 到任意 Oracle 主机 `chmod +x` 即可运行（已在 Oracle / 非 Oracle 主机双重验证）。

```bash
./ash_analyzer help            # 简要帮助：命令列表 + 速查
./ash_analyzer <cmd> -h        # 每条命令的详细帮助（用法/选项/示例）
./ash_analyzer info            # 数据源体检
```

- 连接默认本地 `/ as sysdba`；ORACLE_SID 自动探测（pmon 进程，跳过 +ASM/-MGMTDB），ORACLE_HOME 从 oratab 解析，oratab 未登记实例用 bequeath 试连兜底
- 多实例主机建议 `-s <SID>` 显式指定；19c CDB 可用 `-pdb <容器>` 切换；远程连接 `-c 'user/pwd@tns'`
- 可选配置文件 `ash_analyzer.conf`（样例参数见脚本帮助）

## 数据源与自动识别

| `-i` 参数 | 数据源 | 布局 | 采样间隔 |
|---|---|---|---|
| `hist`（默认） | dba_hist_active_sess_history | hist | 10s |
| `gv` | gv$active_session_history | gv | 1s |
| `v` | v$active_session_history | single | 1s |
| `owner.table` 等 | CTAS/impdp 导入表/视图 | 自动识别（按列存在性） | 自动推断 |

列缺失自动降级：11.2/12.1/19c 列集差异不报错——缺 BLOCKING_INST_ID 时阻塞链退化为仅同实例匹配（有提示）；缺 PGA/TEMP 列 res 干净退出；缺 SQL_EXEC_ID 跳过长执行识别。

## 命令一览（12 条）

| 命令 | 作用 | 关键输出 |
|---|---|---|
| `info` | 数据源体检 | 行数/时间范围/实例分布/密度 Top24/采样断档/跨环境提示 |
| `trend` | 活动会话趋势 | 每分钟直方图 + 峰值样本点 |
| `events` | 顶级等待事件 | 事件排行（含 ON CPU）+ 事件×SQL 交叉 |
| `sql` | SQL 排行 | 样本数排行 + sql_exec_id 长执行识别 |
| `sessions` | 会话排行 | 用户/程序/机器解析（支持 -usermap） |
| `blockers` | 阻塞分析 | 直接阻塞者表 + **根阻塞者等待树** |
| `chain` | 等待链树 | path 形式完整链；`-S` 追踪单会话向上链 |
| `detail -S` | 单会话时间线 | 逐样本明细 + seq# 停滞分析 |
| `obj` | 热点对象 | current_obj# × 事件交叉（支持 -objmap） |
| `res` | PGA/临时段 | 按 SQL 峰值消耗 |
| `text -q` | SQL 文本 | -sqlmap 表 → dba_hist_sqltext → v$sqlarea 兜底 |
| `all` | 一键复盘 | 上述核心报告合并输出 |

常用选项：`-t/-T 'YYYY-MM-DD HH24:MI:SS'` 时间窗、`-m N` 最近 N 分钟、`-g N` 实例过滤、`-n N` 行数、`-p N` 并行（connect-by 提速）、`-f FILE` 落盘、`-w N` 跨实例容差秒、`-x N` 长执行阈值、`-D DBID / -C CON_ID` 多库/CDB 过滤。

## v1.5 新增：expdp 导出与自诊断脚本生成

- `export`：在生产库生成**自包含采集脚本**（bash/sh 兼容，quoted heredoc + 占位符回填），自动完成 idempotent drop-then-CTAS三件套 + 映射表 + spool 清单 + expdp（自动生成 parfile，REUSE_DUMPFILES=y）；`-d <Oracle 目录>` 指定 expdp 目录（默认 DATA_PUMP_DIR，预校验），`-u <用户>` 指定 CTAS 临时表 owner（默认 system，预校验，非 system 需 CREATE TABLE + 目录读写配额）
- `diag`：生成**客户侧自诊断脚本**（现场无需部署 ash_analyzer），窗口可通过 `ash_diag_run.conf` 重插，输出 `diag_report_<tag>.txt`

## 核心设计：跨实例阻塞链

向上遍历 `connect by prior blocking_session = session_id`（+ serial# 匹配防 SID 重用 + DBID 匹配防多库串库），`connect_by_isleaf=1` 即根阻塞者，`root_evt` 是它自己在等的事件（真病灶）。

- **同实例边**：`prior sample_id = sample_id` 精确匹配
- **跨实例边**：RAC 两实例采样网格存在相位差（sample_id 各自独立、sample_time 毫秒级错开），用时间容差连接——实测校准（96 环境真实事故窗口）：±2s 跨实例命中 0%，±5s 命中 99.4%（154/155），故默认 hist=5s / gv=2s，`-w` 可调

真实事故复盘（归档断档风暴）还原出的完整因果链：

```
oracle_exporter ──library cache lock──▶ python run.py ──buffer busy waits──▶ dbmotion
dbmotion ──log file switch (archiving needed)──▶ LGWR ──enq: CF - contention──▶ ARC1
ARC1 ──control file sequential read──▶ (存储 I/O 慢)
```

## 判读要点

- `est_sec = 样本数 × 采样间隔`，近似 DB time 秒
- 等待者表面事件常只是传导症状，`root_evt` 才是真病灶
- `iscycle=1` = 等待环（死锁类），重点排查
- `STATUS=VALID` 但持有者不在样本中 = 持有者空闲未被采样（正常现象）
- `-g` 过滤实例会切断跨实例等待链，RAC 全局分析慎用

## 版本历史

- **v1.5**（2026-10-08）：`export` 自包含采集脚本生成（-d 目录 / -u owner 预校验）、`diag` 客户侧自诊断脚本、两级帮助（`help` 速查 + `<cmd> -h` 详单）
- **v1.3**（2026-09-30）：`text` 入命令列表；chain path 加宽消除折行；`-p N` 同时开 alter session force parallel query；connect-by 边排除 blocking_session_status='INVALID'
- **v1.2**（2026-09-22）：oratab 未登记实例 bequeath 试连兜底、多实例自动选库提示、`-pdb` 容器切换、字典表自适应降级；真 19c + 异环境导入全流程验证
- **v1.1**（2026-09-22）：跨环境导入分析（-objmap/-sqlmap/-usermap、DBID 差异提示、-i 支持视图、conf 配置文件）
- **v1.0**（2026-09-22）：首个版本，12 命令、布局自动识别、列降级、跨实例容差链

## 文档

- [`ash_analyzer_使用手册.md`](./ash_analyzer_使用手册.md) / [HTML 版](./ash_analyzer_使用手册.html)
- 已验证矩阵、判读要点、已知限制详见手册

## License

MIT
