#requires -Version 5.1
<#
  HerMemory 隐私闸门 —— 「随包源码里不得出现构建机用户名」。

  起因为一次真实事故：install.ps1 的注释里写进了「异机实录」的 HERMES_HOME 示例路径，
  而那个路径含构建者姓名的缩写（他自己起的一个目录名）。注释被嵌进 install.ps1 → 装进 Setup.exe
  → 用户装完在日志里看到它。**注释也是要发行的一部分**，所以这道闸门是为了不再靠人记得。

  判据刻意**不把黑名单写进仓库**（把姓名写进黑名单是同一类泄漏），改用一条通用不变量：
    随包/随仓库分发的源文件里，不得出现**构建机用户名**。
  它同时覆盖两种情况：① 直接写出的 Windows 用户目录路径；② 用户自己起的、含姓名缩写的目录名。
  机器无关（换台机器构建，判据自动换），也不需要维护。

  用法（库文件，只定义函数、无副作用）：
    . .\scripts\check-privacy.ps1
    Test-PrivacyGate -Root D:\Projects\HerMemory     # 返回命中列表；已打印报告，未抛错

  已知边界：用户名是很短的常见词（user / admin / test 之类）时无法与正常文本区分，故设长度下限
  与停用词表；命中即报，构建脚本据此中止，另有 -SkipPrivacyGate 逃生口。
#>

function Test-PrivacyGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$NoFail          # 只报告不抛错（供测试/试运行）
    )

    # 这些当成"不是个人信息"：CI 与常见默认账号名。长于 3 个字母的通用词也在此列。
    $stop = @(
        'user','users','admin','administrator','guest','owner','default','public','test','tester',
        'dev','developer','root','local','system','win','windows','pc','home','main','work','build',
        'runner','ubuntu','appveyor','circleci','vagrant','codespace','vscode','posix','nt','azure'
    )

    $names = @()
    foreach ($raw in @($env:USERNAME, $env:USER, $env:LOGNAME)) {
        if (-not $raw) { continue }
        $n = ($raw -split '[\\/]')[-1].Trim()          # 域账号形如 DOMAIN\name
        if ($n.Length -lt 3) { continue }
        if ($stop -contains $n.ToLower()) { continue }
        $names += $n
    }
    $names = @($names | Select-Object -Unique)

    if ($names.Count -eq 0) {
        Write-Host "  跳过：本机用户名过短，或是常见词，无法作为判据。" -ForegroundColor DarkGray
        return @()
    }

    # 扫描范围 = 「会进产物或会随仓库分发」的源码；不含 build/、obj/、bin/、.workbuddy/（本地笔记）
    $targets = @(
        "install.ps1","install.sh","install.bat","gateway-run.bat","export.sh","memory-size.sh",
        "build-offline.ps1","build-release.ps1","README.md","LICENSE","shell","memory","skins","docs","scripts"
    ) | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }

    $exts = @('.ps1','.sh','.bat','.cmd','.cs','.xaml','.csproj','.md','.json','.yaml','.yml','.txt','.vbs','.config')
    $files = foreach ($t in $targets) {
        if ((Get-Item $t).PSIsContainer) {
            Get-ChildItem $t -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $exts -contains $_.Extension.ToLower() -and $_.FullName -notmatch '\\(obj|bin)\\' }
        } else { Get-Item $t }
    }
    $files = @($files)

    $hits = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        foreach ($n in $names) {
            $m = Select-String -Path $f.FullName -Pattern $n -SimpleMatch -CaseSensitive:$false -ErrorAction SilentlyContinue
            foreach ($x in $m) {
                [void]$hits.Add([pscustomobject]@{
                    File  = $f.FullName.Substring($Root.Length).TrimStart('\')
                    Line  = $x.LineNumber
                    Token = $n
                    Text  = $x.Line.Trim()
                })
            }
        }
    }

    Write-Host ("  扫描 {0} 个文件；判据用户名 {1} 个：{2}" -f $files.Count, $names.Count, ($names -join ', '))

    if ($hits.Count -eq 0) { Write-Host "  通过。" -ForegroundColor Green; return @() }

    Write-Host ("  命中 {0} 处：" -f $hits.Count) -ForegroundColor Red
    foreach ($h in $hits) {
        Write-Host ("    {0}:{1}" -f $h.File, $h.Line) -ForegroundColor Red
        Write-Host ("        {0}" -f $h.Text) -ForegroundColor DarkRed
    }

    if (-not $NoFail) {
        throw ("隐私闸门未通过：随包源码里出现了构建机用户名（见上）。`n" +
               "  多半是把本机路径当示例写进了注释或文档。改成中性示例（如 D:\apps\HerMemory）" +
               "或占位符（%LOCALAPPDATA%）。`n" +
               "  提醒：注释也是发行内容——它会被嵌进 install.ps1 / exe，用户看得到。`n" +
               "  确认是误报时可用 -SkipPrivacyGate 跳过本次构建。")
    }
    return $hits
}
