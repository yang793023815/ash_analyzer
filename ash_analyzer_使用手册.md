# ash_analyzer 使用手册

> Oracle ASH 历史性能 / 阻塞分析工具 v1.2
> 支持 RAC 与单实例 · 11.2.0.4 ~ 19c+ · gv$/v$/dba_hist/导入表/导入视图 · 单文件零依赖
>
> 部署位置：`/home/oracle/ash_analyzer/ash_analyzer`（qone1），qone2 `~/ash_analyzer/`，10.10.180.201 `~/ash_analyzer/`（真 19c）
> 本地副本：`~/Desktop/学习/autoclaw/tools/ash_analyzer/ash_analyzer`
> md5: `2da8c8caa719d3ba67c1e6d287e064d9`（三端一致）

---

## 1. 设计目标

事后复盘数据库历史性能问题与阻塞问题：不需要问题发生时在场，凭 ASH 持久化数据还原——

1. 问题发生的**精确时间窗口**（活动会话突增）
2. **症状分类**（CPU / IO / 锁 / 集群等待）
3. **根阻塞者**（等待树的终极持有者 + 它自己在等什么）
4. **完整阻塞链**（受害者 → … → 终点，跨实例可追）
5. **单会话停滞判定**（seq# 是否推进）
6. 补充维度：热点对象、PGA/临时段、SQL 文本、长执行识别

**跨环境分析**：其他环境导出的 ASH 数据（CTAS/impdp 到本机）可直接分析——表/视图名手动指定、布局自动识别、DBID 差异自动提示、对象名/SQL文本/用户名经映射表解析。

方法论来源：MOS 经典 ASH 六步分析法 + 实战脚本集（root blocker connect by 树、sql_exec_id 长执行、阻塞链逐层穿透）。

## 2. 部署与运行

```bash
# 单文件, 任意装有 bash + sqlplus 的 Oracle 服务器
chmod +x ash_analyzer
./ash_analyzer help          # 帮助
./ash_analyzer info          # 体检数据源
```

- **连接**：默认本地 `/ as sysdba`；ORACLE_SID 自动探测（pmon 进程，跳过 +ASM/-MGMTDB），ORACLE_HOME 从 /etc/oratab 解析；**oratab 未登记的实例用 bequeath 试连兑底**（逐候选 home 试连，能查通者即实例 home；oracle 进程 dumpable=0 无法用 /proc 反推，已实测）
- **多实例主机**：多个实例时自动选库并提示（如 201 上 6 实例），建议 `-s panjf1` 显式指定；19c CDB 可用 `-pdb <容器>` 切换
- **远程连接**：`-c 'user/pwd@tns'`
- **配置文件（可选）**：脚本同目录放 `ash_analyzer.conf` 预置默认值（`VIEW_IN`/`CONN`/`TOPN`/`MINS` 等），CLI 参数优先；样例见 `ash_analyzer.conf.example`
- 拷到其他服务器即可运行，无其他依赖（qone2/201 均已部署验证）

## 3. 数据源与自动识别

