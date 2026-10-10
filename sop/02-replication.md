# 主从复制

## 一、文档定位

编制时间为 Day 9（M6 主从复制搭建、M7 从库故障演练）。适用对象为本仓库 3306 主实例与 3308 从实例。覆盖复制的建立、状态巡检、只读边界的划定、冲突事务的处理四组操作。文中命令除注明外均在本环境执行过，输出以数字形式保留。

文档状态：全部小节均已在 2026-10-10 实测。未覆盖的部分为主库故障后的从库提升，该流程只有步骤，未在本环境演练；各小节分别标注。

## 二、问题背景

以下按情境、冲突、问题、结论的顺序说明编制本规范的原因。

**情境。** 单实例在数据增长与查询压力下出现瓶颈，备份也需要在业务库上直接执行。复制能在不改应用架构的前提下分摊读压力，并把备份动作挪到从库。

**冲突。** 复制的成立依赖三项条件同时满足。主库需要记录可传输的变更日志，从库需要一套与主库不同的实例标识，两边需要有严格对齐的起始数据。三项之中任一项缺失，复制不会报错，而是表现为「双 Yes 但数据不一致」或「从库停在某个位置不动」，两种表现的排查路径完全不同。

**问题。** 在同机双实例条件下建立一套位点复制的从库，并给出在复制中断时判定故障层次、恢复复制、评估恢复代价的处理顺序。

**结论。** 复制的健康度分两层判定。线程层看双 Yes 与状态句，数据层看 `CHECKSUM`，两层不可互相替代。第二节给出搭建流程，第三、四节给出两层判定标准，第五节处理只读边界，第六节处理中断恢复。

## 三、复制关系的建立

### 3.1 前置检查

两边分别执行，四项必须先去核对。

```sql
-- 主库 3306
SHOW VARIABLES LIKE 'log_bin';              -- 期望 ON
SHOW VARIABLES LIKE 'binlog_format';        -- 期望 ROW
SHOW VARIABLES LIKE 'server_id';            -- 期望非 0
SHOW VARIABLES LIKE 'log_bin_basename';     -- 记下前缀，本环境为 /var/lib/mysql/binlog

-- 从库 3308
SHOW VARIABLES LIKE 'server_id';            -- 必须与主库不同，本环境为 2
```

实测本环境主库 `server_id` 为 1、从库为 2。两侧取值相同的后果是复制事件在主从之间反复回传，表现为复制关系无法进入稳定状态。

### 3.2 从库实例的配置项

配置文件为 `/etc/mysql/mysql2.cnf`。

```ini
[mysqld]
port=3308
datadir=/var/lib/mysql2
server-id=2
relay_log=/var/lib/mysql2/relay-bin
read_only=ON
socket=/var/lib/mysql2/mysqld2.sock
mysqlx=OFF
```

各行作用如下。

| 配置项 | 作用 | 缺失后果 |
|---|---|---|
| `port` | 端口与主库错开 | 两实例抢同一端口，后启动者失败 |
| `datadir` | 独立数据目录 | 与主库共用数据目录会损坏数据 |
| `server-id` | 全局唯一标识 | 两侧相同导致事件往复 |
| `relay_log` | 中继日志路径 | 使用默认路径，与主库日志混淆 |
| `read_only` | 从库只读 | 见第五节 |
| `socket` | 独立本地套接字 | 本机连接会落到主库实例，误操作风险 |
| `mysqlx` | 关闭 X Plugin | 与主库 33060 端口冲突，启动日志出现端口占用报错 |

`socket` 一项在本环境的实测意义：不加该行时，`mysql -u root` 不带主机参数会通过默认套接字连到 3306 主实例。在从库上执行治理动作时若未察觉，动作会落到主库。

### 3.3 初始化与启动

```bash
# 初始化数据目录，生成空密码 root
sudo mysqld --initialize-insecure --datadir=/var/lib/mysql2 --user=mysql

# 前台启动，便于观察启动日志
sudo mysqld --defaults-file=/etc/mysql/mysql2.cnf --user=mysql &
```

