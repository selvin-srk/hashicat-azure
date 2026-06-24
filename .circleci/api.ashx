<%@ WebHandler Language="C#" Class="ApiHandler" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Text;
using System.Web;
using System.Web.Caching;
using System.Web.Script.Serialization;

public class ApiHandler : IHttpHandler
{
    private static readonly string ConnStr =
        ConfigurationManager.ConnectionStrings["GOALogins"].ConnectionString;

    // All queries run at this timeout (seconds). Increase if still timing out.
    private const int CMD_TIMEOUT = 240;

    // Table alias used in every FROM — WITH(NOLOCK) avoids lock waits on a live table
    private const string TBL = "[REMEDY_Info].[dbo].[GOALogins] WITH(NOLOCK)";

    private readonly JavaScriptSerializer _json = new JavaScriptSerializer();

    public bool IsReusable { get { return false; } }

    // ======================================================================
    //  ENTRY POINT
    // ======================================================================
    public void ProcessRequest(HttpContext ctx)
    {
        _json.MaxJsonLength = int.MaxValue;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.Cache.SetCacheability(HttpCacheability.NoCache);
        ctx.Response.AddHeader("Access-Control-Allow-Origin", "*");

        string action = P(ctx, "action");
        try
        {
            object result;
            switch (action)
            {
                case "filter-options": result = GetFilterOptions(ctx);    break;
                case "kpi":            result = GetKPI(ctx);              break;
                case "daily-volume":   result = GetDailyVolume(ctx);      break;
                case "event-types":    result = GetEventTypes(ctx);       break;
                case "weekday":        result = GetWeekdayDist(ctx);      break;
                case "hourly":         result = GetHourlyDist(ctx);       break;
                case "os-dist":        result = GetOSDist(ctx);           break;
                case "heatmap":        result = GetHeatmap(ctx);          break;
                case "sites":          result = GetSites(ctx);            break;
                case "servers":        result = GetServers(ctx);          break;
                case "historic":       result = GetHistoric(ctx);         break;
                case "live-feed":      result = GetLiveFeed(ctx);         break;
                case "user-search":    result = GetUserSearch(ctx);       break;
                case "user-profile":   result = GetUserProfile(ctx);      break;
                case "anomalies":      result = GetAnomalies(ctx);        break;
                case "machines":       result = GetMachines(ctx);         break;
                case "subnets":        result = GetSubnets(ctx);          break;
                case "comparison":     result = GetComparison(ctx);       break;
                default:
                    ctx.Response.StatusCode = 400;
                    result = new { error = "Unknown action: " + action };
                    break;
            }
            ctx.Response.Write(_json.Serialize(result));
        }
        catch (Exception ex)
        {
            ctx.Response.StatusCode = 500;
            ctx.Response.Write(_json.Serialize(new { error = ex.Message, detail = ex.ToString() }));
        }
    }

    // ======================================================================
    //  HELPERS
    // ======================================================================
    private SqlConnection Conn()
    {
        SqlConnection c = new SqlConnection(ConnStr);
        c.Open();
        return c;
    }

    private SqlCommand Cmd(string sql, SqlConnection cn)
    {
        SqlCommand c = new SqlCommand(sql, cn);
        c.CommandTimeout = CMD_TIMEOUT;
        return c;
    }

    private string P(HttpContext ctx, string key)
    {
        string v = ctx.Request[key];
        return v != null ? v.Trim() : "";
    }

    private DateTime DateP(HttpContext ctx, string key, DateTime def)
    {
        DateTime d;
        string raw = ctx.Request[key];
        if (raw != null && DateTime.TryParse(raw, out d)) return d.Date;
        return def;
    }

    private int IntP(HttpContext ctx, string key, int def)
    {
        int v;
        string raw = ctx.Request[key];
        if (raw != null && int.TryParse(raw, out v)) return v;
        return def;
    }

    private string S(IDataRecord r, string col)
    {
        int o = r.GetOrdinal(col);
        if (r.IsDBNull(o)) return "";
        return r[o].ToString().Trim();
    }

    private int I(IDataRecord r, string col)
    {
        int o = r.GetOrdinal(col);
        if (r.IsDBNull(o)) return 0;
        return Convert.ToInt32(r[o]);
    }

    private long L(IDataRecord r, string col)
    {
        int o = r.GetOrdinal(col);
        if (r.IsDBNull(o)) return 0L;
        return Convert.ToInt64(r[o]);
    }

    private string DateStr(IDataRecord r, string col)
    {
        int o = r.GetOrdinal(col);
        if (r.IsDBNull(o)) return "";
        return Convert.ToDateTime(r[o]).ToString("yyyy-MM-dd");
    }

    private void AddParams(SqlCommand cmd, DateTime from, DateTime to)
    {
        cmd.Parameters.AddWithValue("@from", from);
        cmd.Parameters.AddWithValue("@to",   to);
    }

    // ======================================================================
    //  FILTER OPTIONS  — cached for 60 minutes
    // ======================================================================
    private object GetFilterOptions(HttpContext ctx)
    {
        const string CACHE_KEY = "GOA_FilterOptions";
        object cached = ctx.Cache[CACHE_KEY];
        if (cached != null) return cached;

        List<string> events  = new List<string>();
        List<string> sites   = new List<string>();
        List<string> osList  = new List<string>();

