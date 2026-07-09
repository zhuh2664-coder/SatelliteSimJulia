// ============================================================
// MiniJson.cs — 极简 JSON 解析（无外部依赖）
// ============================================================
//
// 仅支持解析：object / array / string / number / bool / null。
// 返回值：
//   object  -> Dictionary<string, object>
//   array   -> List<object>
//   number  -> double
//   true/false -> bool
//   null    -> null
//
// 配套扩展方法用于安全取值。
// ============================================================

using System;
using System.Collections.Generic;
using System.Text;

public static class MiniJson
{
    public static object Deserialize(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        var p = new Parser(json);
        return ParseValue(p);
    }

    static object ParseValue(Parser p)
    {
        p.SkipWhitespace();
        if (p.End) return null;
        char c = p.Peek;
        switch (c)
        {
            case '{': return ParseObject(p);
            case '[': return ParseArray(p);
            case '"': return ParseString(p);
            case 't':
            case 'f': return ParseBool(p);
            case 'n': return ParseNull(p);
            default: return ParseNumber(p);
        }
    }

    static Dictionary<string, object> ParseObject(Parser p)
    {
        var dict = new Dictionary<string, object>();
        p.Consume('{');
        p.SkipWhitespace();
        if (p.Peek == '}') { p.Consume('}'); return dict; }
        while (true)
        {
            p.SkipWhitespace();
            string key = ParseString(p);
            p.SkipWhitespace();
            p.Consume(':');
            p.SkipWhitespace();
            dict[key] = ParseValue(p);
            p.SkipWhitespace();
            char c = p.ConsumeOne();
            if (c == '}') break;
            // 否则应为 ','，继续
        }
        return dict;
    }

    static List<object> ParseArray(Parser p)
    {
        var list = new List<object>();
        p.Consume('[');
        p.SkipWhitespace();
        if (p.Peek == ']') { p.Consume(']'); return list; }
        while (true)
        {
            p.SkipWhitespace();
            list.Add(ParseValue(p));
            p.SkipWhitespace();
            char c = p.ConsumeOne();
            if (c == ']') break;
        }
        return list;
    }

    static string ParseString(Parser p)
    {
        p.Consume('"');
        var sb = new StringBuilder();
        while (!p.End)
        {
            char c = p.ConsumeOne();
            if (c == '"') break;
            if (c == '\\' && !p.End)
            {
                char esc = p.ConsumeOne();
                switch (esc)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (p.Remaining >= 4)
                        {
                            string hex = p.Substring(4);
                            sb.Append((char)Convert.ToInt32(hex, 16));
                            p.Advance(4);
                        }
                        break;
                    default: sb.Append(esc); break;
                }
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    static bool ParseBool(Parser p)
    {
        if (p.Match("true")) { p.Advance(4); return true; }
        if (p.Match("false")) { p.Advance(5); return false; }
        throw new Exception("Invalid JSON boolean");
    }

    static object ParseNull(Parser p)
    {
        if (p.Match("null")) { p.Advance(4); return null; }
        throw new Exception("Invalid JSON null");
    }

    static double ParseNumber(Parser p)
    {
        int start = p.Index;
        if (p.Peek == '-') p.Advance(1);
        while (!p.End && (char.IsDigit(p.Peek) || p.Peek == '.' || p.Peek == 'e' || p.Peek == 'E' || p.Peek == '+' || p.Peek == '-'))
            p.Advance(1);
        string s = p.Text.Substring(start, p.Index - start);
        return double.Parse(s, System.Globalization.CultureInfo.InvariantCulture);
    }

    class Parser
    {
        public readonly string Text;
        public int Index;
        public Parser(string text) { Text = text; Index = 0; }

        public bool End => Index >= Text.Length;
        public int Remaining => Text.Length - Index;
        public char Peek => Text[Index];

        public void SkipWhitespace()
        {
            while (!End && char.IsWhiteSpace(Peek)) Index++;
        }

        public char ConsumeOne() => Text[Index++];

        public void Consume(char expected)
        {
            SkipWhitespace();
            if (End || Peek != expected)
                throw new Exception($"Expected '{expected}' at {Index}");
            Index++;
        }

        public bool Match(string s) => Text.Substring(Index, Math.Min(s.Length, Remaining)) == s;

        public void Advance(int n) => Index += n;

        public string Substring(int len) => Text.Substring(Index, len);
    }

    // ── 安全取值扩展 ──────────────────────────────────────────

    public static string GetString(this Dictionary<string, object> d, string key, string def = "")
    {
        if (d.TryGetValue(key, out object v) && v is string s) return s;
        return def;
    }

    public static int GetInt(this Dictionary<string, object> d, string key, int def = 0)
    {
        if (!d.TryGetValue(key, out object v)) return def;
        if (v is double dv) return (int)dv;
        if (v is int iv) return iv;
        if (v is long lv) return (int)lv;
        return def;
    }

    public static double GetDouble(this Dictionary<string, object> d, string key, double def = 0)
    {
        if (!d.TryGetValue(key, out object v)) return def;
        if (v is double dv) return dv;
        if (v is int iv) return iv;
        if (v is long lv) return lv;
        return def;
    }

    public static bool GetBool(this Dictionary<string, object> d, string key, bool def = false)
    {
        if (d.TryGetValue(key, out object v) && v is bool b) return b;
        return def;
    }

    public static List<object> GetList(this Dictionary<string, object> d, string key)
    {
        if (d.TryGetValue(key, out object v) && v is List<object> list) return list;
        return new List<object>();
    }
}
