# 账号与权限管理

## 一、文档定位

编制时间为 Day 2（M1 日常运维）。适用对象为本仓库 3306 主实例与后续 3308 从实例。覆盖实例启停、连接协议判定、账号建立与权限授予、远程访问排障四组操作。文中命令均在实例所在主机执行，环境为 Ubuntu 22.04 与 MySQL 8.0。

文档状态：第五节 5.2 中只读账号 `ops_ro` 的建立与验证属于待执行流程，尚未在本环境运行；其余各节的命令与输出均在本环境执行过，并以“实测”标注。

## 二、问题背景

以下按情境、冲突、问题、结论的顺序说明编制本规范的原因。

**情境。** 实例安装完成后，默认状态只允许本机以 socket 方式登录，且仅存在 root 与少量内置账号。日常运维需要宿主机图形客户端接入，脚本需要以最小权限读写业务库。

**冲突。** 默认配置在三处同时构成阻碍。服务端监听地址限定为回环地址，外部连接无法建立；账号的来源主机字段未覆盖宿主机地址，网络可达时仍会被拒绝；WSL 的入站流量由 Hyper-V 防火墙独立管辖，宿主机发出的连接在虚拟交换机层被丢弃。

**问题。** 在 WSL2 实例上建立可复用的账号与权限体系，并给出远程访问失败的定位顺序。

**结论。** 账号、权限、网络三层分开处理。账号与权限的变更立即生效，配置文件与防火墙的变更需要重启服务或重载规则，两者的验证方式不同。第五节与第八节分别给出这两类变更的操作与判定标准。

## 三、实例启停

### 3.1 systemd 方式

Ubuntu 22.04 的 MySQL 由 systemd 托管，以下命令为日常操作入口。

```bash
sudo systemctl status mysql          # 查看状态，加 --no-pager 可避免输出分页
sudo systemctl start mysql           # 启动
sudo systemctl stop mysql            # 停止
sudo systemctl restart mysql         # 重启，修改配置文件后必须执行
sudo systemctl is-active mysql       # 只返回 active 或 inactive
sudo systemctl is-enabled mysql      # 只返回 enabled 或 disabled
```

`is-active` 与 `is-enabled` 的输出为单个词，适合在脚本中作为判断条件。`status` 的完整输出超过一屏时会被分页器接管，处理方式见第九节。

若命令输出停在 `(END)`，按 `q` 返回命令提示符；`Ctrl+C` 对此无效，因为分页器是交互式程序而非正在执行的命令。不分页的三种写法如下。

```bash
systemctl status mysql --no-pager          # 日常巡检推荐
sudo service mysql status | cat            # 管道交给 cat
systemctl is-active mysql                  # 只取状态字段
```

### 3.2 service 与 systemctl 的关系

在启用 systemd 的环境下，`sudo service mysql status` 会转交给 `systemctl` 执行，因此两者输出格式一致。旧手册中的 SysV 风格写法仍然可用，生产环境统一使用 `systemctl`。

### 3.3 不依赖 systemd 的关闭方式

```bash
mysqladmin -u root -p shutdown         # 关闭实例
mysqladmin -u root -p status           # 查看运行状态
mysqladmin -u root -p ping             # 探活，返回 mysqld is alive
```

`mysqladmin` 通过客户端协议通信，不经过操作系统的服务管理接口。若把 systemd 看作楼宇的物业管理，`mysqladmin` 相当于直接走进机房按下电源键，因此在容器或其他没有 systemd 的场景中同样可用，M6 的崩溃恢复演练会用到该特性。

## 四、连接协议的选择依据

### 4.1 两条通路的判定规则

MySQL 客户端根据主机参数的写法决定使用哪种协议。

| 命令写法 | 使用的通路 |
|---|---|
| `mysql -u root -p` | socket |
| `mysql -h localhost -u root -p` | socket |
| `mysql -h 127.0.0.1 -u root -p` | TCP |
| `mysql -h 10.0.0.5 -u root -p` | TCP |

客户端把字符串 `localhost` 解释为使用本机 socket 的指示符，不将其作为地址解析，因此 `-h localhost` 与不写 `-h` 的结果相同。`127.0.0.1` 是明确的地址，只能走 TCP。若把 socket 理解为楼宇内部的通道，TCP 则是临街的大门与道路，两者的入口不同，受影响的环节也不同。

需要强制指定协议时使用 `--protocol`，其取值为 `TCP`、`SOCKET`、`PIPE` 与 `MEMORY`。

```bash
mysql --protocol=TCP -h localhost -u root -p
```

