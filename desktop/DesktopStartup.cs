using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace KeepAwakeDesktop
{
    partial class DesktopForm
    {
        const int HotkeyId = 0x4B41;
        const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "KeepAwakeDesktop";
        bool hotkeyPreference, hotkeyRegistered;
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll", SetLastError = true)] static extern bool UnregisterHotKey(IntPtr window, int id);

        bool ConfigureHotkey(bool enabled)
        {
            if (enabled == hotkeyRegistered) return true;
            if (!enabled) { if (IsHandleCreated) UnregisterHotKey(Handle, HotkeyId); hotkeyRegistered = false; return true; }
            hotkeyRegistered = RegisterHotKey(Handle, HotkeyId, 0x0001 | 0x0002 | 0x4000, (uint)Keys.K);
            return hotkeyRegistered;
        }

        string StartupValue(string path = RunPath)
        {
            using (var key = Registry.CurrentUser.OpenSubKey(path, false)) return key == null ? null : key.GetValue(RunName) as string;
        }
        bool IsAutoStart()
        {
            try { return String.Equals(StartupValue(), "\"" + Application.ExecutablePath + "\" --tray", StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        }
        void WriteStartupValue(string value, string path = RunPath)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(path)) {
                if (key == null) throw new InvalidOperationException("Cannot access the sign-in settings.");
                if (value == null) key.DeleteValue(RunName, false); else key.SetValue(RunName, value, RegistryValueKind.String);
            }
        }
        void TestStartupAndShortcut()
        {
            string path = @"Software\KeepAwakeSelfTest-" + Guid.NewGuid().ToString("N");
            try {
                const string value = "\"C:\\Example\\KeepAwake.exe\" --tray";
                WriteStartupValue(value, path);
                if (StartupValue(path) != value) throw new InvalidOperationException("Sign-in setting did not persist.");
                WriteStartupValue(null, path);
                if (StartupValue(path) != null) throw new InvalidOperationException("Sign-in setting was not removed.");
            } finally { Registry.CurrentUser.DeleteSubKey(path, false); }
            using (var other = new Form()) {
                IntPtr handle = other.Handle;
                if (RegisterHotKey(handle, HotkeyId, 0x0001 | 0x0002 | 0x4000, (uint)Keys.K)) {
                    try { if (ConfigureHotkey(true)) throw new InvalidOperationException("A conflicting global shortcut was accepted."); }
                    finally { UnregisterHotKey(handle, HotkeyId); }
                    if (!ConfigureHotkey(true)) throw new InvalidOperationException("The released global shortcut could not be registered.");
                    ConfigureHotkey(false);
                }
            }
        }
        async Task SavePreferences()
        {
            bool oldHotkey = hotkeyRegistered;
            bool requestedHotkey = hotkey != null && hotkey.Checked;
            if (!ConfigureHotkey(requestedHotkey)) { Notify(T("快捷键被其他程序占用。", "The shortcut is already in use."), true); return; }
            string oldStartup;
            try {
                oldStartup = StartupValue();
                string requested = autoStart != null && autoStart.Checked ? "\"" + Application.ExecutablePath + "\" --tray" : null;
                if (!String.Equals(oldStartup, requested, StringComparison.Ordinal)) WriteStartupValue(requested);
            } catch (Exception ex) {
                ConfigureHotkey(oldHotkey); Notify(ex.Message, true); return;
            }
            await Execute("save", Draft(), true);
            if (preferencesDirty) {
                try { WriteStartupValue(oldStartup); } catch (Exception ex) { Notify(ex.Message, true); }
                ConfigureHotkey(oldHotkey);
            }
        }
    }
}
