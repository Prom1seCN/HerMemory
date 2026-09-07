# 一次性补丁：Home 状态文案 + 档位表格高亮 + 全库正式化（跑完即删）
import io, re

p = "MainWindow.xaml.cs"
t = io.open(p, encoding="utf-8-sig").read()
n0 = len(t)

# —— Home 状态文案（用户定稿） ——
old = '"● 运行中——AI 在线（微信可对话）"'
assert old in t; t = t.replace(old, '"Gateway 运行中——AI 在线"', 1)
old = '"○ 已停止——微信不响应，点启动即回来"'
assert old in t; t = t.replace(old, '"Gateway 已停止——AI 离线"', 1)
old = '"● 状态未知——点重启恢复"'
assert old in t; t = t.replace(old, '"Gateway 状态未知，请点重启"', 1)
old = 'HomeStatus.Text = (cmd == "stop" ? "正在停止" : "正在" + (cmd == "restart" ? "重启" : "启动")) + "……";'
assert old in t; t = t.replace(old, 'HomeStatus.Text = cmd == "stop" ? "正在停止…" : cmd == "restart" ? "正在重启…" : "正在启动…";', 1)

# —— 档位表高亮：UpdateHomeStatus 末尾追加深浅（当前档加粗青色） ——
old = '''            HomeHint.Text = state == "running"
                ? "改 vault\\\\HerMemory\\\\memory\\\\ 下的记忆文件后开新对话生效；改配置（API 地址/Key）需重启网关。"
                : "";'''
assert old in t, "hint anchor"
new = '''            HomeHint.Text = state == "running"
                ? "修改记忆文件后开启新对话生效；修改配置（API 地址、Key）后需重启网关。"
                : "";
            UpdateTierTable();'''
t = t.replace(old, new, 1)

# —— UpdateTierTable 方法（加在 UpdateHomeStatus 之后） ——
anchor = "        private bool _homeBusy;"
method = '''        private void UpdateTierTable()
        {
            var limit = "";
            try
            {
                var outp = HermesCtl.Run("config get memory.memory_char_limit", 20);
                var m = System.Text.RegularExpressions.Regex.Match(outp, @"(2200|5000|10000)");
                limit = m.Success ? m.Groups[1].Value : "";
            }
            catch { }
            var col = limit switch { "2200" => 1, "5000" => 2, "10000" => 3, _ => 0 };
            for (int i = 1; i <= 3; i++)
            {
                var on = i == col;
                var w = FindName("TierM" + i) as TextBlock; if (w != null) { w.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; w.Foreground = on ? Brush("#0E7490") : Brush("#546E7A"); }
                w = FindName("TierU" + i) as TextBlock; if (w != null) { w.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; w.Foreground = on ? Brush("#0E7490") : Brush("#546E7A"); }
            }
        }

        private bool _homeBusy;'''
assert anchor in t; t = t.replace(anchor, method, 1)

# —— 正式化全量替换 ——
pairs = (
    ('"正在检查环境……"', '"正在检查环境…"'),
    ('"即将安装：Hermes 内核（约 5-10 分钟，需联网）+ 记忆库 + 微信接入。"', '"即将安装 Hermes 内核（约 5-10 分钟，需联网）、记忆库与微信接入。"'),
    ('"安装完成后，AI 直接出现在你的微信里；你的全部记忆是纯文本文件，随时可看可改可带走。"', '"安装完成后，AI 将接入微信；全部记忆为纯文本文件，可随时查看、修改与迁移。"'),
    ('"提示：符号链接步骤需要开发者模式或管理员权限（右键“以管理员身份运行”可免去设置）。"', '"符号链接需要开发者模式或管理员权限；以管理员身份运行可免去设置。"'),
    ('"请先填写 API 地址与 API Key。"', '"请填写 API 地址与 API Key。"'),
    ('"获取成功：{ids.Count} 个可用模型，请选择默认模型。"', '"已获取 {ids.Count} 个可用模型，请选择默认模型。"'),
    ('"[{code}] 认证未通过——请检查 API Key。"', '"[{code}] 认证未通过，请检查 API Key。"'),
    ('"[连接超时] 无法连接该地址——检查网络，或关闭代理后重试。"', '"[连接超时] 无法连接该地址，请检查网络或代理设置。"'),
    ('"[{code}] 获取失败——请核对地址与 Key。"', '"[{code}] 获取失败，请核对地址与 Key。"'),
    ('"地址、Key、模型三项都填好才能继续。"', '"请完整填写地址与 Key，并选择模型。"'),
    ('"正在安装……（首次约 5-10 分钟）"', '"正在安装，首次约 5-10 分钟。"'),
    ('"已完成的步骤会自动跳过——修正后点“重新安装”即可续装。"', '"已完成步骤将自动跳过；排除问题后点击“重新安装”继续。"'),
    ('"正在拉起微信接入向导……浏览器将自动打开二维码页面。"', '"正在启动微信接入，浏览器将自动打开二维码页面。"'),
    ('"二维码已在浏览器打开——请用微信扫码并确认（约 8 分钟内有效）。"', '"二维码已在浏览器打开，请使用微信扫码确认（8 分钟内有效）。"'),
    ('"微信接入出错："', '"微信接入异常："'),
    ('"微信已连接：仅允许你的微信 ID（首条消息直达）。"', '"微信已连接，消息授权仅限当前微信 ID。"'),
    ('"安装 gateway 服务（约一两分钟）……"', '"正在安装 gateway 服务，约一两分钟。"'),
    ('"（gateway 计划任务未注册成功——不影响微信使用，可在托盘功能里补装）"', '"（gateway 计划任务未注册，不影响微信使用，可稍后补装）"'),
    ('"你的 HerMemory 已就绪。"', '"HerMemory 已就绪。"'),
    ('"① 打开微信，给它发第一句话——它会自我介绍并引导完成剩余部署。"', '"在微信发送首条消息，AI 将自我介绍并引导完成剩余部署。"'),
    ('"随时可重新接入：双击桌面的 gateway-run.bat，或在向导里重跑。"', '"可随时重新接入：运行 gateway-run.bat 或重新运行安装向导。"'),
    ('"注意：vault（你的文档与记忆）默认保留——那是你的资产，与本软件无关。"', '"vault（文档与记忆）默认保留，不属于卸载范围。"'),
    ('"同时删除 vault（你的文档与记忆，全部抹除，不可恢复）"', '"同时删除 vault（文档与记忆，不可恢复）"'),
    ('"同时删除本程序文件（HerMemory.exe 自身）"', '"同时删除本程序文件（HerMemory.exe）"'),
    ('"移除开机自启与偏好设置……"', '"移除自启项与偏好设置……"'),
    ('"最后确认：删除整个 vault？\\n\\n里面是你的全部文档与 AI 记忆，删除后不可恢复。"', '"最后确认：删除整个 vault？其中为全部文档与 AI 记忆，删除后不可恢复。"'),
    ('"卸载完成。已移除全部软件痕迹。"', '"卸载完成，已移除全部软件痕迹。"'),
    ('"记住我的选择，不再询问（可随时在托盘菜单改回）"', '"记住此选择，以后不再询问（可在托盘菜单修改）"'),
    ('"HerMemory 已在运行（看系统托盘）。"', '"HerMemory 已在运行（见系统托盘）。"'),
)
miss = []
for old, new in pairs:
    if old in t: t = t.replace(old, new, 1)
    else: miss.append(old[:30])
io.open(p, "w", encoding="utf-8-sig", newline="\n").write(t)
print(f"cs OK（替换 {len(pairs)-len(miss)}/{len(pairs)}；未命中: {miss if miss else '无'}）")
