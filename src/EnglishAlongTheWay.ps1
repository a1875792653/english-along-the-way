$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir = Join-Path $projectRoot 'data'
$appTitle = -join ([char[]](0x987A,0x4FBF,0x5B66,0x82F1,0x8BED))
$dictionaryPath = Join-Path $dataDir 'dictionary-en.tsv'
$dictionaryOwner = 'qing' + 'jian-team'
$dictionaryRepo = 'qing' + 'jian'
$dictionaryRevision = '7a2ccc769183403de4c8ccfd8fbd72fc96ed9579'
$dictionaryUrl = "https://raw.githubusercontent.com/$dictionaryOwner/$dictionaryRepo/$dictionaryRevision/assets/glossary/glossary-en.tsv"

if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir | Out-Null
}

if (-not (Test-Path $dictionaryPath)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $dictionaryUrl -OutFile $dictionaryPath
    }
    catch {
        $nl = [Environment]::NewLine
        [System.Windows.Forms.MessageBox]::Show(
            "First-run dictionary download failed." + $nl + $nl + $_.Exception.Message + $nl + $nl + "Source URL:" + $nl + $dictionaryUrl + $nl + $nl + "Save as:" + $nl + $dictionaryPath,
            $appTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace EnglishAlongTheWay
{
    internal static class NativeMethods
    {
        internal const int WM_HOTKEY = 0x0312;
        internal const uint MOD_ALT = 0x0001;
        internal const uint MOD_CONTROL = 0x0002;
        internal const int VK_SPACE = 0x20;

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, int vk);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);
    }

    internal sealed class MainForm : Form
    {
        private const int HotkeyId = 0x5342;
        private const string ForcedSingles = "\u6211\u4f60\u4ed6\u5979\u5b83\u4eec\u60f3\u8981\u53bb\u6765\u5728\u6709\u662f\u7684\u4e86\u548c\u4e0e\u628a\u88ab\u7ed9\u8ba9\u4f1a\u80fd\u4e0d\u5f88\u518d\u4e5f\u90fd\u5c31\u8fd8\u5417\u5462\u5427";

        private readonly Dictionary<string, string> _dictionary;
        private readonly TextBox _input;
        private readonly Label _sentenceValue;
        private readonly RichTextBox _words;
        private readonly Label _onlineStatus;
        private readonly NotifyIcon _tray;
        private readonly System.Windows.Forms.Timer _translationTimer;
        private IntPtr _targetWindow = IntPtr.Zero;
        private bool _hotkeyRegistered;
        private bool _hasPositioned;
        private int _translationSerial;

        internal MainForm(string dictionaryPath)
        {
            _dictionary = LoadDictionary(dictionaryPath);

            Text = "\u987a\u4fbf\u5b66\u82f1\u8bed  \u00b7  v0.3.2";
            FormBorderStyle = FormBorderStyle.SizableToolWindow;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.FromArgb(248, 249, 251);
            Width = 670;
            Height = 350;
            MinimumSize = new Size(520, 300);
            Padding = new Padding(18, 14, 18, 12);
            KeyPreview = true;

            var title = new Label {
                Text = "\u987a\u4fbf\u5b66\u82f1\u8bed  \u00b7  v0.3.2",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(82, 89, 99),
                AutoSize = true,
                Location = new Point(18, 12),
                Anchor = AnchorStyles.Top | AnchorStyles.Left
            };
            Controls.Add(title);

            _onlineStatus = new Label {
                Text = "\u6574\u53e5\uff1a\u8054\u7f51   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730",
                Font = new Font("Segoe UI", 8.5f),
                ForeColor = Color.FromArgb(125, 130, 138),
                AutoSize = true,
                Location = new Point(430, 14),
                Anchor = AnchorStyles.Top | AnchorStyles.Right
            };
            Controls.Add(_onlineStatus);

            _input = new TextBox {
                BorderStyle = BorderStyle.FixedSingle,
                Font = PickFont(17.0f, FontStyle.Regular),
                Location = new Point(18, 38),
                Width = 634,
                Height = 39,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                ImeMode = ImeMode.On
            };
            _input.TextChanged += delegate { OnTextChanged(); };
            Controls.Add(_input);

            var sentenceHeader = new Label {
                Text = "\u6574\u53e5",
                Font = PickFont(10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(45, 49, 55),
                AutoSize = true,
                Location = new Point(18, 91),
                Anchor = AnchorStyles.Top | AnchorStyles.Left
            };
            Controls.Add(sentenceHeader);

            _sentenceValue = new Label {
                Text = "\u8f93\u5165\u4e2d\u6587\u540e\u663e\u793a\u6574\u53e5\u82f1\u6587\u7ffb\u8bd1",
                Font = new Font("Segoe UI", 11.0f),
                ForeColor = Color.FromArgb(55, 78, 106),
                Location = new Point(75, 88),
                Width = 575,
                Height = 48,
                AutoEllipsis = true,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };
            Controls.Add(_sentenceValue);

            var divider = new Label {
                BorderStyle = BorderStyle.Fixed3D,
                Location = new Point(18, 142),
                Width = 634,
                Height = 2,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };
            Controls.Add(divider);

            var wordsHeader = new Label {
                Text = "\u8bcd\u8bed / \u77ed\u8bed",
                Font = PickFont(10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(45, 49, 55),
                AutoSize = true,
                Location = new Point(18, 154),
                Anchor = AnchorStyles.Top | AnchorStyles.Left
            };
            Controls.Add(wordsHeader);

            _words = new RichTextBox {
                ReadOnly = true,
                BorderStyle = BorderStyle.None,
                BackColor = BackColor,
                Font = PickFont(10.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(48, 56, 66),
                Location = new Point(18, 180),
                Width = 634,
                Height = 116,
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                ScrollBars = RichTextBoxScrollBars.Vertical,
                DetectUrls = false,
                TabStop = false,
                Text = "\u8bcd\u8bed\u91ca\u4e49\u4f1a\u5728\u8fd9\u91cc\u5373\u65f6\u663e\u793a\u3002"
            };
            Controls.Add(_words);

            var hint = new Label {
                Text = "Ctrl+Enter  \u53d1\u9001\u5230\u539f\u7a97\u53e3    \u00b7    Esc  \u53d6\u6d88    \u00b7    Ctrl+Alt+Space  \u5524\u8d77",
                Font = new Font("Segoe UI", 8.5f),
                ForeColor = Color.FromArgb(118, 123, 131),
                AutoSize = true,
                Location = new Point(18, 315),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left
            };
            Controls.Add(hint);

            _translationTimer = new System.Windows.Forms.Timer { Interval = 700 };
            _translationTimer.Tick += delegate {
                _translationTimer.Stop();
                StartSentenceTranslation();
            };

            var menu = new ContextMenuStrip();
            menu.Items.Add("\u6253\u5f00 (Ctrl+Alt+Space)", null, delegate { OpenPopup(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("\u9000\u51fa", null, delegate { ExitApplication(); });

            _tray = new NotifyIcon {
                Icon = SystemIcons.Information,
                Text = "\u987a\u4fbf\u5b66\u82f1\u8bed",
                Visible = true,
                ContextMenuStrip = menu
            };
            _tray.DoubleClick += delegate { OpenPopup(); };
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            _hotkeyRegistered = NativeMethods.RegisterHotKey(
                Handle, HotkeyId, NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT, NativeMethods.VK_SPACE);
            if (!_hotkeyRegistered) {
                _tray.ShowBalloonTip(
                    5000,
                    "\u987a\u4fbf\u5b66\u82f1\u8bed",
                    "Ctrl+Alt+Space \u5df2\u88ab\u5176\u4ed6\u7a0b\u5e8f\u5360\u7528\u3002\u4f60\u4ecd\u53ef\u53cc\u51fb\u6258\u76d8\u56fe\u6807\u6253\u5f00\u3002",
                    ToolTipIcon.Warning);
            }
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            if (_hotkeyRegistered) {
                NativeMethods.UnregisterHotKey(Handle, HotkeyId);
                _hotkeyRegistered = false;
            }
            base.OnHandleDestroyed(e);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_HOTKEY && m.WParam.ToInt32() == HotkeyId) {
                OpenPopup();
                return;
            }
            base.WndProc(ref m);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) {
                CancelAndReturn();
                return true;
            }
            if (keyData == (Keys.Control | Keys.Enter)) {
                SendToTarget();
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        private static Font PickFont(float size, FontStyle style)
        {
            try { return new Font("Microsoft YaHei UI", size, style); }
            catch { return new Font("Segoe UI", size, style); }
        }

        private static Dictionary<string, string> LoadDictionary(string path)
        {
            var map = new Dictionary<string, string>(250000, StringComparer.Ordinal);
            using (var reader = new StreamReader(path, Encoding.UTF8, true, 65536)) {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    if (line.Length == 0 || line[0] == '#') continue;
                    int t1 = line.IndexOf('\t');
                    if (t1 <= 0) continue;
                    string key = line.Substring(0, t1).Trim();
                    int t2 = line.IndexOf('\t', t1 + 1);
                    string value = (t2 > t1 ? line.Substring(t1 + 1, t2 - t1 - 1) : line.Substring(t1 + 1)).Trim();
                    if (key.Length > 0 && value.Length > 0 && !map.ContainsKey(key)) map.Add(key, value);
                }
            }
            return map;
        }

        private void OpenPopup()
        {
            if (!Visible) _targetWindow = NativeMethods.GetForegroundWindow();

            if (!_hasPositioned) {
                PositionNearCursor();
                _hasPositioned = true;
            }

            TrySelectChineseInput();
            _input.Clear();
            _sentenceValue.Text = "\u8f93\u5165\u4e2d\u6587\u540e\u663e\u793a\u6574\u53e5\u82f1\u6587\u7ffb\u8bd1";
            _words.Text = "\u8bcd\u8bed\u91ca\u4e49\u4f1a\u5728\u8fd9\u91cc\u5373\u65f6\u663e\u793a\u3002";
            _onlineStatus.Text = "\u6574\u53e5\uff1a\u8054\u7f51   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";

            Show();
            WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
            _input.Focus();
        }

        private void PositionNearCursor()
        {
            Point p = Cursor.Position;
            Rectangle area = Screen.FromPoint(p).WorkingArea;
            int x = p.X + 14;
            int y = p.Y + 18;
            if (x + Width > area.Right) x = area.Right - Width - 10;
            if (y + Height > area.Bottom) y = p.Y - Height - 18;
            if (x < area.Left) x = area.Left + 10;
            if (y < area.Top) y = area.Top + 10;
            Location = new Point(x, y);
        }

        private static void TrySelectChineseInput()
        {
            try {
                foreach (InputLanguage lang in InputLanguage.InstalledInputLanguages) {
                    if (lang.Culture != null && lang.Culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) {
                        InputLanguage.CurrentInputLanguage = lang;
                        break;
                    }
                }
            }
            catch { }
        }

        private void OnTextChanged()
        {
            string text = _input.Text.Trim();
            _translationSerial++;
            _translationTimer.Stop();
            UpdateWordTranslations(text);

            if (text.Length == 0) {
                _sentenceValue.Text = "\u8f93\u5165\u4e2d\u6587\u540e\u663e\u793a\u6574\u53e5\u82f1\u6587\u7ffb\u8bd1";
                _onlineStatus.Text = "\u6574\u53e5\uff1a\u8054\u7f51   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";
                return;
            }

            if (!ContainsHan(text)) {
                _sentenceValue.Text = "\u8bf7\u8f93\u5165\u4e2d\u6587\u3002";
                return;
            }

            _sentenceValue.Text = "\u6b63\u5728\u7ffb\u8bd1\u6574\u53e5\u2026";
            _onlineStatus.Text = "\u6574\u53e5\uff1a0.7 \u79d2\u540e\u7ffb\u8bd1   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";
            _translationTimer.Start();
        }

        private void StartSentenceTranslation()
        {
            string text = _input.Text.Trim();
            if (text.Length == 0 || !ContainsHan(text)) return;

            int serial = _translationSerial;
            _sentenceValue.Text = "\u6b63\u5728\u8054\u7f51\u7ffb\u8bd1\u2026";
            _onlineStatus.Text = "\u6574\u53e5\uff1a\u8054\u7f51\u7ffb\u8bd1\u4e2d   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";

            ThreadPool.QueueUserWorkItem(delegate {
                string result = null;
                try { result = TranslateWithGoogle(text); } catch { }

                try {
                    BeginInvoke((MethodInvoker)delegate {
                        if (serial != _translationSerial || _input.Text.Trim() != text) return;
                        if (!String.IsNullOrWhiteSpace(result)) {
                            _sentenceValue.Text = result;
                            _onlineStatus.Text = "\u6574\u53e5\uff1a\u8054\u7f51   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";
                        } else {
                            _sentenceValue.Text = "\u6574\u53e5\u7ffb\u8bd1\u6682\u65f6\u5931\u8d25\uff0c\u4e0b\u65b9\u8bcd\u8bed\u91ca\u4e49\u4ecd\u53ef\u6b63\u5e38\u4f7f\u7528\u3002";
                            _onlineStatus.Text = "\u6574\u53e5\uff1a\u8054\u7f51\u4e0d\u53ef\u7528   \u00b7   \u8bcd\u8bed\uff1a\u672c\u5730";
                        }
                    });
                }
                catch { }
            });
        }

        private static string TranslateWithGoogle(string text)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=" + Uri.EscapeDataString(text);
            using (var wc = new WebClient()) {
                wc.Encoding = Encoding.UTF8;
                wc.Headers[HttpRequestHeader.UserAgent] = "Mozilla/5.0";
                var serializer = new JavaScriptSerializer();
                object[] top = serializer.DeserializeObject(wc.DownloadString(url)) as object[];
                if (top == null || top.Length == 0) return null;
                object[] segments = top[0] as object[];
                if (segments == null) return null;
                var sb = new StringBuilder();
                foreach (object item in segments) {
                    object[] segment = item as object[];
                    if (segment != null && segment.Length > 0 && segment[0] != null) sb.Append(Convert.ToString(segment[0]));
                }
                return sb.ToString().Trim();
            }
        }

        private void UpdateWordTranslations(string text)
        {
            if (text.Length == 0) {
                _words.Text = "\u8bcd\u8bed\u91ca\u4e49\u4f1a\u5728\u8fd9\u91cc\u5373\u65f6\u663e\u793a\u3002";
                return;
            }

            List<KeyValuePair<string, string>> items = SegmentForDictionary(text);
            if (items.Count == 0) {
                _words.Text = "\u6682\u65e0\u53ef\u7528\u7684\u672c\u5730\u8bcd\u8bed\u91ca\u4e49\u3002";
                return;
            }

            var sb = new StringBuilder();
            for (int i = 0; i < items.Count && i < 16; i++) {
                if (i > 0) sb.AppendLine();
                sb.Append(items[i].Key).Append("    ").Append(CompactDefinition(items[i].Value, 150));
            }
            _words.Text = sb.ToString();
        }

        private List<KeyValuePair<string, string>> SegmentForDictionary(string text)
        {
            var result = new List<KeyValuePair<string, string>>();
            int i = 0;

            while (i < text.Length) {
                if (!IsHan(text[i])) { i++; continue; }

                int runEnd = i;
                while (runEnd < text.Length && IsHan(text[runEnd])) runEnd++;

                while (i < runEnd) {
                    string chosen = null;
                    string gloss = null;
                    char current = text[i];

                    if (ForcedSingles.IndexOf(current) >= 0) {
                        string single = current.ToString();
                        if (_dictionary.TryGetValue(single, out gloss)) chosen = single;
                    }

                    if (chosen == null) {
                        int maxLen = Math.Min(4, runEnd - i);
                        for (int len = maxLen; len >= 2; len--) {
                            string candidate = text.Substring(i, len);
                            if (_dictionary.TryGetValue(candidate, out gloss)) {
                                chosen = candidate;
                                break;
                            }
                        }
                    }

                    if (chosen == null) {
                        string single = current.ToString();
                        if (_dictionary.TryGetValue(single, out gloss)) chosen = single;
                    }

                    if (chosen != null) {
                        result.Add(new KeyValuePair<string, string>(chosen, gloss));
                        i += chosen.Length;
                    } else {
                        i++;
                    }
                }
            }

            return result;
        }

        private static bool ContainsHan(string text)
        {
            for (int i = 0; i < text.Length; i++) if (IsHan(text[i])) return true;
            return false;
        }

        private static bool IsHan(char c)
        {
            return (c >= '\u3400' && c <= '\u9FFF') || (c >= '\uF900' && c <= '\uFAFF');
        }

        private static string CompactDefinition(string value, int maxLen)
        {
            if (String.IsNullOrEmpty(value)) return value;
            string v = Regex.Replace(value, @"\s+", " ").Trim();
            return v.Length <= maxLen ? v : v.Substring(0, maxLen - 1) + "\u2026";
        }

        private void CancelAndReturn()
        {
            _translationTimer.Stop();
            _translationSerial++;
            Hide();
            if (_targetWindow != IntPtr.Zero) NativeMethods.SetForegroundWindow(_targetWindow);
        }

        private void SendToTarget()
        {
            string text = _input.Text;
            if (String.IsNullOrEmpty(text)) {
                CancelAndReturn();
                return;
            }

            _translationTimer.Stop();
            _translationSerial++;
            IntPtr target = _targetWindow;
            Hide();

            if (target != IntPtr.Zero) {
                NativeMethods.SetForegroundWindow(target);
                Thread.Sleep(80);
            }

            IDataObject oldClipboard = null;
            bool hadClipboard = false;
            try {
                oldClipboard = Clipboard.GetDataObject();
                hadClipboard = oldClipboard != null;
            }
            catch { }

            if (!SetClipboardTextWithRetry(text)) {
                MessageBox.Show(
                    "\u65e0\u6cd5\u8bbf\u95ee\u526a\u8d34\u677f\uff0c\u6587\u5b57\u6ca1\u6709\u53d1\u9001\u3002",
                    "\u987a\u4fbf\u5b66\u82f1\u8bed",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            try {
                SendKeys.SendWait("^v");
                Thread.Sleep(220);
            }
            finally {
                if (hadClipboard) {
                    try { Clipboard.SetDataObject(oldClipboard, true); } catch { }
                }
            }
        }

        private static bool SetClipboardTextWithRetry(string text)
        {
            for (int i = 0; i < 8; i++) {
                try {
                    Clipboard.SetText(text, TextDataFormat.UnicodeText);
                    return true;
                }
                catch { Thread.Sleep(35); }
            }
            return false;
        }

        private void ExitApplication()
        {
            _translationTimer.Stop();
            _tray.Visible = false;
            if (_hotkeyRegistered) {
                NativeMethods.UnregisterHotKey(Handle, HotkeyId);
                _hotkeyRegistered = false;
            }
            Application.ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) {
                if (_translationTimer != null) _translationTimer.Dispose();
                if (_tray != null) {
                    _tray.Visible = false;
                    _tray.Dispose();
                }
            }
            base.Dispose(disposing);
        }
    }

    public static class Program
    {
        public static void Run(string dictionaryPath)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var form = new MainForm(dictionaryPath)) {
                IntPtr forceHandle = form.Handle;
                form.Hide();
                Application.Run();
            }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @(
        'System.dll',
        'System.Core.dll',
        'System.Drawing.dll',
        'System.Windows.Forms.dll',
        'System.Web.Extensions.dll'
    )

    [EnglishAlongTheWay.Program]::Run($dictionaryPath)
}
catch {
    $nl = [Environment]::NewLine
    [System.Windows.Forms.MessageBox]::Show(
        (-join ([char[]](0x7A0B,0x5E8F,0x542F,0x52A8,0x5931,0x8D25))) + ":" + $nl + $nl + $_.Exception.Message,
        $appTitle,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
