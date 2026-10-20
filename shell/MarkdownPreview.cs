using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace HerMemory
{
    /// <summary>
    /// 极简 Markdown → FlowDocument（零依赖，不联网，不装任何包）。
    ///
    /// 为什么不用 Markdig/WebView2：Markdig 只出 HTML，要在 WPF 里显示 HTML 得带一个浏览器
    /// 内核（WebView2 运行时并非每台机器都有）；本项目坚持「单文件 exe、装完即用」，所以
    /// 用 WPF 自带的 FlowDocument 做一个够用的子集：
    ///   标题 / 段落 / 无序·有序列表（两级）/ 引用 / 分隔线 / 围栏代码 / 表格 /
    ///   行内 **粗体** *斜体* `代码` ~~删除线~~ [链接](url)
    /// 解析不出的一律按普通段落渲染——预览只是辅助，不能因为一段怪文本就报错。
    /// </summary>
    internal static class MarkdownPreview
    {
        public static FlowDocument Render(string markdown, bool dark)
        {
            var ink = dark ? Hex("#E6EDF3") : Hex("#0F172A");
            var muted = dark ? Hex("#8B949E") : Hex("#64748B");
            var accent = dark ? Hex("#22D3EE") : Hex("#0891B2");
            var codeBg = dark ? Hex("#1B2127") : Hex("#F1F5F9");
            var rule = dark ? Hex("#30363D") : Hex("#E2E8F0");

            var doc = new FlowDocument
            {
                PagePadding = new Thickness(4, 0, 12, 24),
                FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI"),
                FontSize = 13.5,
                Foreground = new SolidColorBrush(ink),
                Background = Brushes.Transparent,
                ColumnWidth = double.PositiveInfinity,
            };

            if (string.IsNullOrEmpty(markdown))
            {
                doc.Blocks.Add(Note("（空文件）", muted));
                return doc;
            }

            var lines = markdown.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            var context = new Ctx(ink, muted, accent, codeBg, rule, dark);

            int i = 0;
            while (i < lines.Length)
            {
                var line = lines[i];

                // 围栏代码块：```lang ... ```
                var fence = FenceOf(line);
                if (fence != null)
                {
                    i++;
                    var sb = new StringBuilder();
                    while (i < lines.Length && FenceOf(lines[i]) == null)
                    {
                        sb.AppendLine(lines[i]);
                        i++;
                    }
                    if (i < lines.Length) i++; // 吃掉收尾围栏
                    doc.Blocks.Add(CodeBlock(sb.ToString(), context));
                    continue;
                }

                if (line.Trim().Length == 0) { i++; continue; }

                // 分隔线
                if (IsRule(line))
                {
                    doc.Blocks.Add(new Paragraph(new Run(" "))
                    {
                        Margin = new Thickness(0, 10, 0, 10),
                        BorderBrush = new SolidColorBrush(rule),
                        BorderThickness = new Thickness(0, 1, 0, 0),
                        FontSize = 1,
                    });
                    i++;
                    continue;
                }

                // 标题
                var heading = HeadingOf(line);
                if (heading != null)
                {
                    var (level, text) = heading.Value;
                    var p = new Paragraph { Margin = new Thickness(0, level <= 2 ? 16 : 12, 0, 6) };
                    p.Inlines.AddRange(InlinesOf(text, context, accent,
                        size: level == 1 ? 22 : level == 2 ? 18 : level == 3 ? 16 : 14.5,
                        weight: level <= 2 ? FontWeights.Bold : FontWeights.SemiBold));
                    if (level == 1)
                    {
                        p.BorderBrush = new SolidColorBrush(rule);
                        p.BorderThickness = new Thickness(0, 0, 0, 1);
                        p.Padding = new Thickness(0, 0, 0, 4);
                    }
                    doc.Blocks.Add(p);
                    i++;
                    continue;
                }

                // 表格：本行含 | 且下一行是分隔行
                if (line.Contains("|") && i + 1 < lines.Length && IsTableSeparator(lines[i + 1]))
                {
                    i = AppendTable(doc, lines, i, context);
                    continue;
                }

                // 引用
                if (line.TrimStart().StartsWith(">", StringComparison.Ordinal))
                {
                    var sb = new StringBuilder();
                    while (i < lines.Length && lines[i].TrimStart().StartsWith(">", StringComparison.Ordinal))
                    {
                        var t = lines[i].TrimStart().Substring(1);
                        sb.AppendLine(t.StartsWith(" ", StringComparison.Ordinal) ? t.Substring(1) : t);
                        i++;
                    }
                    var p = new Paragraph { Margin = new Thickness(0, 4, 0, 8), Padding = new Thickness(10, 2, 6, 2) };
                    p.BorderBrush = new SolidColorBrush(accent);
                    p.BorderThickness = new Thickness(3, 0, 0, 0);
                    p.Inlines.AddRange(InlinesOf(sb.ToString().TrimEnd(), context, muted, size: 13.5, weight: FontWeights.Normal));
                    doc.Blocks.Add(p);
                    continue;
                }

                // 列表（含两级缩进）
                var bullet = ListItemOf(line);
                if (bullet != null)
                {
                    doc.Blocks.Add(AppendList(lines, ref i, context));
                    continue;
                }

                // 普通段落：连到下一空行/下一个块级标记为止
                var para = new StringBuilder();
                while (i < lines.Length && lines[i].Trim().Length > 0
                       && FenceOf(lines[i]) == null && HeadingOf(lines[i]) == null
                       && !IsRule(lines[i]) && !lines[i].TrimStart().StartsWith(">", StringComparison.Ordinal)
                       && ListItemOf(lines[i]) == null)
                {
                    if (para.Length > 0) para.Append('\n');
                    para.Append(lines[i].Trim());
                    i++;
                }
                var para2 = new Paragraph { Margin = new Thickness(0, 3, 0, 7), LineHeight = 20 };
                para2.Inlines.AddRange(InlinesOf(para.ToString(), context, ink, 13.5, FontWeights.Normal));
                doc.Blocks.Add(para2);
            }

            return doc;
        }

        // ================= 块级 =================

        private sealed class Ctx
        {
            public readonly Color Ink, Muted, Accent, CodeBg, Rule;
            public readonly bool Dark;
            public Ctx(Color ink, Color muted, Color accent, Color codeBg, Color rule, bool dark)
            { Ink = ink; Muted = muted; Accent = accent; CodeBg = codeBg; Rule = rule; Dark = dark; }
        }

        private static Block Note(string text, Color color) => new Paragraph(new Run(text))
        {
            Foreground = new SolidColorBrush(color),
            Margin = new Thickness(0, 8, 0, 8),
        };

        private static string? FenceOf(string line)
        {
            var t = line.TrimStart();
            if (t.StartsWith("```", StringComparison.Ordinal) || t.StartsWith("~~~", StringComparison.Ordinal))
                return t.Substring(3).Trim();
            return null;
        }

        private static bool IsRule(string line)
        {
            var t = line.Trim();
            if (t.Length < 3) return false;
            if (t.StartsWith("- ", StringComparison.Ordinal) || t.StartsWith("* ", StringComparison.Ordinal)
                || t.StartsWith("+ ", StringComparison.Ordinal)) return false;
            foreach (var c in t)
                if (c != '-' && c != '*' && c != '_' && c != ' ') return false;
            return t.Replace(" ", "").Length >= 3;
        }

        private static (int level, string text)? HeadingOf(string line)
        {
            int n = 0;
            while (n < line.Length && line[n] == '#') n++;
            if (n < 1 || n > 6) return null;
            if (n < line.Length && line[n] != ' ' && line[n] != '\t') return null;
            var text = line.Substring(Math.Min(n, line.Length)).Trim();
            if (text.Length == 0) return null;
            // 去掉结尾的闭合 #（"## 标题 ##"）
            text = text.TrimEnd('#').TrimEnd();
            return (n, text);
        }

        private static bool IsTableSeparator(string line)
        {
            var t = line.Trim();
            if (!t.Contains("-", StringComparison.Ordinal)) return false;
            foreach (var c in t)
                if (c != '|' && c != '-' && c != ':' && c != ' ') return false;
            return t.Contains("|", StringComparison.Ordinal);
        }

        private static (bool ordered, int level, string text)? ListItemOf(string line)
        {
            int spaces = 0;
            while (spaces < line.Length && line[spaces] == ' ') spaces++;
            var rest = line.Substring(spaces);
            if (rest.Length == 0) return null;

            if (rest.Length >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ')
                return (false, Math.Min(spaces / 2, 3), rest.Substring(2).Trim());

            int d = 0;
            while (d < rest.Length && char.IsDigit(rest[d])) d++;
            if (d > 0 && d <= 3 && d + 1 < rest.Length && (rest[d] == '.' || rest[d] == ')') && rest[d + 1] == ' ')
                return (true, Math.Min(spaces / 2, 3), rest.Substring(d + 2).Trim());

            return null;
        }

        private static System.Windows.Documents.List AppendList(string[] lines, ref int i, Ctx ctx)
        {
            var list = new System.Windows.Documents.List
            {
                MarkerStyle = TextMarkerStyle.Disc,
                Margin = new Thickness(0, 3, 0, 8),
                Padding = new Thickness(0, 0, 0, 0),
            };
            var baseOrdered = false;
            while (i < lines.Length)
            {
                var item = ListItemOf(lines[i]);
                if (item == null) break;
                var (ordered, level, text) = item.Value;
                if (list.ListItems.Count == 0) baseOrdered = ordered;
                if (ordered != baseOrdered) break;   // 有序/无序切换就另起一个列表

                var p = new Paragraph { Margin = new Thickness(0, 1, 0, 1) };
                p.Inlines.AddRange(InlinesOf(text, ctx, ctx.Ink, 13.5, FontWeights.Normal));
                var li = new ListItem(p);
                if (level > 0) li.Margin = new Thickness(level * 16, 0, 0, 0);
                list.ListItems.Add(li);
                i++;
            }
            list.MarkerStyle = baseOrdered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc;
            return list;
        }

        private static int AppendTable(BlockCollection blocks, string[] lines, int start, Ctx ctx)
        {
            var header = SplitRow(lines[start]);
            int i = start + 2;
            var body = new List<string[]>();
            while (i < lines.Length && lines[i].Contains("|", StringComparison.Ordinal) && lines[i].Trim().Length > 0)
            {
                body.Add(SplitRow(lines[i]));
                i++;
            }

            var table = new Table { CellSpacing = 0, Margin = new Thickness(0, 6, 0, 10) };
            int cols = Math.Max(1, header.Length);
            for (int c = 0; c < cols; c++) table.Columns.Add(new TableColumn());
            var group = new TableRowGroup();

            var headRow = new TableRow { Background = new SolidColorBrush(ctx.Dark ? Hex("#161B22") : Hex("#F8FAFC")) };
            for (int c = 0; c < cols; c++)
            {
                var cell = new TableCell(new Paragraph(new Run(c < header.Length ? header[c] : ""))
                {
                    Margin = new Thickness(0),
                    FontWeight = FontWeights.SemiBold,
                    FontSize = 12.5,
                })
                { Padding = new Thickness(8, 5, 8, 5), BorderBrush = new SolidColorBrush(ctx.Rule), BorderThickness = new Thickness(0, 0, 0, 1) };
                headRow.Cells.Add(cell);
            }
            group.Rows.Add(headRow);

            foreach (var row in body)
            {
                var tr = new TableRow();
                for (int c = 0; c < cols; c++)
                {
                    var p = new Paragraph { Margin = new Thickness(0), FontSize = 12.5 };
                    p.Inlines.AddRange(InlinesOf(c < row.Length ? row[c] : "", ctx, ctx.Ink, 12.5, FontWeights.Normal));
                    tr.Cells.Add(new TableCell(p)
                    {
                        Padding = new Thickness(8, 5, 8, 5),
                        BorderBrush = new SolidColorBrush(ctx.Rule),
                        BorderThickness = new Thickness(0, 0, 0, 1),
                    });
                }
                group.Rows.Add(tr);
            }
            table.RowGroups.Add(group);
            blocks.Add(table);
            return i;
        }

        private static string[] SplitRow(string line)
        {
            var t = line.Trim();
            if (t.StartsWith("|", StringComparison.Ordinal)) t = t.Substring(1);
            if (t.EndsWith("|", StringComparison.Ordinal)) t = t.Substring(0, t.Length - 1);
            var parts = t.Split('|');
            for (int i = 0; i < parts.Length; i++) parts[i] = parts[i].Trim();
            return parts;
        }

        private static Block CodeBlock(string code, Ctx ctx)
        {
            var p = new Paragraph
            {
                FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
                FontSize = 12.5,
                Margin = new Thickness(0, 6, 0, 10),
                Padding = new Thickness(12, 8, 12, 8),
                Background = new SolidColorBrush(ctx.CodeBg),
                LineHeight = 18,
            };
            p.Inlines.Add(new Run(code.TrimEnd('\n')));
            return p;
        }

        // ================= 行内 =================

        private static IEnumerable<System.Windows.Documents.Inline> InlinesOf(string text, Ctx ctx, Color color, double size, FontWeight weight)
        {
            var runs = new List<Inline>();
            if (string.IsNullOrEmpty(text)) { runs.Add(new Run("")); return runs; }

            var plain = new StringBuilder();
            int i = 0;

            void Flush()
            {
                if (plain.Length == 0) return;
                runs.Add(new Run(plain.ToString())
                {
                    Foreground = new SolidColorBrush(color),
                    FontSize = size,
                    FontWeight = weight,
                });
                plain.Clear();
            }

            while (i < text.Length)
            {
                char c = text[i];

                // 行内代码
                if (c == '`')
                {
                    int end = text.IndexOf('`', i + 1);
                    if (end > i + 1)
                    {
                        Flush();
                        var code = text.Substring(i + 1, end - i - 1);
                        runs.Add(new Run(" " + code + " ")
                        {
                            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
                            FontSize = size - 0.5,
                            Background = new SolidColorBrush(ctx.CodeBg),
                            Foreground = new SolidColorBrush(ctx.Dark ? Hex("#7EE787") : Hex("#0F766E")),
                        });
                        i = end + 1;
                        continue;
                    }
                }

                // 链接 [文本](地址)
                if (c == '[')
                {
                    int close = text.IndexOf("](", i + 1, StringComparison.Ordinal);
                    if (close > i)
                    {
                        int end = text.IndexOf(')', close + 2);
                        if (end > close)
                        {
                            Flush();
                            var label = text.Substring(i + 1, close - i - 1);
                            var url = text.Substring(close + 2, end - close - 2).Trim();
                            var link = new Hyperlink(new Run(string.IsNullOrEmpty(label) ? url : label))
                            {
                                Foreground = new SolidColorBrush(ctx.Accent),
                                TextDecorations = null,
                                ToolTip = url,
                            };
                            var target = url;
                            link.Click += (_, _) => OpenUrl(target);
                            runs.Add(link);
                            i = end + 1;
                            continue;
                        }
                    }
                }

                // 粗体 / 删除线
                if (i + 1 < text.Length && (text.Substring(i, 2) == "**" || text.Substring(i, 2) == "~~"))
                {
                    var mark = text.Substring(i, 2);
                    int end = text.IndexOf(mark, i + 2, StringComparison.Ordinal);
                    if (end > i + 2 - 1 && end > i + 1)
                    {
                        Flush();
                        var inner = text.Substring(i + 2, end - i - 2);
                        runs.Add(new Run(inner)
                        {
                            Foreground = new SolidColorBrush(color),
                            FontSize = size,
                            FontWeight = mark == "**" ? FontWeights.Bold : weight,
                            TextDecorations = mark == "~~" ? TextDecorations.Strikethrough : null,
                        });
                        i = end + 2;
                        continue;
                    }
                }

                plain.Append(c);
                i++;
            }

            Flush();
            return runs;
        }

        private static void OpenUrl(string url)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(url)) return;
                if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return;
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch { }
        }

        private static System.Windows.Media.Color Hex(string hex) => (Color)ColorConverter.ConvertFromString(hex);
    }
}
