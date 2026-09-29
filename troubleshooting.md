## Day1 环境搭建
- payment行数差异：COUNT(*) = 16044，information_schema.table_rows = 16086;
> 原因：在InnoDB引擎下，information_schema.tables.table_rows是来自InnoDB的统计信息，它随机采样若干索引页，按照索引页数等比放大而得到的结果，由于每页的行数取决于存储数据的长度，页内行数是不均匀的，所以这个结果只能是一个近似值，不是精确值。甚至重新ANALYZE一下表，再次抽样又会分析出不同的结果；而COUNT(*)会进行扫表，得到的永远是精确值；

---

## Day2 日常运维

### 1. 终端环境的辨识

在 PowerShell 中执行 `sudo service mysql status`，返回的内容是“已在此计算机上禁用 Sudo。若要启用它，请转到设置应用中的 Developer Settings page”。该提示来自 Windows 11 自带的同名命令 `sudo.exe`，其作用是以管理员权限拉起后续命令，默认处于关闭状态，因此返回的是操作系统自身措辞的提示信息。Linux 的 `sudo` 是另外一个与之无关的程序。

判断当前所处终端的依据是提示符。`PS C:\...>` 属于 Windows PowerShell，`wang@主机名:...$` 属于 Ubuntu。两者的命令集不通用，`grep`、`ss`、`cat` 一类工具在 PowerShell 中不可用。

处理方式是先执行 `wsl -d Ubuntu-22.04` 进入发行版，再执行 Linux 命令。Windows 自带的 `sudo` 与本项目无关，无需在系统设置中启用。

### 2. 分页输出的处理

`service mysql status` 的输出末尾出现 `lines 1-14/14 (END)`，光标停留不动，无法返回命令提示符。原因是该命令在 systemd 环境下转交给 `systemctl status mysql` 执行，而 `systemctl` 默认把输出交给 `less` 分页器，输出超过一屏时分页器接管显示并等待按键。

按 `q` 即可返回。此处 `Ctrl+C` 无效，因为分页器是等待输入的交互式程序，并非正在执行中的命令，这一点容易误判为终端失去响应。

避免分页的写法有三种。加 `--no-pager` 适用于日常巡检；把输出通过管道交给 `cat` 可绕过分页；`systemctl is-active mysql` 只返回单个状态词，适合写入脚本作为判断条件。

### 3. 客户端与服务端配置文件的区分

按手册执行 `sudo vi /etc/mysql/mysql.conf.d/mysqld.cnf` 时，看到的文件首行注释标明该文件属于客户端配置，内容仅包含 `[mysql]` 段，其中没有 `bind-address`。该现象的原因是文件名输入有误，打开的是 `mysql.cnf`，即客户端配置文件；服务端配置文件的文件名为 `mysqld.cnf`，两者相差一个字母 `d`，该字母代表 daemon。

定位参数所在位置时应使用检索命令，而不是逐个打开文件核对。

```bash
sudo grep -rn "bind-address" /etc/mysql/
# -r 递归检索目录，-n 显示行号
# 预期输出：/etc/mysql/mysql.conf.d/mysqld.cnf:26:bind-address = 127.0.0.1
```

使用 vim 时，左侧一列 `~` 表示该行之后没有内容，属于空行占位符，不是文件中的字符。进入 vim 后执行 `:f` 会显示当前编辑文件的完整路径，可用于确认目标文件。

Ubuntu 的实例配置由多个文件拼接而成，主入口 `/etc/mysql/my.cnf` 只有若干行 `!includedir` 指令，实际参数位于 `mysql.conf.d/` 目录下。读取顺序自上而下，后读取到的取值覆盖先前的取值。各段的适用范围不同，`[mysqld]` 对应服务端进程，`[mysql]` 只对应 mysql 命令行客户端，把服务端参数写入 `[mysql]` 段不会产生效果。配置文件修改之后必须重启实例才生效。

### 4. 远程连接失败的定位

从宿主机图形客户端连接实例地址 172.26.141.222 的 3306 端口时，返回 2002 错误，内容为 `Can't connect to server on '172.26.141.222' (10061)`。

排查从服务端监听地址开始。

```bash
sudo ss -lntp | grep 3306
```

本环境实测输出为两行，第一行是 127.0.0.1:33060，对应 8.0 版本引入的 X Protocol 端口，由参数 `mysqlx-bind-address` 控制，图形客户端的普通连接不使用该端口；第二行是 0.0.0.0:3306，表明实例已监听全部网卡，监听地址一项没有问题，因此 2002 的原因不在服务端。

排查随后转向网络可达性。在宿主机 PowerShell 中执行端口测试，实测输出的关键字段为 `PingSucceeded : True`、`TcpTestSucceeded : False`，接口别名为 `vEthernet (WSL (Hyper-V firewall))`。链路层可达而传输层不可达，且接口名称中出现防火墙字段，指向 WSL 的入站流量被拦截。自 WSL 2.0.9 与 Windows 11 22H2 起，Hyper-V 防火墙默认启用，它把 Windows Defender 防火墙的规则作用于虚拟机的流量，宿主机发往其中的入站连接默认被拒绝。该防火墙位于虚拟交换机一侧，与实例是否对外开放监听无关。