        using (SqlConnection cn = Conn())
        {
            // Use TOP to cap scan time; DISTINCT on indexed columns is fast once indexes exist
            string[] sqls = new string[]
            {
                "SELECT DISTINCT TOP 200 Event        FROM " + TBL + " WHERE Event IS NOT NULL ORDER BY Event",
                "SELECT DISTINCT TOP 500 AdsSiteName  FROM " + TBL + " WHERE AdsSiteName IS NOT NULL ORDER BY AdsSiteName",
                "SELECT DISTINCT TOP 100 MachineOS    FROM " + TBL + " WHERE MachineOS IS NOT NULL ORDER BY MachineOS"
            };
            List<string>[] lists = new List<string>[] { events, sites, osList };

            for (int i = 0; i < sqls.Length; i++)
            {
                using (SqlCommand cmd = Cmd(sqls[i], cn))
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                        if (!r.IsDBNull(0)) lists[i].Add(r[0].ToString().Trim());
            }
        }

        object result = new { events = events, sites = sites, os = osList };
        // Cache for 60 minutes — these rarely change
        ctx.Cache.Insert(CACHE_KEY, result, null,
            DateTime.Now.AddMinutes(60), Cache.NoSlidingExpiration);
        return result;
    }

    // ======================================================================
    //  KPI
    // ======================================================================
    private object GetKPI(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        string sql = @"
SELECT
    COUNT(*)                                                                AS TotalLogins,
    COUNT(DISTINCT LastLogonID)                                             AS UniqueUsers,
    COUNT(DISTINCT MachineName)                                             AS UniqueMachines,
    SUM(CASE WHEN Event LIKE '%VPN%' THEN 1 ELSE 0 END)                    AS VPNSessions,
    SUM(CASE WHEN (
            CAST(TRY_CONVERT(time, LogonTime) AS TIME) < '06:00:00'
         OR CAST(TRY_CONVERT(time, LogonTime) AS TIME) > '20:00:00'
         OR LogonWeekday IN ('Saturday','Sunday')
    ) THEN 1 ELSE 0 END)                                                    AS AnomalousLogins,
    COUNT(*) / NULLIF(DATEDIFF(day, @from, DATEADD(day,1,@to)), 0)         AS AvgPerDay
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                if (r.Read())
                    return new {
                        totalLogins     = L(r, "TotalLogins"),
                        uniqueUsers     = I(r, "UniqueUsers"),
                        uniqueMachines  = I(r, "UniqueMachines"),
                        vpnSessions     = I(r, "VPNSessions"),
                        anomalousLogins = I(r, "AnomalousLogins"),
                        avgPerDay       = I(r, "AvgPerDay")
                    };
        }
        return new {};
    }

    // ======================================================================
    //  DAILY VOLUME
    // ======================================================================
    private object GetDailyVolume(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddDays(-30));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<string> labels = new List<string>();
        List<long>   data   = new List<long>();

        string sql = @"
SELECT CAST(LogonDate AS DATE) AS Day, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY CAST(LogonDate AS DATE) ORDER BY Day";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read()) { labels.Add(DateStr(r, "Day")); data.Add(L(r, "Cnt")); }
        }
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  EVENT TYPES
    // ======================================================================
    private object GetEventTypes(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddDays(-30));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<string> labels = new List<string>();
        List<long>   data   = new List<long>();

        string sql = @"
SELECT COALESCE(Event,'Unknown') AS Ev, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY Event ORDER BY Cnt DESC";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read()) { labels.Add(S(r, "Ev")); data.Add(L(r, "Cnt")); }
        }
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  WEEKDAY
    // ======================================================================
    private object GetWeekdayDist(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        string[] order = new string[] { "Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday" };
        Dictionary<string, long> dict = new Dictionary<string, long>();
        foreach (string d in order) dict[d] = 0;

        string sql = @"
SELECT COALESCE(LogonWeekday,'Unknown') AS Wd, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to) AND LogonWeekday IS NOT NULL
GROUP BY LogonWeekday";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    string k = S(r, "Wd");
                    if (dict.ContainsKey(k)) dict[k] = Convert.ToInt64(r["Cnt"]);
                }
        }

        List<long> data = new List<long>();
        foreach (string k in order) data.Add(dict.ContainsKey(k) ? dict[k] : 0);
        return new { labels = new List<string>(order), data = data };
    }

    // ======================================================================
    //  HOURLY
    // ======================================================================
    private object GetHourlyDist(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddDays(-30));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        long[] data = new long[24];

        string sql = @"
