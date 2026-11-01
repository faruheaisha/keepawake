using System;
using System.Collections.Generic;
using System.Globalization;

namespace KeepAwakeDesktop
{
    // A draft is compared with the confirmed session, rather than the last clicked control.
    sealed class SessionDraft
    {
        readonly Dictionary<string, object> settings;
        readonly double minutes;
        readonly string until;
        internal SessionDraft(Dictionary<string, object> worker, Dictionary<string, object> request)
        {
            settings = new Dictionary<string, object>();
            foreach (string key in new[] { "keepDisplayOn", "antiLock", "antiLockMethod" }) settings[key] = Value.Get(worker, key);
            settings["antiLockIntervalSec"] = Value.Get(worker, "antiLockInterval"); settings["batteryFloorPercent"] = Value.Get(worker, "batteryFloor");
            long end = Value.Number(worker, "expiresEpoch"), start = Value.Number(worker, "startedEpoch");
            minutes = request != null ? Convert.ToDouble(Value.Get(request, "minutes"), CultureInfo.InvariantCulture) : end > 0 ? Math.Max(1, Math.Round((end - start) / 60.0)) : 0;
            until = request == null ? "" : Value.Text(request, "until");
        }
        internal bool Differs(Dictionary<string, object> draft, double draftMinutes, string draftUntil)
        {
            foreach (string key in settings.Keys)
                if (Value.Text(settings, key) != Value.Text(draft, key)) return true;
            return minutes != draftMinutes || until != (draftUntil ?? "");
        }
    }
}
