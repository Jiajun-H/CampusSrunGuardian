using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal sealed class Credentials
{
    public string Username;
    public string Password;
    public string UserType;
}

internal static class CampusSrunGuardian
{
    private const string PortalHost = "10.175.100.48";
    private const string PortalBase = "http://10.175.100.48/";
    private const string AccessId = "1";
    private const string EncVersion = "srun_bx1";
    private const string InfoPrefix = "SRBX1";
    private const string NValue = "200";
    private const string TypeValue = "1";
    private const string OsValue = "Windows 10";
    private const string NameValue = "windows";
    private const int OnlineCheckSeconds = 60;
    private const int HttpTimeoutMs = 10000;
    private const string AppDirectoryName = "CampusSrunGuardian";
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("CampusSrunGuardian.credentials.v1");
    private static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        AppDirectoryName);
    private static readonly string CredentialPath = Path.Combine(DataDirectory, "credentials.bin");
    private static readonly string LogPath = Path.Combine(DataDirectory, "guardian.log");
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly object LogLock = new object();

    private static int Main(string[] args)
    {
        try
        {
            string command = args.Length == 0 ? "--help" : args[0].ToLowerInvariant();
            if (command == "--configure")
            {
                Configure();
                return 0;
            }
            if (command == "--configure-stdin-base64")
            {
                ConfigureFromStandardInput();
                return 0;
            }
            if (command == "--status")
                return PrintStatus();
            if (command == "--prepare-login")
                return PrepareLogin();
            if (command == "--once")
                return RunOnce();
            if (command == "--run")
            {
                RunGuardian();
                return 0;
            }

            PrintHelp();
            return command == "--help" || command == "-h" ? 0 : 2;
        }
        catch (Exception ex)
        {
            Log("fatal", SafeError(ex));
            Console.Error.WriteLine("Operation failed: " + SafeError(ex));
            return 1;
        }
    }

    private static int RunOnce()
    {
        try
        {
            return CheckAndAuthenticate(true) ? 0 : 1;
        }
        catch (WebException ex)
        {
            // Scheduled one-shot checks also run while Windows is switching networks.
            // An unreachable portal is a normal skip; the next event or fallback run retries.
            if (ex.Status == WebExceptionStatus.ConnectFailure ||
                ex.Status == WebExceptionStatus.NameResolutionFailure ||
                ex.Status == WebExceptionStatus.Timeout ||
                ex.Status == WebExceptionStatus.ProxyNameResolutionFailure)
            {
                Console.WriteLine("SRun portal is unreachable; this check was skipped.");
                return 0;
            }
            throw;
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("Campus SRun Guardian");
        Console.WriteLine("  --configure  Securely save credentials (run locally as Administrator).");
        Console.WriteLine("  --status     Check current SRun status; does not authenticate.");
        Console.WriteLine("  --prepare-login Fetch a challenge and prepare fields; does not submit login.");
        Console.WriteLine("  --once       Check status and authenticate only if offline.");
        Console.WriteLine("  --run        Run the background monitor.");
    }

    private static void Configure()
    {
        RequireAdministrator();
        Console.Write("Campus username: ");
        string username = Console.ReadLine();
        Console.Write("Optional account suffix, without @ (blank if none): ");
        string userType = Console.ReadLine();
        Console.Write("Campus password: ");
        string password = ReadHidden();

        SaveConfiguredCredentials(username, userType, password);
        Console.WriteLine("Credentials saved with machine-scope DPAPI.");
    }

    private static void ConfigureFromStandardInput()
    {
        RequireAdministrator();
        string username = ReadBase64Utf8Line();
        string userType = ReadBase64Utf8Line();
        string password = ReadBase64Utf8Line();

        SaveConfiguredCredentials(username, userType, password);
        Console.WriteLine("Credentials saved with machine-scope DPAPI.");
    }

    private static string ReadBase64Utf8Line()
    {
        string value = Console.ReadLine();
        if (value == null)
            throw new InvalidDataException("The configuration input was incomplete.");
        return new UTF8Encoding(false, true).GetString(Convert.FromBase64String(value));
    }

    private static void SaveConfiguredCredentials(string username, string userType, string password)
    {

        if (String.IsNullOrWhiteSpace(username))
            throw new InvalidOperationException("The username cannot be empty.");
        if (String.IsNullOrEmpty(password))
            throw new InvalidOperationException("The password cannot be empty.");
        if (username.Contains("\r") || username.Contains("\n") ||
            (userType ?? "").Contains("\r") || (userType ?? "").Contains("\n") ||
            password.Contains("\r") || password.Contains("\n"))
            throw new InvalidOperationException("Configuration fields must be single-line values.");

        Directory.CreateDirectory(DataDirectory);
        HardenDirectory(DataDirectory);
        if (File.Exists(LogPath))
            ApplyFileAcl(LogPath);
        SaveCredentials(new Credentials
        {
            Username = username.Trim(),
            Password = password,
            UserType = (userType ?? "").Trim().TrimStart('@')
        });
        Log("configure", "Encrypted credentials saved.");
    }

    private static string ReadHidden()
    {
        var chars = new List<char>();
        while (true)
        {
            ConsoleKeyInfo key = Console.ReadKey(true);
            if (key.Key == ConsoleKey.Enter)
                break;
            if (key.Key == ConsoleKey.Backspace)
            {
                if (chars.Count > 0)
                    chars.RemoveAt(chars.Count - 1);
                continue;
            }
            if (!Char.IsControl(key.KeyChar))
                chars.Add(key.KeyChar);
        }
        Console.WriteLine();
        char[] buffer = chars.ToArray();
        string value = new String(buffer);
        Array.Clear(buffer, 0, buffer.Length);
        for (int i = 0; i < chars.Count; i++)
            chars[i] = '\0';
        chars.Clear();
        return value;
    }

    private static int PrintStatus()
    {
        try
        {
            Dictionary<string, object> status = GetUserInfo();
            bool online = IsOnline(status);
            string portalIp = GetAddress(status);
            Console.WriteLine("Portal: " + PortalHost);
            Console.WriteLine("Access ID: " + AccessId);
            Console.WriteLine("SRun session: " + (online ? "online" : "offline"));
            if (!String.IsNullOrEmpty(portalIp))
                Console.WriteLine("SRun-reported address: " + portalIp);
            return online ? 0 : 3;
        }
        catch (Exception ex)
        {
            Console.WriteLine("SRun status unavailable: " + SafeError(ex));
            return 4;
        }
    }

    private static int PrepareLogin()
    {
        Credentials credentials = LoadCredentials();
        Dictionary<string, object> status = GetUserInfo();
        string clientIp = GetAddress(status);
        if (String.IsNullOrEmpty(clientIp))
            throw new InvalidDataException("SRun status did not include a client IP; refusing to guess from the system route.");

        string username = credentials.Username;
        if (!String.IsNullOrEmpty(credentials.UserType))
            username += "@" + credentials.UserType;

        Dictionary<string, object> challengeResponse = GetChallenge(username, clientIp);
        string token = GetString(challengeResponse, "challenge");
        if (String.IsNullOrEmpty(token))
            throw new InvalidOperationException("SRun did not return a challenge.");
        string challengeIp = GetAddress(challengeResponse);
        if (!String.IsNullOrEmpty(challengeIp))
            clientIp = challengeIp;

        Dictionary<string, string> payload = BuildLoginParameters(credentials, username, clientIp, token);
        if (payload.Count != 12)
            throw new InvalidOperationException("Prepared login field count is unexpected.");

        Console.WriteLine("SRun challenge received.");
        Console.WriteLine("SRun client IP is present.");
        Console.WriteLine("Login fields were prepared locally and were not submitted.");
        return 0;
    }

    private static void RunGuardian()
    {
        int failures = 0;
        Log("monitor", "Background monitor started.");
        while (true)
        {
            bool success = false;
            try
            {
                success = CheckAndAuthenticate(false);
            }
            catch (Exception ex)
            {
                Log("monitor", SafeError(ex));
            }

            if (success)
            {
                failures = 0;
                Thread.Sleep(TimeSpan.FromSeconds(OnlineCheckSeconds));
            }
            else
            {
                failures = Math.Min(failures + 1, 8);
                int delay = Math.Min(300, 5 * (int)Math.Pow(2, failures - 1));
                Log("retry", "Next attempt in " + delay + " seconds.");
                Thread.Sleep(TimeSpan.FromSeconds(delay));
            }
        }
    }

    private static bool CheckAndAuthenticate(bool showStatus)
    {
        Dictionary<string, object> status = GetUserInfo();
        if (IsOnline(status))
        {
            if (showStatus)
                Console.WriteLine("SRun session is already online.");
            return true;
        }

        Credentials credentials = LoadCredentials();
        string clientIp = GetAddress(status);
        if (String.IsNullOrEmpty(clientIp))
            throw new InvalidDataException("SRun status did not include a client IP; refusing to guess from the system route.");
        string username = credentials.Username;
        if (!String.IsNullOrEmpty(credentials.UserType))
            username += "@" + credentials.UserType;

        Dictionary<string, object> challengeResponse = GetChallenge(username, clientIp);
        string token = GetString(challengeResponse, "challenge");
        if (String.IsNullOrEmpty(token))
            throw new InvalidOperationException("SRun did not return a challenge.");
        string challengeIp = GetAddress(challengeResponse);
        if (!String.IsNullOrEmpty(challengeIp))
            clientIp = challengeIp;

        Dictionary<string, string> login = BuildLoginParameters(credentials, username, clientIp, token);

        Dictionary<string, object> response = RequestJsonp("cgi-bin/srun_portal", login);
        string result = GetString(response, "error");
        if (result != "ok")
        {
            string safeCode = SafeServerCode(result);
            Log("login", "Portal rejected login: " + safeCode);
            if (showStatus)
                Console.WriteLine("SRun rejected the login: " + safeCode);
            return false;
        }

        Thread.Sleep(750);
        Dictionary<string, object> verified = GetUserInfo();
        if (!IsOnline(verified))
        {
            Log("login", "Login was accepted but online status was not confirmed.");
            if (showStatus)
                Console.WriteLine("Login response was accepted; online status was not confirmed.");
            return false;
        }

        Log("login", "Authentication succeeded.");
        if (showStatus)
            Console.WriteLine("SRun authentication succeeded.");
        return true;
    }

    private static Dictionary<string, string> BuildLoginParameters(
        Credentials credentials, string username, string clientIp, string token)
    {
        string hmd5 = HmacMd5(token, credentials.Password);
        string infoJson = MakeInfoJson(username, credentials.Password, clientIp);
        string info = "{" + InfoPrefix + "}" + CustomBase64(XEncode(infoJson, token));
        string checksum = Sha1(
            token + username + token + hmd5 +
            token + AccessId + token + clientIp +
            token + NValue + token + TypeValue +
            token + info);

        var login = new Dictionary<string, string>();
        login["action"] = "login";
        login["username"] = username;
        login["password"] = "{MD5}" + hmd5;
        login["ac_id"] = AccessId;
        login["ip"] = clientIp;
        login["info"] = info;
        login["chksum"] = checksum;
        login["n"] = NValue;
        login["type"] = TypeValue;
        login["os"] = OsValue;
        login["name"] = NameValue;
        login["double_stack"] = "0";
        return login;
    }

    private static Dictionary<string, object> GetUserInfo()
    {
        return RequestJsonp("cgi-bin/rad_user_info", null);
    }

    private static Dictionary<string, object> GetChallenge(string username, string ip)
    {
        var query = new Dictionary<string, string>();
        query["username"] = username;
        query["ip"] = ip;
        return RequestJsonp("cgi-bin/get_challenge", query);
    }

    private static Dictionary<string, object> RequestJsonp(string path, IDictionary<string, string> query)
    {
        string callback = "jQuery" + Guid.NewGuid().ToString("N").Substring(0, 16) +
            "_" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var values = new Dictionary<string, string>();
        if (query != null)
        {
            foreach (KeyValuePair<string, string> item in query)
                values[item.Key] = item.Value;
        }
        values["callback"] = callback;
        values["_"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();

        var builder = new StringBuilder(PortalBase).Append(path).Append('?');
        bool first = true;
        foreach (KeyValuePair<string, string> item in values)
        {
            if (!first)
                builder.Append('&');
            first = false;
            builder.Append(Uri.EscapeDataString(item.Key));
            builder.Append('=');
            builder.Append(Uri.EscapeDataString(item.Value ?? ""));
        }

        string body = HttpGet(new Uri(builder.ToString()));
        int start = body.IndexOf('(');
        int end = body.LastIndexOf(')');
        if (start < 0 || end <= start)
            throw new InvalidDataException("Portal returned a non-JSONP response.");
        string json = body.Substring(start + 1, end - start - 1);
        return Json.Deserialize<Dictionary<string, object>>(json);
    }

    private static string HttpGet(Uri uri)
    {
        if (!String.Equals(uri.Host, PortalHost, StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Refusing a portal request outside the configured HTTP host.");

        var request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = "GET";
        request.Proxy = null;
        request.AllowAutoRedirect = false;
        request.Timeout = HttpTimeoutMs;
        request.ReadWriteTimeout = HttpTimeoutMs;
        request.UserAgent = "CampusSrunGuardian/0.1";
        request.Accept = "*/*";
        using (var response = (HttpWebResponse)request.GetResponse())
        {
            if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
                throw new WebException("Portal returned HTTP " + (int)response.StatusCode + ".");
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                return reader.ReadToEnd();
        }
    }

    private static bool IsOnline(IDictionary<string, object> response)
    {
        return String.Equals(GetString(response, "error"), "ok", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetAddress(IDictionary<string, object> response)
    {
        string value = GetString(response, "client_ip");
        if (String.IsNullOrEmpty(value))
            value = GetString(response, "online_ip");
        return value;
    }

    private static string GetString(IDictionary<string, object> dictionary, string key)
    {
        object value;
        return dictionary != null && dictionary.TryGetValue(key, out value) && value != null
            ? Convert.ToString(value)
            : "";
    }

    private static string MakeInfoJson(string username, string password, string ip)
    {
        // Go's encoding/json sorts map keys; preserve that byte order for SRun's checksum.
        return "{\"acid\":" + JsonQuote(AccessId) +
            ",\"enc_ver\":" + JsonQuote(EncVersion) +
            ",\"ip\":" + JsonQuote(ip) +
            ",\"password\":" + JsonQuote(password) +
            ",\"username\":" + JsonQuote(username) + "}";
    }

    private static string JsonQuote(string value)
    {
        var result = new StringBuilder("\"");
        foreach (char c in value ?? "")
        {
            switch (c)
            {
                case '"': result.Append("\\\""); break;
                case '\\': result.Append("\\\\"); break;
                case '\b': result.Append("\\b"); break;
                case '\f': result.Append("\\f"); break;
                case '\n': result.Append("\\n"); break;
                case '\r': result.Append("\\r"); break;
                case '\t': result.Append("\\t"); break;
                case '<': result.Append("\\u003c"); break;
                case '>': result.Append("\\u003e"); break;
                case '&': result.Append("\\u0026"); break;
                case '\u2028': result.Append("\\u2028"); break;
                case '\u2029': result.Append("\\u2029"); break;
                default:
                    if (c < 0x20)
                        result.Append("\\u").Append(((int)c).ToString("x4"));
                    else
                        result.Append(c);
                    break;
            }
        }
        return result.Append('"').ToString();
    }

    private static string HmacMd5(string token, string password)
    {
        using (var hmac = new HMACMD5(Encoding.UTF8.GetBytes(token)))
            return ToHex(hmac.ComputeHash(Encoding.UTF8.GetBytes(password)));
    }

    private static string Sha1(string value)
    {
        using (SHA1 sha = SHA1.Create())
            return ToHex(sha.ComputeHash(Encoding.UTF8.GetBytes(value)));
    }

    private static string ToHex(byte[] bytes)
    {
        var result = new StringBuilder(bytes.Length * 2);
        foreach (byte b in bytes)
            result.Append(b.ToString("x2"));
        return result.ToString();
    }

    private static byte[] XEncode(string text, string keyText)
    {
        if (text.Length == 0)
            return new byte[0];

        // SRun's JavaScript implementation packs UTF-16 code units (charCodeAt),
        // not UTF-8 bytes, before applying the 32-bit mixing loop.
        uint[] v = PackWords(text, true);
        uint[] key = PackWords(keyText, false);
        if (key.Length < 4)
            Array.Resize(ref key, 4);

        // SRun's XEncode mixing steps follow the public implementation noted in
        // THIRD_PARTY_NOTICES.md; use unsigned 32-bit wraparound throughout.
        unchecked
        {
            int n = v.Length - 1;
            uint z = v[n];
            uint sum = 0;
            const uint delta = 0x9E3779B9;
            int rounds = 6 + 52 / (n + 1);
            while (rounds-- > 0)
            {
                sum += delta;
                uint e = (sum >> 2) & 3;
                for (int p = 0; p < n; p++)
                {
                    uint y = v[p + 1];
                    uint m = z >> 5 ^ y << 2;
                    m += (y >> 3 ^ z << 4) ^ sum ^ y;
                    m += key[(p & 3) ^ (int)e] ^ z;
                    v[p] += m;
                    z = v[p];
                }
                uint first = v[0];
                uint lastMix = z >> 5 ^ first << 2;
                lastMix += (first >> 3 ^ z << 4) ^ sum ^ first;
                lastMix += key[(n & 3) ^ (int)e] ^ z;
                v[n] += lastMix;
                z = v[n];
            }
        }
        return UnpackWords(v, false);
    }

    private static uint[] PackWords(string input, bool includeLength)
    {
        int count = (input.Length + 3) / 4;
        uint[] words = new uint[count + (includeLength ? 1 : 0)];
        for (int i = 0; i < input.Length; i++)
            words[i >> 2] |= (uint)input[i] << ((i & 3) * 8);
        if (includeLength)
            words[count] = (uint)input.Length;
        return words;
    }

    private static byte[] UnpackWords(uint[] words, bool includeLength)
    {
        int byteLength = words.Length * 4;
        if (includeLength)
        {
            if (words.Length == 0)
                return new byte[0];
            byteLength = (int)words[words.Length - 1];
            if (byteLength < 0 || byteLength > (words.Length - 1) * 4)
                throw new InvalidDataException("Invalid encoded payload length.");
        }
        var result = new byte[byteLength];
        for (int i = 0; i < byteLength; i++)
            result[i] = (byte)(words[i >> 2] >> ((i & 3) * 8));
        return result;
    }

    private static string CustomBase64(byte[] bytes)
    {
        const string standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const string custom = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA";
        string encoded = Convert.ToBase64String(bytes);
        var result = new StringBuilder(encoded.Length);
        foreach (char c in encoded)
        {
            int index = standard.IndexOf(c);
            result.Append(index < 0 ? c : custom[index]);
        }
        return result.ToString();
    }

    private static void SaveCredentials(Credentials credentials)
    {
        byte[] clear;
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream, Encoding.UTF8))
        {
            writer.Write(credentials.Username);
            writer.Write(credentials.Password);
            writer.Write(credentials.UserType ?? "");
            writer.Flush();
            clear = stream.ToArray();
        }

        byte[] protectedData = ProtectedData.Protect(clear, Entropy, DataProtectionScope.LocalMachine);
        Array.Clear(clear, 0, clear.Length);
        string temporaryPath = CredentialPath + ".tmp";
        File.WriteAllBytes(temporaryPath, protectedData);
        ApplyFileAcl(temporaryPath);
        if (File.Exists(CredentialPath))
            File.Replace(temporaryPath, CredentialPath, null);
        else
            File.Move(temporaryPath, CredentialPath);
        ApplyFileAcl(CredentialPath);
        Array.Clear(protectedData, 0, protectedData.Length);
    }

    private static Credentials LoadCredentials()
    {
        if (!File.Exists(CredentialPath))
            throw new FileNotFoundException("Credentials are not configured. Run --configure locally.", CredentialPath);

        byte[] encrypted = File.ReadAllBytes(CredentialPath);
        byte[] clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.LocalMachine);
        try
        {
            using (var stream = new MemoryStream(clear))
            using (var reader = new BinaryReader(stream, Encoding.UTF8))
            {
                return new Credentials
                {
                    Username = reader.ReadString(),
                    Password = reader.ReadString(),
                    UserType = reader.ReadString()
                };
            }
        }
        finally
        {
            Array.Clear(clear, 0, clear.Length);
            Array.Clear(encrypted, 0, encrypted.Length);
        }
    }

    private static void HardenDirectory(string path)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null),
            FileSystemRights.Modify | FileSystemRights.ReadAndExecute,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    private static void ApplyFileAcl(string path)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null),
            FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.ReadPermissions,
            AccessControlType.Allow));
        File.SetAccessControl(path, security);
    }

    private static void RequireAdministrator()
    {
        WindowsIdentity identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        if (!principal.IsInRole(WindowsBuiltInRole.Administrator))
            throw new UnauthorizedAccessException("Run --configure from an elevated PowerShell window.");
    }

    private static string SafeServerCode(string value)
    {
        if (String.IsNullOrEmpty(value))
            return "unknown";
        string safe = Regex.Replace(value, "[^A-Za-z0-9_-]", "");
        return safe.Length == 0 ? "unknown" : safe.Substring(0, Math.Min(48, safe.Length));
    }

    private static string SafeError(Exception ex)
    {
        var web = ex as WebException;
        if (web != null)
            return "Network request failed (" + web.Status.ToString() + ").";
        var socket = ex as SocketException;
        if (socket != null)
            return "Network route unavailable (" + socket.SocketErrorCode.ToString() + ").";
        if (ex is UnauthorizedAccessException)
            return "Access denied. Check the configured credential/task permissions.";
        if (ex is FileNotFoundException)
            return "Credentials are not configured.";
        return ex.GetType().Name + ".";
    }

    private static void Log(string category, string message)
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            lock (LogLock)
            {
                File.AppendAllText(LogPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + category + "] " +
                    message + Environment.NewLine,
                    Encoding.UTF8);
            }
        }
        catch
        {
        }
    }
}