前台启动的副作用是实例日志与客户端输出共用同一终端。此后在同一终端执行 SQL，两类内容混排。区分依据是行首特征：客户端返回带 `Query OK` 或结果集边框，实例日志带 ISO 时间戳与 `[ERROR] [MY-NNNNNN] [Repl]` 一类标记。

### 3.4 复制账号

在主库执行。

```sql
CREATE USER 'repl'@'127.0.0.1' IDENTIFIED BY 'Repl123!';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'127.0.0.1';
FLUSH PRIVILEGES;
```

权限只给 `REPLICATION SLAVE`。复制账号的职责是读取主库 binlog，不涉及业务表的读写。来源主机限定为从库地址，不用通配符。

### 3.5 起始位点的确定

起始位点来自全量备份文件，不来自 `SHOW MASTER STATUS`。

```bash
mysqldump -u root -p --single-transaction --source-data=2 --databases sakila > full.sql

grep -n -i "change" full.sql
# -- CHANGE MASTER TO MASTER_LOG_FILE='binlog.000009', MASTER_LOG_POS=827;
```

`mysqldump` 在本环境输出版本为 10.13 Distrib 8.0.46，位点注释仍写作 `CHANGE MASTER TO`，与服务端 8.0.26 起的 `CHANGE REPLICATION SOURCE TO` 不一致。检索时用 `MASTER_LOG` 或 `change` 一类跨版本关键字。

`SHOW MASTER STATUS` 给出的是查询时刻的写入位置，晚于备份时刻，用作起点会导致起点之后的部分数据被重复执行，报 1062 主键冲突。

### 3.6 建立复制关系

在从库执行。

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='127.0.0.1',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='Repl123!',
  SOURCE_LOG_FILE='binlog.000009',
  SOURCE_LOG_POS=827;