### 4.2 当前会话所用通路的确认

```sql
\s
```

`\s` 是客户端元命令，由客户端自身处理，不发送至服务端。输出中的 `Connection` 字段显示 `Localhost via UNIX socket` 或 `127.0.0.1 via TCP/IP`。

socket 文件的位置可通过下列语句查询。

```sql
SHOW VARIABLES LIKE 'socket';
-- 预期输出：/var/run/mysqld/mysqld.sock
```

### 4.3 适用场景与影响范围

| 维度 | socket | TCP |
|---|---|---|
| 本机运维与脚本登库 | 适用 | 可用 |
| 跨机器应用连接 | 不可行 | 唯一选择 |
| 宿主机图形客户端接入 | 不可行 | 适用 |
| 主从复制（M7） | 不可行 | 适用 |
| 性能 | 不经过网络协议栈，无握手开销 | 相对较慢 |
| 受影响的因素 | socket 文件的路径与权限 | 监听地址、授权来源、防火墙 |

socket 通路的可用性与监听地址及防火墙无关。本环境在调整监听地址之前，`mysql -u root -p` 始终可以登录，可用于快速判断服务本身是否正常。

### 4.4 参数的大小写区分

| 参数 | 含义 |
|---|---|
| `-p` | 密码 |
| `-P` | 端口 |
| `-u` | 用户名 |
| `-U` | `--safe-updates`，与端口无关 |

`-p` 之后不直接跟密码，否则密码会进入命令历史与进程列表。

## 五、账号与权限

### 5.1 账号的标识方式

```sql
SELECT user, host, plugin FROM mysql.user ORDER BY user, host;
```

MySQL 的账号由用户名与来源主机两部分共同标识。`'ops_ro'@'localhost'` 与 `'ops_ro'@'%'` 是两个独立的账号，因此授权语句必须同时写出 host 部分。

| host 写法 | 匹配范围 |
|---|---|
| `localhost` | 仅本机 socket 连接 |
| `127.0.0.1` | 仅本机 TCP 连接 |
| `192.168.1.%` | 指定网段 |
| `%` | 任意来源 |

授权结果的查询方式如下。

```sql
SHOW GRANTS FOR 'ops_ro'@'localhost';
-- 预期输出形如：GRANT SELECT ON `sakila`.* TO `ops_ro`@`localhost`
```

当前会话身份的确认使用下列语句。

```sql
SELECT CURRENT_USER(), USER();
```

`CURRENT_USER()` 返回服务端实际认证出的身份，`USER()` 返回连接时声明的身份。两者不一致时，说明该连接匹配到了带通配符的账号。

### 5.2 只读账号的建立与验证

按 Day 2 验收要求，需要在不参考笔记的条件下完成本节全部操作。

```sql
CREATE USER 'ops_ro'@'localhost' IDENTIFIED BY 'OpsRo123!';
GRANT SELECT ON sakila.* TO 'ops_ro'@'localhost';
FLUSH PRIVILEGES;
SHOW GRANTS FOR 'ops_ro'@'localhost';
```

创建完成后重新登录以验证效果。

```bash
mysql -u ops_ro -p
```

```sql
USE sakila;
SELECT COUNT(*) FROM film;                  -- 预期 1000

INSERT INTO sakila.actor (first_name, last_name) VALUES ('TEST','TEST');
-- 预期：ERROR 1142 (42000): INSERT command denied to user 'ops_ro'@'localhost' for table 'actor'

UPDATE sakila.actor SET first_name = 'X' WHERE actor_id = 1;
-- 预期：ERROR 1142 ... UPDATE command denied ...

DELETE FROM sakila.actor WHERE actor_id = 1;
-- 预期：ERROR 1142 ... DELETE command denied ...

SELECT COUNT(*) FROM mysql.user;
-- 预期：ERROR 1142 ... SELECT command denied ... for table 'user'
```

判定标准为两项：查询返回预期结果，写入操作返回错误码 1142。若查询阶段返回 1045，说明认证未通过，属于账号或来源主机不匹配，与权限无关。

### 5.3 权限的授予范围

```sql
GRANT SELECT ON sakila.film TO 'ops_ro'@'localhost';      -- 单表
GRANT SELECT ON sakila.*     TO 'ops_ro'@'localhost';     -- 单库
GRANT SELECT ON *.*          TO 'ops_ro'@'localhost';     -- 全实例
```

按角色划分的授予范围如下，生产环境不直接授予 `ALL`。