SELECT DATEPART(hour, TRY_CONVERT(time, LogonTime)) AS Hr, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY DATEPART(hour, TRY_CONVERT(time, LogonTime))";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                    if (!r.IsDBNull(0))
                    {
                        int h = Convert.ToInt32(r["Hr"]);
                        if (h >= 0 && h < 24) data[h] = Convert.ToInt64(r["Cnt"]);
                    }
        }

        List<string> labels = new List<string>();
        for (int i = 0; i < 24; i++) labels.Add(i.ToString("00") + "h");
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  OS DIST
    // ======================================================================
    private object GetOSDist(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<string> labels = new List<string>();
        List<long>   data   = new List<long>();

        string sql = @"
SELECT TOP 12 COALESCE(MachineOS,'Unknown') AS OS, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY MachineOS ORDER BY Cnt DESC";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read()) { labels.Add(S(r, "OS")); data.Add(L(r, "Cnt")); }
        }
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  HEATMAP
    // ======================================================================
    private object GetHeatmap(HttpContext ctx)
    {
        int    year = IntP(ctx, "year", DateTime.Now.Year);
        string site = P(ctx, "site");

        string[] dayOrder = new string[] { "Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday" };
        Dictionary<string, int> dayIdx = new Dictionary<string, int>
        {
            {"Monday",0},{"Tuesday",1},{"Wednesday",2},{"Thursday",3},{"Friday",4},{"Saturday",5},{"Sunday",6}
        };
        long[,] matrix = new long[7, 24];

        StringBuilder sb = new StringBuilder(@"
SELECT LogonWeekday, DATEPART(hour, TRY_CONVERT(time, LogonTime)) AS Hr, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE YEAR(LogonDate) = @year AND LogonWeekday IS NOT NULL");
        if (site != "") sb.Append(" AND AdsSiteName = @site");
        sb.Append(" GROUP BY LogonWeekday, DATEPART(hour, TRY_CONVERT(time, LogonTime))");

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sb.ToString(), cn))
        {
            cmd.Parameters.AddWithValue("@year", year);
            if (site != "") cmd.Parameters.AddWithValue("@site", site);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    string day = S(r, "LogonWeekday");
                    if (!r.IsDBNull(1) && dayIdx.ContainsKey(day))
                    {
                        int h = Convert.ToInt32(r["Hr"]);
                        int d = dayIdx[day];
                        if (h >= 0 && h < 24) matrix[d, h] = Convert.ToInt64(r["Cnt"]);
                    }
                }
        }

        List<List<long>> result = new List<List<long>>();
        for (int d = 0; d < 7; d++)
        {
            List<long> row = new List<long>();
            for (int h = 0; h < 24; h++) row.Add(matrix[d, h]);
            result.Add(row);
        }
        List<string> hours = new List<string>();
        for (int i = 0; i < 24; i++) hours.Add(i.ToString("00"));
        return new { days = dayOrder, hours = hours, matrix = result };
    }

    // ======================================================================
    //  SITES
    // ======================================================================
    private object GetSites(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<string> labels = new List<string>();
        List<long>   data   = new List<long>();

        string sql = @"
SELECT TOP 15 COALESCE(AdsSiteName,'Unknown') AS Site, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY AdsSiteName ORDER BY Cnt DESC";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read()) { labels.Add(S(r, "Site")); data.Add(L(r, "Cnt")); }
        }
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  SERVERS
    // ======================================================================
    private object GetServers(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<string> labels = new List<string>();
        List<long>   data   = new List<long>();

        string sql = @"
SELECT TOP 10 COALESCE(LogonServer,'Unknown') AS Srv, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY LogonServer ORDER BY Cnt DESC";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read()) { labels.Add(S(r, "Srv")); data.Add(L(r, "Cnt")); }
        }
        return new { labels = labels, data = data };
    }

    // ======================================================================
    //  HISTORIC
    // ======================================================================
    private object GetHistoric(HttpContext ctx)
    {
        int fromYear = IntP(ctx, "fromYear", DateTime.Now.Year - 10);
        int toYear   = IntP(ctx, "toYear",   DateTime.Now.Year);

        List<string> labels         = new List<string>();
        List<long>   totalLogins    = new List<long>();
        List<int>    uniqueUsers    = new List<int>();
        List<int>    vpnSessions    = new List<int>();
        List<int>    uniqueMachines = new List<int>();

        string sql = @"
SELECT
    YEAR(LogonDate)                                              AS Yr,
    COUNT(*)                                                     AS TotalLogins,
    COUNT(DISTINCT LastLogonID)                                  AS UniqueUsers,
    SUM(CASE WHEN Event LIKE '%VPN%' THEN 1 ELSE 0 END)         AS VPNSessions,
    COUNT(DISTINCT MachineName)                                  AS UniqueMachines
FROM " + TBL + @"
WHERE YEAR(LogonDate) >= @fromYear AND YEAR(LogonDate) <= @toYear
GROUP BY YEAR(LogonDate) ORDER BY Yr";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            cmd.Parameters.AddWithValue("@fromYear", fromYear);
            cmd.Parameters.AddWithValue("@toYear",   toYear);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    labels.Add(r["Yr"].ToString());
                    totalLogins.Add(L(r, "TotalLogins"));
                    uniqueUsers.Add(I(r, "UniqueUsers"));
                    vpnSessions.Add(I(r, "VPNSessions"));
                    uniqueMachines.Add(I(r, "UniqueMachines"));
                }
        }
        return new {
            labels         = labels,
            totalLogins    = totalLogins,
            uniqueUsers    = uniqueUsers,
            vpnSessions    = vpnSessions,
            uniqueMachines = uniqueMachines
        };
    }

    // ======================================================================
    //  LIVE FEED
    // ======================================================================
    private object GetLiveFeed(HttpContext ctx)
    {
        DateTime from    = DateP(ctx, "from",     DateTime.Now.AddDays(-7));
        DateTime to      = DateP(ctx, "to",       DateTime.Now);
        int page         = Math.Max(1, IntP(ctx, "page",     1));
        int pageSize     = IntP(ctx, "pageSize",  25);
        string evFilter  = P(ctx, "event");
        string siteFilter= P(ctx, "site");
        string search    = P(ctx, "search");

        StringBuilder where = new StringBuilder("WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)");
        if (evFilter   != "") where.Append(" AND Event = @event");
        if (siteFilter != "") where.Append(" AND AdsSiteName = @site");
        if (search     != "") where.Append(" AND (LastLogonID LIKE @search OR MachineName LIKE @search OR NetworkInfoPrimaryIP LIKE @search)");

        int totalCount = 0;
        using (SqlConnection cn = Conn())
        {
            string cntSql = "SELECT COUNT(*) FROM " + TBL + " " + where.ToString();
            using (SqlCommand cmd = Cmd(cntSql, cn))
            {
                AddParams(cmd, from, to);
                if (evFilter   != "") cmd.Parameters.AddWithValue("@event",  evFilter);
                if (siteFilter != "") cmd.Parameters.AddWithValue("@site",   siteFilter);
                if (search     != "") cmd.Parameters.AddWithValue("@search", "%" + search + "%");
                totalCount = (int)cmd.ExecuteScalar();
            }
        }

        int offset = (page - 1) * pageSize;
        List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();

        string dataSql = "SELECT Id, LogonDate, LogonTime, LogonWeekday, LastLogonID, MachineName, Event, AdsSiteName, LogonServer, MachineOS, NetworkInfoPrimaryIP, UserDistinguishedName " +
                         "FROM " + TBL + " " + where.ToString() +
                         " ORDER BY LogonDate DESC, LogonTime DESC" +
                         " OFFSET " + offset.ToString() + " ROWS FETCH NEXT " + pageSize.ToString() + " ROWS ONLY";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(dataSql, cn))
        {
            AddParams(cmd, from, to);
            if (evFilter   != "") cmd.Parameters.AddWithValue("@event",  evFilter);
            if (siteFilter != "") cmd.Parameters.AddWithValue("@site",   siteFilter);
            if (search     != "") cmd.Parameters.AddWithValue("@search", "%" + search + "%");
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    Dictionary<string, object> row = new Dictionary<string, object>();
                    row["id"]      = r["Id"];
                    row["date"]    = DateStr(r, "LogonDate");
                    row["time"]    = S(r, "LogonTime");
                    row["weekday"] = S(r, "LogonWeekday");
                    row["user"]    = S(r, "LastLogonID");
                    row["machine"] = S(r, "MachineName");
                    row["event"]   = S(r, "Event");
                    row["site"]    = S(r, "AdsSiteName");
                    row["server"]  = S(r, "LogonServer");
                    row["os"]      = S(r, "MachineOS");
                    row["ip"]      = S(r, "NetworkInfoPrimaryIP");
                    row["dn"]      = S(r, "UserDistinguishedName");
                    rows.Add(row);
                }
        }
        return new {
            rows       = rows,
            totalCount = totalCount,
            page       = page,
            pageSize   = pageSize,
            totalPages = (int)Math.Ceiling((double)totalCount / pageSize)
        };
    }

    // ======================================================================
    //  USER SEARCH
    // ======================================================================
    private object GetUserSearch(HttpContext ctx)
    {
        string q      = P(ctx, "q");
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        if (q == "") return new { users = new List<object>() };

        string sqlQ = q.Replace("*", "%");
        if (sqlQ.IndexOf('%') < 0) sqlQ = "%" + sqlQ + "%";

        string sql = @"
SELECT TOP 50
    LastLogonID, UserDistinguishedName,
    COUNT(*)                                                                 AS TotalLogins,
    MIN(CAST(LogonDate AS DATE))                                             AS FirstSeen,
    MAX(CAST(LogonDate AS DATE))                                             AS LastSeen,
    COUNT(DISTINCT MachineName)                                              AS MachinesUsed,
    COUNT(DISTINCT AdsSiteName)                                              AS SitesUsed,
    SUM(CASE WHEN Event LIKE '%VPN%' THEN 1 ELSE 0 END)                     AS VPNSessions,
    SUM(CASE WHEN (
            CAST(TRY_CONVERT(time, LogonTime) AS TIME) < '06:00:00'
         OR CAST(TRY_CONVERT(time, LogonTime) AS TIME) > '20:00:00'
         OR LogonWeekday IN ('Saturday','Sunday')
    ) THEN 1 ELSE 0 END)                                                     AS AfterHours
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
  AND (LastLogonID LIKE @q OR UserDistinguishedName LIKE @q OR MachineName LIKE @q)
GROUP BY LastLogonID, UserDistinguishedName
ORDER BY TotalLogins DESC";

        List<Dictionary<string, object>> users = new List<Dictionary<string, object>>();
        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            cmd.Parameters.AddWithValue("@q", sqlQ);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    Dictionary<string, object> u = new Dictionary<string, object>();
                    u["logonId"]      = S(r, "LastLogonID");
                    u["dn"]           = S(r, "UserDistinguishedName");
                    u["totalLogins"]  = L(r, "TotalLogins");
                    u["firstSeen"]    = DateStr(r, "FirstSeen");
                    u["lastSeen"]     = DateStr(r, "LastSeen");
                    u["machinesUsed"] = I(r, "MachinesUsed");
                    u["sitesUsed"]    = I(r, "SitesUsed");
                    u["vpnSessions"]  = I(r, "VPNSessions");
                    u["afterHours"]   = I(r, "AfterHours");
                    users.Add(u);
                }
        }
        return new { users = users };
    }

    // ======================================================================
    //  USER PROFILE
    // ======================================================================
    private object GetUserProfile(HttpContext ctx)
    {
        string userId = P(ctx, "userId");
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        if (userId == "") return new { error = "userId required" };

        List<string> monthLabels = new List<string>();
        List<long>   monthData   = new List<long>();
        long[]       hourData    = new long[24];
        List<string> machLabels  = new List<string>();
        List<long>   machData    = new List<long>();
        List<Dictionary<string, object>> events = new List<Dictionary<string, object>>();

        using (SqlConnection cn = Conn())
        {
            string monthlySql = @"
SELECT YEAR(LogonDate) AS Yr, MONTH(LogonDate) AS Mo, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LastLogonID = @u AND LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY YEAR(LogonDate), MONTH(LogonDate) ORDER BY Yr, Mo";
            using (SqlCommand cmd = Cmd(monthlySql, cn))
            {
                cmd.Parameters.AddWithValue("@u", userId);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        monthLabels.Add(r["Yr"].ToString() + "-" + Convert.ToInt32(r["Mo"]).ToString("00"));
                        monthData.Add(L(r, "Cnt"));
                    }
            }

            string hourlySql = @"
SELECT DATEPART(hour, TRY_CONVERT(time, LogonTime)) AS Hr, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LastLogonID = @u AND LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY DATEPART(hour, TRY_CONVERT(time, LogonTime))";
            using (SqlCommand cmd = Cmd(hourlySql, cn))
            {
                cmd.Parameters.AddWithValue("@u", userId);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                        if (!r.IsDBNull(0))
                        {
                            int h = Convert.ToInt32(r["Hr"]);
                            if (h >= 0 && h < 24) hourData[h] = L(r, "Cnt");
                        }
            }

            string machSql = @"
SELECT TOP 8 MachineName, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LastLogonID = @u AND LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY MachineName ORDER BY Cnt DESC";
            using (SqlCommand cmd = Cmd(machSql, cn))
            {
                cmd.Parameters.AddWithValue("@u", userId);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read()) { machLabels.Add(S(r, "MachineName")); machData.Add(L(r, "Cnt")); }
            }

            string evSql = @"