本例中另有一处同时存在的错误被 2002 掩盖。账号建立时来源主机写为 `192.168.%.%`，而 NAT 模式下服务端看到的来源地址是 172.26.128.1，使用 localhost 转发时为 127.0.0.1，两者均不匹配该网段。网络环节修通之后，该问题会立即以 1045 错误的形式出现。

处理方式有两种。第一种是把客户端主机填写为 127.0.0.1，WSL2 默认启用 localhost 转发，宿主机上对 127.0.0.1:3306 的连接会被自动送入实例，该写法同时绕开 Hyper-V 防火墙并避免实例地址变化带来的影响。第二种是在管理员权限的 PowerShell 中为该发行版添加放行规则。

```powershell
New-NetFirewallHyperVRule -Name "WSL-MySQL-3306" -DisplayName "WSL 3306" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 3306

Get-NetFirewallHyperVRule -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
```

`{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}` 是该发行版的固定 VMCreatorId，Hyper-V 防火墙依据该标识判断流量归属，普通 `New-NetFirewallRule` 对虚拟机流量不生效。不建议使用 `Set-NetFirewallHyperVVMSetting` 配合 `-DefaultInboundAction Allow`，该设置放开的是虚拟机的全部入站流量。

账号部分需要按下述语句重建。

```sql
DROP USER IF EXISTS 'navicat'@'192.168.%.%';
CREATE USER 'navicat'@'%' IDENTIFIED WITH mysql_native_password BY 'Navicat123!';
GRANT ALL PRIVILEGES ON sakila.* TO 'navicat'@'%';
FLUSH PRIVILEGES;
```

远程访问的失败原因分布在三个层次，可依据错误码逐层排除。服务端监听地址层失败返回 2002，账号授权来源层失败返回 1045，网络可达层失败同样返回 2002。错误码 2002 同时覆盖第一层与第三层，因此该错误出现时不能只检查监听地址。第三层的快速判据是链路层可达而传输层不可达，两者同时出现通常由防火墙导致。

`ping` 命令不适用于判断实例端口是否可达。该命令使用 ICMP 协议，WSL2 默认不回复 ICMP 请求，同时链路层可达也不代表端口处于开放状态，判断可达性需要执行 TCP 端口测试。

账号权限与配置文件参数的生效条件不同。前者修改后立即生效，不需要重启；后者必须重启实例。两个层次的操作在验证方式上也因此不同。

宿主机与实例位于同一台物理机器，但分属两个独立网络栈，二者之间的通信经过 Hyper-V 虚拟交换机与独立防火墙，该环节的排查方式与跨主机场景一致。

### 5. 短选项参数的字符辨识

执行 `sudo ss -Intp | grep 3306` 时返回 `ss: invalid option -- 'I'`。该参数的第一位是小写字母 `l`，取自 listening，实际输入为大写字母 `I`。等宽字体下小写 `l`、大写 `I` 与数字 `1` 形状接近，属于终端中常见的输入错误。

`ss -lntp` 的四个字符依次为 listening、numeric、tcp、processes，全部为字母，不含数字。

两种规避方式。使用长选项写法可完全避免辨识问题，也可以改用其他命令获取同一信息，例如在实例内执行 `SELECT @@bind_address, @@port;`，返回 127.0.0.1 表示仅监听本机，返回 0.0.0.0 或 `*` 表示监听全部网卡。命令返回参数错误时不宜反复重试同一条命令，更换写法或更换命令的效率更高。

### 6. 服务自启状态的确认

实例状态查询的结果显示 `Loaded: ... enabled; vendor preset: enabled` 与 `Active: active (running)`，说明服务随发行版启动自动拉起，不需要每次开机手动执行启动命令。本环境的 systemd 处于启用状态，这与早期 WSL 版本不运行 systemd 的经验不同，新版 WSL 默认启用 systemd。

判断依据是 `systemctl is-enabled mysql` 的返回值。返回 `enabled` 说明 systemd 已启用，返回 `command not found` 或提示没有 systemd 则属于早期情形。在启用 systemd 的环境下，`sudo service mysql status` 会转交给 `systemctl` 执行，两者输出格式一致，生产环境统一使用 `systemctl`。

### 附：两天问题的共性

| 项目 | Day1 | Day2 |
|---|---|---|
| 认知类问题 | 指南把主键最大值当作行数 | 指南断言该发行版不运行 systemd，该结论属于早期版本的经验 |
| 环境差异类问题 | InnoDB 的行数统计为估算值 | Hyper-V 防火墙默认拦截宿主机发往虚拟机的入站流量 |
| 共同结论 | 文档记载的结论不等于当前环境的实际行为，实测输出才是判断依据 | 同上 |
