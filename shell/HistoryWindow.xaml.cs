using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;

namespace HerMemory
{
    /// <summary>某个记忆文件的本地历史：列表 + 差异 + 回滚。</summary>
    public partial class HistoryWindow : Window
    {
        private readonly string _fileName;
        private List<MemoryHistory.Snapshot> _items = new();

        /// <summary>恢复成功后触发，编辑器据此重新载入当前文件。</summary>
        public event Action? Restored;

        public HistoryWindow(string fileName)
        {
            InitializeComponent();
            _fileName = fileName ?? "MEMORY.md";
            Title = "记忆历史 · " + _fileName;
            Loaded += (_, _) => Reload();
        }

        private void Reload()
        {
            Status.Text = "正在读取历史……";
            var file = _fileName;
            _ = System.Threading.Tasks.Task.Run(() =>
            {
                var list = MemoryHistory.Log(300);
                return list;
            }).ContinueWith(t =>
            {
                if (t.IsFaulted || t.Result == null) { Status.Text = "读取历史失败"; return; }
                _items = t.Result;
                SnapshotList.Items.Clear();
                if (_items.Count == 0)
                {
                    Status.Text = "还没有历史。保存一次文件，或点「立即快照」。";
                }
                else
                {
                    foreach (var s in _items) SnapshotList.Items.Add(s.Display);
                    Status.Text = $"共 {_items.Count} 个快照（本机保存，不随同步库走）";
                }
                DiffBox.Text = "";
                BtnRestore.IsEnabled = false;
            }, System.Threading.Tasks.TaskScheduler.FromCurrentSynchronizationContext());
        }

        private void SnapshotList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var idx = SnapshotList.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) { BtnRestore.IsEnabled = false; return; }
            var snap = _items[idx];
            BtnRestore.IsEnabled = true;
            DiffBox.Text = "读取中……";
            var file = _fileName;
            _ = System.Threading.Tasks.Task.Run(() => MemoryHistory.Diff(snap.Sha, file))
                .ContinueWith(t =>
                {
                    var text = t.IsFaulted || t.Result == null ? "读取失败" : t.Result;
                    DiffBox.Text = string.IsNullOrWhiteSpace(text)
                        ? "（该版本与当前内容相同）"
                        : text;
                    DiffBox.ScrollToHome();
                }, System.Threading.Tasks.TaskScheduler.FromCurrentSynchronizationContext());
        }

        private void BtnSnapshot_Click(object sender, RoutedEventArgs e)
        {
            BtnSnapshot.IsEnabled = false;
            Status.Text = "正在创建快照……";
            _ = System.Threading.Tasks.Task.Run(() => MemoryHistory.Commit("手动快照"))
                .ContinueWith(t =>
                {
                    var msg = t.IsFaulted || t.Result == default ? "快照失败" : t.Result.message;
                    Status.Text = msg;
                    BtnSnapshot.IsEnabled = true;
                    Reload();
                }, System.Threading.Tasks.TaskScheduler.FromCurrentSynchronizationContext());
        }

        private void BtnRestore_Click(object sender, RoutedEventArgs e)
        {
            var idx = SnapshotList.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) return;
            var snap = _items[idx];

            var ok = System.Windows.MessageBox.Show(this,
                $"把「{_fileName}」恢复成 {snap.Time:yyyy-MM-dd HH:mm:ss} 的版本？\n\n" +
                "当前内容会先记一条快照，所以恢复错了还能再回来。",
                "恢复记忆", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (ok != MessageBoxResult.Yes) return;

            BtnRestore.IsEnabled = false;
            Status.Text = "正在恢复……";
            var file = _fileName;
            _ = System.Threading.Tasks.Task.Run(() =>
            {
                // 先给当前状态留一条，恢复本身也可回滚
                MemoryHistory.Commit("恢复前快照：" + file);
                if (!MemoryHistory.RestoreFile(snap.Sha, file)) return (false, "恢复失败：该版本里没有这个文件");
                var c = MemoryHistory.Commit("恢复 " + file + " 到 " + snap.Time.ToString("yyyy-MM-dd HH:mm"));
                return (true, c.ok ? "已恢复" : "已恢复（但快照记录失败：" + c.message + "）");
            }).ContinueWith(t =>
            {
                if (t.IsFaulted) { Status.Text = "恢复异常"; BtnRestore.IsEnabled = true; return; }
                Status.Text = t.Result.Item2;
                if (t.Result.Item1)
                {
                    try { Restored?.Invoke(); } catch { }
                }
                else BtnRestore.IsEnabled = true;
                Reload();
            }, System.Threading.Tasks.TaskScheduler.FromCurrentSynchronizationContext());
        }
    }
}