SELECT TOP 200 LogonDate, LogonTime, LogonWeekday, MachineName,
               Event, LogonServer, AdsSiteName, NetworkInfoPrimaryIP, MachineOS
FROM " + TBL + @"
WHERE LastLogonID = @u AND LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
ORDER BY LogonDate DESC, LogonTime DESC";
            using (SqlCommand cmd = Cmd(evSql, cn))
            {
                cmd.Parameters.AddWithValue("@u", userId);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        Dictionary<string, object> ev = new Dictionary<string, object>();
                        ev["date"]    = DateStr(r, "LogonDate");
                        ev["time"]    = S(r, "LogonTime");
                        ev["weekday"] = S(r, "LogonWeekday");
                        ev["machine"] = S(r, "MachineName");
                        ev["event"]   = S(r, "Event");
                        ev["server"]  = S(r, "LogonServer");
                        ev["site"]    = S(r, "AdsSiteName");
                        ev["ip"]      = S(r, "NetworkInfoPrimaryIP");
                        ev["os"]      = S(r, "MachineOS");
                        events.Add(ev);
                    }
            }
        }

        List<string> hourLabels = new List<string>();
        for (int i = 0; i < 24; i++) hourLabels.Add(i.ToString("00") + "h");

        return new {
            monthlyChart = new { labels = monthLabels, data = monthData },
            hourlyChart  = new { labels = hourLabels,  data = hourData  },
            machineChart = new { labels = machLabels,  data = machData  },
            events       = events
        };
    }

    // ======================================================================
    //  ANOMALIES
    // ======================================================================
    private object GetAnomalies(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddDays(-30));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<Dictionary<string, object>> alerts = new List<Dictionary<string, object>>();

        using (SqlConnection cn = Conn())
        {
            string ahSql = @"
SELECT TOP 25 LastLogonID, MachineName,
    CAST(LogonDate AS DATE) AS LogDate, LogonTime, AdsSiteName, Event, LogonWeekday
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
  AND (
      CAST(TRY_CONVERT(time, LogonTime) AS TIME) < '06:00:00'
   OR CAST(TRY_CONVERT(time, LogonTime) AS TIME) > '20:00:00'
   OR LogonWeekday IN ('Saturday','Sunday')
  )
ORDER BY LogonDate DESC, LogonTime DESC";
            using (SqlCommand cmd = Cmd(ahSql, cn))
            {
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        Dictionary<string, object> a = new Dictionary<string, object>();
                        a["type"]     = "After-Hours";
                        a["severity"] = "warning";
                        a["user"]     = S(r, "LastLogonID");
                        a["machine"]  = S(r, "MachineName");
                        a["date"]     = DateStr(r, "LogDate");
                        a["time"]     = S(r, "LogonTime");
                        a["site"]     = S(r, "AdsSiteName");
                        a["event"]    = S(r, "Event");
                        a["detail"]   = "Login outside business hours by " + S(r, "LastLogonID") + " on " + S(r, "MachineName") + " (" + S(r, "LogonWeekday") + " " + S(r, "LogonTime") + ")";
                        alerts.Add(a);
                    }
            }

            string msSql = @"