START REPLICA;
```

位点复制与 GTID 复制的取舍如下。

| 维度 | 位点复制 | GTID 复制 |
|---|---|---|
| 起点来源 | 手工填写文件名与字节位置 | `SOURCE_AUTO_POSITION=1` |
| 出错时的日志 | 事务显示为 `ANONYMOUS`，只给 `end_log_pos` | 显示具体 GTID 编号 |
| 主从切换 | 需人工推算位点 | 自动定位断点 |
| 本环境取值 | `Auto_Position: 0` | 未启用 |

本环境选择位点复制的理由是它与 M5 的位点知识同源，先把手动定位做透。生产环境因切换风险更低而优先选 GTID。

## 四、状态巡检

### 4.1 线程层判定

```sql
SHOW REPLICA STATUS\G
```

六个字段构成线程层的完整判定。

| 字段 | 健康值 | 含义 |
|---|---|---|
| `Replica_IO_Running` | `Yes` | IO 线程正在接收主库 binlog |
| `Replica_SQL_Running` | `Yes` | SQL 线程正在回放 |
| `Replica_SQL_Running_State` | `Replica has read all relay log; waiting for more updates` | 已追平，空转等待新事件 |
| `Read_Source_Log_Pos` | 持续向主库最新位置靠拢 | IO 线程读到主库 binlog 的字节位置 |
| `Exec_Source_Log_Pos` | 等于 `Read_Source_Log_Pos` | SQL 线程执行到的字节位置 |
| `Seconds_Behind_Source` | `0` | 估算延迟，不单独作为依据 |

双 `Yes` 只是及格线。两个位点相等说明读到的都已执行完，没有积压。加上状态句显示已追平，线程层才算健康。

本环境实测的位点推进过程：

| 时点 | `Read_Source_Log_Pos` | `Exec_Source_Log_Pos` |
|---|---|---|
| `START REPLICA` 后 | 827 | 827 |
| 主库插入一条记录后 | 1465 | 1465 |

两次差值 638 字节，即那条 `INSERT` 事件在 binlog 中的体积。两个位点始终相等，说明 SQL 线程没有积压。

### 4.2 数据层判定

线程层通过不代表数据一致。数据层单独校验。

```sql
-- 两侧各执行一次，比对数值
CHECKSUM TABLE sakila.payment;
```

本环境实测两侧均为 `1103857893`。

`CHECKSUM TABLE` 计算的是表内所有行的字节校验和，行数相同而内容不同时数值必然不同。仅比对行数无法发现内容差异。

生产环境的更严格手段是 Percona Toolkit 的 `pt-table-checksum`，按块比对并输出差异表，适合大表而不产生全表锁。

### 4.3 两层的独立性

第六节的演练提供了一个直接证据：从库的 `sakila.payment` 两侧校验一致，`sakila.repl_test` 两侧校验不一致，而同一时刻从库的 `Replica_IO_Running` 与 `Replica_SQL_Running` 均为 `Yes`。

结论是线程层的双 `Yes` 与数据层的校验一致没有推导关系。巡检需要两层都做。

## 五、只读边界的划定

### 5.1 两个变量的分工

| 变量 | 拦住的账号范围 |
|---|---|
| `read_only=ON` | 无 SUPER 权限的账号 |
| `super_read_only=ON` | 含 root 在内的全部账号 |

`super_read_only` 置为 ON 时会连带把 `read_only` 也置为 ON，反向不成立。

### 5.2 实测的三步对照

| 账号 | 只读设置 | 结果 |
|---|---|---|
| 普通账号 `app_user`，库级权限 | `read_only=ON` | 报 `ERROR 1290`，被拦 |
| root，含 SUPER | `read_only=ON` | 写入成功，绕过限制 |
| root，含 SUPER | `super_read_only=ON` | 报 `ERROR 1290`，被拦 |

三步构成完整证据链。前两步的对照说明 `read_only` 的适用范围，第三步说明补齐手段。面试回答「如何防止在从库误写」时，只答 `read_only` 覆盖的是第一步与第二步之间的差异，属于半个答案。

### 5.3 复制线程不受只读约束

SQL 线程回放主库事务时会临时绕过只读限制。这是复制能把数据写进只读从库的原因，也是只读设置不会阻断复制的原因。只读约束的作用对象是交互式写入，不是复制线程。

### 5.4 操作顺序

需要写入的动作必须排在打开 `super_read_only` 之前。

```sql
SET GLOBAL super_read_only = OFF;
-- 执行所需的写入
SET GLOBAL super_read_only = ON;
```

顺序颠倒时，写入动作会被自己刚设立的约束拦住，报 1290。本环境在演练中实际遇到过一次，现象是清理测试数据失败。

## 六、复制中断的处理

### 6.1 判定故障层次

复制中断先区分断在哪一层，两层的处理方式不同。

| 表现 | 判定 | 处理方向 |
|---|---|---|
| `Replica_IO_Running: No` | IO 层断 | 查网络、账号、位点是否已被清理 |
| `Replica_SQL_Running: No` | SQL 层断 | 看 `Last_SQL_Error`，处理数据冲突 |
| 双 Yes 但数据不一致 | 线程正常，数据分叉 | 用 `CHECKSUM` 定位差异表，评估修复方式 |

IO 线程负责拉取中继日志，SQL 线程负责回放。数据冲突只会让 SQL 线程停，IO 线程多数情况下保持 `Yes`。

### 6.2 数据冲突的处理

典型报错如下。

```
Replica_SQL_Running: No
Last_SQL_Errno: 1062
Last_SQL_Error: Could not execute Write_rows event on table sakila.repl_test;
                Duplicate entry '99' for key 'repl_test.PRIMARY'
