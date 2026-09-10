# SOD 酵素 DApp

H5入口：**[https://sodgpc.github.io/](https://sodgpc.github.io/)**

本仓库公开SOD的合约源码、ABI、BSC主网地址与使用说明。页面面向手机浏览，连接BNB Smart Chain（chainId `56`）钱包使用。

## 当前合约

SOD使用三个独立的OpenZeppelin Transparent Proxy。用户及前端调用代理地址；实现地址用于查看逻辑，ProxyAdmin用于升级治理。完整实现、ProxyAdmin、角色、代币、路由和交易对地址见 [addresses.json](addresses.json)。

| 合约 | 用途 | 当前代理地址 |
| --- | --- | --- |
| `SodMining` | 商品订单、推荐关系、算力与收益结算 | [`0x2cC3d50ff78c0b4857D2c097b82d7682fd1907B5`](https://bscscan.com/address/0x2cC3d50ff78c0b4857D2c097b82d7682fd1907B5) |
| `SodHistoryRegistry` | 由Mining写入的算力变更记录 | [`0x58c134601e475Fcc865160bCAcF83bDA54e8929b`](https://bscscan.com/address/0x58c134601e475Fcc865160bCAcF83bDA54e8929b) |
| `SodAutoWithdraw` | 用户自愿授权的自动提现与预付执行次数 | [`0x30e7C7083C93D08a3f3A4112Eeb375006299437B`](https://bscscan.com/address/0x30e7C7083C93D08a3f3A4112Eeb375006299437B) |

价格读取复用已有Oracle [`0x7c7CdA7C435776815606879390523c6486C0b0fB`](https://bscscan.com/address/0x7c7CdA7C435776815606879390523c6486C0b0fB)。该Oracle沿用原治理，SOD三个业务代理不接管其升级权限。仓库中的Oracle相关源码可用于阅读和编译，不代表新部署了一份主网Oracle。

业务owner与升级治理是不同权限：

| 合约 | 业务owner | ProxyAdmin owner |
| --- | --- | --- |
| Mining | B792部署钱包 | A502的2/3 Safe |
| History | B792部署钱包 | A502的2/3 Safe |
| AutoWithdraw | B792部署钱包 | B792部署钱包 |

- B792：[`0xB7924467cEce8FD55dA013d8cFe2333173c9C236`](https://bscscan.com/address/0xB7924467cEce8FD55dA013d8cFe2333173c9C236)，带EIP-7702委托代码的EOA。
- A502：[`0xA5026571A9BCfE4B2839fe274EcAbA7f0fc3e684`](https://bscscan.com/address/0xA5026571A9BCfE4B2839fe274EcAbA7f0fc3e684)，2/3 Safe。
- 自动提现executor：[`0xb7941CA8DB894178d415A48F76085822dC489F16`](https://bscscan.com/address/0xb7941CA8DB894178d415A48F76085822dC489F16)。AutoWithdraw业务owner可更换executor，绑定的Mining在初始化后固定。

## 商品购买与收益规则

每份「青之梅SOD酵素 12盒10支装」价格700 USDT，订单成功增加1,000个人算力。首次参与需绑定有效推荐关系，钱包的USDT授权与确认购买分别完成。

- 订单资金分为运营265 USDT、直推35 USDT及400 USDT兑换GPC，兑换所得全部进入Mining订单矿池。
- 推荐人未失活且有效个人算力至少35时，领取35 USDT并消耗35算力；不足时该35 USDT转运营，不扣剩余算力。
- 设当前有效个人算力为 `P`，团队去除最大直推分支后的算力为 `S`。静态收益的USDT值为 `P × 0.0035`；社区收益为 `min(S, 10P) × 0.0035 × 10%`。总毛收益最多为静态的2倍且不超过剩余个人算力，整数运算向下取整。
- 领取按毛收益USDT值消耗个人算力，并按Oracle价格换算GPC。合约将毛GPC的5%转技术钱包、95%发送领取用户；该规则不额外增加商品购买金额。
- 每24小时可手动领取一次，漏领天数不累计。购买重置领取冷却；在原周期内再次购买不延长180天失活起点，成功领取刷新该起点。算力归零后，新购买开始新周期。
- 单次毛领取上限为当前矿池GPC的1%；全局24小时窗口累计上限为窗口起点矿池的2%。报价、价格偏差、到期维护等条件不满足时交易回退。

推荐关系最多向上计算30层，订单间隔至少1分钟。再次购买需重新支付700 USDT，合约不提供内部复投或添加LP流程。

## 自动提现使用

自动提现是可选功能，手动领取始终保留。开启前请确认钱包连接正确的BSC网络与上表Mining、AutoWithdraw代理。

1. 在自动提现入口购买执行次数，每次为 **0.0005 BNB**，次数为整数且不可转让。支付用于购买次数，**购买本身不会授权代领**；为他人购买或管理员赠送次数也不会替该用户开启授权。
2. 用户另行确认开启，将Mining中的 `autoWithdrawDelegate` 设置为本项目AutoWithdraw代理。用户可随时暂停，撤销该授权。
3. 用户已授权、仍有次数，并在现有24小时领取冷却结束后再等10分钟，且 `checkAuto` 返回可执行时，指定executor可发起自动提现。授权本身不会重新开始24小时计时。
4. 只有成功结算正数净GPC才原子扣除1次。收益固定发送给该受益人，执行方不能更换收款人；失败交易和手动领取不扣自动次数。

`checkAuto`同时检查授权、次数、有效算力、失活状态、Mining是否暂停、History是否就绪、报价及矿池额度。它是执行前查询，交易仍须通过Mining全部保护。自动成功领取与手动领取采用相同收益、算力消耗和历史记录规则，并刷新下一次领取时间；手动领取后，自动提现也需等待新的冷却加10分钟。

主要接口：

| 合约 | 接口 | 说明 |
| --- | --- | --- |
| Mining | `placeOrder(deadline, userMinGpcOut)` | 支付商品订单 |
| Mining | `withdraw()` | 本人手动领取 |
| Mining | `setAutoWithdrawDelegate(delegate)` | 本人设置或撤销代领授权 |
| AutoWithdraw | `buyCredits(credits)` | 精确支付次数对应BNB，为本人购买 |
| AutoWithdraw | `buyFor(beneficiary, credits)` | 为指定用户购买，不代替其授权 |
| AutoWithdraw | `checkAuto(beneficiary)` | 查询当前自动提现资格 |
| AutoWithdraw | `execute(beneficiary)` | 仅executor可执行；成功事件含受益人、executor、净GPC及剩余次数 |

## 源码与编译

- `contracts/`：Solidity生产源码及接口。
- `abi/`：供应用集成使用的ABI。
- `addresses.json`：当前主网地址快照及治理角色。
- `hardhat.config.js`：与生产实现一致的编译参数，不配置网络账户。

使用Node.js 22.13或更新版本；构建依赖固定为Hardhat `2.28.6`、OpenZeppelin Contracts `4.9.6`及Contracts Upgradeable `4.9.6`。

```sh
npm ci
npm run compile
```

编译器为Solidity **0.8.21**，`viaIR: true`，优化器开启且 `runs: 100`，目标EVM为 **paris**。保留源码路径及这些设置，编译产物输出至 `artifacts/`。这些命令只编译源码，不部署合约。

## 链上源码查看

Mining和AutoWithdraw实现已完成BscScan源码验证：

- [Mining实现源码：0x3b7FfBDE40a975D3327939408C97a53BFa4fC901](https://bscscan.com/address/0x3b7FfBDE40a975D3327939408C97a53BFa4fC901#code)
- [AutoWithdraw实现源码：0xaC938A6B177E4843BaDCaB8abE5131821BFF7629](https://bscscan.com/address/0xaC938A6B177E4843BaDCaB8abE5131821BFF7629#code)
- [History实现浏览器入口：0xf51A4B17696c96C0A122AA6CAc0aCA8219a6E639](https://bscscan.com/address/0xf51A4B17696c96C0A122AA6CAc0aCA8219a6E639#code)

地址快照日期：2026-09-11。代理可由各自ProxyAdmin治理方升级，当前实现与权限以链上状态为准。
