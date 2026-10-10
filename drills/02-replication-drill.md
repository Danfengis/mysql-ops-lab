# 从库故障演练记录

## 一、演练信息

| 项目 | 内容 |
|---|---|
| 日期 | 2026-10-10 |
| 对应模块 | M6 主从复制搭建、M7 从库故障演练 |
| 环境 | WSL2 Ubuntu 22.04，同机双实例，MySQL 8.0.46 |
| 主库 | 端口 3306，`server_id=1` |
| 从库 | 端口 3308，`server_id=2`，`read_only=ON` |
| 复制方式 | 位点复制，`Auto_Position=0` |
| 起始位点 | `binlog.000009`，`Pos 827` |

## 二、复制建立与同步验证

### 2.1 位点推进

| 时点 | `Read_Source_Log_Pos` | `Exec_Source_Log_Pos` |
|---|---|---|
| `START REPLICA` 后 | 827 | 827 |
| 主库执行一条 `INSERT` 后 | 1465 | 1465 |

两次差值 638 字节，为那条 `INSERT` 事件在 binlog 中的体积。两个位点在两次采样中均相等，SQL 线程无积压。

### 2.2 线程状态

```
Replica_IO_Running:  Yes
Replica_SQL_Running: Yes
Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
Seconds_Behind_Source: 0
```

### 2.3 数据一致性

| 表 | 主库 | 从库 | 结论 |
|---|---|---|---|
| `sakila.payment` | 1103857893 | 1103857893 | 一致 |
| `sakila.repl_test` | 1179643698 | 2913362174 | 不一致，见第四节 |

`payment` 两侧一致，`repl_test` 两侧不一致。两表在同一次巡检中给出相反结果，说明校验命令本身有效，不一致的来源是数据而非工具。

## 三、只读边界的对照

### 3.1 三步对照

| 步骤 | 账号 | 权限 | 只读设置 | 结果 | 错误码 |
|---|---|---|---|---|---|
| 一 | `app_user` | 仅 sakila 库级权限 | `read_only=ON` | 被拦 | 1290 |
| 二 | `root` | 含 SUPER | `read_only=ON` | 写入成功 | 无 |
| 三 | `root` | 含 SUPER | `super_read_only=ON` | 被拦 | 1290 |

### 3.2 结论

`read_only` 的适用范围是无 SUPER 权限的账号。root 携带 SUPER 权限，在第 3.1 节第二步绕过限制。`super_read_only` 才覆盖 root。

三步的报错文本一致，均为：

```
ERROR 1290 (HY000): The MySQL server is running with the --read-only option
so it cannot execute this statement
```

第三步的报错文本中选项名为 `--super-read-only`，与第一步不同，这个差异可以佐证拦住它的是哪个变量。

### 3.3 复制线程不受约束

三步对照期间，从库的复制线程始终为双 `Yes`，只读设置未影响复制。SQL 线程回放主库事务时临时绕过只读限制。

## 四、冲突事务与跳过

### 4.1 冲突的制造

分叉的种子是在从库手工写入一条主键为 99 的记录：

| 位置 | id | t | created |
|---|---|---|---|
| 从库 | 99 | `slave-only-row` | 2026-10-10 15:51:09 |
| 主库 | 99 | `master-row` | 2026-10-10 15:51:53 |

两行时间相差 44 秒。从库那条写入在前，主库那条在后，主库不知道从库已占用该主键。

### 4.2 故障现象

主库写入成功，从库侧报错。

```
Last_SQL_Errno: 1062
Last_SQL_Error: Could not execute Write_rows event on table sakila.repl_test;
                Duplicate entry '99' for key 'repl_test.PRIMARY'
```

实例错误日志：

```
2026-10-10T07:51:53.937450Z 16 [ERROR] [MY-010584] [Repl] Replica SQL for channel '':
Worker 1 failed executing transaction 'ANONYMOUS' at source log binlog.000009,
end_log_pos 2482; Could not execute Write_rows event on table sakila.repl_test;
Duplicate entry '99' for key 'repl_test.PRIMARY', Error_code: 1062;
handler error HA_ERR_FOUND_DUPP_KEY
```

线程状态在此刻的分布：

| 字段 | 值 |
|---|---|
| `Replica_IO_Running` | `Yes` |
| `Replica_SQL_Running` | `No` |

IO 线程继续拉取日志，停的是 SQL 线程。数据冲突只影响回放这一环。

### 4.3 处理与恢复

```sql
STOP REPLICA SQL_THREAD;
SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;
START REPLICA SQL_THREAD;
```

两条命令各返回一个 warning，内容为对应语法的弃用提醒。操作本身生效。

恢复后的位点变化：

| 项目 | 位点 |
|---|---|
| 坏事务位置 | `end_log_pos 2482` |
| 跳过后执行位置 | 2513 |

跳过后 `Replica_SQL_Running` 回到 `Yes`，`Last_SQL_Errno` 归零。

### 4.4 跳过的代价

跳过的事务不会补回从库。恢复后的数据状态：

| 位置 | id=99 的值 | checksum |
|---|---|---|
| 主库 | `master-row` | 1179643698 |
| 从库 | `slave-only-row` | 2913362174 |

两侧数值不同，分叉保留在数据中。这是演练的预期结果，说明跳过不是修复，而是把故障从线程层转移到数据层。

`SQL_SLAVE_SKIP_COUNTER` 在 8.0 已标为弃用。官方推荐的处理方向是先修数据再恢复复制，或直接重建从库。

## 五、异常与偏差

### 5.1 演练步骤顺序

演练 A 的原始设计把清理脏数据排在设置 `super_read_only=ON` 之后。执行到清理时被自己刚设立的约束拦住，报 1290。

修正后的顺序为先关闭只读、执行清理、再恢复只读。这类顺序问题的通用规则是：会收紧约束的操作排在所有需要写入的动作之后。

### 5.2 日志混流

从库实例以前台方式启动，实例日志与客户端输出共用同一终端。在主库执行写入时，从库的报错日志出现在同一屏幕，容易误判为主库的报错。

区分依据：

| 特征 | 归属 |
|---|---|
| `Query OK` 或结果集边框 | 客户端返回 |
| ISO 时间戳加 `[ERROR] [MY-NNNNNN] [Repl]` | 实例日志 |
| 出现 `Replica SQL for channel` | 从库实例 |

### 5.3 `ANONYMOUS` 的含义

错误日志中事务标识写作 `ANONYMOUS`，表示当前为位点复制，事务无 GTID 编号。定位只能依赖 `end_log_pos`，需要人工回查 binlog。GTID 复制在此处会给出具体编号，是排障上的实际差异。

## 六、待补充

| 项目 | 状态 |
|---|---|
| 从库提升为主库的演练 | 未执行，`sop/02-replication.md` 第 6.5 节仅有步骤 |
| 延迟场景的实测 | 未构造，`sop/02-replication.md` 第 6.4 节为通用排查方向 |
| `pt-table-checksum` 的实际使用 | 未执行，当前用 `CHECKSUM TABLE` 手工比对 |
| GTID 复制的搭建 | 未执行，当前为位点复制 |
