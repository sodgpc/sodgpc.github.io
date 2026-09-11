# SOD酵素 DApp

H5入口：**[https://sodgpc.github.io/](https://sodgpc.github.io/)**

本仓库公开SOD酵素的生产合约源码、ABI、BSC主网地址与使用说明。页面面向手机浏览，连接BNB Smart Chain（chainId `56`）钱包使用。

## V2主网实例

2026-09-11在业务尚为空、无需迁移用户状态的前提下，SOD重新部署了一套V2业务代理。Mining、History和AutoWithdraw均使用新的OpenZeppelin Transparent Proxy；Mining已绑定新的History，并一次性绑定新的AutoWithdraw全局服务。

| 合约 | 用途 | 代理地址 |
| --- | --- | --- |
| `SodMining` | 商品订单、推荐关系、算力与收益结算 | [`0x8dbd06b54c1b81782fF4A127bD919C6c3F0e5168`](https://bscscan.com/address/0x8dbd06b54c1b81782fF4A127bD919C6c3F0e5168) |
| `SodHistoryRegistry` | 仅由当前Mining写入算力变更记录 | [`0xa67d3d303DB69B102d5660DC76ad834D00735D54`](https://bscscan.com/address/0xa67d3d303DB69B102d5660DC76ad834D00735D54) |
| `SodAutoWithdraw` | 预付自动提现次数；正余额即生效 | [`0xbF5c04FA9d6849Cd0f9670d5085411d68d5cDeeA`](https://bscscan.com/address/0xbF5c04FA9d6849Cd0f9670d5085411d68d5cDeeA) |

完整实现地址、ProxyAdmin、部署交易、区块、钱包、资产、路由和交易对见 [addresses.json](addresses.json)。H5和自动执行器只应使用上表代理地址；实现地址仅用于源码与字节码核对。

价格读取继续复用由原系统维护的Oracle [`0x7c7CdA7C435776815606879390523c6486C0b0fB`](https://bscscan.com/address/0x7c7CdA7C435776815606879390523c6486C0b0fB)。本次没有部署或接管Oracle，其价格观测和治理仍由外部系统负责。

此前空业务套件（Mining `0x2cC3…07B5`、History `0x58c1…29b`、AutoWithdraw `0x30e7…437B`）已弃用，仅作为历史链上记录保留，不再作为前端、执行器或后续业务入口；旧Mining经完整空业务检查后已暂停。History实现代码未改变，因此新History代理复用已部署实现 `0xf51A…E639`；Mining与AutoWithdraw运行V2实现。

## 治理与执行权限

| 合约 | 业务owner | ProxyAdmin owner |
| --- | --- | --- |
| Mining | B792部署钱包 | A502的2/3 Safe |
| History | B792部署钱包 | A502的2/3 Safe |
| AutoWithdraw | B792部署钱包 | B792部署钱包 |

- B792：[`0xB7924467cEce8FD55dA013d8cFe2333173c9C236`](https://bscscan.com/address/0xB7924467cEce8FD55dA013d8cFe2333173c9C236)，带EIP-7702委托代码的私钥控制EOA。
- A502：[`0xA5026571A9BCfE4B2839fe274EcAbA7f0fc3e684`](https://bscscan.com/address/0xA5026571A9BCfE4B2839fe274EcAbA7f0fc3e684)，2/3 Safe。
- 自动提现executor：[`0xb7941CA8DB894178d415A48F76085822dC489F16`](https://bscscan.com/address/0xb7941CA8DB894178d415A48F76085822dC489F16)。

AutoWithdraw的ProxyAdmin由B792单签控制。Mining虽然固定信任AutoWithdraw代理地址，但该ProxyAdmin仍可替换代理实现；单签私钥泄露会影响次数判断和代领逻辑。这是需要显式接受或后续迁移到多签的高权限风险。

## 商品与收益规则

产品名为「青之梅·SOD酵素」。每份支付700 USDT并增加1,000个人算力；页面不显示包装规格。订单资金分为运营265 USDT、直推35 USDT及400 USDT兑换GPC，兑换所得全部进入Mining订单矿池。推荐人有效个人算力不足35时，35 USDT转运营；达到门槛则发放35 USDT并消耗35算力。

静态收益按有效个人算力的0.35%计算；社区收益按截断到个人算力10倍的有效小区计算，权重10%，总毛收益最多为静态的2倍。领取按毛收益USDT值消耗个人算力，并按Oracle价格换算GPC；毛GPC的5%转技术钱包、95%发送用户。每24小时最多手动领取一次，购买会重置领取冷却。

钱包进入页面后核对推荐关系。明确未绑定时必须由用户填写或确认有效上级，并在钱包中签名；邀请链接中的 `ref` 或 `invite` 只用于预填，不会自动签名或绑定。钱包连接、绑定上级、USDT授权和购买支付是相互独立的确认。

## 自动提现V2

V2没有用户级开启或暂停。用户通过 `buyCredits(credits)` 为本人购买不可转让的执行次数，每次价格为 **0.0005 BNB**；正余额立即成为自动执行条件之一。

- 用户不能暂停、撤销、转让、主动销毁或退款来停止队列；只有次数耗尽后停止。
- 冷却条件为上次领取或购买后24小时，再额外等待10分钟。
- 仅指定executor可调用 `execute(beneficiary)`，净收益固定发送受益人。
- 只有成功结算正数净GPC才原子扣除1次；失败交易不扣次数。
- 手动 `withdraw()` 不扣次数，但会刷新领取时间，使后续自动执行顺延。
- `checkAuto` 同时检查次数、全局服务绑定、有效算力、失活状态、Mining暂停、History、Oracle报价及矿池额度。

`SodMining.autoWithdrawService()` 已一次性绑定到上表AutoWithdraw代理；`withdrawFor`只接受该服务。旧 `setAutoWithdrawDelegate` 和 `buyFor` 入口仅为ABI兼容保留，调用会回退。

## 源码、ABI与编译

- `contracts/`：V2生产Solidity源码及接口。
- `abi/`：与当前源码匹配的四份ABI。
- `addresses.json`：V2主网实例、外部Oracle、角色及弃用前序实例。
- `hardhat.config.js`：生产编译参数，不包含网络账户。

使用Node.js 22.13或更新版本。依赖固定为Hardhat `2.28.6`、OpenZeppelin Contracts `4.9.6`及Contracts Upgradeable `4.9.6`；Solidity为 `0.8.21`，`viaIR: true`，优化器 `runs: 100`，目标EVM为 `paris`。

```sh
npm ci
npm run compile
```

这些命令只编译源码，不部署合约。

## 链上源码入口

- [Mining V2实现：0xa0c16495fFd611ddC158ad0b12938F388919c0AB](https://bscscan.com/address/0xa0c16495fFd611ddC158ad0b12938F388919c0AB#code)
- [AutoWithdraw V2实现：0xdF074657E4f479d53a7A099e9b4461f31658269C](https://bscscan.com/address/0xdF074657E4f479d53a7A099e9b4461f31658269C#code)
- [History实现：0xf51A4B17696c96C0A122AA6CAc0aCA8219a6E639](https://bscscan.com/address/0xf51A4B17696c96C0A122AA6CAc0aCA8219a6E639#code)

地址快照日期：2026-09-11。代理可由各自ProxyAdmin治理方升级，当前实现、绑定及权限最终以BSC链上状态为准。部署记录合并、链上验证、前端与执行器地址切换及线上发布产物哈希核验均已完成。
