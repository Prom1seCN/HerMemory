# 一次性补丁第 2 轮：XAML 正式化（跑完即删）
import io

p = "MainWindow.xaml"
t = io.open(p, encoding="utf-8-sig").read()
pairs = (
    ('即将安装：Hermes 内核（约 5-10 分钟，需联网）+ 记忆库 + 微信接入。', '即将安装 Hermes 内核（约 5-10 分钟，需联网）、记忆库与微信接入。'),
    ('安装完成后，AI 直接出现在你的微信里；你的全部记忆是纯文本文件，随时可看可改可带走。', '安装完成后，AI 将接入微信；全部记忆为纯文本文件，可随时查看、修改与迁移。'),
    ('提示：符号链接步骤需要开发者模式或管理员权限（右键“以管理员身份运行”可免去设置）。', '符号链接需要开发者模式或管理员权限；以管理员身份运行可免去设置。'),
    ('注意：vault（你的文档与记忆）默认保留——那是你的资产，与本软件无关。', 'vault（文档与记忆）默认保留，不属于卸载范围。'),
    ('同时删除 vault（你的文档与记忆，全部抹除，不可恢复）', '同时删除 vault（文档与记忆，不可恢复）'),
    ('同时删除本程序文件（HerMemory.exe 自身）', '同时删除本程序文件（HerMemory.exe）'),
)
miss = []
for old, new in pairs:
    if old in t: t = t.replace(old, new, 1)
    else: miss.append(old[:20])
io.open(p, "w", encoding="utf-8-sig", newline="\n").write(t)
print(f"xaml OK（{len(pairs)-len(miss)}/{len(pairs)}；未命中: {miss if miss else '无'}）")
