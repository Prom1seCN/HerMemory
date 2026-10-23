using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace HerMemory
{
    /// <summary>
    /// 应用内嵌的 Markdown 编辑器：直接编辑 vault 里那五个记忆文件。
    ///
    /// 设计取舍：
    ///  · 只改 vault 里那份真文件——AI 是通过符号链接/junction 读它的，所以没有「两份要对齐」。
    ///  · 保存用「同目录临时文件 + 替换」，避免写到一半断电把记忆写坏；编码固定 UTF-8 无 BOM。
    ///  · 打开期间外部改动（AI 自己写记忆、你用别的编辑器改过）要能被发现：保存前比对
    ///    (长度, mtime)，不一致就先问，绝不静默覆盖别人的改动。
    ///  · 预览走 MarkdownPreview（本地渲染，零依赖、不联网）。
    /// </summary>
    public partial class MemoryEditorWindow : Window
    {
        private sealed class Entry : INotifyPropertyChanged
        {
            public string FilePath = "";
            public string Label = "";
            public int Budget;                 // 0 = 不限
            private string _display = "";
            public string Display
            {
                get => _display;
                set
                {
                    if (_display == value) return;
                    _display = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Display)));
                }
            }
            public event PropertyChangedEventHandler? PropertyChanged;
        }

        private readonly string _memoryDir;
        private readonly ObservableCollection<Entry> _entries = new();
        private readonly DispatcherTimer _previewTimer;
        private Entry? _current;
        private string? _stamp;               // 打开/保存时的 (长度:mtime)，用于发现外部改动
        private bool _dirty;
        private bool _suppress;               // 切换条目时抑制 SelectionChanged 的脏检查
        private bool _budgetsLoaded;

        public MemoryEditorWindow()
        {
            InitializeComponent();
            _memoryDir = AppPaths.VaultMemoryDir;

            _previewTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(260) };
            _previewTimer.Tick += (_, _) => { _previewTimer.Stop(); RenderPreview(); };

            FileList.DisplayMemberPath = nameof(Entry.Display);
            FileList.ItemsSource = _entries;
            BuildEntries();

            Loaded += OnLoaded;
            Closing += OnClosing;
        }

        // ================= 初始化 =================

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            FadeInWindow();
            Theme.ApplyTitleBar(this);
            if (_entries.Count > 0) FileList.SelectedIndex = 0;
            // 记忆预算要问一次 CLI（约 1 秒），放到后台，不挡窗口出现
            _ = System.Threading.Tasks.Task.Run(() =>
            {
                var mem = ParseLimit(HermesCtl.Run("config get memory.memory_char_limit", 20));
                var usr = ParseLimit(HermesCtl.Run("config get memory.user_char_limit", 20));
                Dispatcher.Invoke(() =>
                {
                    foreach (var en in _entries)
                    {
                        if (string.Equals(Path.GetFileName(en.FilePath), "MEMORY.md", StringComparison.OrdinalIgnoreCase)) en.Budget = mem;
                        else if (string.Equals(Path.GetFileName(en.FilePath), "USER.md", StringComparison.OrdinalIgnoreCase)) en.Budget = usr;
                        RefreshEntry(en);
                    }
                    _budgetsLoaded = true;
                    UpdateCountText();
                });
            });
        }

        private static int ParseLimit(string output)
        {
            var m = Regex.Match(output ?? "", @"(\d{2,7})");
            return m.Success ? int.Parse(m.Groups[1].Value) : 0;
        }

        private void BuildEntries()
        {
            var files = new[]
            {
                ("MEMORY.md", "长期记忆"),
                ("USER.md", "用户档案"),
                ("SOUL.md", "人格设定"),
                ("AGENTS.md", "行为准则"),
                ("AUTOMATION.md", "自动化登记"),
            };
            foreach (var (name, label) in files)
            {
                var en = new Entry
                {
                    FilePath = Path.Combine(_memoryDir, name),
                    Label = name + " · " + label,
                };
                RefreshEntry(en);
                _entries.Add(en);
            }
        }

        private void RefreshEntry(Entry en)
        {
            int chars = 0;
            try
            {
                if (File.Exists(en.FilePath)) chars = File.ReadAllText(en.FilePath).Length;
            }
            catch { }
            var text = en.Label + "  ·  " + chars + " 字";
            if (en.Budget > 0 && chars > en.Budget) text += "（超预算）";
            en.Display = text;
        }

        // ================= 选中 / 脏检查 =================

        private void FileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppress) return;
            var next = FileList.SelectedItem as Entry;
            if (next == null || ReferenceEquals(next, _current)) return;

            if (_dirty && _current != null)
            {
                var r = System.Windows.MessageBox.Show(this,
                    $"「{_current.Label}」有未保存的修改。要先保存吗？",
                    "编辑记忆", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Yes);
                if (r == MessageBoxResult.Cancel)
                {
                    // 撤销这次切换
                    _suppress = true;
                    FileList.SelectedItem = _current;
                    _suppress = false;
                    return;
                }
                if (r == MessageBoxResult.Yes && !Save(quiet: false))
                {
                    // 保存失败：列表已切到 next，但 _current 还是旧文件 —— 不回滚的话
                    // 接下来的编辑会写进旧文件，用户以为在改新文件。
                    _suppress = true;
                    FileList.SelectedItem = _current;
                    _suppress = false;
                    return;
                }
            }
            LoadEntry(next);
        }

        private void LoadEntry(Entry en)
        {
            _current = en;
            try
            {
                Editor.Text = File.Exists(en.FilePath) ? File.ReadAllText(en.FilePath) : "";
                _stamp = StampOf(en.FilePath);
                _dirty = false;
                SetSaveState("已打开", "#90A4AE");
            }
            catch (Exception ex)
            {
                Editor.Text = "";
                SetSaveState("读取失败：" + ex.Message, "#C62828");
            }
            Editor.CaretIndex = 0;
            StatusPath.Text = en.FilePath;
            UpdateCountText();
            RenderPreview();
        }

        private static string? StampOf(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var fi = new FileInfo(path);
                return fi.Length + ":" + fi.LastWriteTimeUtc.Ticks;
            }
            catch { return null; }
        }

        // ================= 编辑 / 保存 =================

        private void Editor_TextChanged(object sender, TextChangedEventArgs e)
        {
            _dirty = true;
            UpdateCountText();
            SetSaveState("未保存", "#EF6C00");
            _previewTimer.Stop();
            _previewTimer.Start();
        }

        private void Editor_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
        {
            if (e.Key == Key.S && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                e.Handled = true;
                Save(quiet: false);
            }
        }

        private void BtnSave_Click(object sender, RoutedEventArgs e) => Save(quiet: false);

        /// <summary>取消 = 放弃本次编辑并关窗。有未保存修改时先确认；
        /// 确认后把 _dirty 清掉，避免 Close() 触发 OnClosing 再问一次。</summary>
        private void BtnCancel_Click(object sender, RoutedEventArgs e)
        {
            if (_dirty)
            {
                var r = System.Windows.MessageBox.Show(this,
                    "放弃未保存的修改？", "编辑记忆",
                    MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
                if (r != MessageBoxResult.Yes) return;
                _dirty = false;
            }
            Close();
        }

        /// <summary>Esc 等同「取消」——对话框的通用习惯。</summary>
        private void Window_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            BtnCancel_Click(sender, e);
        }

        private bool Save(bool quiet)
        {
            if (_current == null) return false;
            var path = _current.FilePath;

            // 外部改动保护：打开后被 AI / 别的编辑器改过就先问，不静默覆盖
            var disk = StampOf(path);
            // _stamp == null 表示打开时文件还不存在（例如 AUTOMATION.md）；此后别的进程创建了它，
            // 也必须按"外部改动"处理，否则一次保存就把人家刚写的内容盖掉。
            if (!quiet && disk != null && disk != _stamp)
            {
                var r = System.Windows.MessageBox.Show(this,
                    "这个文件在打开之后被其他程序改过（可能是 AI 自己写的，或你用别的编辑器改过）。\n\n"
                    + "选「是」用自己的内容覆盖磁盘上的版本；选「否」放弃本次保存、重新载入磁盘版本。",
                    "文件已被外部修改", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
                if (r != MessageBoxResult.Yes)
                {
                    var en = _current;
                    if (en != null) LoadEntry(en);
                    return false;
                }
            }

            try
            {
                WriteAtomic(path, Editor.Text);
                _stamp = StampOf(path);
                _dirty = false;
                RefreshEntry(_current);
                UpdateCountText();
                SetSaveState("已保存 " + DateTime.Now.ToString("HH:mm:ss"), "#2E7D32");
                // 记忆时光机：后台记一条，不挡保存手感（失败也不影响文件已经写对了）
                var name = Path.GetFileName(path);
                _ = System.Threading.Tasks.Task.Run(() => MemoryHistory.Commit("编辑器保存：" + name));
                return true;
            }
            catch (Exception ex)
            {
                SetSaveState("保存失败：" + ex.Message, "#C62828");
                if (!quiet)
                    System.Windows.MessageBox.Show(this, "保存失败：" + ex.Message + "\n\n文件位置：" + path,
                        "编辑记忆", MessageBoxButton.OK, MessageBoxImage.Error);
                return false;
            }
        }

        /// <summary>同目录临时文件 + 原子替换：避免写到一半中断把记忆写坏。固定 UTF-8 无 BOM。</summary>
        private static void WriteAtomic(string path, string text)
        {
            var dir = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(dir)) throw new IOException("路径无效：" + path);
            Directory.CreateDirectory(dir);

            var tmp = Path.Combine(dir, "." + Path.GetFileName(path) + ".hm-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp");
            File.WriteAllBytes(tmp, new UTF8Encoding(false).GetBytes(text ?? ""));
            try
            {
                if (File.Exists(path))
                {
                    try { File.Replace(tmp, path, null, true); }
                    catch
                    {
                        // 同目录 rename 是原子的；绝不用 File.Copy 覆盖 —— 复制到一半断电/被杀
                        // 会在目标位置留下半截记忆文件，而 tmp 已被删，等于记忆被截断。
                        File.Move(tmp, path, true);
                    }
                }
                else File.Move(tmp, path);
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                throw;
            }
        }

        private void UpdateCountText()
        {
            if (_current == null) { CountText.Text = ""; return; }
            int chars = Editor.Text.Length;
            var text = chars + " 字符";
            if (_current.Budget > 0)
            {
                text += " / 预算 " + _current.Budget;
                if (chars > _current.Budget) text += "（超出 " + (chars - _current.Budget) + "）";
            }
            else if (!_budgetsLoaded)
            {
                text += "（预算读取中…）";
            }
            CountText.Text = text;
            CountText.Foreground = _current.Budget > 0 && chars > _current.Budget
                ? Brush("#C62828") : Brush("#78909C");
        }

        private void SetSaveState(string text, string color)
        {
            try
            {
                SaveState.Text = text;
                SaveState.Foreground = Brush(color);
            }
            catch { }
        }

        // ================= 预览 =================

        private void PreviewToggle_Click(object sender, RoutedEventArgs e)
        {
            var on = PreviewToggle.IsChecked == true;
            PreviewHost.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            PreviewSplitter.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            if (on) RenderPreview();
        }

        private void RenderPreview()
        {
            if (PreviewToggle.IsChecked != true) return;
            try { Preview.Document = MarkdownPreview.Render(Editor.Text, Theme.IsDark); }
            catch { }
        }

        private void BtnHistory_Click(object sender, RoutedEventArgs e)
        {
            if (_current == null) return;
            // 有未保存改动时，历史里看不到它们——先提醒保存，避免"恢复了却把刚写的弄丢"
            if (_dirty)
            {
                var r = System.Windows.MessageBox.Show(this,
                    "当前有未保存的修改。历史快照只包含已保存的内容，建议先保存再看历史。\n\n现在保存吗？",
                    "记忆历史", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Yes);
                // 取消或"不保存"都不进历史：历史窗口里一恢复就会用磁盘旧版覆盖编辑器，
                // 未保存的内容会静默消失。要看历史，先落盘。
                if (r != MessageBoxResult.Yes) return;
                if (!Save(quiet: false)) return;
            }
            try
            {
                var w = new HistoryWindow(Path.GetFileName(_current.FilePath)) { Owner = this };
                w.Restored += () =>
                {
                    var en = _current;
                    if (en != null) LoadEntry(en);
                };
                w.ShowDialog();
            }
            catch (Exception ex) { ReportError("打开记忆历史", ex); }
        }

        private void ReportError(string what, Exception ex)
        {
            try
            {
                System.Windows.MessageBox.Show(this, what + "失败：" + ex.Message, "编辑记忆",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
            catch { }
        }

        private void BtnReveal_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var target = _current?.FilePath ?? _memoryDir;
                if (File.Exists(target))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{target}\"") { UseShellExecute = true });
                else if (Directory.Exists(_memoryDir))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{_memoryDir}\"") { UseShellExecute = true });
            }
            catch { }
        }

        // ================= 关闭 =================

        private void OnClosing(object? sender, CancelEventArgs e)
        {
            if (!_dirty) return;
            var r = System.Windows.MessageBox.Show(this,
                "还有未保存的修改，要保存吗？",
                "编辑记忆", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.Yes);
            if (r == MessageBoxResult.Cancel) { e.Cancel = true; return; }
            if (r == MessageBoxResult.Yes && !Save(quiet: false)) e.Cancel = true;
        }

        /// <summary>窗口淡入：260ms 内从 0 到 1，并轻微上浮。
        /// 编辑器是"点一下就弹出来"的窗口，直接出现会有硬切感。</summary>
        private void FadeInWindow()
        {
            Root.Opacity = 0;
            var tt = new System.Windows.Media.TranslateTransform(0, 8);
            Root.RenderTransform = tt;
            var ease = new System.Windows.Media.Animation.CubicEase
            {
                EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut,
            };
            Root.BeginAnimation(OpacityProperty,
                new System.Windows.Media.Animation.DoubleAnimation(0, 1,
                    new Duration(TimeSpan.FromMilliseconds(240))) { EasingFunction = ease });
            tt.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty,
                new System.Windows.Media.Animation.DoubleAnimation(8, 0,
                    new Duration(TimeSpan.FromMilliseconds(320))) { EasingFunction = ease });
        }

        private static System.Windows.Media.Brush Res(string key) =>
            System.Windows.Application.Current?.Resources[key] as System.Windows.Media.Brush
            ?? System.Windows.Media.Brushes.Gray;

        /// <summary>语义色折到主题令牌（深色下 #C62828 这类深红看不清）。</summary>
        private static System.Windows.Media.Brush Brush(string hex) => hex switch
        {
            "#C62828" => Res("Danger"),
            "#2E7D32" => Res("Success"),
            "#EF6C00" => Res("Warn"),
            "#90A4AE" or "#78909C" or "#B0BEC5" => Res("Subtle"),
            "#546E7A" or "#455A64" or "#37474F" => Res("Muted"),
            _ => new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex)),
        };
    }
}