```

实例错误日志中的对应行如下。

```
[ERROR] [MY-010584] [Repl] Replica SQL for channel '': Worker 1 failed executing
transaction 'ANONYMOUS' at source log binlog.000009, end_log_pos 2482;
Error_code: MY-001062; handler error HA_ERR_FOUND_DUPP_KEY
```

日志中的三项信息各有用途。`Write_rows event` 而非 `INSERT` 说明当前为 ROW 格式；`ANONYMOUS` 说明当前为位点复制，无 GTID 编号；`end_log_pos 2482` 是坏事务在主库 binlog 中的位置。

处理分两条路线，选择依据是这条冲突数据在业务上能否丢弃。

**路线一，数据可丢，跳过该事务。**

```sql
STOP REPLICA SQL_THREAD;
SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;
START REPLICA SQL_THREAD;
SHOW REPLICA STATUS\G
```

本环境实测：坏事务在 `end_log_pos 2482`，跳过一条后执行位置推进到 2513，`Replica_SQL_Running` 恢复 `Yes`，`Last_SQL_Errno` 归零。

跳过之后的分叉是不可逆的。被跳过的事务不会在任何后续时点补回从库。恢复之后的数据校验如下，两侧数值不再相同。

| 表 | 主库 | 从库 |
|---|---|---|
| `sakila.payment` | 1103857893 | 1103857893 |
| `sakila.repl_test` | 1179643698 | 2913362174 |

**路线二，数据不可丢，先修数据再恢复复制。**

```sql
-- 从库，先解除只读
SET GLOBAL super_read_only = OFF;
DELETE FROM sakila.repl_test WHERE id = 99;
SET GLOBAL super_read_only = ON;