| -i 参数 | 实际数据源 | 布局 | 采样间隔 |
|---|---|---|---|
| `hist`（默认） | dba_hist_active_sess_history | hist | 10s |
| `gv` | gv$active_session_history | gv | 1s |
| `v` | v$active_session_history | single | 1s |
| `system.t_ash` 等任意表/**视图** | CTAS/impdp 导入 | 自动识别 | 自动推断 |

**布局识别规则**（按列存在性）：

| 列特征 | 判定布局 |
|---|---|
| 有 INST_ID | gv（1s） |
| 有 SNAP_ID + INSTANCE_NUMBER | hist（10s） |
| 有 INSTANCE_NUMBER（无 SNAP_ID/DBID） | hist（10s）+ 提示 |
| 都没有 | single |

**列缺失自动降级**：19c/11.2 列集差异不报错——缺 BLOCKING_INST_ID 时阻塞链退化为仅同实例匹配（有提示）；缺 PGA/TEMP 列时 res 命令干净退出；缺 SQL_EXEC_ID 时跳过长执行识别。已用 12.1 真机模拟 19c 超集列（USECS_PER_ROW / IN_TABLESPACE_ENCRYPTION 等）验证。

## 4. 跨环境导入分析（v1.1 核心）

场景：生产库出问题 → 把 ASH 数据导出到测试机分析（不影响生产）。

```bash
# ① 源库导出三件套 (+ users 可选)
create table t_ash  as select * from dba_hist_active_sess_history where ...;
create table t_obj  as select object_id, owner, object_name, object_type from dba_objects;
create table t_sqltext as select * from dba_hist_sqltext where ...;
-- expdp/impdp 到测试机 (注意: 19c dump 不能导入 12.1, 版本头校验 ORA-39142)

# ② 测试机上分析 (-i 指定 ASH 表, 布局自动识别)
./ash_analyzer info     -i system.t_ash        # DBID 与本地不一致会自动提示
./ash_analyzer blockers -i system.t_ash -t '...' -T '...'
./ash_analyzer chain    -i system.t_ash -t '...' -T '...'

# ③ 配套映射表解析源库对象名 / SQL 文本 / 用户名
./ash_analyzer obj      -i system.t_ash -objmap  system.t_obj     -t ... -T ...
./ash_analyzer text -q 5vjr1z7vagt30     -sqlmap system.t_sqltext
./ash_analyzer sessions -i system.t_ash -usermap system.t_users
```

- **映射表列要求**：objmap = `OBJECT_ID/OWNER/OBJECT_NAME`（OBJECT_TYPE 可选）；sqlmap = `SQL_ID` + `SQL_TEXT` 或 `SQL_FULLTEXT`；usermap = `USER_ID/USERNAME`。缺列会明确报错
- **DBID 自动识别**：`info` 检测到数据 DBID 与本地库不一致时输出"跨环境提示"；`obj`/`text`/`sessions` 在未配映射表时也会警告解析不可信
- **多库合并导入**：`-D <dbid>` 锁定单一 DBID
- 异环境数据的 `current_obj#`/`user_id`/SQL 文本均属源库——**必须配映射表**，本地字典解析结果不可信

## 5. 命令一览

| 命令 | 作用 | 关键输出 |
|---|---|---|
| `info` | 数据源体检 | 行数/时间范围/各实例分布/密度Top24/采样断档/跨环境提示 |
| `trend` | 活动会话趋势 | 每分钟直方图 + 峰值样本点 |
| `events` | 顶级等待事件 | 事件排行(含ON CPU) + 事件×SQL 交叉 |
| `sql` | SQL 排行 | 样本数排行 + sql_exec_id 长执行识别 |
| `sessions` | 会话排行 | 用户/程序/机器解析（支持 -usermap） |
| `blockers` | 阻塞分析 | 直接阻塞者表 + **根阻塞者等待树** |
| `chain` | 等待链树 | path 形式完整链; `-S` 追踪单会话向上链 |
| `detail -S` | 单会话时间线 | 逐样本明细 + seq# 停滞分析 |
| `obj` | 热点对象 | current_obj# × 事件 交叉（支持 -objmap） |
| `res` | PGA/临时段 | 按 SQL 峰值消耗 |
| `text -q` | SQL 文本 | -sqlmap 表 → dba_hist_sqltext → v$sqlarea 兜底 |
| `all` | 一键复盘 | 上述核心报告合并输出 |

常用选项：`-t/-T 'YYYY-MM-DD HH24:MI:SS'` 时间窗、`-m N` 最近 N 分钟、`-g N` 实例过滤、`-n N` 行数、`-f FILE` 落盘、`-p N` 并行、`-w N` 跨实例容差秒、`-x N` 长执行阈值、`-D DBID`/`-C CON_ID` 多库/CDB 过滤。

## 6. 核心方法论：六步下钻

```bash
# ① 定位窗口: 活动会话突增段
./ash_analyzer trend -t '2026-09-20 16:40:00' -T '2026-09-20 17:00:00'

# ② 症状分类: 顶级等待事件
./ash_analyzer events -t '2026-09-20 16:44:00' -T '2026-09-20 16:50:00'

# ③ 找根: Root Blocker (等待树终点, 看它自己的 ROOT_EVT)
./ash_analyzer blockers -t '2026-09-20 16:44:00' -T '2026-09-20 16:50:00'

# ④ 验证链路: 从受害者到终点的完整路径
./ash_analyzer chain -S 65 -t '2026-09-20 16:45:00' -T '2026-09-20 16:46:00'

# ⑤ 看持有者是否卡死: seq# 是否推进
./ash_analyzer detail -S 406 -t '2026-09-20 16:44:00' -T '2026-09-20 16:46:00'

# ⑥ 补充: 热点对象 / PGA / SQL 文本
./ash_analyzer obj ... / res ... / text -q 9zg9qd9bm4spu
```

## 7. 阻塞链实现原理（本工具的核心设计）

**向上遍历**：`connect by prior blocking_session = session_id`——子行是父行的持有者，从受害者一路走到链终点（`connect_by_isleaf=1`），根阻塞者 = 等待树终点。

**同实例边**：`prior sample_id = sample_id` 精确匹配（同一采样点内的等待关系）。

**跨实例边**：RAC 两实例的采样网格存在**相位差**（实测 96 环境：inst1 与 inst2 的 sample_time 毫秒级错开、sample_id 序列各自独立、跨实例持有者在 ±2s 内零命中、±5s 命中 99.4%）。因此：

```sql
( prior instance_number <> instance_number
  and abs((cast(prior sample_time as date) - cast(sample_time as date))*86400) <= 5 )  -- 默认 hist=5s, gv=2s, -w 可调
```

配套防护：`prior blocking_inst_id = instance_number`（持有者实例对位）、serial# 匹配防 SID 重用、DBID 匹配防多库导入串库。

**实测校准数据**（96 环境，2026-09-20 事故窗口）：
- 155 条跨实例阻塞行：±2s 命中 0，±5s 命中 154（99.4%）
- 10 天 hist 全表阻塞树分析 0.5s 完成

## 8. 真实案例复盘（2026-09-20 16:43-16:50 归档断档事故）

工具输出还原的完整因果链：

```
oracle_exporter(2.4) --library cache lock--> 1.19
python run.py(1.19)  --buffer busy waits----> 1.65 (dbmotion)
dbmotion(1.65)      --log file switch (archiving needed)--> 1.406 (LGWR)
LGWR(1.406)         --enq: CF - contention--> 1.317 (ARC1)
ARC1(1.317)         --control file sequential read--> (存储I/O慢)
```

- 根阻塞者 #1：`dbmotion 1.65`（root_evt=log file switch (archiving needed)，230 链/14 受害者）
- 根阻塞者 #2：`LGWR 1.406`（root_evt=control file sequential read）
- 病灶指向：归档目的地写入慢 + 控制文件 I/O，与当时 archive log 磁盘问题一致

## 9. 判读要点

- **est_sec = 样本数 × 采样间隔**（hist 10s / gv 1s），近似 DB time 秒
- **ON CPU 数接近物理 CPU 数** → 需结合 OS 侧（run queue / OSWatcher）
- **root_evt 是真正病灶**：等待者表面事件（如 library cache lock）常只是传导症状
- **seq# 不变** = 卡死在同一等待（hang）；**seq# 递进** = 在走只是慢
- **iscycle=1** = 等待环（死锁类），重点排查
- **STATUS=VALID 但持有者不在样本中** = 持有者空闲未被 ASH 采样（正常现象，对照直接阻塞者表）
- **-g 实例过滤会切断跨实例等待链**，RAC 全局分析慎用
- 未被采样的持有者不进等待树——这是 ASH 机制固有限制，不是工具 bug

## 10. 已验证矩阵

| 场景 | 状态 |
|---|---|
| **10.10.180.201 真 19c（panjf 非 CDB）+ 真实异环境导入 m_ash（112 列/4 节点源）** | ✅ 真机全流程 |
| **bequeath 试连 home 兑底（oratab 未登记实例）** | ✅ 真机（panjf1） |
| **多实例自动选库提示（6 实例主机）** | ✅ 真机（201） |
| 12.1 RAC hist（dba_hist_ash，双实例） | ✅ 真机 |
| 12.1 RAC gv$（实时，1s） | ✅ 真机 |
| 12.1 单实例 v$（lcbdg DG 备库） | ✅ 真机 |
| CTAS 全列导入表（含 96/qone2 双机验证） | ✅ 真机 |
| 列缺失降级（无 BLOCKING_INST_ID/PGA/SQL_EXEC_ID） | ✅ 真机 |
| 19c 超集列模拟（USECS_PER_ROW 等 19c 独有列） | ✅ 真机模拟 |
| **真 19c 列集（m_ash 112 列）** | ✅ 真机（201） |
| 跨实例阻塞链（±5s 容差） | ✅ 真机（99.4% 命中率校准） |
| -s 多实例主机选择（orcl1/lcbdg1/panjf1） | ✅ 真机 |
| -f 落盘 / -p 并行 / -g 过滤 / -D/-C | ✅ 真机 |
| **-objmap/-sqlmap/-usermap 映射表** | ✅ 真机（96 零DDL + qone2 全流程） |
| **DBID 差异自动提示（异环境识别）** | ✅ 真机（qone2） |
| **conf 配置文件** | ✅ 真机（conf 接管 + CLI 覆盖） |
| qone2 部署 | ✅ v1.1 已同步（md5 一致） |
| 11.2.0.4 | 语法全程兼容（无 12c+ 特性），待 11.2 环境实测 |

## 11. 已知限制

1. **未被 ASH 采样的持有者**（空闲会话）不会出现在等待树——工具在 blockers 输出中保留"直接阻塞者"表供对照
2. `-g N` 过滤实例后跨实例链断开（数据被过滤，非逻辑问题）
3. 19c CDB 的 PDB 级 ASH 需 `-C con_id` 过滤（或 PDB 内本地运行）
4. `ash.dmp`（19c 导出的 SYSTEM.M_ASH）在 12.1 无法 impdp（ORA-39142 版本头校验）——需在 19c 库导入后 `-i system.m_ash` 分析（配 -objmap/-sqlmap/-usermap 使用源库字典）
5. 库正处于锁风暴时，工具本身查询正常，但涉及 DDL 的环境准备（CTAS 导入等）会被排队挂起——先解决风暴或换时间窗导入

## 12. 版本历史

- v1.2 (2026-09-22)：环境探测兑底（oratab 未登记实例用 bequeath 试连找 home；oracle 进程 dumpable=0 无法读 /proc/exe）、多实例自动选库提示、-pdb 容器切换（19c CDB）、字典表自适应（无 dba 权限降级 all_objects/all_users）；201 真 19c + 异环境 m_ash 全流程验证（4 节点 RAC 源事故复盘：4 节点 LGWR log file parallel write → gc/log 集群等待链）
- v1.1 (2026-09-22)：跨环境导入分析——`-objmap/-sqlmap/-usermap` 映射表、DBID 差异自动提示、`-i` 支持视图、conf 配置文件
- v1.0 (2026-09-22)：首个版本。12 命令、布局自动识别、列降级、跨实例容差链、六步法全覆盖；96 双节点真机验证