| 角色 | 权限集合 |
|---|---|
| 只读与报表 | `SELECT` |
| 应用写入 | `SELECT, INSERT, UPDATE, DELETE` |
| 库表维护 | 上一行加 `CREATE, DROP, ALTER, INDEX` |
| 备份账号 | `SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER` |
| 复制账号（M7） | `REPLICATION SLAVE, REPLICATION CLIENT` |

可选子句包括 `WITH MAX_QUERIES_PER_HOUR n` 与 `WITH GRANT OPTION`。后者允许账号继续向下授权，生产环境慎用。

### 5.4 权限的回收

```sql
REVOKE INSERT ON sakila.* FROM 'ops_ro'@'localhost';
REVOKE ALL PRIVILEGES ON sakila.* FROM 'ops_ro'@'localhost';
```

`GRANT` 与 `REVOKE` 的语法结构一一对应，前者授予权限，后者收回权限。

### 5.5 变更的生效条件

| 变更对象 | 生效条件 |
|---|---|
| 账号与权限 | 立即生效，无需重启 |
| 配置文件参数 | 必须重启实例 |
| `SET GLOBAL` 参数 | 只对新建连接生效，且重启后失效 |
| `SET SESSION` 参数 | 当前会话立即生效，会话结束后失效 |

`FLUSH PRIVILEGES` 的用途需要单独说明。通过 `CREATE USER` 与 `GRANT` 等标准语句修改权限时，权限缓存会自动刷新，该语句并非必需；它的实际用途是在直接改写 `mysql.user` 表之后重新加载权限数据。保留该语句不影响正确性。

### 5.6 账号的删除

```sql
DROP USER IF EXISTS 'ops_ro'@'localhost';
```

删除账号应使用 `DROP USER`，它会连带清理该账号在 `mysql.db` 与 `mysql.tables_priv` 中的授权记录。直接删除 `mysql.user` 中的行会留下孤立授权。

## 六、表数据的删除方式比较

| 维度 | `DELETE` | `TRUNCATE` | `DROP` |
|---|---|---|---|
| 语句类型 | DML | DDL | DDL |
| 删除对象 | 满足条件的行 | 全部行，保留表结构 | 整张表 |
| `WHERE` 子句 | 支持 | 不支持 | 不支持 |
| 事务回滚 | 支持 | 不支持 | 不支持 |
| 触发器 | 触发 | 不触发 | 不触发 |
| 自增计数器 | 不重置 | 重置为 1 | 表被删除 |
| 执行速度 | 较慢 | 较快 | 较快 |
| 磁盘空间 | 不释放，产生碎片 | 释放 | 释放 |
| 所需权限 | `DELETE` | `DROP` | `DROP` |

DDL 语句不参与事务，`TRUNCATE` 与 `DROP` 执行后无法通过 `ROLLBACK` 恢复，只能依靠备份与 binlog 重建数据，该流程是 M6 的主题。

## 七、运行参数的查看与修改

```sql
SELECT @@bind_address, @@port, @@socket, @@datadir,
       @@character_set_server, @@collation_server,
       @@time_zone, @@system_time_zone, @@max_connections;
```

| 参数 | 本环境取值 | 说明 |
|---|---|---|
| `bind-address` | `0.0.0.0`（调整后） | `127.0.0.1` 仅本机，`0.0.0.0` 或 `*` 为全部网卡 |
| `port` | `3306` | 从实例在 M7 使用 `3308` |
| `datadir` | `/var/lib/mysql` | 不可置于 `/mnt/c`，M7 会验证该结论 |
| `character_set_server` | `utf8mb4` | 需与 `collation_server` 同属 utf8mb4 系列 |

MySQL 8.0 另有一个 X Protocol 端口 `33060`，由参数 `mysqlx-bind-address` 控制，与经典协议端口互不影响，宿主机图形客户端连接不使用该端口。

参数的查询与临时修改方式如下。

```sql
SHOW VARIABLES LIKE 'max_connections';
SELECT @@global.max_connections, @@session.max_connections;
SET GLOBAL max_connections = 200;      -- 不持久化，重启后失效
```

`SET GLOBAL` 只对新建连接生效，验证时需要重新建立连接，否则会误判为未生效。持久化修改应写入 `my.cnf`。

## 八、远程访问的成立条件

### 8.1 三层判定

远程连接失败的原因分布在三个层次，可按错误码逐层排除。

| 层次 | 检查对象 | 失败时的错误码 |
|---|---|---|
| 服务端监听地址 | `bind-address` 的取值与 `ss` 的监听结果 | 2002 |
| 账号授权来源 | 账号 host 字段与服务端看到的来源地址是否匹配 | 1045 |
| 网络可达性 | 防火墙与路由是否放行 | 2002 |