SELECT TOP 15
    LastLogonID, CAST(LogonDate AS DATE) AS LogDate,
    COUNT(DISTINCT AdsSiteName) AS SiteCount
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to) AND AdsSiteName IS NOT NULL
GROUP BY LastLogonID, CAST(LogonDate AS DATE)
HAVING COUNT(DISTINCT AdsSiteName) >= 2
ORDER BY LogDate DESC, SiteCount DESC";
            using (SqlCommand cmd = Cmd(msSql, cn))
            {
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        Dictionary<string, object> a = new Dictionary<string, object>();
                        a["type"]      = "Multi-Site";
                        a["severity"]  = "critical";
                        a["user"]      = S(r, "LastLogonID");
                        a["date"]      = DateStr(r, "LogDate");
                        a["siteCount"] = I(r, "SiteCount");
                        a["detail"]    = "User " + S(r, "LastLogonID") + " logged in from " + I(r, "SiteCount").ToString() + " different sites on " + DateStr(r, "LogDate");
                        alerts.Add(a);
                    }
            }

            string hfSql = @"
SELECT TOP 10
    LastLogonID, CAST(LogonDate AS DATE) AS LogDate, COUNT(*) AS LoginCount
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY LastLogonID, CAST(LogonDate AS DATE)
HAVING COUNT(*) > 100
ORDER BY LoginCount DESC";
            using (SqlCommand cmd = Cmd(hfSql, cn))
            {
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        Dictionary<string, object> a = new Dictionary<string, object>();
                        a["type"]       = "High-Frequency";
                        a["severity"]   = "warning";
                        a["user"]       = S(r, "LastLogonID");
                        a["date"]       = DateStr(r, "LogDate");
                        a["loginCount"] = I(r, "LoginCount");
                        a["detail"]     = "User " + S(r, "LastLogonID") + " had " + I(r, "LoginCount").ToString() + " logins on " + DateStr(r, "LogDate") + " — possible shared/service account";
                        alerts.Add(a);
                    }
            }
        }

        List<string> trendLabels = new List<string>();
        List<int>    trendData   = new List<int>();
        string trendSql = @"
