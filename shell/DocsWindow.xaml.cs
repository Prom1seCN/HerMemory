using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace HerMemory
{
    /// <summary>
    /// 内嵌的使用说明阅读器：左侧目录、右侧 Markdown 渲染，复用编辑记忆那套
    /// <see cref="MarkdownPreview"/>，所以两处的排版、代码块、表格观感一致。
    ///
    /// 只读——说明文档不是记忆，没有编辑入口，避免用户顺手改坏随包文档。
    /// </summary>
    public partial class DocsWindow : Window
    {
        private static DocsWindow? _open;

        private sealed class Item
        {
            public string Title = "";
            public string Path = "";
            public override string ToString() => Title;
        }

        /// <summary>文档的中文名与展示顺序。表里没有的文件按文件名追加在后面，
        /// 这样新增文档不需要改代码，也不会因为漏登记而消失。</summary>
        private static readonly (string File, string Title)[] Known =
        {
            ("GUIDE.md", "使用指南"),
            ("ONBOARDING.md", "初次部署"),
            ("COMMANDS.md", "常用命令"),
            ("GET-API-KEY.md", "获取 API Key"),
            ("INSTALL.md", "安装说明"),
            ("INSTALL_TIPS.md", "安装提示"),
            ("LINUX.md", "Linux 部署"),
            ("README_REBORN.md", "导出与重生"),
            ("BETA.md", "测试说明"),
        };

        public static void Open(Window? owner)
        {
            if (_open != null) { try { _open.Activate(); } catch { } return; }
            _open = new DocsWindow();
            try { if (owner != null && owner.IsVisible) _open.Owner = owner; } catch { }
            _open.Closed += (_, _) => _open = null;
            _open.Show();
        }

        public DocsWindow()
        {
            InitializeComponent();
            Loaded += (_, _) => LoadDocs();
        }

        private void LoadDocs()
        {
            var items = new List<Item>();
            try
            {
                var dir = AppPaths.VaultDocsDir;
                if (!Directory.Exists(dir))
                {
                    var alt = Path.Combine(AppContext.BaseDirectory, "docs");
                    if (Directory.Exists(alt)) dir = alt;
                }
                if (!Directory.Exists(dir)) return;

                var byName = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var f in Directory.GetFiles(dir, "*.md"))
                    byName[Path.GetFileName(f)] = f;

                foreach (var (file, title) in Known)
                {
                    if (byName.TryGetValue(file, out var full))
                    {
                        items.Add(new Item { Title = title, Path = full });
                        byName.Remove(file);
                    }
                }
                foreach (var kv in byName.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase))
                    items.Add(new Item { Title = Path.GetFileNameWithoutExtension(kv.Key), Path = kv.Value });
            }
            catch { }

            DocList.ItemsSource = items;
            if (items.Count > 0) DocList.SelectedIndex = 0;
            else Preview.Document = MarkdownPreview.Render("# 没有找到使用说明\n\n文档目录为空。", Theme.IsDark);
        }

        private void DocList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (DocList.SelectedItem is not Item item) return;
            try
            {
                var text = File.ReadAllText(item.Path, System.Text.Encoding.UTF8);
                Preview.Document = MarkdownPreview.Render(text, Theme.IsDark);
            }
            catch (Exception ex)
            {
                Preview.Document = MarkdownPreview.Render("# 读取失败\n\n" + ex.Message, Theme.IsDark);
            }
        }
    }
}