错误码 2002 同时对应第一层与第三层，因此该错误出现时不能只检查监听地址。第三层的快速判据是：`PingSucceeded` 为真而 `TcpTestSucceeded` 为假，两者同时出现说明链路层正常而传输层被拦截，通常由防火墙导致。

### 8.2 配置步骤

第一步，调整监听地址并重启实例。

```bash
sudo grep -rn "bind-address" /etc/mysql/
sudo vi +/bind-address /etc/mysql/mysql.conf.d/mysqld.cnf
# 将取值改为 0.0.0.0，该参数必须位于 [mysqld] 段
sudo systemctl restart mysql
```

第二步，确认监听结果。

```bash
sudo ss --listening --numeric --tcp --processes | grep 3306
```

本环境实测输出如下，其中第二行表明已监听全部网卡，第一层通过。

```
LISTEN 0   70    127.0.0.1:33060   0.0.0.0:*   users:(("mysqld",pid=281,fd=21))
LISTEN 0   151   0.0.0.0:3306      0.0.0.0:*   users:(("mysqld",pid=281,fd=23))
```

第三步，建立远程账号并限定授权范围。

```sql
CREATE USER 'navicat'@'%' IDENTIFIED WITH mysql_native_password BY 'Navicat123!';
GRANT ALL PRIVILEGES ON sakila.* TO 'navicat'@'%';
FLUSH PRIVILEGES;
```

来源主机写为 `%` 是练习环境的妥协。本环境使用 NAT 模式，宿主机侧连接在服务端呈现的来源地址会随重启变化，可能是网关地址或 `127.0.0.1`。生产环境按网段精确授权，例如 `'user'@'10.0.3.%'`。

第四步，确认服务端看到的来源地址。服务端在拒绝连接时会把该地址写入错误信息，错误码 1045 的消息中含有 `@'x.x.x.x'` 片段，该片段即为实际来源地址，可直接作为授权依据。

```bash
sudo tail -20 /var/log/mysql/error.log
```

```sql
SELECT * FROM performance_schema.host_cache\G
```

### 8.3 宿主机图形客户端的连接参数

| 参数 | 取值 |
|---|---|
| 主机 | `127.0.0.1` |
| 端口 | `3306` |
| 用户名 | `navicat` |
| 密码 | `Navicat123!` |

主机填写 `127.0.0.1` 的依据是 WSL2 默认启用 localhost 转发，宿主机上对 `127.0.0.1:3306` 的连接会被自动送入实例。该写法同时绕过 Hyper-V 防火墙，并避免了实例地址每次重启变化的问题。实例地址可通过 `wsl hostname -I` 获取。

### 8.4 宿主机防火墙的拦截

在监听地址与账号授权均已正确的情况下，仍可能出现 2002。此时在宿主机 Powershell 中执行端口测试。

```powershell
Test-NetConnection 172.26.141.222 -Port 3306
```

本环境实测输出的关键字段如下。

```
PingSucceeded    : True
TcpTestSucceeded : False
InterfaceAlias   : vEthernet (WSL (Hyper-V firewall))
SourceAddress    : 172.26.128.1
```

`InterfaceAlias` 字段中的 Hyper-V firewall 即为原因。自 WSL 2.0.9 与 Windows 11 22H2 起，Hyper-V 防火墙默认启用，它把 Windows Defender 防火墙的规则作用于 WSL 虚拟机的流量，宿主机发往 WSL 的入站连接默认被拒绝。该防火墙相当于楼外单独设置的门岗，与实例自身是否对外开放监听无关。

两种处理方式如下。第一种是把客户端主机改为 `127.0.0.1`，通过 localhost 转发绕开该入站路径。第二种是在管理员权限的 Powershell 中为 WSL 添加放行规则。

```powershell
New-NetFirewallHyperVRule -Name "WSL-MySQL-3306" -DisplayName "WSL MySQL 3306" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 3306

Get-NetFirewallHyperVRule -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
```

`{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}` 是 WSL 的固定 VMCreatorId。Hyper-V 防火墙依据该标识判断流量归属，普通 `New-NetFirewallRule` 对 WSL 流量不生效。不建议使用 `Set-NetFirewallHyperVVMSetting` 配合 `-DefaultInboundAction Allow`，该设置会放开 WSL 的全部入站流量。

宿主机与实例位于同一台物理机器，但分属两个独立网络栈，两者之间的通信经过 Hyper-V 虚拟交换机与独立防火墙，因此该环节的排查与跨主机场景一致。