SELECT CAST(LogonDate AS DATE) AS Day, COUNT(*) AS Cnt
FROM " + TBL + @"
WHERE LogonDate >= DATEADD(day,-30,GETDATE())
  AND (
      CAST(TRY_CONVERT(time, LogonTime) AS TIME) < '06:00:00'
   OR CAST(TRY_CONVERT(time, LogonTime) AS TIME) > '20:00:00'
   OR LogonWeekday IN ('Saturday','Sunday')
  )
GROUP BY CAST(LogonDate AS DATE) ORDER BY Day";
        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(trendSql, cn))
        using (SqlDataReader r = cmd.ExecuteReader())
            while (r.Read()) { trendLabels.Add(DateStr(r, "Day")); trendData.Add(I(r, "Cnt")); }

        int critCount = 0, warnCount = 0, ahCount = 0, msCount = 0, hfCount = 0;
        foreach (Dictionary<string, object> a in alerts)
        {
            string t = a["type"].ToString();
            if (a["severity"].ToString() == "critical") critCount++; else warnCount++;
            if (t == "After-Hours")         ahCount++;
            else if (t == "Multi-Site")     msCount++;
            else if (t == "High-Frequency") hfCount++;
        }

        return new {
            alerts = alerts,
            counts = new { critical = critCount, warning = warnCount, afterHours = ahCount, multiSite = msCount, highFrequency = hfCount },
            trend  = new { labels = trendLabels, data = trendData }
        };
    }

    // ======================================================================
    //  MACHINES
    // ======================================================================
    private object GetMachines(HttpContext ctx)
    {
        DateTime from  = DateP(ctx, "from",   DateTime.Now.AddYears(-1));
        DateTime to    = DateP(ctx, "to",     DateTime.Now);
        string search  = P(ctx, "search");
        string os      = P(ctx, "os");
        int page       = Math.Max(1, IntP(ctx, "page", 1));
        int pageSize   = 50;

        StringBuilder where = new StringBuilder("WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)");
        if (search != "") where.Append(" AND (MachineName LIKE @search OR MachineDistinguishedName LIKE @search)");
        if (os     != "") where.Append(" AND MachineOS = @os");

        int total = 0;
        using (SqlConnection cn = Conn())
        {
            string cntSql = "SELECT COUNT(DISTINCT MachineName) FROM " + TBL + " " + where.ToString();
            using (SqlCommand cmd = Cmd(cntSql, cn))
            {
                AddParams(cmd, from, to);
                if (search != "") cmd.Parameters.AddWithValue("@search", "%" + search + "%");
                if (os     != "") cmd.Parameters.AddWithValue("@os",     os);
                total = (int)cmd.ExecuteScalar();
            }
        }

        int offset = (page - 1) * pageSize;
        string dataSql = "SELECT MachineName, MachineOS, AdsSiteName, COUNT(*) AS TotalLogins, COUNT(DISTINCT LastLogonID) AS UniqueUsers, MAX(CAST(LogonDate AS DATE)) AS LastLogin, MAX(LastLogonID) AS LastUser " +
                         "FROM " + TBL + " " + where.ToString() +
                         " GROUP BY MachineName, MachineOS, AdsSiteName" +
                         " ORDER BY TotalLogins DESC" +
                         " OFFSET " + offset.ToString() + " ROWS FETCH NEXT " + pageSize.ToString() + " ROWS ONLY";

        List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(dataSql, cn))
        {
            AddParams(cmd, from, to);
            if (search != "") cmd.Parameters.AddWithValue("@search", "%" + search + "%");
            if (os     != "") cmd.Parameters.AddWithValue("@os",     os);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    Dictionary<string, object> row = new Dictionary<string, object>();
                    row["machine"]     = S(r, "MachineName");
                    row["os"]          = S(r, "MachineOS");
                    row["site"]        = S(r, "AdsSiteName");
                    row["totalLogins"] = I(r, "TotalLogins");
                    row["uniqueUsers"] = I(r, "UniqueUsers");
                    row["lastLogin"]   = DateStr(r, "LastLogin");
                    row["lastUser"]    = S(r, "LastUser");
                    rows.Add(row);
                }
        }
        return new {
            rows       = rows,
            total      = total,
            page       = page,
            pageSize   = pageSize,
            totalPages = (int)Math.Ceiling((double)total / pageSize)
        };
    }

    // ======================================================================
    //  SUBNETS
    // ======================================================================
    private object GetSubnets(HttpContext ctx)
    {
        DateTime from = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to   = DateP(ctx, "to",   DateTime.Now);

        List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();

        string sql = @"
SELECT TOP 50
    COALESCE(NetworkInfoPrimarySubnet,'Unknown')  AS Subnet,
    COALESCE(NetworkInfoPrimaryMask,'')           AS Mask,
    COALESCE(NetworkInfoPrimaryHostName,'')       AS HostName,
    COALESCE(AdsSiteName,'Unknown')               AS Site,
    COUNT(*)                                       AS LoginCount,
    COUNT(DISTINCT LastLogonID)                    AS UniqueUsers,
    MAX(CAST(LogonDate AS DATE))                   AS LastActivity
FROM " + TBL + @"
WHERE LogonDate >= @from AND LogonDate < DATEADD(day,1,@to)
GROUP BY NetworkInfoPrimarySubnet, NetworkInfoPrimaryMask, NetworkInfoPrimaryHostName, AdsSiteName
ORDER BY LoginCount DESC";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    Dictionary<string, object> row = new Dictionary<string, object>();
                    row["subnet"]       = S(r, "Subnet");
                    row["mask"]         = S(r, "Mask");
                    row["hostName"]     = S(r, "HostName");
                    row["site"]         = S(r, "Site");
                    row["loginCount"]   = I(r, "LoginCount");
                    row["uniqueUsers"]  = I(r, "UniqueUsers");
                    row["lastActivity"] = DateStr(r, "LastActivity");
                    rows.Add(row);
                }
        }
        return new { rows = rows };
    }

    // ======================================================================
    //  COMPARISON
    // ======================================================================
    private object GetComparison(HttpContext ctx)
    {
        string type    = P(ctx, "type");
        if (type == "") type = "user";
        string entityA = P(ctx, "a");
        string entityB = P(ctx, "b");
        DateTime from  = DateP(ctx, "from", DateTime.Now.AddYears(-1));
        DateTime to    = DateP(ctx, "to",   DateTime.Now);

        if (entityA == "" || entityB == "")
            return new { error = "Both entity A and B are required." };

        string col = (type == "site") ? "AdsSiteName" : (type == "machine") ? "MachineName" : "LastLogonID";

        if (type == "period")
        {
            int yearA, yearB;
            if (!int.TryParse(entityA, out yearA) || !int.TryParse(entityB, out yearB))
                return new { error = "Period comparison requires 4-digit years." };
            return ComparePeriods(yearA, yearB);
        }

        List<string> chartLabels = new List<string>();
        List<long>   chartDataA  = new List<long>();
        List<long>   chartDataB  = new List<long>();
        long[]       hourDataA   = new long[24];
        long[]       hourDataB   = new long[24];
        long[]       weekDataA   = new long[7];
        long[]       weekDataB   = new long[7];
        object statsA, statsB;

        using (SqlConnection cn = Conn())
        {
            statsA = GetEntityStats(cn, col, entityA, from, to);
            statsB = GetEntityStats(cn, col, entityB, from, to);

            string mSql = "SELECT YEAR(LogonDate) AS Yr, MONTH(LogonDate) AS Mo, " +
                          "SUM(CASE WHEN " + col + "=@a THEN 1 ELSE 0 END) AS CntA, " +
                          "SUM(CASE WHEN " + col + "=@b THEN 1 ELSE 0 END) AS CntB " +
                          "FROM " + TBL + " " +
                          "WHERE (" + col + "=@a OR " + col + "=@b) AND LogonDate>=@from AND LogonDate<DATEADD(day,1,@to) " +
                          "GROUP BY YEAR(LogonDate),MONTH(LogonDate) ORDER BY Yr,Mo";
            using (SqlCommand cmd = Cmd(mSql, cn))
            {
                cmd.Parameters.AddWithValue("@a", entityA);
                cmd.Parameters.AddWithValue("@b", entityB);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        chartLabels.Add(r["Yr"].ToString() + "-" + Convert.ToInt32(r["Mo"]).ToString("00"));
                        chartDataA.Add(L(r, "CntA"));
                        chartDataB.Add(L(r, "CntB"));
                    }
            }

            string hSql = "SELECT DATEPART(hour,TRY_CONVERT(time,LogonTime)) AS Hr, " +
                          "SUM(CASE WHEN " + col + "=@a THEN 1 ELSE 0 END) AS CntA, " +
                          "SUM(CASE WHEN " + col + "=@b THEN 1 ELSE 0 END) AS CntB " +
                          "FROM " + TBL + " " +
                          "WHERE (" + col + "=@a OR " + col + "=@b) AND LogonDate>=@from AND LogonDate<DATEADD(day,1,@to) " +
                          "GROUP BY DATEPART(hour,TRY_CONVERT(time,LogonTime))";
            using (SqlCommand cmd = Cmd(hSql, cn))
            {
                cmd.Parameters.AddWithValue("@a", entityA);
                cmd.Parameters.AddWithValue("@b", entityB);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                        if (!r.IsDBNull(0))
                        {
                            int h = Convert.ToInt32(r["Hr"]);
                            if (h >= 0 && h < 24) { hourDataA[h] = L(r,"CntA"); hourDataB[h] = L(r,"CntB"); }
                        }
            }

            Dictionary<string,int> wi = new Dictionary<string,int>
                {{"Monday",0},{"Tuesday",1},{"Wednesday",2},{"Thursday",3},{"Friday",4},{"Saturday",5},{"Sunday",6}};
            string wSql = "SELECT LogonWeekday, " +
                          "SUM(CASE WHEN " + col + "=@a THEN 1 ELSE 0 END) AS CntA, " +
                          "SUM(CASE WHEN " + col + "=@b THEN 1 ELSE 0 END) AS CntB " +
                          "FROM " + TBL + " " +
                          "WHERE (" + col + "=@a OR " + col + "=@b) AND LogonDate>=@from AND LogonDate<DATEADD(day,1,@to) " +
                          "GROUP BY LogonWeekday";
            using (SqlCommand cmd = Cmd(wSql, cn))
            {
                cmd.Parameters.AddWithValue("@a", entityA);
                cmd.Parameters.AddWithValue("@b", entityB);
                AddParams(cmd, from, to);
                using (SqlDataReader r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        string d = S(r, "LogonWeekday");
                        if (wi.ContainsKey(d)) { weekDataA[wi[d]] = L(r,"CntA"); weekDataB[wi[d]] = L(r,"CntB"); }
                    }
            }
        }

        List<string> hLabels = new List<string>();
        for (int i = 0; i < 24; i++) hLabels.Add(i.ToString("00") + "h");

        return new {
            statsA  = statsA,
            statsB  = statsB,
            chart   = new { labels = chartLabels, dataA = chartDataA, dataB = chartDataB },
            hourly  = new { labels = hLabels, dataA = hourDataA, dataB = hourDataB },
            weekly  = new { labels = new string[]{"Mon","Tue","Wed","Thu","Fri","Sat","Sun"}, dataA = weekDataA, dataB = weekDataB }
        };
    }

    private object GetEntityStats(SqlConnection cn, string col, string entity, DateTime from, DateTime to)
    {
        string sql = "SELECT COUNT(*) AS TotalLogins, COUNT(DISTINCT CAST(LogonDate AS DATE)) AS ActiveDays, " +
                     "COUNT(DISTINCT MachineName) AS UniqueMachines, " +
                     "SUM(CASE WHEN Event LIKE '%VPN%' THEN 1 ELSE 0 END) AS VPNSessions, " +
                     "SUM(CASE WHEN CAST(TRY_CONVERT(time,LogonTime) AS TIME)<'06:00:00' OR CAST(TRY_CONVERT(time,LogonTime) AS TIME)>'20:00:00' THEN 1 ELSE 0 END) AS AfterHours " +
                     "FROM " + TBL + " " +
                     "WHERE " + col + "=@entity AND LogonDate>=@from AND LogonDate<DATEADD(day,1,@to)";
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            cmd.Parameters.AddWithValue("@entity", entity);
            AddParams(cmd, from, to);
            using (SqlDataReader r = cmd.ExecuteReader())
                if (r.Read())
                    return new {
                        totalLogins    = L(r, "TotalLogins"),
                        activeDays     = I(r, "ActiveDays"),
                        uniqueMachines = I(r, "UniqueMachines"),
                        vpnSessions    = I(r, "VPNSessions"),
                        afterHours     = I(r, "AfterHours")
                    };
        }
        return new {};
    }

    private object ComparePeriods(int yearA, int yearB)
    {
        List<string> labels = new List<string>();
        List<long>   dataA  = new List<long>();
        List<long>   dataB  = new List<long>();

        string sql = @"
SELECT MONTH(LogonDate) AS Mo,
    SUM(CASE WHEN YEAR(LogonDate)=@a THEN 1 ELSE 0 END) AS CntA,
    SUM(CASE WHEN YEAR(LogonDate)=@b THEN 1 ELSE 0 END) AS CntB
FROM " + TBL + @"
WHERE YEAR(LogonDate) IN (@a,@b)
GROUP BY MONTH(LogonDate) ORDER BY Mo";

        using (SqlConnection cn = Conn())
        using (SqlCommand cmd = Cmd(sql, cn))
        {
            cmd.Parameters.AddWithValue("@a", yearA);
            cmd.Parameters.AddWithValue("@b", yearB);
            using (SqlDataReader r = cmd.ExecuteReader())
                while (r.Read())
                {
                    labels.Add(new DateTime(2000, Convert.ToInt32(r["Mo"]), 1).ToString("MMM"));
                    dataA.Add(L(r, "CntA"));
                    dataB.Add(L(r, "CntB"));
                }
        }
        return new { chart = new { labels = labels, dataA = dataA, dataB = dataB } };
    }
}
