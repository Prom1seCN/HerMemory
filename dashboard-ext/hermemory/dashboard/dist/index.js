(function () {
  var SDK = window.__HERMES_PLUGIN_SDK__;
  var React = SDK.React;
  var h = React.createElement;
  var C = SDK.components;
  var useState = SDK.hooks.useState;
  var useEffect = SDK.hooks.useEffect;

  function api(path, options) {
    return SDK.fetchJSON("/api/plugins/hermemory" + path, options);
  }

  function fmtSize(n) {
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  function MemoryCard() {
    var filesState = useState(null);
    var files = filesState[0], setFiles = filesState[1];
    var current = useState(null);
    var sel = current[0], setSel = current[1];
    var textState = useState("");
    var text = textState[0], setText = textState[1];
    var msgState = useState("");
    var msg = msgState[0], setMsg = msgState[1];

    function reload() {
      api("/files").then(function (r) { setFiles(r); }).catch(function (e) { setMsg(String(e)); });
    }
    useEffect(function () { reload(); }, []);

    function open(path) {
      api("/file?path=" + encodeURIComponent(path)).then(function (r) {
        setSel(r.path); setText(r.content); setMsg("");
      }).catch(function (e) { setMsg(String(e)); });
    }

    function save() {
      if (!sel) return;
      api("/file", { method: "POST", body: JSON.stringify({ path: sel, content: text }) })
        .then(function (r) { setMsg("已保存 " + r.path + "（" + r.bytes + " 字节，旧文件已备份）"); reload(); })
        .catch(function (e) { setMsg("保存失败：" + e); });
    }

    var list = h("div", { style: { maxHeight: 260, overflow: "auto", marginBottom: 12 } },
      files && files.files && files.files.length
        ? files.files.map(function (f) {
            var active = sel === f.path;
            return h("div", {
              key: f.path,
              onClick: function () { open(f.path); },
              style: {
                padding: "6px 8px", cursor: "pointer", borderRadius: 6,
                background: active ? "rgba(127,127,127,0.18)" : "transparent",
                display: "flex", justifyContent: "space-between", fontSize: 13,
              },
            }, h("span", null, f.path), h("span", { style: { opacity: 0.6 } }, fmtSize(f.size)));
          })
        : h("div", { style: { opacity: 0.6, fontSize: 13 } }, files ? "记忆库里还没有 .md 文件" : "加载中…"));

    var editor = sel ? h("div", null,
      h("div", { style: { fontSize: 13, marginBottom: 6 } }, "编辑：" + sel),
      h("textarea", {
        value: text,
        onChange: function (e) { setText(e.target.value); },
        spellCheck: false,
        style: {
          width: "100%", minHeight: 260, fontFamily: "ui-monospace, monospace", fontSize: 13,
          padding: 10, borderRadius: 8, border: "1px solid rgba(127,127,127,0.35)",
          background: "transparent", color: "inherit", resize: "vertical",
        },
      }),
      h("div", { style: { marginTop: 8, display: "flex", gap: 8, alignItems: "center" } },
        h(C.Button, { onClick: save }, "保存"),
        h(C.Button, { variant: "ghost", onClick: function () { setSel(null); setText(""); } }, "取消"),
        h("span", { style: { fontSize: 12, opacity: 0.75 } }, msg))) : null;

    return h(C.Card, null,
      h(C.CardHeader, null, h(C.CardTitle, null, "记忆库")),
      h(C.CardContent, null,
        h("div", { style: { fontSize: 12, opacity: 0.65, marginBottom: 8 } },
          files ? files.root + (files.exists ? "" : "（目录不存在）") : ""),
        list, editor));
  }

  function HealthCard() {
    var resState = useState(null);
    var res = resState[0], setRes = resState[1];
    var busy = useState(false);
    var running = busy[0], setRunning = busy[1];

    function run() {
      setRunning(true);
      api("/health").then(function (r) { setRes(r); })
        .catch(function (e) { setRes({ ok: false, checks: [{ name: "请求失败", ok: false, detail: String(e) }] }); })
        .then(function () { setRunning(false); });
    }
    useEffect(function () { run(); }, []);

    return h(C.Card, null,
      h(C.CardHeader, null,
        h(C.CardTitle, null, "体检"),
        res ? h(C.Badge, { style: { marginLeft: 8 } }, res.ok ? "全部通过" : "有问题") : null),
      h(C.CardContent, null,
        h(C.Button, { onClick: run, disabled: running }, running ? "检查中…" : "重新检查"),
        h("div", { style: { marginTop: 10 } },
          (res && res.checks ? res.checks : []).map(function (c, i) {
            return h("div", { key: i, style: { fontSize: 13, padding: "3px 0" } },
              h("span", { style: { color: c.ok ? "#16a34a" : "#dc2626", marginRight: 6 } }, c.ok ? "✓" : "✗"),
              c.name, c.detail ? h("span", { style: { opacity: 0.6, marginLeft: 8 } }, c.detail) : null);
          }))));
  }

  function ExportCard() {
    var outState = useState("");
    var out = outState[0], setOut = outState[1];
    var busy = useState(false);
    var running = busy[0], setRunning = busy[1];

    function doExport() {
      setRunning(true); setOut("打包中…");
      api("/export", { method: "POST" })
        .then(function (r) { setOut("已导出：" + r.path + "（" + fmtSize(r.size) + "）"); })
        .catch(function (e) { setOut("导出失败：" + e); })
        .then(function () { setRunning(false); });
    }

    return h(C.Card, null,
      h(C.CardHeader, null, h(C.CardTitle, null, "导出与搬家")),
      h(C.CardContent, null,
        h("div", { style: { fontSize: 13, opacity: 0.75, marginBottom: 10 } },
          "把记忆库与配置（自动剔除密钥）打成一个 zip，换机器或换 agent 都能接手。"),
        h(C.Button, { onClick: doExport, disabled: running }, running ? "导出中…" : "导出记忆库"),
        out ? h("div", { style: { marginTop: 10, fontSize: 12, wordBreak: "break-all" } }, out) : null));
  }

  function Page() {
    return h("div", { style: { display: "grid", gap: 16, padding: 4 } },
      h(MemoryCard, null),
      h("div", { style: { display: "grid", gap: 16, gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))" } },
        h(HealthCard, null),
        h(ExportCard, null)));
  }

  window.__HERMES_PLUGINS__.register("hermemory", Page);
})();