## 九、常见错误码的定位

| 错误码 | 含义 | 所在层次 | 处理方向 |
|---|---|---|---|
| 2002，消息含 `to server on 'IP'` | 端口无监听或数据包不可达 | 第一层或第三层 | 检查监听地址，再做端口测试 |
| 2002，消息含 `through socket` | socket 通路不可用 | 无 | 检查服务状态与 socket 文件路径 |
| 1045 | 认证未通过 | 第二层 | 依据错误信息中的来源地址调整授权 |
| 1130 | 来源主机不允许连接 | 第二层 | 检查账号 host 字段 |
| 1251 | 客户端不支持服务端认证插件 | 无 | 升级客户端，或临时改用兼容插件 |
| 1142 | 已通过认证，权限不足 | 无 | 授予相应权限 |
| 1044 | 已通过认证，无目标库权限 | 无 | 授予库级权限 |

1045 与 1130 属于认证阶段失败，1142 与 1044 属于授权阶段失败。两者的处理顺序不同，区分依据是该错误是否在输入正确密码之后出现。

## 十、生产环境的权限约束

| 项目 | 练习环境 | 生产环境 |
|---|---|---|
| 账号 host | 使用 `%` | 按网段精确授权 |
| 权限范围 | 单库 `ALL` | 按角色授予最小权限 |
| root 账号 | 直接使用 | 禁止远程登录，日常使用专用运维账号 |
| 认证插件 | `mysql_native_password` | `caching_sha2_password` |
| 监听地址 | `0.0.0.0` | 仅对应用网段开放或经跳板机 |
| 密码存储 | 记录在文档中 | 存入密钥管理平台，不进入仓库与命令历史 |
| `WITH GRANT OPTION` | 不使用 | 原则上不授予 |

`mysql_native_password` 从 MySQL 8.0.34 起废弃，9.0 起移除，仅在客户端版本过低时作为过渡手段使用。

## 十一、自检项

- 不参考笔记，建立一个仅具备 `sakila` 库查询权限的账号，并完成查询成功与写入失败两项验证
- 说明 socket 与 TCP 的差异、各自的适用场景，以及 `-h localhost` 所走的通路
- 从宿主机图形客户端接入实例，并看到 `sakila` 库
- 说明 `GRANT` 与 `REVOKE` 的作用
- 说明 `DELETE`、`TRUNCATE`、`DROP` 的差异，并指出其中无法回滚的语句
- 说明远程访问的三层判定，以及 2002、1045、1130 各自对应的层次
- 指出账号权限变更与配置文件变更的生效条件差异

## 附录 A 术语索引

下表列出本规范涉及的主要术语及其出现章节，可用于检索。

| 术语 | 章节 |
|---|---|
| 服务启停 | 3.1 |
| `mysqladmin` | 3.3 |
| socket 连接 | 4.1 |
| TCP 连接 | 4.1 |
| `-h localhost` | 4.1 |
| `-P` 端口参数 | 4.4 |
| 账号 host | 5.1 |
| 只读账号 | 5.2 |
| `GRANT` | 5.3 |
| `REVOKE` | 5.4 |
| `FLUSH PRIVILEGES` | 5.5 |
| `DROP USER` | 5.6 |
| `TRUNCATE` | 六 |
| `bind-address` | 7 与 8.2 |
| 远程连接三层 | 8.1 |
| Hyper-V 防火墙 | 8.4 |
| 错误码 2002 | 8.1 与 九 |
| 错误码 1045 | 5.2 与 九 |
| 错误码 1142 | 5.2 与 九 |
| 最小权限 | 5.3 与 十 |

## 附录 B 配图建议

以下位置建议补充截图，以缩短阅读路径。图片按目录归入 `screenshots/Day2/`。

| 位置 | 建议内容 | 文件名 |
|---|---|---|
| 3.1 | `systemctl status mysql` 的输出，含 `enabled` 与 `active (running)` 字段 | `systemctl-status.png` |
| 5.2 | 只读账号查询成功与写入报 1142 的两条对照 | `readonly-verify.png` |
| 8.2 | `ss -lntp \| grep 3306` 显示 `0.0.0.0:3306` | `ss-listen.png` |
| 8.3 | 图形客户端连接配置与连接成功后的库列表 | `navicat-conn.png` |
| 8.4 | PowerShell 端口测试输出，含 `InterfaceAlias` 字段 | `hyperv-firewall.png` |

---

下一篇为 SOP 02，主题为事务、隔离级别与锁，对应 Day 3 的 M2。