START REPLICA SQL_THREAD;
```

`SQL_SLAVE_SKIP_COUNTER` 在 8.0 已标为弃用。执行时会返回一个 warning。官方推荐的方向是先修数据再恢复，或直接重建从库，不推荐在生产上把跳过作为常规手段。想按错误码固定跳过时，用静态参数 `replica_skip_errors = 1062,1054`，该参数需要重启实例生效。

### 6.3 IO 层中断的处理

`Last_IO_Errno` 非零时按四项顺序排查。

1. 网络连通性：从从库执行 `mysql -h 主库地址 -P 3306 -u repl -p`，看能否建连
2. 账号与密码：核对 `CHANGE REPLICATION SOURCE TO` 中填写的凭据
3. 位点是否已被清理：从库要求的 binlog 文件若超出主库的保留期，已无法补齐，只能重建从库
4. 主库连接数上限：`max_connections` 占满时新建复制连接会被拒

### 6.4 复制延迟的处理

延迟排查的第一步是区分 IO 落后与 SQL 落后，二者的处理方向不同。

| 现象 | 判断 | 方向 |
|---|---|---|
| `Read_Source_Log_Pos` 落后主库最新位置 | IO 慢 | 网络、主库 binlog 生成速率 |
| `Read_Pos` 追得上，`Exec_Pos` 落后 | SQL 慢 | 从库回放能力 |
| 两者同时落后 | 综合 | 两侧一并排查 |

SQL 落后的常见原因与对策如下。

| 原因 | 表现 | 对策 |
|---|---|---|
| 大事务 | `Exec_Pos` 长时间不动 | 主库侧把大事务拆小 |
| 从库硬件规格低于主库 | SQL 线程持续落后 | 从库规格对齐主库 |
| 从库上有长查询占资源 | 回放线程抢不到资源 | 报表类查询限流或迁到独立实例 |
| 单线程回放瓶颈 | 主库多核写入，从库单线程跟不上 | 开启并行复制，设 `replica_parallel_workers` |
| 锁等待 | SQL 线程阻塞在锁上 | 定位从库上的长事务 |

### 6.5 从库的提升

该流程未在本环境演练，以下为步骤。

1. 确认主库不可恢复
2. 在各从库上执行 `STOP REPLICA`，记录各自的 `Relay_Source_Log_File` 与 `Exec_Source_Log_Pos`
3. 取位点最靠前者作为候选新主
4. 其余从库补齐到候选新主的位点
5. 候选新主上解除只读：`SET GLOBAL super_read_only = OFF;`
6. 其余从库指向新主
7. 应用侧切换连接地址

## 七、预防措施

1. 从库同时开启 `read_only` 与 `super_read_only`
2. 复制账号只授 `REPLICATION SLAVE`，来源主机限定域名或 IP
3. 优先使用 GTID 复制，降低手工位点接错的可能
4. 定期执行 `pt-table-checksum`，不依赖线程状态推断数据一致
5. 监控三项指标：线程状态、延迟、两个位点的差值
6. 主库 binlog 保留期覆盖从库可能的最长中断时间
7. 单笔 binlog 事件超过一定体积时预警，倒逼大事务拆分
8. 不在从库执行任何事务性写入，含临时性的单行修改

## 八、命令索引

| 目的 | 命令 |
|---|---|
| 查看复制状态 | `SHOW REPLICA STATUS\G` |
| 启动全部复制线程 | `START REPLICA;` |
| 仅启动 IO 线程 | `START REPLICA IO_THREAD;` |
| 仅启动 SQL 线程 | `START REPLICA SQL_THREAD;` |
| 停止全部复制线程 | `STOP REPLICA;` |
| 清空复制配置 | `RESET REPLICA ALL;` |
| 跳过一条事务 | `SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;` |
| 按错误码跳过 | `replica_skip_errors = 1062,1054`，静态参数 |
| 查看只读状态 | `SHOW VARIABLES WHERE Variable_name IN ('read_only','super_read_only');` |
| 设置最高只读 | `SET GLOBAL super_read_only = ON;` |
| 校验表一致性 | `CHECKSUM TABLE 库.表;` |
| 查看主库当前位点 | `SHOW MASTER STATUS;` |
| 列出 binlog 文件 | `SHOW BINARY LOGS;` |
| 建立复制账号 | `GRANT REPLICATION SLAVE ON *.* TO 'repl'@'从库地址';` |

## 九、自检项

- [ ] 能说出复制依赖的三项前提条件
- [ ] 能说出 `server-id` 两侧相同的后果
- [ ] 能解释从库配置中 `socket` 一项的作用
- [ ] 能说出起始位点取自何处，为何不取 `SHOW MASTER STATUS`
- [ ] 能说出位点复制与 GTID 复制在排障上的差异
- [ ] 能说出线程层的六个判定字段
- [ ] 能解释为何双 `Yes` 不能推出数据一致
- [ ] 能说出三项数据层校验手段的适用场景
- [ ] 能说出 `read_only` 与 `super_read_only` 的适用范围差异
- [ ] 能解释复制线程为何不受只读约束
- [ ] 能说出复制中断的两层判定顺序
- [ ] 能说出跳过事务的代价与官方推荐做法
- [ ] 能说出延迟排查的第一步
- [ ] 能说出从库提升的主要步骤

## 附录 A 术语索引

| 术语 | 说明 |
|---|---|
| binlog | 二进制日志，Server 层的逻辑变更日志，复制与 PITR 的数据源 |
| relay log | 中继日志，从库 IO 线程写入、SQL 线程读取的中间文件 |
| Binlog Dump 线程 | 主库侧线程，读取 binlog 并推送给从库 |
| IO 线程 | 从库侧线程，接收主库 binlog 并写入 relay log |
| SQL 线程 | 从库侧线程，读取 relay log 并回放 |
| GTID | 全局事务标识，为每个事务分配唯一编号，替代位点定位 |
| `server-id` | 实例的唯一标识，复制关系中两侧必须不同 |
| 位点 | binlog 文件内的字节偏移量 |
| MTS | 多线程复制，SQL 线程按并行方式回放 |
| `ANONYMOUS` | 位点复制下事务在日志中的标识，表示无 GTID 编号 |

## 附录 B 配图建议

| 图号 | 内容 | 用途 |
|---|---|---|
| B-1 | 三个线程的接力路线图，标注线程归属与数据流向 | 说明复制原理 |
| B-2 | 位点推进的时间线图，标出 827 与 1465 两个刻度 | 说明位点与数据量的对应关系 |
| B-3 | 只读三步对照的表格截图 | 说明 `read_only` 与 `super_read_only` 的差异 |
| B-4 | 主从两侧 `CHECKSUM` 的输出截图，payment 一致与 repl_test 不一致并排 | 说明线程层与数据层的独立 |
