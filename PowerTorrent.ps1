#requires -Version 5.1
<#
.SYNOPSIS
	PowerTorrent - a dependency-free BitTorrent client for Windows PowerShell 5.1.

.DESCRIPTION
	A BitTorrent client in a single Windows PowerShell 5.1 script. It parses
	.torrent files and magnet URIs, announces to HTTP/UDP trackers, optionally
	walks the mainline DHT, and speaks the peer wire protocol (pipelined
	requests, rarest-first or sequential, BEP 9/10 metadata, MSE/PE encryption,
	uTP, BitTorrent v2 magnets, SHA-1/SHA-256 resume). Completed torrents can seed.

	No extra modules, binaries, or NuGet packages. Networking and hashing run in
	embedded C# compiled with Add-Type (C# 5 / .NET 4.5).

	The default UI is a WPF window with themes, a notification-area tray, and
	per-user magnet/.torrent associations. Use -NoGui for a console session.

.PARAMETER Torrent
	Path to a .torrent file, or a magnet:? URI. If omitted, the WPF window
	opens (unless -NoGui, which shows a file picker).

.PARAMETER Magnet
	A magnet:? URI (xt=urn:btih and/or xt=urn:btmh). Metadata is fetched via BEP 9/10.

.PARAMETER SavePath
	Directory that will contain the downloaded content. Defaults to the folder
	that holds the .torrent file, or the current directory for magnets.

.PARAMETER Port
	TCP port advertised to trackers and bound for incoming peers (6881-6890 tried).

.PARAMETER MaxPeers
	Maximum simultaneous peer connections (outgoing + incoming). Default 40.

.PARAMETER Sequential
	Download pieces in order instead of rarest-first (better for media playback).

.PARAMETER NoDht
	Do not query the mainline DHT for extra peers.

.PARAMETER NoSeed
	Exit when the download completes instead of seeding.

.PARAMETER NoEncrypt
	Do not use MSE/PE protocol encryption (plaintext TCP only).

.PARAMETER NoUtp
	Do not use uTP (BEP 29); TCP only.

.PARAMETER Peer
	Force a first peer as ip:port (useful for testing).

.PARAMETER LogLevel
	0 = errors, 1 = info (default), 2 = detail, 3 = debug.

.PARAMETER ListOnly
	Parse the torrent, print metadata, and exit.

.PARAMETER SelfTest
	Run built-in bencode / endian / encoding tests and exit.

.PARAMETER NoGui
	Use the console dashboard instead of the WPF window.

.PARAMETER Register
	Register PowerTorrent as the current-user handler for magnet: links
	(and .torrent files unless -MagnetOnly). Then exit.

.PARAMETER Unregister
	Remove the current-user magnet: / .torrent associations. Then exit.

.PARAMETER MagnetOnly
	With -Register, associate magnet: links only (not .torrent files).

.PARAMETER Accept
	Skip the one-time legal notice for this run (does not write a settings file).

.PARAMETER RememberAccept
	Skip the legal notice and store that choice in the settings INI.

.EXAMPLE
	.\PowerTorrent.ps1 -Torrent .\ubuntu.torrent -SavePath D:\Downloads

.EXAMPLE
	.\PowerTorrent.ps1 -Magnet 'magnet:?xt=urn:btih:...' -SavePath D:\Downloads

.EXAMPLE
	.\PowerTorrent.ps1 -SelfTest

.EXAMPLE
	.\PowerTorrent.ps1 -Register

.EXAMPLE
	.\PowerTorrent.ps1 -Accept

.EXAMPLE
	.\PowerTorrent.ps1 -RememberAccept

.NOTES
	Optional settings are stored in PowerTorrent.ini next to this script.
	That file is created only when you save options or choose Remember this
	on the legal notice.
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)]
	[Alias('Path')]
	[string]$Torrent,

	[Alias('Uri')]
	[string]$Magnet = '',

	[Alias('OutputDirectory', 'Out')]
	[string]$SavePath = '',

	[int]$Port = 6881,

	[int]$MaxPeers = 40,

	[switch]$Sequential,

	[switch]$NoDht,

	[switch]$NoSeed,

	[switch]$NoEncrypt,

	[switch]$NoUtp,

	[string]$Peer = '',

	[ValidateSet(0, 1, 2, 3)]
	[int]$LogLevel = 1,

	[switch]$ListOnly,

	[switch]$SelfTest,

	[switch]$NoGui,

	[switch]$Register,

	[switch]$Unregister,

	[switch]$MagnetOnly,

	[switch]$Accept,

	[switch]$RememberAccept
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('Verbose') -and $VerbosePreference -eq 'Continue') {
	$LogLevel = 3
}

# Helpers
$script:PowerTorrentCSharp = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.ComponentModel;
using System.Text;
using System.Threading;

namespace PowerTorrent {

	public sealed class EngineSettings {
		public string TorrentPath;
		public string MagnetUri;
		public string SavePath;
		public int ListenPort;
		public int MaxPeers;
		public int LogLevel;
		public bool Sequential;
		public bool EnableDht;
		public bool SeedAfterComplete;
		public string ForcedPeer;
		public bool EnableEncrypt;
		public bool EnableUtp;
	}

	public sealed class TorrentRow : INotifyPropertyChanged {
		public event PropertyChangedEventHandler PropertyChanged;
		void Notify(string n) {
			PropertyChangedEventHandler h = PropertyChanged;
			if (h != null) h(this, new PropertyChangedEventArgs(n));
		}
		public string Id;
		string name = "";
		string sizeText = "";
		string progressText = "0%";
		string status = "Idle";
		string peersText = "0 / 0";
		string downText = "0 B/s";
		string upText = "0 B/s";
		string eta = "--";
		string hash = "";
		double progress;
		public string Name { get { return name; } set { if (name != value) { name = value; Notify("Name"); } } }
		public string SizeText { get { return sizeText; } set { if (sizeText != value) { sizeText = value; Notify("SizeText"); } } }
		public double Progress { get { return progress; } set { if (progress != value) { progress = value; Notify("Progress"); } } }
		public string ProgressText { get { return progressText; } set { if (progressText != value) { progressText = value; Notify("ProgressText"); } } }
		public string Status { get { return status; } set { if (status != value) { status = value; Notify("Status"); } } }
		public string PeersText { get { return peersText; } set { if (peersText != value) { peersText = value; Notify("PeersText"); } } }
		public string DownText { get { return downText; } set { if (downText != value) { downText = value; Notify("DownText"); } } }
		public string UpText { get { return upText; } set { if (upText != value) { upText = value; Notify("UpText"); } } }
		public string Eta { get { return eta; } set { if (eta != value) { eta = value; Notify("Eta"); } } }
		public string Hash { get { return hash; } set { if (hash != value) { hash = value; Notify("Hash"); } } }
		public void Apply(EngineStatus s) {
			if (s == null) return;
			Name = s.Name;
			Hash = s.InfoHashHex;
			SizeText = Engine.Fmt(s.TotalSize);
			Progress = s.ProgressPercent;
			ProgressText = s.ProgressPercent.ToString("0.0", CultureInfo.InvariantCulture) + "%";
			Status = s.State;
			PeersText = s.PeersConnected.ToString(CultureInfo.InvariantCulture) + " / " + s.PeersKnown.ToString(CultureInfo.InvariantCulture);
			DownText = Engine.Fmt((long)s.DownBytesPerSec) + "/s";
			UpText = Engine.Fmt((long)s.UpBytesPerSec) + "/s";
			Eta = s.Eta;
		}
	}

	public static class TorrentRowFilter {
		public static string Name = "All";
		public static bool Pass(object obj) {
			TorrentRow row = obj as TorrentRow;
			if (row == null) return true;
			string st = row.Status;
			if (st == null) st = "";
			string n = Name;
			if (n == null || n.Length == 0 || n == "All") return true;
			if (n == "Downloading") return st == "Downloading" || st == "Metadata" || st == "Announcing";
			if (n == "Seeding") return st == "Seeding";
			if (n == "Completed") return st == "Complete" || st == "Seeding";
			if (n == "Paused") return st == "Paused";
			if (n == "Checking") return st == "Hashing";
			return true;
		}
		public static Predicate<object> GetPredicate() {
			return Pass;
		}
	}

	public sealed class MagnetLink {
		public byte[] InfoHash;
		public string InfoHashHex = "";
		public byte[] V2Hash;
		public string V2InfoHashHex = "";
		public bool V2Only;
		public string DisplayName = "";
		public List<string> Trackers = new List<string>();
		public List<string> Webseeds = new List<string>();

		public static MagnetLink Parse(string uri) {
			if (string.IsNullOrEmpty(uri)) throw new ArgumentException("empty magnet");
			string u = uri.Trim();
			if (u.Length < 8 || u.Substring(0, 8).ToLowerInvariant() != "magnet:?")
				throw new Exception("not a magnet URI");
			MagnetLink mag = new MagnetLink();
			string query = u.Substring(8);
			string[] parts = query.Split('&');
			for (int i = 0; i < parts.Length; i++) {
				string kv = parts[i];
				int eq = kv.IndexOf('=');
				if (eq <= 0) continue;
				string key = Unesc(kv.Substring(0, eq)).ToLowerInvariant();
				string val = Unesc(kv.Substring(eq + 1));
				if (key == "xt" || key.StartsWith("xt.")) {
					string low = val.ToLowerInvariant();
					if (low.StartsWith("urn:btih:")) {
						string h = val.Substring(9).Trim();
						byte[] hash = ParseInfoHash(h);
						if (hash != null) {
							mag.InfoHash = hash;
							mag.InfoHashHex = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
						}
					} else if (low.StartsWith("urn:btmh:")) {
						string h = val.Substring(9).Trim().ToLowerInvariant();
						if (h.StartsWith("1220")) h = h.Substring(4);
						if (h.Length == 64) {
							try {
								byte[] v2 = new byte[32];
								for (int n = 0; n < 32; n++) v2[n] = Convert.ToByte(h.Substring(n * 2, 2), 16);
								mag.V2Hash = v2;
								mag.V2InfoHashHex = h;
								if (mag.InfoHash == null) {
									mag.InfoHash = new byte[20];
									Buffer.BlockCopy(v2, 0, mag.InfoHash, 0, 20);
									mag.InfoHashHex = BitConverter.ToString(mag.InfoHash).Replace("-", "").ToLowerInvariant();
									mag.V2Only = true;
								}
							} catch { }
						}
					}
				} else if (key == "dn" && mag.DisplayName.Length == 0) {
					mag.DisplayName = val;
				} else if (key == "tr") {
					if (!string.IsNullOrEmpty(val)) mag.Trackers.Add(val.Trim());
				} else if (key == "ws") {
					if (!string.IsNullOrEmpty(val)) mag.Webseeds.Add(val.Trim());
				}
			}
			if (mag.InfoHash == null || mag.InfoHash.Length != 20)
				throw new Exception("magnet missing xt=urn:btih or xt=urn:btmh info hash");
			return mag;
		}

		static string Unesc(string s) {
			try { return Uri.UnescapeDataString(s.Replace('+', ' ')); }
			catch { return s; }
		}

		public static byte[] ParseInfoHash(string h) {
			if (string.IsNullOrEmpty(h)) return null;
			h = h.Trim();
			if (h.Length == 40) {
				try {
					byte[] b = new byte[20];
					for (int i = 0; i < 20; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
					return b;
				} catch { return null; }
			}
			if (h.Length == 32) return FromBase32(h);
			return null;
		}

		public static byte[] FromBase32(string s) {
			const string abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
			s = s.ToUpperInvariant().Replace("=", "");
			int buffer = 0, bits = 0, idx = 0;
			byte[] outb = new byte[20];
			for (int i = 0; i < s.Length; i++) {
				int v = abc.IndexOf(s[i]);
				if (v < 0) return null;
				buffer = (buffer << 5) | v;
				bits += 5;
				if (bits >= 8) {
					bits -= 8;
					if (idx >= 20) return null;
					outb[idx++] = (byte)((buffer >> bits) & 0xFF);
				}
			}
			if (idx != 20) return null;
			return outb;
		}
	}

	public sealed class EngineStatus {
		public string Name = "";
		public string InfoHashHex = "";
		public string State = "Idle";
		public string ErrorMessage = "";
		public long Downloaded;
		public long Uploaded;
		public long TotalSize;
		public double ProgressPercent;
		public double DownBytesPerSec;
		public double UpBytesPerSec;
		public int PeersConnected;
		public int PeersKnown;
		public int PiecesDone;
		public int PiecesTotal;
		public int ListenPort;
		public string Eta = "--";
		public string[] LogLines = new string[0];
	}

	public sealed class TorrentInfo {
		public string Name = "";
		public string Comment = "";
		public string CreatedBy = "";
		public string InfoHashHex = "";
		public long TotalSize;
		public int PieceLength;
		public int PieceCount;
		public int FileCount;
		public string[] Trackers = new string[0];
		public string[] Webseeds = new string[0];
		public string[] Files = new string[0];
		public bool IsMulti;
	}

	internal static class Bt {
		public static void W32(byte[] b, int o, int v) {
			b[o] = (byte)((v >> 24) & 0xFF);
			b[o + 1] = (byte)((v >> 16) & 0xFF);
			b[o + 2] = (byte)((v >> 8) & 0xFF);
			b[o + 3] = (byte)(v & 0xFF);
		}
		public static int R32(byte[] b, int o) {
			return (int)(((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | (uint)b[o + 3]);
		}
		public static void W64(byte[] b, int o, long v) {
			ulong u = (ulong)v;
			b[o] = (byte)(u >> 56);
			b[o + 1] = (byte)(u >> 48);
			b[o + 2] = (byte)(u >> 40);
			b[o + 3] = (byte)(u >> 32);
			b[o + 4] = (byte)(u >> 24);
			b[o + 5] = (byte)(u >> 16);
			b[o + 6] = (byte)(u >> 8);
			b[o + 7] = (byte)u;
		}
		public static long R64(byte[] b, int o) {
			uint hi = (uint)R32(b, o);
			uint lo = (uint)R32(b, o + 4);
			return (long)(((ulong)hi << 32) | (ulong)lo);
		}
		public static string UrlEnc(byte[] data) {
			char[] hex = "0123456789ABCDEF".ToCharArray();
			StringBuilder sb = new StringBuilder(data.Length * 3);
			for (int i = 0; i < data.Length; i++) {
				sb.Append('%');
				sb.Append(hex[(data[i] >> 4) & 0xF]);
				sb.Append(hex[data[i] & 0xF]);
			}
			return sb.ToString();
		}
		public static string SafeName(string n) {
			if (string.IsNullOrEmpty(n)) return "unknown";
			n = n.Replace('/', '_').Replace('\\', '_');
			char[] bad = Path.GetInvalidFileNameChars();
			StringBuilder sb = new StringBuilder(n.Length);
			for (int i = 0; i < n.Length; i++) {
				char c = n[i];
				bool ok = true;
				for (int j = 0; j < bad.Length; j++) {
					if (c == bad[j]) { ok = false; break; }
				}
				sb.Append(ok ? c : '_');
			}
			string s = sb.ToString().Trim();
			if (s.Length == 0 || s == "." || s == "..") return "_";
			return s;
		}
		public static void AddCompactPeers(byte[] data, List<string> dst) {
			if (data == null) return;
			int n = data.Length / 6;
			for (int i = 0; i < n; i++) {
				int o = i * 6;
				int port = (data[o + 4] << 8) | data[o + 5];
				byte b0 = data[o];
				if (port <= 0 || port > 65535) continue;
				if (b0 == 0 || b0 == 127 || b0 == 255) continue;
				dst.Add(string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}:{4}", data[o], data[o + 1], data[o + 2], data[o + 3], port));
			}
		}
		public static IPAddress ResolveV4(string host) {
			try {
				IPAddress parsed;
				if (IPAddress.TryParse(host, out parsed)) {
					if (parsed.AddressFamily == AddressFamily.InterNetwork) return parsed;
					return null;
				}
				IPAddress[] addrs = Dns.GetHostAddresses(host);
				for (int i = 0; i < addrs.Length; i++) {
					if (addrs[i].AddressFamily == AddressFamily.InterNetwork) return addrs[i];
				}
			} catch {
			}
			return null;
		}
		public static byte[] MakePeerId() {
			byte[] id = new byte[20];
			byte[] prefix = Encoding.ASCII.GetBytes("-PT1200-");
			Buffer.BlockCopy(prefix, 0, id, 0, 8);
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			byte[] r = new byte[12];
			rng.GetBytes(r);
			rng.Dispose();
			string alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
			for (int i = 0; i < 12; i++) id[8 + i] = (byte)alphabet[r[i] % alphabet.Length];
			return id;
		}
	}

	internal sealed class Be {
		public int Kind;
		public long I;
		public byte[] Bytes;
		public List<Be> List;
		public Dictionary<string, Be> Dict;
		public List<KeyValuePair<byte[], Be>> Pairs;
		public static Be Int(long n) { Be b = new Be(); b.Kind = 0; b.I = n; return b; }
		public static Be Blob(byte[] x) { Be b = new Be(); b.Kind = 1; b.Bytes = x; return b; }
		public static Be FromList(List<Be> x) { Be b = new Be(); b.Kind = 2; b.List = x; return b; }
		public static Be FromDict(Dictionary<string, Be> x) { Be b = new Be(); b.Kind = 3; b.Dict = x; return b; }
		public Be Get(string key) {
			if (Dict == null) return null;
			Be v;
			if (Dict.TryGetValue(key, out v)) return v;
			return null;
		}
		public string Str(string key) {
			Be v = Get(key);
			if (v == null || v.Bytes == null) return null;
			return Encoding.UTF8.GetString(v.Bytes);
		}
		public long GetInt(string key, long def) {
			Be v = Get(key);
			if (v == null || v.Kind != 0) return def;
			return v.I;
		}
	}

	internal sealed class Benc {
		byte[] d;
		int i;
		int depth;
		Benc(byte[] data) { d = data; i = 0; depth = 0; }

		public static Be Decode(byte[] data) {
			int n;
			return DecodeAt(data, 0, out n);
		}

		public static Be DecodeAt(byte[] data, int offset, out int consumed) {
			consumed = 0;
			if (data == null || offset < 0 || offset >= data.Length) throw new Exception("empty bencode");
			Benc p = new Benc(data);
			p.i = offset;
			Be v = p.Parse();
			consumed = p.i - offset;
			return v;
		}

		public static byte[] SliceDictValue(byte[] data, string key) {
			if (data == null || data.Length == 0 || data[0] != (byte)'d') return null;
			Benc p = new Benc(data);
			p.i = 1;
			while (p.i < p.d.Length && p.d[p.i] != (byte)'e') {
				Be k = p.Parse();
				int vs = p.i;
				p.Parse();
				int ve = p.i;
				if (k.Bytes != null && Encoding.UTF8.GetString(k.Bytes) == key) {
					byte[] sl = new byte[ve - vs];
					Buffer.BlockCopy(p.d, vs, sl, 0, sl.Length);
					return sl;
				}
			}
			return null;
		}

		public static byte[] Encode(Be v) {
			MemoryStream ms = new MemoryStream();
			Enc(v, ms);
			return ms.ToArray();
		}

		static void Enc(Be v, MemoryStream ms) {
			if (v.Kind == 0) {
				byte[] t = Encoding.ASCII.GetBytes("i" + v.I.ToString(CultureInfo.InvariantCulture) + "e");
				ms.Write(t, 0, t.Length);
			} else if (v.Kind == 1) {
				byte[] t = Encoding.ASCII.GetBytes(v.Bytes.Length.ToString(CultureInfo.InvariantCulture) + ":");
				ms.Write(t, 0, t.Length);
				ms.Write(v.Bytes, 0, v.Bytes.Length);
			} else if (v.Kind == 2) {
				ms.WriteByte((byte)'l');
				for (int n = 0; n < v.List.Count; n++) Enc(v.List[n], ms);
				ms.WriteByte((byte)'e');
			} else {
				ms.WriteByte((byte)'d');
				List<string> keys = new List<string>(v.Dict.Keys);
				keys.Sort(StringComparer.Ordinal);
				for (int n = 0; n < keys.Count; n++) {
					Enc(Be.Blob(Encoding.UTF8.GetBytes(keys[n])), ms);
					Enc(v.Dict[keys[n]], ms);
				}
				ms.WriteByte((byte)'e');
			}
		}

		Be Parse() {
			if (depth > 64) throw new Exception("bencode too nested");
			if (i >= d.Length) throw new Exception("truncated bencode");
			byte c = d[i];
			if (c == (byte)'i') return ParseInt();
			if (c == (byte)'l') return ParseList();
			if (c == (byte)'d') return ParseDict();
			if (c >= (byte)'0' && c <= (byte)'9') return ParseBytes();
			throw new Exception("invalid bencode at " + i.ToString(CultureInfo.InvariantCulture));
		}

		Be ParseInt() {
			i++;
			int s = i;
			if (i < d.Length && d[i] == (byte)'-') i++;
			if (i >= d.Length || d[i] < (byte)'0' || d[i] > (byte)'9') throw new Exception("bad int");
			while (i < d.Length && d[i] != (byte)'e') {
				if (d[i] < (byte)'0' || d[i] > (byte)'9') throw new Exception("bad int");
				i++;
			}
			if (i >= d.Length) throw new Exception("unterminated int");
			string ns = Encoding.ASCII.GetString(d, s, i - s);
			i++;
			return Be.Int(long.Parse(ns, CultureInfo.InvariantCulture));
		}

		Be ParseBytes() {
			int s = i;
			while (i < d.Length && d[i] != (byte)':') i++;
			if (i >= d.Length) throw new Exception("bad string");
			int len = int.Parse(Encoding.ASCII.GetString(d, s, i - s), CultureInfo.InvariantCulture);
			i++;
			if (len < 0 || i + len > d.Length) throw new Exception("string overflow");
			byte[] b = new byte[len];
			Buffer.BlockCopy(d, i, b, 0, len);
			i += len;
			return Be.Blob(b);
		}

		Be ParseList() {
			depth++;
			i++;
			List<Be> list = new List<Be>();
			while (i < d.Length && d[i] != (byte)'e') list.Add(Parse());
			if (i >= d.Length) throw new Exception("unterminated list");
			i++;
			depth--;
			return Be.FromList(list);
		}

		Be ParseDict() {
			depth++;
			i++;
			Dictionary<string, Be> dict = new Dictionary<string, Be>();
			List<KeyValuePair<byte[], Be>> pairs = new List<KeyValuePair<byte[], Be>>();
			while (i < d.Length && d[i] != (byte)'e') {
				Be k = Parse();
				Be v = Parse();
				if (k.Bytes == null) throw new Exception("dict key is not a string");
				dict[Encoding.UTF8.GetString(k.Bytes)] = v;
				pairs.Add(new KeyValuePair<byte[], Be>(k.Bytes, v));
			}
			if (i >= d.Length) throw new Exception("unterminated dict");
			i++;
			depth--;
			Be b = Be.FromDict(dict);
			b.Pairs = pairs;
			return b;
		}
	}

	internal sealed class Rc4 {
		byte[] s = new byte[256];
		int i, j;
		public Rc4(byte[] key) {
			for (int k = 0; k < 256; k++) s[k] = (byte)k;
			int jj = 0;
			for (int k = 0; k < 256; k++) {
				jj = (jj + s[k] + key[k % key.Length]) & 255;
				byte t = s[k]; s[k] = s[jj]; s[jj] = t;
			}
			i = 0; j = 0;
		}
		Rc4() { }
		public Rc4 Clone() {
			Rc4 c = new Rc4();
			c.s = (byte[])s.Clone();
			c.i = i; c.j = j;
			return c;
		}
		public void Crypt(byte[] buf, int off, int n) {
			for (int k = 0; k < n; k++) {
				i = (i + 1) & 255;
				j = (j + s[i]) & 255;
				byte t = s[i]; s[i] = s[j]; s[j] = t;
				buf[off + k] ^= s[(s[i] + s[j]) & 255];
			}
		}
		public void Discard(int n) {
			byte[] t = new byte[n];
			Crypt(t, 0, n);
		}
	}

	internal static class Crypto {
		static readonly BigInteger DhP = BigInteger.Parse("00FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563", NumberStyles.AllowHexSpecifier);
		static readonly BigInteger DhG = new BigInteger(2);

		public static byte[] Sha1(params byte[][] parts) {
			int len = 0;
			for (int i = 0; i < parts.Length; i++) len += parts[i].Length;
			byte[] all = new byte[len];
			int o = 0;
			for (int i = 0; i < parts.Length; i++) { Buffer.BlockCopy(parts[i], 0, all, o, parts[i].Length); o += parts[i].Length; }
			using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) return sha.ComputeHash(all);
		}
		public static byte[] Sha256(byte[] d, int off, int len) {
			using (SHA256CryptoServiceProvider sha = new SHA256CryptoServiceProvider()) return sha.ComputeHash(d, off, len);
		}
		public static byte[] Sha256All(byte[] d) { return Sha256(d, 0, d.Length); }

		public static BigInteger RandomX() {
			byte[] r = new byte[21];
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			rng.GetBytes(r);
			rng.Dispose();
			r[20] = 0;
			r[0] |= 1;
			return new BigInteger(r);
		}
		public static byte[] Int96(BigInteger v) {
			byte[] le = v.ToByteArray();
			byte[] be = new byte[96];
			int n = le.Length;
			if (n > 0 && le[n - 1] == 0) n--;
			for (int i = 0; i < n && i < 96; i++) be[95 - i] = le[i];
			return be;
		}
		public static BigInteger From96(byte[] be) {
			byte[] le = new byte[97];
			for (int i = 0; i < 96; i++) le[i] = be[95 - i];
			return new BigInteger(le);
		}
		public static byte[] DhPub(BigInteger x) { return Int96(BigInteger.ModPow(DhG, x, DhP)); }
		public static byte[] DhSecret(byte[] their96, BigInteger x) {
			return Int96(BigInteger.ModPow(From96(their96), x, DhP));
		}
		public static Rc4 Rc4Key(bool initiatorSend, byte[] S, byte[] skey) {
			byte[] tag = Encoding.ASCII.GetBytes(initiatorSend ? "keyA" : "keyB");
			Rc4 r = new Rc4(Sha1(tag, S, skey));
			r.Discard(1024);
			return r;
		}
		public static byte[] MerklePiece(byte[] piece, int len) {
			List<byte[]> nodes = new List<byte[]>();
			int i = 0;
			while (i < len) {
				int n = Math.Min(16384, len - i);
				nodes.Add(Sha256(piece, i, n));
				i += n;
			}
			if (nodes.Count == 0) nodes.Add(Sha256(new byte[0], 0, 0));
			while (nodes.Count > 1) {
				List<byte[]> next = new List<byte[]>();
				for (int k = 0; k < nodes.Count; k += 2) {
					byte[] cat = new byte[64];
					Buffer.BlockCopy(nodes[k], 0, cat, 0, 32);
					if (k + 1 < nodes.Count) Buffer.BlockCopy(nodes[k + 1], 0, cat, 32, 32);
					next.Add(Sha256(cat, 0, 64));
				}
				nodes = next;
			}
			return nodes[0];
		}
		public static byte[] MerkleRoot(List<byte[]> layers) {
			if (layers == null || layers.Count == 0) return Sha256(new byte[0], 0, 0);
			List<byte[]> nodes = new List<byte[]>(layers);
			while (nodes.Count > 1) {
				List<byte[]> next = new List<byte[]>();
				for (int k = 0; k < nodes.Count; k += 2) {
					byte[] cat = new byte[64];
					Buffer.BlockCopy(nodes[k], 0, cat, 0, 32);
					if (k + 1 < nodes.Count) Buffer.BlockCopy(nodes[k + 1], 0, cat, 32, 32);
					next.Add(Sha256(cat, 0, 64));
				}
				nodes = next;
			}
			return nodes[0];
		}
	}

	internal abstract class PeerIo {
		public string Transport = "TCP";
		public abstract bool ReadExact(byte[] buf, int off, int n, int timeoutMs);
		public abstract void Write(byte[] buf, int n);
		public abstract bool PollRead(int microSeconds);
		public abstract int Available { get; }
		public abstract void Close();
	}

	internal sealed class TcpPeerIo : PeerIo {
		TcpClient tcp;
		NetworkStream ns;
		Rc4 sendRc4, recvRc4;
		byte[] push = new byte[0];
		int pushOff;
		public TcpPeerIo(TcpClient c) {
			tcp = c;
			tcp.NoDelay = true;
			try { tcp.ReceiveBufferSize = 256 * 1024; } catch { }
			try { tcp.SendBufferSize = 128 * 1024; } catch { }
			ns = c.GetStream();
			Transport = "TCP";
		}
		public static TcpPeerIo Dial(string host, int port, int timeoutMs) {
			TcpClient c = new TcpClient();
			c.NoDelay = true;
			c.ReceiveBufferSize = 256 * 1024;
			c.SendBufferSize = 128 * 1024;
			IAsyncResult ar = c.BeginConnect(host, port, null, null);
			if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false)) {
				try { c.Close(); } catch { }
				return null;
			}
			try { c.EndConnect(ar); } catch { try { c.Close(); } catch { } return null; }
			return new TcpPeerIo(c);
		}
		void PushFront(byte[] d, int off, int n) {
			byte[] nb = new byte[n + (push.Length - pushOff)];
			Buffer.BlockCopy(d, off, nb, 0, n);
			if (push.Length - pushOff > 0) Buffer.BlockCopy(push, pushOff, nb, n, push.Length - pushOff);
			push = nb; pushOff = 0;
		}
		bool ReadRaw(byte[] buf, int off, int n, int timeoutMs) {
			int got = 0;
			while (got < n && pushOff < push.Length) buf[off + got++] = push[pushOff++];
			if (pushOff >= push.Length) { push = new byte[0]; pushOff = 0; }
			tcp.ReceiveTimeout = timeoutMs;
			while (got < n) {
				int r;
				try { r = ns.Read(buf, off + got, n - got); }
				catch { return false; }
				if (r <= 0) return false;
				got += r;
			}
			return true;
		}
		public override bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
			if (!ReadRaw(buf, off, n, timeoutMs)) return false;
			if (recvRc4 != null) recvRc4.Crypt(buf, off, n);
			return true;
		}
		public override void Write(byte[] buf, int n) {
			if (sendRc4 != null) {
				byte[] t = new byte[n];
				Buffer.BlockCopy(buf, 0, t, 0, n);
				sendRc4.Crypt(t, 0, n);
				ns.Write(t, 0, n);
			} else ns.Write(buf, 0, n);
		}
		public override bool PollRead(int microSeconds) {
			try {
				if (pushOff < push.Length) return true;
				if (ns.DataAvailable) return true;
				return tcp.Client.Poll(microSeconds, SelectMode.SelectRead);
			} catch { return false; }
		}
		public override int Available {
			get {
				int a = push.Length - pushOff;
				try { a += tcp.Client.Available; } catch { }
				return a;
			}
		}
		public override void Close() {
			try { ns.Close(); } catch { }
			try { tcp.Close(); } catch { }
		}

		public bool TryMseOutgoing(byte[] skey) {
			try {
				BigInteger x = Crypto.RandomX();
				byte[] ya = Crypto.DhPub(x);
				RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
				byte[] pad = new byte[24];
				rng.GetBytes(pad);
				rng.Dispose();
				byte[] pkt = new byte[96 + pad.Length];
				Buffer.BlockCopy(ya, 0, pkt, 0, 96);
				Buffer.BlockCopy(pad, 0, pkt, 96, pad.Length);
				ns.Write(pkt, 0, pkt.Length);

				byte[] yb = new byte[96];
				if (!ReadRaw(yb, 0, 96, 5000)) return false;
				byte[] S = Crypto.DhSecret(yb, x);
				sendRc4 = Crypto.Rc4Key(true, S, skey);
				recvRc4 = Crypto.Rc4Key(false, S, skey);

				byte[] req1 = Crypto.Sha1(Encoding.ASCII.GetBytes("req1"), S);
				byte[] xor = Crypto.Sha1(Encoding.ASCII.GetBytes("req2"), skey);
				byte[] r3 = Crypto.Sha1(Encoding.ASCII.GetBytes("req3"), S);
				for (int i = 0; i < 20; i++) xor[i] ^= r3[i];
				byte[] vc = new byte[8];
				byte[] provide = new byte[4]; provide[3] = 0x03;
				byte[] padCLen = new byte[2];
				byte[] iaLen = new byte[2];
				byte[] encPart = new byte[8 + 4 + 2 + 2];
				Buffer.BlockCopy(vc, 0, encPart, 0, 8);
				Buffer.BlockCopy(provide, 0, encPart, 8, 4);
				sendRc4.Crypt(encPart, 0, encPart.Length);
				byte[] p3 = new byte[40 + encPart.Length];
				Buffer.BlockCopy(req1, 0, p3, 0, 20);
				Buffer.BlockCopy(xor, 0, p3, 20, 20);
				Buffer.BlockCopy(encPart, 0, p3, 40, encPart.Length);
				ns.Write(p3, 0, p3.Length);

				byte[] rest = new byte[528];
				tcp.ReceiveTimeout = 5000;
				int got = 0;
				DateTime dead = DateTime.UtcNow.AddMilliseconds(5000);
				while (got < 8 && DateTime.UtcNow < dead) {
					if (tcp.Client.Available <= 0) { Thread.Sleep(20); continue; }
					int r = ns.Read(rest, got, rest.Length - got);
					if (r <= 0) break;
					got += r;
				}
				if (got < 8) return false;
				byte[] want = new byte[8];
				Rc4 probe = recvRc4.Clone();
				probe.Crypt(want, 0, 8);
				int start = -1;
				for (int s = 0; s <= got - 8; s++) {
					bool match = true;
					for (int k = 0; k < 8; k++) if (rest[s + k] != want[k]) { match = false; break; }
					if (match) { start = s; break; }
				}
				if (start < 0) return false;
				int left = got - start;
				byte[] p4 = new byte[Math.Max(left, 16)];
				Buffer.BlockCopy(rest, start, p4, 0, left);
				int need = 8 + 4 + 2;
				while (left < need) {
					int r = ns.Read(p4, left, p4.Length - left);
					if (r <= 0) return false;
					left += r;
				}
				recvRc4.Crypt(p4, 0, 8);
				for (int k = 0; k < 8; k++) if (p4[k] != 0) return false;
				recvRc4.Crypt(p4, 8, 4);
				int sel = (p4[8] << 24) | (p4[9] << 16) | (p4[10] << 8) | p4[11];
				recvRc4.Crypt(p4, 12, 2);
				int padD = (p4[12] << 8) | p4[13];
				if (padD < 0 || padD > 512) return false;
				int have = left - 14;
				if (have < padD) {
					Array.Resize(ref p4, 14 + padD);
					if (!ReadRaw(p4, left, padD - have, 4000)) return false;
					left = 14 + padD;
				}
				if (padD > 0) recvRc4.Crypt(p4, 14, padD);
				int extra = left - (14 + padD);
				if (extra > 0) PushFront(p4, 14 + padD, extra);
				if ((sel & 2) == 0) { sendRc4 = null; recvRc4 = null; }
				Transport = "TCP/MSE";
				return true;
			} catch { return false; }
		}

		public bool AcceptMseOrPlain(byte[] skey, bool allowMse) {
			byte[] first = new byte[20];
			if (!ReadRaw(first, 0, 20, 8000)) return false;
			if (first[0] == 19 && Encoding.ASCII.GetString(first, 1, 19) == "BitTorrent protocol") {
				PushFront(first, 0, 20);
				Transport = "TCP";
				return true;
			}
			if (!allowMse) return false;
			PushFront(first, 0, 20);
			try {
				byte[] ya = new byte[96];
				if (!ReadRaw(ya, 0, 96, 5000)) return false;
				BigInteger x = Crypto.RandomX();
				byte[] yb = Crypto.DhPub(x);
				RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
				byte[] pad = new byte[24];
				rng.GetBytes(pad);
				rng.Dispose();
				byte[] pkt = new byte[96 + pad.Length];
				Buffer.BlockCopy(yb, 0, pkt, 0, 96);
				Buffer.BlockCopy(pad, 0, pkt, 96, pad.Length);
				ns.Write(pkt, 0, pkt.Length);
				byte[] S = Crypto.DhSecret(ya, x);
				byte[] req1 = Crypto.Sha1(Encoding.ASCII.GetBytes("req1"), S);
				byte[] acc = new byte[640];
				int got = 0;
				DateTime dead = DateTime.UtcNow.AddMilliseconds(6000);
				int hit = -1;
				while (DateTime.UtcNow < dead && hit < 0) {
					if (tcp.Client.Available > 0) {
						int r = ns.Read(acc, got, acc.Length - got);
						if (r <= 0) break;
						got += r;
					} else Thread.Sleep(15);
					for (int s = 0; s <= got - 20; s++) {
						bool m = true;
						for (int k = 0; k < 20; k++) if (acc[s + k] != req1[k]) { m = false; break; }
						if (m) { hit = s; break; }
					}
				}
				if (hit < 0) return false;
				int pos = hit + 20;
				while (got < pos + 20) {
					int r = ns.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				byte[] rec = new byte[20];
				Buffer.BlockCopy(acc, pos, rec, 0, 20);
				byte[] r3 = Crypto.Sha1(Encoding.ASCII.GetBytes("req3"), S);
				for (int i = 0; i < 20; i++) rec[i] ^= r3[i];
				byte[] expect = Crypto.Sha1(Encoding.ASCII.GetBytes("req2"), skey);
				for (int i = 0; i < 20; i++) if (rec[i] != expect[i]) return false;
				pos += 20;
				sendRc4 = Crypto.Rc4Key(false, S, skey);
				recvRc4 = Crypto.Rc4Key(true, S, skey);
				int need = pos + 8 + 4 + 2;
				while (got < need) {
					int r = ns.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				recvRc4.Crypt(acc, pos, 8);
				for (int k = 0; k < 8; k++) if (acc[pos + k] != 0) return false;
				pos += 8;
				recvRc4.Crypt(acc, pos, 4);
				int provide = (acc[pos] << 24) | (acc[pos + 1] << 16) | (acc[pos + 2] << 8) | acc[pos + 3];
				pos += 4;
				recvRc4.Crypt(acc, pos, 2);
				int padC = (acc[pos] << 8) | acc[pos + 1];
				pos += 2;
				if (padC < 0 || padC > 512) return false;
				while (got < pos + padC + 2) {
					int r = ns.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (padC > 0) { recvRc4.Crypt(acc, pos, padC); pos += padC; }
				recvRc4.Crypt(acc, pos, 2);
				int ia = (acc[pos] << 8) | acc[pos + 1];
				pos += 2;
				while (got < pos + ia) {
					Array.Resize(ref acc, Math.Max(acc.Length * 2, pos + ia));
					int r = ns.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (ia > 0) { recvRc4.Crypt(acc, pos, ia); PushFront(acc, pos, ia); pos += ia; }
				if (got > pos) PushFront(acc, pos, got - pos);
				byte[] p4 = new byte[14];
				int sel = ((provide & 2) != 0) ? 2 : 1;
				p4[11] = (byte)sel;
				sendRc4.Crypt(p4, 0, 8);
				sendRc4.Crypt(p4, 8, 4);
				sendRc4.Crypt(p4, 12, 2);
				ns.Write(p4, 0, 14);
				if (sel != 2) { sendRc4 = null; recvRc4 = null; Transport = "TCP"; }
				else Transport = "TCP/MSE";
				return true;
			} catch { return false; }
		}
	}

	internal sealed class UtpConn {
		public IPEndPoint Remote;
		public int SendId, RecvId;
		public int State; // 0 idle 1 syn 2 connected 3 closed
		UtpHub hub;
		ushort seq, ack;
		int nextIn;
		int remoteWnd = 64 * 1024;
		readonly object gate = new object();
		readonly Queue<byte> appIn = new Queue<byte>();
		readonly AutoResetEvent ev = new AutoResetEvent(false);
		readonly List<byte[]> inflight = new List<byte[]>();
		readonly List<ushort> infSeq = new List<ushort>();
		readonly List<DateTime> infSent = new List<DateTime>();
		readonly Dictionary<int, byte[]> reorder = new Dictionary<int, byte[]>();
		DateTime lastRecv = DateTime.UtcNow;
		const int Mss = 640;

		public UtpConn(UtpHub hub) { this.hub = hub; }

		public bool Connect(string host, int port, int timeoutMs) {
			IPAddress ip = Bt.ResolveV4(host);
			if (ip == null) return false;
			Remote = new IPEndPoint(ip, port);
			Random rng = new Random(Guid.NewGuid().GetHashCode());
			RecvId = rng.Next(1, 60000);
			SendId = RecvId + 1;
			seq = (ushort)rng.Next(1, 60000);
			ack = 0;
			nextIn = -1;
			State = 1;
			hub.Register(this);
			SendPkt(4, RecvId, seq, ack, null);
			seq++;
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			while (DateTime.UtcNow < dead && State != 2 && State != 3) {
				ev.WaitOne(50);
			}
			return State == 2;
		}

		public void AcceptSyn(ushort synSeq) {
			Random rng = new Random(Guid.NewGuid().GetHashCode());
			seq = (ushort)rng.Next(1, 60000);
			ack = synSeq;
			nextIn = synSeq + 1;
			State = 2;
			SendPkt(2, SendId, seq, ack, null);
		}

		public void OnPacket(byte[] pkt) {
			if (pkt == null || pkt.Length < 20) return;
			int type = (pkt[0] >> 4) & 0xF;
			int ext = pkt[1];
			int hdr = 20;
			while (ext != 0 && hdr + 2 <= pkt.Length) {
				ext = pkt[hdr];
				int elen = pkt[hdr + 1];
				hdr += 2 + elen;
				if (hdr > pkt.Length) return;
			}
			ushort theirSeq = (ushort)((pkt[16] << 8) | pkt[17]);
			ushort theirAck = (ushort)((pkt[18] << 8) | pkt[19]);
			remoteWnd = (pkt[12] << 24) | (pkt[13] << 16) | (pkt[14] << 8) | pkt[15];
			lastRecv = DateTime.UtcNow;
			lock (gate) {
				for (int i = inflight.Count - 1; i >= 0; i--) {
					if ((short)(theirAck - infSeq[i]) >= 0) {
						inflight.RemoveAt(i); infSeq.RemoveAt(i); infSent.RemoveAt(i);
					}
				}
				if (type == 4) { // SYN incoming
					ack = theirSeq;
					nextIn = theirSeq + 1;
					State = 2;
					SendPkt(2, SendId, seq, ack, null);
					ev.Set();
					return;
				}
				if (State == 1 && type == 2) {
					ack = theirSeq;
					nextIn = theirSeq + 1;
					State = 2;
					ev.Set();
					return;
				}
				if (type == 3) { State = 3; ev.Set(); return; }
				if (type == 1) {
					ack = theirSeq;
					State = 3;
					SendPkt(2, SendId, seq, ack, null);
					ev.Set();
					return;
				}
				if (type == 0 && pkt.Length > hdr) {
					int pay = pkt.Length - hdr;
					byte[] data = new byte[pay];
					Buffer.BlockCopy(pkt, hdr, data, 0, pay);
					if (nextIn < 0) nextIn = theirSeq;
					if (theirSeq == (ushort)nextIn) {
						for (int i = 0; i < data.Length; i++) appIn.Enqueue(data[i]);
						nextIn = (nextIn + 1) & 0xFFFF;
						ack = theirSeq;
						while (reorder.ContainsKey(nextIn)) {
							byte[] more = reorder[nextIn];
							reorder.Remove(nextIn);
							for (int i = 0; i < more.Length; i++) appIn.Enqueue(more[i]);
							ack = (ushort)nextIn;
							nextIn = (nextIn + 1) & 0xFFFF;
						}
						ev.Set();
					} else if ((short)(theirSeq - (ushort)nextIn) > 0 && reorder.Count < 64) {
						reorder[theirSeq] = data;
					}
					SendPkt(2, SendId, seq, ack, null);
				}
			}
		}

		public void SendPkt(int type, int connId, ushort sq, ushort ak, byte[] payload) {
			int plen = payload == null ? 0 : payload.Length;
			byte[] pkt = new byte[20 + plen];
			pkt[0] = (byte)((type << 4) | 1);
			pkt[1] = 0;
			pkt[2] = (byte)((connId >> 8) & 0xFF);
			pkt[3] = (byte)(connId & 0xFF);
			uint ts = (uint)(Environment.TickCount * 1000);
			pkt[4] = (byte)(ts >> 24); pkt[5] = (byte)(ts >> 16); pkt[6] = (byte)(ts >> 8); pkt[7] = (byte)ts;
			pkt[12] = 0; pkt[13] = 1; pkt[14] = 0; pkt[15] = 0; // 64k window
			pkt[16] = (byte)(sq >> 8); pkt[17] = (byte)sq;
			pkt[18] = (byte)(ak >> 8); pkt[19] = (byte)ak;
			if (plen > 0) Buffer.BlockCopy(payload, 0, pkt, 20, plen);
			hub.SendRaw(pkt, Remote);
		}

		public void Tick() {
			lock (gate) {
				DateTime now = DateTime.UtcNow;
				if (State == 3) return;
				if ((now - lastRecv).TotalSeconds > 30) { State = 3; ev.Set(); return; }
				for (int i = 0; i < inflight.Count; i++) {
					if ((now - infSent[i]).TotalMilliseconds > 600 && infSeq.Count > 0) {
						hub.SendRaw(inflight[i], Remote);
						infSent[i] = now;
					}
				}
			}
		}

		public bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			int got = 0;
			while (got < n) {
				Tick();
				lock (gate) {
					while (appIn.Count > 0 && got < n) buf[off + got++] = appIn.Dequeue();
					if (State == 3 && got < n && appIn.Count == 0) return false;
				}
				if (got >= n) return true;
				int left = (int)(dead - DateTime.UtcNow).TotalMilliseconds;
				if (left <= 0) return false;
				ev.WaitOne(Math.Min(200, left));
			}
			return true;
		}

		public void Write(byte[] buf, int n) {
			int o = 0;
			while (o < n && State == 2) {
				Tick();
				lock (gate) {
					if (inflight.Count >= 24) { }
					else {
						int take = Math.Min(Mss, n - o);
						byte[] pay = new byte[take];
						Buffer.BlockCopy(buf, o, pay, 0, take);
						byte[] pkt = new byte[20 + take];
						int connId = SendId;
						ushort sq = seq;
						seq++;
						pkt[0] = (byte)((0 << 4) | 1);
						pkt[2] = (byte)((connId >> 8) & 0xFF);
						pkt[3] = (byte)(connId & 0xFF);
						uint ts = (uint)(Environment.TickCount * 1000);
						pkt[4] = (byte)(ts >> 24); pkt[5] = (byte)(ts >> 16); pkt[6] = (byte)(ts >> 8); pkt[7] = (byte)ts;
						pkt[13] = 1;
						pkt[16] = (byte)(sq >> 8); pkt[17] = (byte)sq;
						pkt[18] = (byte)(ack >> 8); pkt[19] = (byte)ack;
						Buffer.BlockCopy(pay, 0, pkt, 20, take);
						inflight.Add(pkt); infSeq.Add(sq); infSent.Add(DateTime.UtcNow);
						hub.SendRaw(pkt, Remote);
						o += take;
						continue;
					}
				}
				ev.WaitOne(50);
			}
		}

		public bool PollRead(int microSeconds) {
			lock (gate) { if (appIn.Count > 0) return true; }
			Tick();
			ev.WaitOne(Math.Max(1, microSeconds / 1000));
			lock (gate) { return appIn.Count > 0 || State == 3; }
		}
		public int Avail { get { lock (gate) return appIn.Count; } }
		public void Close() {
			lock (gate) {
				if (State == 2) SendPkt(1, SendId, seq, ack, null);
				State = 3;
			}
			hub.Remove(this);
		}
	}

	internal sealed class UtpPeerIo : PeerIo {
		UtpConn c;
		public UtpPeerIo(UtpConn c) { this.c = c; Transport = "uTP"; }
		public override bool ReadExact(byte[] buf, int off, int n, int timeoutMs) { return c.ReadExact(buf, off, n, timeoutMs); }
		public override void Write(byte[] buf, int n) { c.Write(buf, n); }
		public override bool PollRead(int microSeconds) { return c.PollRead(microSeconds); }
		public override int Available { get { return c.Avail; } }
		public override void Close() { c.Close(); }
	}

	internal sealed class UtpHub {
		Engine eng;
		UdpClient udp;
		Thread thr;
		volatile bool run;
		readonly object gate = new object();
		readonly Dictionary<string, UtpConn> map = new Dictionary<string, UtpConn>();
		public int Port;

		public UtpHub(Engine eng) { this.eng = eng; }

		public bool Start(int port) {
			try {
				udp = new UdpClient(port);
				Port = ((IPEndPoint)udp.Client.LocalEndPoint).Port;
				run = true;
				thr = new Thread(RecvLoop);
				thr.IsBackground = true;
				thr.Start();
				return true;
			} catch { udp = null; return false; }
		}
		public void Stop() {
			run = false;
			try { if (udp != null) udp.Close(); } catch { }
		}
		public void SendRaw(byte[] pkt, IPEndPoint ep) {
			try { udp.Send(pkt, pkt.Length, ep); } catch { }
		}
		public void Remove(UtpConn c) {
			lock (gate) {
				string k = Key(c.Remote, c.RecvId);
				map.Remove(k);
			}
		}
		static string Key(IPEndPoint ep, int recvId) {
			return ep.Address + ":" + ep.Port.ToString(CultureInfo.InvariantCulture) + ":" + recvId.ToString(CultureInfo.InvariantCulture);
		}
		public void Register(UtpConn c) {
			lock (gate) map[Key(c.Remote, c.RecvId)] = c;
		}
		public UtpConn Connect(string host, int port, int timeoutMs) {
			UtpConn c = new UtpConn(this);
			if (!c.Connect(host, port, timeoutMs)) return null;
			return c;
		}
		void RecvLoop() {
			IPEndPoint any = new IPEndPoint(IPAddress.Any, 0);
			while (run) {
				try {
					udp.Client.ReceiveTimeout = 250;
					byte[] pkt = udp.Receive(ref any);
					if (pkt == null || pkt.Length < 20) continue;
					int connId = (pkt[2] << 8) | pkt[3];
					int type = (pkt[0] >> 4) & 0xF;
					IPEndPoint from = new IPEndPoint(any.Address, any.Port);
					UtpConn c = null;
					lock (gate) {
						foreach (KeyValuePair<string, UtpConn> kv in map) {
							if (kv.Value.Remote != null && kv.Value.Remote.Address.Equals(from.Address) && kv.Value.Remote.Port == from.Port && kv.Value.RecvId == connId) {
								c = kv.Value; break;
							}
						}
					}
					if (c == null && type == 4) {
						c = new UtpConn(this);
						c.Remote = from;
						c.RecvId = connId + 1;
						c.SendId = connId;
						ushort synSeq = (ushort)((pkt[16] << 8) | pkt[17]);
						lock (gate) map[Key(from, c.RecvId)] = c;
						c.AcceptSyn(synSeq);
						eng.StartIncomingUtp(c);
					} else if (c != null) c.OnPacket(pkt);
				} catch (SocketException) {
				} catch { if (!run) break; }
			}
		}
	}

	public sealed class Engine {
		EngineSettings settings;
		EngineStatus status = new EngineStatus();
		Meta meta;
		PieceMgr pieces;
		byte[] infoHash;
		byte[] peerId;
		volatile bool running;
		volatile bool paused;
		object peerLock = new object();
		List<PeerWorker> peers = new List<PeerWorker>();
		object poolLock = new object();
		Queue<string> pool = new Queue<string>();
		HashSet<string> seen = new HashSet<string>();
		object logLock = new object();
		List<string> logs = new List<string>();
		int logLevel;
		TcpListener listener;
		int boundPort;
		long sessionDown;
		long sessionUp;
		double downBps;
		double upBps;
		long lastDl;
		long lastUl;
		DateTime lastSp = DateTime.UtcNow;
		DateTime lastRecycle = DateTime.MinValue;
		int activePeerThreads;
		Thread coordThread;
		Thread dhtThread;
		Thread acceptThread;
		int announceInterval = 1800;
		bool startedAnnounced;
		object statusLock = new object();
		byte[] rawInfo;
		byte[] fetchedInfo;
		volatile bool infoReady;
		object metaLock = new object();
		int mdSize = -1;
		byte[][] mdPieces;
		bool[] mdHave;
		int mdGot;
		List<string> magnetTrackers = new List<string>();
		List<string> magnetWebseeds = new List<string>();
		byte[] v2Hash;
		bool v2Only;
		UtpHub utp;

		sealed class FileEnt {
			public string Path;
			public string RelPath;
			public long Length;
			public long Offset;
			public int Index;
			public byte[] PiecesRoot;
			public byte[] LayerHashes;
		}

		sealed class Meta {
			public string Name;
			public string Comment;
			public string CreatedBy;
			public byte[] InfoHash;
			public string InfoHashHex;
			public int PieceLength;
			public int PieceCount;
			public long TotalSize;
			public byte[] PieceHashes;
			public List<string> Trackers = new List<string>();
			public List<string> Webseeds = new List<string>();
			public List<FileEnt> Files = new List<FileEnt>();
			public bool IsMulti;
			public byte[] RawInfo;
			public bool V2;
			public byte[] V2Hash;
			public Dictionary<string, byte[]> PieceLayers = new Dictionary<string, byte[]>();

			public static Meta Stub(string name, byte[] hash, List<string> trackers, List<string> webseeds) {
				Meta m = new Meta();
				m.InfoHash = hash;
				m.InfoHashHex = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
				if (string.IsNullOrEmpty(name)) name = "magnet-" + m.InfoHashHex.Substring(0, 12);
				m.Name = Bt.SafeName(name);
				if (trackers != null) {
					HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
					for (int i = 0; i < trackers.Count; i++) AddTracker(m, seenT, trackers[i]);
				}
				if (webseeds != null) {
					for (int i = 0; i < webseeds.Count; i++) AddWeb(m, webseeds[i]);
				}
				return m;
			}

			public static Meta FromInfoBytes(byte[] rawInfo, string savePath) {
				Be info = Benc.Decode(rawInfo);
				if (info == null || info.Dict == null) throw new Exception("invalid info dict");
				Meta m = new Meta();
				m.RawInfo = rawInfo;
				FillInfo(m, info, savePath);
				if (m.V2 && m.PieceHashes == null) {
					byte[] h256 = Crypto.Sha256All(rawInfo);
					m.V2Hash = h256;
					m.InfoHash = new byte[20];
					Buffer.BlockCopy(h256, 0, m.InfoHash, 0, 20);
				} else {
					using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
						m.InfoHash = sha.ComputeHash(rawInfo);
					}
				}
				m.InfoHashHex = BitConverter.ToString(m.InfoHash).Replace("-", "").ToLowerInvariant();
				return m;
			}

			public static Meta Load(byte[] torrentBytes, string savePath) {
				Be root = Benc.Decode(torrentBytes);
				if (root.Dict == null) throw new Exception("torrent is not a dictionary");
				Be info = root.Get("info");
				if (info == null || info.Dict == null) throw new Exception("torrent missing info dict");

				byte[] rawInfo = Benc.SliceDictValue(torrentBytes, "info");
				if (rawInfo == null) rawInfo = Benc.Encode(info);

				Meta m = new Meta();
				m.RawInfo = rawInfo;
				FillInfo(m, info, savePath);
				if (m.V2 && m.PieceHashes == null) {
					byte[] h256 = Crypto.Sha256All(rawInfo);
					m.V2Hash = h256;
					m.InfoHash = new byte[20];
					Buffer.BlockCopy(h256, 0, m.InfoHash, 0, 20);
				} else {
					using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
						m.InfoHash = sha.ComputeHash(rawInfo);
					}
					if (m.V2) m.V2Hash = Crypto.Sha256All(rawInfo);
				}
				m.InfoHashHex = BitConverter.ToString(m.InfoHash).Replace("-", "").ToLowerInvariant();
				Be layers = root.Get("piece layers");
				if (layers != null && layers.Pairs != null) {
					for (int i = 0; i < layers.Pairs.Count; i++) {
						byte[] k = layers.Pairs[i].Key;
						Be v = layers.Pairs[i].Value;
						if (k != null && k.Length == 32 && v != null && v.Bytes != null)
							m.PieceLayers[BitConverter.ToString(k).Replace("-", "")] = v.Bytes;
					}
				}
				ApplyLayers(m);
				m.Comment = root.Str("comment") ?? "";
				m.CreatedBy = root.Str("created by") ?? "";

				HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
				string ann = root.Str("announce");
				AddTracker(m, seenT, ann);
				Be al = root.Get("announce-list");
				if (al != null && al.List != null) {
					for (int t = 0; t < al.List.Count; t++) {
						Be tier = al.List[t];
						if (tier.List != null) {
							for (int u = 0; u < tier.List.Count; u++) {
								if (tier.List[u].Bytes != null)
									AddTracker(m, seenT, Encoding.UTF8.GetString(tier.List[u].Bytes));
							}
						} else if (tier.Bytes != null) {
							AddTracker(m, seenT, Encoding.UTF8.GetString(tier.Bytes));
						}
					}
				}

				Be ul = root.Get("url-list");
				if (ul != null) {
					if (ul.Bytes != null) AddWeb(m, Encoding.UTF8.GetString(ul.Bytes));
					else if (ul.List != null) {
						for (int i = 0; i < ul.List.Count; i++) {
							if (ul.List[i].Bytes != null) AddWeb(m, Encoding.UTF8.GetString(ul.List[i].Bytes));
						}
					}
				}
				return m;
			}

			static void FillInfo(Meta m, Be info, string savePath) {
				m.Name = info.Str("name");
				if (string.IsNullOrEmpty(m.Name)) m.Name = "download";
				m.Name = Bt.SafeName(m.Name);

				long pl = info.GetInt("piece length", 0);
				if (pl < 16 || pl > 32L * 1024 * 1024) throw new Exception("invalid piece length");
				m.PieceLength = (int)pl;

				Be piecesBe = info.Get("pieces");
				bool haveV1 = piecesBe != null && piecesBe.Bytes != null && piecesBe.Bytes.Length % 20 == 0 && piecesBe.Bytes.Length > 0;
				if (haveV1) m.PieceHashes = piecesBe.Bytes;
				if (info.GetInt("meta version", 1) >= 2) m.V2 = true;

				string saveRoot = savePath;
				if (string.IsNullOrEmpty(saveRoot)) saveRoot = Directory.GetCurrentDirectory();

				Be tree = info.Get("file tree");
				if (tree != null && tree.Dict != null) {
					m.V2 = true;
					long[] off = new long[1];
					WalkTree(tree, "", saveRoot, m, off);
					m.TotalSize = off[0];
					m.IsMulti = m.Files.Count > 1;
					if (m.IsMulti) {
						for (int fi = 0; fi < m.Files.Count; fi++) {
							m.Files[fi].RelPath = m.Name + "/" + m.Files[fi].RelPath;
							m.Files[fi].Path = Path.Combine(saveRoot, m.Files[fi].RelPath.Replace('/', Path.DirectorySeparatorChar));
						}
					} else if (m.Files.Count == 1) {
						if (string.IsNullOrEmpty(m.Files[0].RelPath)) m.Files[0].RelPath = m.Name;
						m.Files[0].Path = Path.Combine(saveRoot, m.Files[0].RelPath.Replace('/', Path.DirectorySeparatorChar));
					}
				} else {
				Be filesBe = info.Get("files");
				if (filesBe != null && filesBe.List != null) {
					m.IsMulti = true;
					long off = 0;
					for (int fi = 0; fi < filesBe.List.Count; fi++) {
						Be f = filesBe.List[fi];
						if (f.Dict == null) throw new Exception("invalid file entry");
						long len = f.GetInt("length", -1);
						if (len < 0) throw new Exception("file missing length");
						Be pathBe = f.Get("path");
						if (pathBe == null || pathBe.List == null || pathBe.List.Count == 0)
							throw new Exception("file missing path");
						string rel = m.Name;
						string abs = Path.Combine(saveRoot, m.Name);
						for (int p = 0; p < pathBe.List.Count; p++) {
							if (pathBe.List[p].Bytes == null) throw new Exception("invalid path element");
							string part = Bt.SafeName(Encoding.UTF8.GetString(pathBe.List[p].Bytes));
							rel = rel + "/" + part;
							abs = Path.Combine(abs, part);
						}
						FileEnt e = new FileEnt();
						e.Path = abs;
						e.RelPath = rel;
						e.Length = len;
						e.Offset = off;
						e.Index = fi;
						m.Files.Add(e);
						off += len;
					}
					m.TotalSize = off;
				} else {
					m.IsMulti = false;
					long len = info.GetInt("length", -1);
					if (len < 0) throw new Exception("torrent missing length");
					FileEnt e = new FileEnt();
					e.Path = Path.Combine(saveRoot, m.Name);
					e.RelPath = m.Name;
					e.Length = len;
					e.Offset = 0;
					e.Index = 0;
					m.Files.Add(e);
					m.TotalSize = len;
				}
				}

				if (m.TotalSize == 0) m.PieceCount = 0;
				else m.PieceCount = (int)((m.TotalSize + m.PieceLength - 1) / m.PieceLength);
				if (m.PieceHashes != null && m.PieceHashes.Length != m.PieceCount * 20)
					throw new Exception("pieces length does not match file size");
				if (m.PieceHashes == null && !m.V2)
					throw new Exception("invalid pieces field");
				ApplyLayers(m);
			}

			static void WalkTree(Be node, string relBase, string saveRoot, Meta m, long[] off) {
				if (node == null || node.Dict == null) return;
				Be leaf = node.Get("");
				if (leaf != null && leaf.Dict != null) {
					long len = leaf.GetInt("length", 0);
					Be pr = leaf.Get("pieces root");
					FileEnt e = new FileEnt();
					e.RelPath = relBase.Replace('\\', '/');
					e.Path = Path.Combine(saveRoot, e.RelPath.Replace('/', Path.DirectorySeparatorChar));
					e.Length = len;
					e.Offset = off[0];
					e.Index = m.Files.Count;
					if (pr != null) e.PiecesRoot = pr.Bytes;
					m.Files.Add(e);
					off[0] += len;
					return;
				}
				foreach (KeyValuePair<string, Be> kv in node.Dict) {
					if (kv.Key == "") continue;
					string child = relBase.Length == 0 ? Bt.SafeName(kv.Key) : relBase + "/" + Bt.SafeName(kv.Key);
					WalkTree(kv.Value, child, saveRoot, m, off);
				}
			}

			static void ApplyLayers(Meta m) {
				if (m.PieceLayers == null || m.PieceLayers.Count == 0) return;
				for (int i = 0; i < m.Files.Count; i++) {
					FileEnt f = m.Files[i];
					if (f.PiecesRoot == null || f.PiecesRoot.Length != 32) continue;
					string k = BitConverter.ToString(f.PiecesRoot).Replace("-", "");
					byte[] layers;
					if (m.PieceLayers.TryGetValue(k, out layers)) f.LayerHashes = layers;
				}
			}

			static void AddTracker(Meta m, HashSet<string> seenT, string url) {
				if (string.IsNullOrEmpty(url)) return;
				url = url.Trim();
				if (url.Length == 0) return;
				if (!seenT.Add(url)) return;
				m.Trackers.Add(url);
			}
			static void AddWeb(Meta m, string url) {
				if (string.IsNullOrEmpty(url)) return;
				url = url.Trim();
				if (url.Length == 0) return;
				m.Webseeds.Add(url);
			}
		}

		sealed class PieceMgr {
			Engine eng;
			Meta m;
			FileStream[] streams;
			object gate = new object();
			bool[] done;
			int[] avail;
			byte[][] buf;
			byte[][] st;
			int n;
			int pieceLen;
			long total;
			int doneCount;
			long verified;
			long pending;
			int inFlight;
			int maxInFlight;
			const int BS = 16384;

			public PieceMgr(Engine eng, Meta m) {
				this.eng = eng;
				this.m = m;
				n = m.PieceCount;
				pieceLen = m.PieceLength;
				total = m.TotalSize;
				done = new bool[Math.Max(n, 0)];
				avail = new int[Math.Max(n, 0)];
				buf = new byte[Math.Max(n, 0)][];
				st = new byte[Math.Max(n, 0)][];
				int denom = Math.Max(16384, pieceLen);
				maxInFlight = Math.Max(8, Math.Min(48, (int)(64L * 1024 * 1024 / denom)));
			}

			public bool IsComplete { get { return n == 0 || doneCount >= n; } }
			public int DoneCount { get { return doneCount; } }
			public bool IsEndgame() {
				if (n - doneCount > 3) return false;
				return RemainingBlocks() <= 32;
			}

			public void Open() {
				streams = new FileStream[m.Files.Count];
				for (int i = 0; i < m.Files.Count; i++) {
					FileEnt f = m.Files[i];
					string dir = Path.GetDirectoryName(f.Path);
					if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
					streams[i] = new FileStream(f.Path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite, 256 * 1024);
					if (streams[i].Length != f.Length) streams[i].SetLength(f.Length);
				}
			}

			public void Close() {
				if (streams == null) return;
				for (int i = 0; i < streams.Length; i++) {
					if (streams[i] != null) {
						try { streams[i].Flush(); streams[i].Close(); } catch { }
						streams[i] = null;
					}
				}
			}

			public int PieceSize(int idx) {
				if (idx < 0 || idx >= n) return 0;
				if (idx < n - 1) return pieceLen;
				long rem = total - (long)idx * (long)pieceLen;
				return (int)rem;
			}

			int BlockCount(int idx) {
				int sz = PieceSize(idx);
				if (sz <= 0) return 0;
				return (sz + BS - 1) / BS;
			}

			int BlockLen(int idx, int b) {
				int sz = PieceSize(idx);
				int off = b * BS;
				int left = sz - off;
				if (left <= 0) return 0;
				return left > BS ? BS : left;
			}

			void IO(long offset, byte[] buffer, int bufOff, int len, bool write) {
				int remain = len;
				for (int fi = 0; fi < m.Files.Count && remain > 0; fi++) {
					FileEnt f = m.Files[fi];
					long fe = f.Offset + f.Length;
					if (offset >= fe || offset < f.Offset) continue;
					long local = offset - f.Offset;
					int nbyte = (int)Math.Min((long)remain, f.Length - local);
					FileStream s = streams[f.Index];
					lock (s) {
						s.Seek(local, SeekOrigin.Begin);
						if (write) {
							s.Write(buffer, bufOff, nbyte);
						} else {
							int need = nbyte;
							int o = bufOff;
							while (need > 0) {
								int g = s.Read(buffer, o, need);
								if (g <= 0) throw new IOException("short read");
								need -= g;
								o += g;
							}
						}
					}
					offset += nbyte;
					bufOff += nbyte;
					remain -= nbyte;
				}
				if (remain != 0) throw new IOException("io span");
			}

			public void HashCheck() {
				if (n == 0) return;
				byte[] tmp = new byte[pieceLen];
				for (int i = 0; i < n && eng.running; i++) {
					while (eng.paused && eng.running) Thread.Sleep(100);
					if (!eng.running) return;
					int sz = PieceSize(i);
					bool readOk = true;
					try { IO((long)i * (long)pieceLen, tmp, 0, sz, false); }
					catch { readOk = false; }
					if (readOk && VerifyPieceData(i, tmp, sz)) {
						done[i] = true;
						doneCount++;
						verified += sz;
					}
					if ((i & 15) == 0) eng.OnHashProgress(i + 1, n);
				}
				eng.OnHashProgress(n, n);
			}

			bool VerifyPieceData(int piece, byte[] data, int sz) {
				if (m.PieceHashes != null && m.PieceHashes.Length >= (piece + 1) * 20) {
					byte[] h;
					using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
						h = sha.ComputeHash(data, 0, sz);
					}
					int ho = piece * 20;
					for (int k = 0; k < 20; k++) if (h[k] != m.PieceHashes[ho + k]) return false;
					return true;
				}
				if (m.V2) {
					byte[] layer = Crypto.MerklePiece(data, sz);
					long off = (long)piece * (long)pieceLen;
					for (int fi = 0; fi < m.Files.Count; fi++) {
						FileEnt f = m.Files[fi];
						if (off < f.Offset || off >= f.Offset + f.Length) continue;
						if (f.LayerHashes != null && f.LayerHashes.Length >= 32) {
							int local = (int)((off - f.Offset) / pieceLen);
							int lo = local * 32;
							if (lo + 32 > f.LayerHashes.Length) return false;
							for (int k = 0; k < 32; k++) if (layer[k] != f.LayerHashes[lo + k]) return false;
							return true;
						}
						if (f.PiecesRoot != null && f.Length <= pieceLen) {
							for (int k = 0; k < 32; k++) if (layer[k] != f.PiecesRoot[k]) return false;
							return true;
						}
						return true;
					}
					return true;
				}
				return false;
			}

			bool HasFreeBlock(int idx, bool endgame) {
				int bc = BlockCount(idx);
				if (st[idx] == null) return true;
				for (int b = 0; b < bc; b++) {
					if (st[idx][b] == 0) return true;
					if (endgame && st[idx][b] == 1) return true;
				}
				return false;
			}

			int Pick(BitArray has, bool sequential, bool endgame) {
				int best = -1;
				int bestScore = int.MaxValue;
				for (int i = 0; i < n; i++) {
					if (done[i]) continue;
					if (has != null && (i >= has.Length || !has[i])) continue;
					if (!HasFreeBlock(i, endgame)) continue;
					if (st[i] == null && !endgame && inFlight >= maxInFlight) continue;
					if (sequential) return i;
					int score = (st[i] != null) ? avail[i] - 100000 : avail[i];
					if (score < bestScore) { bestScore = score; best = i; }
				}
				return best;
			}

			public bool TryClaim(BitArray has, bool sequential, bool endgame, out int piece, out int begin, out int length) {
				piece = -1;
				begin = 0;
				length = 0;
				lock (gate) {
					int pick = Pick(has, sequential, endgame);
					if (pick < 0) return false;
					int bc = BlockCount(pick);
					if (st[pick] == null) {
						st[pick] = new byte[bc];
						buf[pick] = new byte[PieceSize(pick)];
						inFlight++;
					}
					for (int b = 0; b < bc; b++) {
						byte s = st[pick][b];
						if (s == 0 || (endgame && s == 1)) {
							if (s == 0) st[pick][b] = 1;
							piece = pick;
							begin = b * BS;
							length = BlockLen(pick, b);
							return true;
						}
					}
					return false;
				}
			}

			public void Unclaim(int piece, int begin) {
				lock (gate) {
					if (piece < 0 || piece >= n || st[piece] == null) return;
					int b = begin / BS;
					if (b >= 0 && b < st[piece].Length && st[piece][b] == 1) st[piece][b] = 0;
				}
			}

			// 0 = rejected, 1 = block stored, 2 = piece verified and written
			public int Submit(int piece, int begin, byte[] data, int off, int len) {
				lock (gate) {
					if (piece < 0 || piece >= n || done[piece]) return 0;
					if (st[piece] == null || buf[piece] == null) return 0;
					int b = begin / BS;
					if (b < 0 || b >= st[piece].Length) return 0;
					int expect = BlockLen(piece, b);
					if (len != expect) return 0;
					if (st[piece][b] == 2) return 0;
					Buffer.BlockCopy(data, off, buf[piece], begin, len);
					st[piece][b] = 2;
					pending += len;
					eng.AddSessionDown(len);
					int bc = st[piece].Length;
					for (int k = 0; k < bc; k++) if (st[piece][k] != 2) return 1;
					int sz = PieceSize(piece);
					bool ok = VerifyPieceData(piece, buf[piece], sz);
					if (!ok) {
						eng.Log(1, "piece " + piece.ToString(CultureInfo.InvariantCulture) + " hash mismatch, retrying");
						pending -= sz;
						if (pending < 0) pending = 0;
						st[piece] = null;
						buf[piece] = null;
						inFlight--;
						return 0;
					}
					try {
						IO((long)piece * (long)pieceLen, buf[piece], 0, sz, true);
					} catch (Exception ex) {
						eng.Log(0, "write failed: " + ex.Message);
						pending -= sz;
						if (pending < 0) pending = 0;
						st[piece] = null;
						buf[piece] = null;
						inFlight--;
						return 0;
					}
					done[piece] = true;
					doneCount++;
					verified += sz;
					pending -= sz;
					if (pending < 0) pending = 0;
					st[piece] = null;
					buf[piece] = null;
					inFlight--;
					return 2;
				}
			}

			public bool Has(int piece) {
				if (piece < 0 || piece >= n) return false;
				return done[piece];
			}

			public byte[] ReadBlock(int piece, int begin, int length) {
				lock (gate) {
					if (!Has(piece)) return null;
					int sz = PieceSize(piece);
					if (begin < 0 || length <= 0 || begin + (long)length > sz) return null;
					byte[] data = new byte[length];
					try { IO((long)piece * (long)pieceLen + begin, data, 0, length, false); }
					catch { return null; }
					return data;
				}
			}

			public void AddAvail(BitArray has) {
				lock (gate) {
					if (has == null) return;
					int lim = Math.Min(n, has.Length);
					for (int i = 0; i < lim; i++) if (has[i]) avail[i]++;
				}
			}
			public void SubAvail(BitArray has) {
				lock (gate) {
					if (has == null) return;
					int lim = Math.Min(n, has.Length);
					for (int i = 0; i < lim; i++) if (has[i] && avail[i] > 0) avail[i]--;
				}
			}
			public void AddAvailOne(int idx) {
				lock (gate) {
					if (idx >= 0 && idx < n) avail[idx]++;
				}
			}

			public bool PeerHasSomethingWeNeed(BitArray has) {
				if (has == null) return false;
				int lim = Math.Min(n, has.Length);
				for (int i = 0; i < lim; i++) if (!done[i] && has[i]) return true;
				return false;
			}

			public int RemainingBlocks() {
				lock (gate) {
					int c = 0;
					for (int i = 0; i < n; i++) {
						if (done[i]) continue;
						int bc = BlockCount(i);
						if (st[i] == null) { c += bc; continue; }
						for (int b = 0; b < bc; b++) if (st[i][b] != 2) c++;
					}
					return c;
				}
			}

			public byte[] MakeBitfield() {
				int blen = (n + 7) / 8;
				byte[] bf = new byte[blen];
				for (int i = 0; i < n; i++) {
					if (done[i]) bf[i / 8] |= (byte)(1 << (7 - (i % 8)));
				}
				return bf;
			}

			public void Snapshot(out int dc, out int tot, out long ver, out long totb) {
				dc = doneCount;
				tot = n;
				ver = verified + pending;
				totb = total;
			}
		}

		sealed class PeerWorker {
			Engine eng;
			string host;
			int port;
			TcpClient tcp;
			PeerIo io;
			object wlock = new object();
			bool incoming;
			bool amChoked = true;
			BitArray their;
			List<int> claimsPiece = new List<int>();
			List<int> claimsBegin = new List<int>();
			List<DateTime> claimAt = new List<DateTime>();
			DateTime lastRecv;
			DateTime lastSend;
			bool addedAvail;
			bool theyExt;
			int theirUtMeta;
			int theirUtPex;
			byte[] pendingBitfield;
			List<int> pendingHaves = new List<int>();
			int lastMetaIdx = -1;
			DateTime lastMetaAt = DateTime.MinValue;

			public PeerWorker(Engine eng, string host, int port) {
				this.eng = eng;
				this.host = host;
				this.port = port;
				incoming = false;
			}
			public PeerWorker(Engine eng, TcpClient c) {
				this.eng = eng;
				this.tcp = c;
				incoming = true;
				try {
					IPEndPoint ep = (IPEndPoint)c.Client.RemoteEndPoint;
					host = ep.Address.ToString();
					port = ep.Port;
				} catch {
					host = "incoming";
					port = 0;
				}
			}
			public PeerWorker(Engine eng, UtpConn uc) {
				this.eng = eng;
				this.io = new UtpPeerIo(uc);
				incoming = true;
				host = uc.Remote.Address.ToString();
				port = uc.Remote.Port;
			}

			public void Run() {
				try {
					if (!Connect()) {
						eng.Log(2, "connect failed " + host + ":" + port.ToString(CultureInfo.InvariantCulture));
						return;
					}
					string via = (io != null) ? io.Transport : "TCP";
					eng.Log(1, "connected " + host + ":" + port.ToString(CultureInfo.InvariantCulture) + " via " + via);
					lock (eng.peerLock) eng.peers.Add(this);
					if (theyExt) SendExtHandshake();
					if (eng.pieces != null) {
						SendBitfield();
						SendInterested();
						SendUnchoke();
					}
					lastRecv = DateTime.UtcNow;
					byte[] lenBuf = new byte[4];
					while (eng.running && !eng.paused) {
						bool readable = false;
						try {
							readable = io.PollRead(50000);
							if (!readable && io.Available > 0) readable = true;
						} catch { break; }
						if (!readable) {
							Pump();
							if ((DateTime.UtcNow - lastRecv).TotalSeconds > 180) break;
							continue;
						}
						if (io.Available == 0 && !io.PollRead(0)) break;
						if (!ReadExact(lenBuf, 0, 4, 20000)) break;
						int mlen = Bt.R32(lenBuf, 0);
						if (mlen == 0) { lastRecv = DateTime.UtcNow; continue; }
						if (mlen < 0 || mlen > 262144) break;
						byte[] msg = new byte[mlen];
						if (!ReadExact(msg, 0, mlen, 20000)) break;
						lastRecv = DateTime.UtcNow;
						Handle(msg);
						Pump();
					}
				} catch (Exception ex) {
					eng.Log(3, "peer " + host + ":" + port.ToString(CultureInfo.InvariantCulture) + " " + ex.Message);
				} finally {
					Cleanup();
				}
			}

			public void Kill() {
				try { if (io != null) io.Close(); } catch { }
				try { if (tcp != null) tcp.Close(); } catch { }
			}

			public void SendHavePublic(int piece) {
				try { SendHave(piece); } catch { }
			}

			public void OnEngineHasInfo() {
				try {
					their = new BitArray(Math.Max(eng.meta.PieceCount, 0));
					if (pendingBitfield != null) ApplyBitfield(pendingBitfield);
					pendingBitfield = null;
					for (int i = 0; i < pendingHaves.Count; i++) {
						int idx = pendingHaves[i];
						if (idx >= 0 && idx < their.Length && !their[idx]) {
							their[idx] = true;
							if (eng.pieces != null) eng.pieces.AddAvailOne(idx);
						}
					}
					pendingHaves.Clear();
					SendBitfield();
					SendInterested();
					SendUnchoke();
					if (theyExt) SendExtHandshake();
				} catch { }
			}

			bool Connect() {
				if (io != null) return Handshake();
				if (incoming && tcp != null) {
					TcpPeerIo tio = new TcpPeerIo(tcp);
					if (!tio.AcceptMseOrPlain(eng.infoHash, eng.settings.EnableEncrypt)) return false;
					io = tio;
					return Handshake();
				}
				if (eng.utp != null && eng.settings.EnableUtp) {
					try {
						UtpConn uc = eng.utp.Connect(host, port, 3000);
						if (uc != null) {
							io = new UtpPeerIo(uc);
							return Handshake();
						}
					} catch { }
				}
				TcpPeerIo dio = TcpPeerIo.Dial(host, port, 5000);
				if (dio == null) return false;
				if (eng.settings.EnableEncrypt) {
					if (dio.TryMseOutgoing(eng.infoHash)) {
						io = dio;
						return Handshake();
					}
					dio.Close();
					dio = TcpPeerIo.Dial(host, port, 5000);
					if (dio == null) return false;
				}
				io = dio;
				return Handshake();
			}

			bool Handshake() {
				byte[] hs = new byte[68];
				hs[0] = 19;
				byte[] proto = Encoding.ASCII.GetBytes("BitTorrent protocol");
				Buffer.BlockCopy(proto, 0, hs, 1, 19);
				hs[25] = (byte)(hs[25] | 0x10);
				Buffer.BlockCopy(eng.infoHash, 0, hs, 28, 20);
				Buffer.BlockCopy(eng.peerId, 0, hs, 48, 20);
				byte[] theirs = new byte[68];
				if (incoming) {
					if (!ReadExact(theirs, 0, 68, 15000)) return false;
					if (!CheckHs(theirs)) return false;
					WriteAll(hs);
				} else {
					WriteAll(hs);
					if (!ReadExact(theirs, 0, 68, 15000)) return false;
					if (!CheckHs(theirs)) return false;
				}
				theyExt = (theirs[25] & 0x10) != 0;
				lastRecv = DateTime.UtcNow;
				lastSend = DateTime.UtcNow;
				int pc = (eng.meta != null) ? eng.meta.PieceCount : 0;
				their = new BitArray(Math.Max(pc, 0));
				return true;
			}

			bool CheckHs(byte[] theirs) {
				if (theirs[0] != 19) return false;
				if (Encoding.ASCII.GetString(theirs, 1, 19) != "BitTorrent protocol") return false;
				for (int i = 0; i < 20; i++) if (theirs[28 + i] != eng.infoHash[i]) return false;
				return true;
			}

			void WriteAll(byte[] msg) {
				if (msg == null || io == null) return;
				lock (wlock) {
					io.Write(msg, msg.Length);
					lastSend = DateTime.UtcNow;
				}
			}

			bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
				if (io == null) return false;
				return io.ReadExact(buf, off, n, timeoutMs);
			}

			void SendInterested() {
				byte[] msg = new byte[5];
				Bt.W32(msg, 0, 1);
				msg[4] = 2;
				WriteAll(msg);
			}
			void SendUnchoke() {
				byte[] msg = new byte[5];
				Bt.W32(msg, 0, 1);
				msg[4] = 1;
				WriteAll(msg);
			}
			void SendHave(int piece) {
				byte[] msg = new byte[9];
				Bt.W32(msg, 0, 5);
				msg[4] = 4;
				Bt.W32(msg, 5, piece);
				WriteAll(msg);
			}
			void SendExt(int extId, byte[] payload) {
				byte[] msg = new byte[6 + payload.Length];
				Bt.W32(msg, 0, 2 + payload.Length);
				msg[4] = 20;
				msg[5] = (byte)extId;
				Buffer.BlockCopy(payload, 0, msg, 6, payload.Length);
				WriteAll(msg);
			}

			void SendExtHandshake() {
				Dictionary<string, Be> m = new Dictionary<string, Be>();
				m["ut_metadata"] = Be.Int(1);
				m["ut_pex"] = Be.Int(2);
				Dictionary<string, Be> root = new Dictionary<string, Be>();
				root["m"] = Be.FromDict(m);
				if (eng.boundPort > 0) root["p"] = Be.Int(eng.boundPort);
				root["v"] = Be.Blob(Encoding.UTF8.GetBytes("PowerTorrent/1.2"));
				if (eng.settings.EnableEncrypt) root["e"] = Be.Int(1);
				if (eng.rawInfo != null) root["metadata_size"] = Be.Int(eng.rawInfo.Length);
				SendExt(0, Benc.Encode(Be.FromDict(root)));
			}

			void SendMetaRequest(int index) {
				if (theirUtMeta <= 0) return;
				Dictionary<string, Be> d = new Dictionary<string, Be>();
				d["msg_type"] = Be.Int(0);
				d["piece"] = Be.Int(index);
				SendExt(theirUtMeta, Benc.Encode(Be.FromDict(d)));
			}

			void ServeMetaPiece(int index) {
				if (theirUtMeta <= 0) return;
				byte[] data = eng.MetaPieceBytes(index);
				if (data == null) {
					Dictionary<string, Be> rej = new Dictionary<string, Be>();
					rej["msg_type"] = Be.Int(2);
					rej["piece"] = Be.Int(index);
					SendExt(theirUtMeta, Benc.Encode(Be.FromDict(rej)));
					return;
				}
				Dictionary<string, Be> d = new Dictionary<string, Be>();
				d["msg_type"] = Be.Int(1);
				d["piece"] = Be.Int(index);
				d["total_size"] = Be.Int(eng.rawInfo.Length);
				byte[] hdr = Benc.Encode(Be.FromDict(d));
				byte[] payload = new byte[hdr.Length + data.Length];
				Buffer.BlockCopy(hdr, 0, payload, 0, hdr.Length);
				Buffer.BlockCopy(data, 0, payload, hdr.Length, data.Length);
				SendExt(theirUtMeta, payload);
			}

			void ApplyBitfield(byte[] bf) {
				if (eng.pieces == null || their == null) return;
				int bits = bf.Length;
				if (addedAvail) eng.pieces.SubAvail(their);
				their = new BitArray(Math.Max(eng.meta.PieceCount, 0));
				for (int i = 0; i < eng.meta.PieceCount; i++) {
					int bi = i / 8;
					if (bi >= bits) break;
					int bit = 7 - (i % 8);
					if ((bf[bi] & (1 << bit)) != 0) their[i] = true;
				}
				eng.pieces.AddAvail(their);
				addedAvail = true;
			}

			void SendBitfield() {
				if (eng.pieces == null) return;
				byte[] bf = eng.pieces.MakeBitfield();
				bool any = false;
				for (int i = 0; i < bf.Length; i++) if (bf[i] != 0) { any = true; break; }
				if (!any) return;
				byte[] msg = new byte[5 + bf.Length];
				Bt.W32(msg, 0, 1 + bf.Length);
				msg[4] = 5;
				Buffer.BlockCopy(bf, 0, msg, 5, bf.Length);
				WriteAll(msg);
			}
			void SendRequest(int piece, int begin, int len) {
				byte[] msg = new byte[17];
				Bt.W32(msg, 0, 13);
				msg[4] = 6;
				Bt.W32(msg, 5, piece);
				Bt.W32(msg, 9, begin);
				Bt.W32(msg, 13, len);
				WriteAll(msg);
			}
			void SendKeepAlive() {
				WriteAll(new byte[4]);
			}
			void SendPieceMsg(int index, int begin, byte[] data) {
				byte[] msg = new byte[13 + data.Length];
				Bt.W32(msg, 0, 9 + data.Length);
				msg[4] = 7;
				Bt.W32(msg, 5, index);
				Bt.W32(msg, 9, begin);
				Buffer.BlockCopy(data, 0, msg, 13, data.Length);
				WriteAll(msg);
				eng.AddSessionUp(data.Length);
			}

			void Handle(byte[] msg) {
				if (msg.Length < 1) return;
				int id = msg[0];
				if (id == 0) {
					amChoked = true;
					DropClaims();
				} else if (id == 1) {
					amChoked = false;
				} else if (id == 2) {
					SendUnchoke();
				} else if (id == 4 && msg.Length >= 5) {
					int idx = Bt.R32(msg, 1);
					if (eng.pieces == null) {
						pendingHaves.Add(idx);
					} else if (their != null && idx >= 0 && idx < their.Length && !their[idx]) {
						their[idx] = true;
						eng.pieces.AddAvailOne(idx);
					}
				} else if (id == 5) {
					int bits = msg.Length - 1;
					byte[] bf = new byte[bits];
					Buffer.BlockCopy(msg, 1, bf, 0, bits);
					if (eng.pieces == null) pendingBitfield = bf;
					else {
						ApplyBitfield(bf);
						if (eng.pieces.PeerHasSomethingWeNeed(their)) SendInterested();
					}
				} else if (id == 6 && msg.Length >= 13) {
					if (eng.pieces == null) return;
					int idx = Bt.R32(msg, 1);
					int begin = Bt.R32(msg, 5);
					int len = Bt.R32(msg, 9);
					if (len > 16384 || len <= 0) return;
					byte[] data = eng.pieces.ReadBlock(idx, begin, len);
					if (data != null) SendPieceMsg(idx, begin, data);
				} else if (id == 20 && msg.Length >= 2) {
					HandleExt(msg);
				} else if (id == 7 && msg.Length >= 9) {
					int idx = Bt.R32(msg, 1);
					int begin = Bt.R32(msg, 5);
					int dlen = msg.Length - 9;
					bool match = false;
					for (int i = 0; i < claimsPiece.Count; i++) {
						if (claimsPiece[i] == idx && claimsBegin[i] == begin) {
							claimsPiece.RemoveAt(i);
							claimsBegin.RemoveAt(i);
							claimAt.RemoveAt(i);
							match = true;
							break;
						}
					}
					if (!match) return;
					if (eng.pieces == null) return;
					int stored = eng.pieces.Submit(idx, begin, msg, 9, dlen);
					if (stored == 0) eng.pieces.Unclaim(idx, begin);
					else if (stored == 2) {
						eng.Log(2, "piece " + idx.ToString(CultureInfo.InvariantCulture) + " verified");
						eng.BroadcastHave(idx);
					}
				}
			}

			void HandleExt(byte[] msg) {
				int ext = msg[1];
				if (ext == 0) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					Be m = d.Get("m");
					if (m != null && m.Dict != null) {
						theirUtMeta = (int)m.GetInt("ut_metadata", 0);
						theirUtPex = (int)m.GetInt("ut_pex", 0);
					}
					int msz = (int)d.GetInt("metadata_size", 0);
					if (msz > 0 && !eng.infoReady) eng.OfferMetaSize(msz);
				} else if (ext == 1) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					int mtype = (int)d.GetInt("msg_type", -1);
					int piece = (int)d.GetInt("piece", -1);
					if (mtype == 0) {
						ServeMetaPiece(piece);
					} else if (mtype == 1) {
						int rest = msg.Length - 2 - consumed;
						if (rest < 0) return;
						byte[] data = new byte[rest];
						if (rest > 0) Buffer.BlockCopy(msg, 2 + consumed, data, 0, rest);
						int ts = (int)d.GetInt("total_size", 0);
						if (ts > 0) eng.OfferMetaSize(ts);
						lastMetaIdx = -1;
						eng.OfferMetaPiece(piece, data);
					} else if (mtype == 2) {
						lastMetaIdx = -1;
					}
				} else if (ext == 2) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					Be added = d.Get("added");
					if (added != null && added.Bytes != null) {
						List<string> tmp = new List<string>();
						Bt.AddCompactPeers(added.Bytes, tmp);
						for (int i = 0; i < tmp.Count; i++) eng.RememberPeer(tmp[i]);
						if (tmp.Count > 0) eng.Log(2, "PEX +" + tmp.Count.ToString(CultureInfo.InvariantCulture) + " from " + host);
					}
				}
			}

			void Pump() {
				if (!eng.running || eng.paused) return;
				DateTime now = DateTime.UtcNow;
				if ((now - lastSend).TotalSeconds > 100) {
					try { SendKeepAlive(); } catch { }
				}
				if (eng.pieces == null) {
					if (theirUtMeta > 0 && !eng.infoReady) {
						if (lastMetaIdx < 0 || (now - lastMetaAt).TotalSeconds > 8) {
							int idx = eng.NextMetaPiece();
							if (idx >= 0) {
								lastMetaIdx = idx;
								lastMetaAt = now;
								try { SendMetaRequest(idx); } catch { }
							}
						}
					}
					return;
				}
				for (int i = claimsPiece.Count - 1; i >= 0; i--) {
					if ((now - claimAt[i]).TotalSeconds > 25) {
						eng.pieces.Unclaim(claimsPiece[i], claimsBegin[i]);
						claimsPiece.RemoveAt(i);
						claimsBegin.RemoveAt(i);
						claimAt.RemoveAt(i);
					}
				}
				if (amChoked) return;
				bool endgame = eng.pieces.IsEndgame();
				while (claimsPiece.Count < 32) {
					int p, b, l;
					if (!eng.pieces.TryClaim(their, eng.settings.Sequential, endgame, out p, out b, out l)) break;
					claimsPiece.Add(p);
					claimsBegin.Add(b);
					claimAt.Add(DateTime.UtcNow);
					try { SendRequest(p, b, l); }
					catch {
						eng.pieces.Unclaim(p, b);
						claimsPiece.RemoveAt(claimsPiece.Count - 1);
						claimsBegin.RemoveAt(claimsBegin.Count - 1);
						claimAt.RemoveAt(claimAt.Count - 1);
						break;
					}
				}
			}

			void DropClaims() {
				if (eng.pieces == null) {
					claimsPiece.Clear();
					claimsBegin.Clear();
					claimAt.Clear();
					return;
				}
				for (int i = 0; i < claimsPiece.Count; i++) eng.pieces.Unclaim(claimsPiece[i], claimsBegin[i]);
				claimsPiece.Clear();
				claimsBegin.Clear();
				claimAt.Clear();
			}

			void Cleanup() {
				try { DropClaims(); } catch { }
				if (addedAvail && eng.pieces != null) {
					try { eng.pieces.SubAvail(their); } catch { }
					addedAvail = false;
				}
				lock (eng.peerLock) eng.peers.Remove(this);
				try { if (io != null) io.Close(); } catch { }
				try { if (tcp != null) tcp.Close(); } catch { }
			}
		}

		public Engine(EngineSettings s) {
			if (s == null) throw new ArgumentNullException("s");
			settings = s;
			if (settings.MaxPeers <= 0) settings.MaxPeers = 40;
			if (settings.ListenPort <= 0) settings.ListenPort = 6881;
			logLevel = settings.LogLevel;
			peerId = Bt.MakePeerId();

			bool isMagnet = !string.IsNullOrEmpty(s.MagnetUri);
			if (isMagnet) {
				MagnetLink mag = MagnetLink.Parse(s.MagnetUri);
				infoHash = mag.InfoHash;
				v2Hash = mag.V2Hash;
				v2Only = mag.V2Only;
				magnetTrackers = mag.Trackers;
				magnetWebseeds = mag.Webseeds;
				meta = Meta.Stub(mag.DisplayName, mag.InfoHash, mag.Trackers, mag.Webseeds);
				infoReady = false;
				status.State = "Idle";
				status.Name = meta.Name;
				return;
			}

			if (string.IsNullOrEmpty(s.TorrentPath) || !File.Exists(s.TorrentPath))
				throw new FileNotFoundException("torrent not found", s.TorrentPath);
			byte[] torrentBytes = File.ReadAllBytes(s.TorrentPath);
			meta = Meta.Load(torrentBytes, s.SavePath);
			infoHash = meta.InfoHash;
			v2Hash = meta.V2Hash;
			v2Only = meta.V2 && meta.PieceHashes == null;
			rawInfo = meta.RawInfo;
			pieces = new PieceMgr(this, meta);
			infoReady = true;
			status.State = "Idle";
			status.Name = meta.Name;
		}

		public bool IsRunning {
			get {
				if (!running) return false;
				string st;
				lock (statusLock) st = status.State;
				if (st == "Error" || st == "Stopped" || st == "Complete") return false;
				return true;
			}
		}

		public static string Fmt(long n) {
			double v = (double)n;
			string u = "B";
			if (v >= 1024) { v /= 1024; u = "KB"; }
			if (v >= 1024) { v /= 1024; u = "MB"; }
			if (v >= 1024) { v /= 1024; u = "GB"; }
			if (v >= 1024) { v /= 1024; u = "TB"; }
			return v.ToString("0.00", CultureInfo.InvariantCulture) + " " + u;
		}

		public TorrentInfo GetInfo() {
			TorrentInfo t = new TorrentInfo();
			t.Name = meta != null ? meta.Name : "";
			t.Comment = meta != null ? (meta.Comment ?? "") : "";
			t.CreatedBy = meta != null ? (meta.CreatedBy ?? "") : "";
			t.InfoHashHex = meta != null ? meta.InfoHashHex : "";
			t.TotalSize = meta != null ? meta.TotalSize : 0;
			t.PieceLength = meta != null ? meta.PieceLength : 0;
			t.PieceCount = meta != null ? meta.PieceCount : 0;
			t.FileCount = (meta != null && meta.Files != null) ? meta.Files.Count : 0;
			t.IsMulti = meta != null && meta.IsMulti;
			t.Trackers = (meta != null) ? meta.Trackers.ToArray() : new string[0];
			t.Webseeds = (meta != null) ? meta.Webseeds.ToArray() : new string[0];
			int fc = t.FileCount;
			t.Files = new string[fc];
			for (int i = 0; i < fc; i++) {
				t.Files[i] = meta.Files[i].RelPath + "	(" + Fmt(meta.Files[i].Length) + ")";
			}
			return t;
		}

		public EngineSettings Settings { get { return settings; } }
		public bool IsPaused { get { return paused; } }

		void ZeroRates() {
			downBps = 0;
			upBps = 0;
			lastDl = Interlocked.Read(ref sessionDown);
			lastUl = Interlocked.Read(ref sessionUp);
			lastSp = DateTime.UtcNow;
		}

		public void Pause() {
			paused = true;
			ZeroRates();
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) snap[i].Kill();
			lock (statusLock) status.State = "Paused";
			Log(1, "paused");
		}

		public void Resume() {
			paused = false;
			lastDl = Interlocked.Read(ref sessionDown);
			lastUl = Interlocked.Read(ref sessionUp);
			lastSp = DateTime.UtcNow;
			if (!running) {
				Start();
				return;
			}
			lock (statusLock) {
				if (status.State == "Paused") {
					if (!infoReady) status.State = "Metadata";
					else if (pieces != null && pieces.IsComplete)
						status.State = settings.SeedAfterComplete ? "Seeding" : "Complete";
					else status.State = "Downloading";
				}
			}
			Log(1, "resumed");
		}

		public void Start() {
			if (running) return;
			running = true;
			coordThread = new Thread(Coordinator);
			coordThread.IsBackground = true;
			coordThread.Name = "PowerTorrent";
			coordThread.Start();
		}

		public void ApplyLiveSettings() {
			if (settings.MaxPeers <= 0) settings.MaxPeers = 40;
			if (settings.ListenPort <= 0) settings.ListenPort = 6881;
			if (!running) return;
			if (settings.EnableDht) {
				Thread t = dhtThread;
				if (t == null || !t.IsAlive) {
					dhtThread = new Thread(DhtRun);
					dhtThread.IsBackground = true;
					dhtThread.Start();
					Log(1, "DHT enabled");
				}
			}
			if (settings.EnableUtp && utp == null && boundPort > 0) {
				utp = new UtpHub(this);
				if (utp.Start(boundPort)) Log(1, "uTP enabled on UDP " + boundPort.ToString(CultureInfo.InvariantCulture));
				else utp = null;
			}
		}

		public void Stop() {
			paused = false;
			running = false;
			ZeroRates();
			try { if (utp != null) utp.Stop(); } catch { }
			try { if (listener != null) listener.Stop(); } catch { }
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) snap[i].Kill();
			if (startedAnnounced) {
				try { AnnounceAll("stopped"); } catch { }
			}
			if (coordThread != null && Thread.CurrentThread != coordThread) {
				try { coordThread.Join(3000); } catch { }
			}
			if (pieces != null) pieces.Close();
			ZeroRates();
			lock (statusLock) {
				if (status.State != "Complete" && status.State != "Error") status.State = "Stopped";
			}
		}

		public EngineStatus GetStatus() {
			EngineStatus s = new EngineStatus();
			int dc = 0, tot = 0;
			long ver = 0, totb = 0;
			if (pieces != null) pieces.Snapshot(out dc, out tot, out ver, out totb);
			lock (statusLock) {
				s.State = status.State;
				s.ErrorMessage = status.ErrorMessage;
			}
			s.Name = meta != null ? meta.Name : "";
			s.InfoHashHex = meta != null ? meta.InfoHashHex : "";
			s.Downloaded = ver;
			s.Uploaded = Interlocked.Read(ref sessionUp);
			s.TotalSize = meta != null ? meta.TotalSize : 0;
			if (s.State == "Metadata" || (!infoReady && pieces == null)) {
				int got, totMd;
				lock (metaLock) {
					got = mdGot;
					totMd = mdHave != null ? mdHave.Length : 0;
				}
				s.State = "Metadata";
				s.PiecesDone = got;
				s.PiecesTotal = totMd;
				s.ProgressPercent = totMd > 0 ? (100.0 * got / totMd) : 0;
				s.Eta = "metadata";
			} else if (s.State == "Hashing") {
				int hpDone, hpTot;
				lock (statusLock) {
					hpDone = status.PiecesDone;
					hpTot = status.PiecesTotal;
				}
				s.PiecesDone = hpDone;
				s.PiecesTotal = hpTot > 0 ? hpTot : tot;
				s.ProgressPercent = s.PiecesTotal > 0 ? (100.0 * hpDone / s.PiecesTotal) : 0;
				s.Eta = "checking";
			} else {
				s.ProgressPercent = s.TotalSize > 0 ? (100.0 * ver / s.TotalSize) : 0;
				s.PiecesDone = dc;
				s.PiecesTotal = tot;
				if (downBps > 64 && ver < s.TotalSize) {
					int secI = (int)((s.TotalSize - ver) / downBps);
					if (secI < 0) secI = 0;
					s.Eta = string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}", secI / 3600, (secI / 60) % 60, secI % 60);
				} else {
					s.Eta = "--";
				}
			}
			lock (peerLock) s.PeersConnected = peers.Count;
			lock (poolLock) s.PeersKnown = seen.Count;
			s.ListenPort = boundPort;
			lock (logLock) s.LogLines = logs.ToArray();
			if (paused && s.State != "Stopped" && s.State != "Error" && s.State != "Complete")
				s.State = "Paused";
			bool halt = paused || !running || s.State == "Stopped" || s.State == "Paused" || s.State == "Error" || s.State == "Complete";
			if (halt) {
				s.DownBytesPerSec = 0;
				s.UpBytesPerSec = 0;
				if (s.State == "Paused" || s.State == "Stopped" || s.State == "Complete" || s.State == "Error")
					s.Eta = "--";
			} else {
				s.DownBytesPerSec = downBps;
				s.UpBytesPerSec = upBps;
			}
			return s;
		}

		public static string SelfTest() {
			try {
				Be a = Benc.Decode(Encoding.ASCII.GetBytes("i42e"));
				if (a.Kind != 0 || a.I != 42) return "int";
				Be b = Benc.Decode(Encoding.ASCII.GetBytes("4:spam"));
				if (Encoding.ASCII.GetString(b.Bytes) != "spam") return "str";
				Be c = Benc.Decode(Encoding.ASCII.GetBytes("le"));
				if (c.List == null || c.List.Count != 0) return "elist";
				Be d = Benc.Decode(Encoding.ASCII.GetBytes("de"));
				if (d.Dict == null || d.Dict.Count != 0) return "edict";
				Be e = Benc.Decode(Encoding.ASCII.GetBytes("d3:foo3:bare"));
				if (e.Str("foo") != "bar") return "dict";
				byte[] rt = Benc.Encode(e);
				Be e2 = Benc.Decode(rt);
				if (e2.Str("foo") != "bar") return "roundtrip";

				byte[] torrent = Encoding.ASCII.GetBytes("d8:announce15:http://t.com:804:infod6:lengthi4e4:name4:test12:piece lengthi16384e6:pieces20:01234567890123456789ee");
				byte[] info = Benc.SliceDictValue(torrent, "info");
				if (info == null || info[0] != (byte)'d') return "slice";
				Be root = Benc.Decode(torrent);
				if (root.Get("info") == null) return "parse torrent";
				if (root.Get("info").GetInt("length", 0) != 4) return "info length";

				byte[] buf4 = new byte[4];
				Bt.W32(buf4, 0, 0x01020304);
				if (buf4[0] != 1 || buf4[1] != 2 || buf4[2] != 3 || buf4[3] != 4) return "w32";
				if (Bt.R32(buf4, 0) != 0x01020304) return "r32";

				byte[] buf8 = new byte[8];
				Bt.W64(buf8, 0, 0x41727101980L);
				if (buf8[2] != 0x04 || buf8[3] != 0x17 || buf8[7] != 0x80) return "w64-magic";
				if (Bt.R64(buf8, 0) != 0x41727101980L) return "r64";

				string enc = Bt.UrlEnc(new byte[] { 0x00, 0xAB, 0xFF });
				if (enc != "%00%AB%FF") return "urlenc " + enc;

				List<string> peers = new List<string>();
				Bt.AddCompactPeers(new byte[] { 1, 2, 3, 4, 0x1A, 0xE1 }, peers);
				if (peers.Count != 1 || peers[0] != "1.2.3.4:6881") return "compact " + (peers.Count > 0 ? peers[0] : "none");

				byte[] empty = Benc.Encode(Be.FromDict(new Dictionary<string, Be>()));
				if (empty.Length != 2 || empty[0] != (byte)'d' || empty[1] != (byte)'e') return "enc-de";

				int consumed;
				Be da = Benc.DecodeAt(Encoding.ASCII.GetBytes("i42eMORE"), 0, out consumed);
				if (da.I != 42 || consumed != 4) return "decodeat";

				MagnetLink mag = MagnetLink.Parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Hello%20World&tr=udp%3A%2F%2Ft.example.com%3A80");
				if (mag.InfoHashHex != "0123456789abcdef0123456789abcdef01234567") return "magnet-hex";
				if (mag.DisplayName != "Hello World") return "magnet-dn";
				if (mag.Trackers.Count != 1 || mag.Trackers[0] != "udp://t.example.com:80") return "magnet-tr";

				byte[] z = MagnetLink.FromBase32("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
				if (z == null || z.Length != 20) return "b32-len";
				for (int i = 0; i < 20; i++) if (z[i] != 0) return "b32-zero";

				byte[] h = MagnetLink.ParseInfoHash("0123456789ABCDEF0123456789ABCDEF01234567");
				if (h == null || h[0] != 0x01 || h[19] != 0x67) return "parse-hash";

				MagnetLink mag2 = MagnetLink.Parse("magnet:?xt=urn:btmh:1220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
				if (!mag2.V2Only || mag2.V2Hash == null || mag2.V2Hash.Length != 32) return "magnet-v2";
				if (mag2.InfoHash[0] != 0x00 || mag2.InfoHash[1] != 0x01 || mag2.V2Hash[31] != 0x1f) return "magnet-v2-trunc";

				Rc4 rc = new Rc4(Encoding.ASCII.GetBytes("Key"));
				byte[] pt = Encoding.ASCII.GetBytes("Plaintext");
				rc.Crypt(pt, 0, pt.Length);
				string rcHex = BitConverter.ToString(pt).Replace("-", "");
				if (rcHex != "BBF316E8D940AF0AD3") return "rc4 " + rcHex;

				BigInteger two = new BigInteger(2);
				byte[] pub = Crypto.DhPub(two);
				if (pub.Length != 96 || pub[95] != 4) return "dh-pub";
				byte[] sec = Crypto.DhSecret(pub, two);
				if (sec[95] != 16) return "dh-sec";

				byte[] leaf = new byte[16384];
				byte[] mroot = Crypto.MerklePiece(leaf, leaf.Length);
				if (mroot == null || mroot.Length != 32) return "merkle";
				return null;
			} catch (Exception ex) {
				return ex.ToString();
			}
		}

		void AddSessionDown(int n) { Interlocked.Add(ref sessionDown, n); }
		void AddSessionUp(int n) { Interlocked.Add(ref sessionUp, n); }

		void Log(int level, string msg) {
			if (level > logLevel) return;
			string line = DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + msg;
			lock (logLock) {
				logs.Add(line);
				while (logs.Count > 15) logs.RemoveAt(0);
			}
		}

		void OnHashProgress(int cur, int tot) {
			lock (statusLock) {
				status.State = "Hashing";
				status.PiecesDone = cur;
				status.PiecesTotal = tot;
			}
		}

		void BroadcastHave(int piece) {
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) {
				try { snap[i].SendHavePublic(piece); } catch { }
			}
		}

		bool OfferMetaSize(int size) {
			if (size <= 0 || size > 8 * 1024 * 1024) return false;
			lock (metaLock) {
				if (mdSize < 0) {
					mdSize = size;
					int n = (size + 16383) / 16384;
					mdPieces = new byte[n][];
					mdHave = new bool[n];
					mdGot = 0;
					Log(1, "metadata size " + size.ToString(CultureInfo.InvariantCulture) + " bytes (" + n.ToString(CultureInfo.InvariantCulture) + " piece(s))");
					return true;
				}
				return mdSize == size;
			}
		}

		int NextMetaPiece() {
			lock (metaLock) {
				if (mdHave == null) return -1;
				for (int i = 0; i < mdHave.Length; i++) if (!mdHave[i]) return i;
				return -1;
			}
		}

		byte[] MetaPieceBytes(int index) {
			lock (metaLock) {
				if (rawInfo == null) return null;
				int sz = rawInfo.Length;
				int n = (sz + 16383) / 16384;
				if (index < 0 || index >= n) return null;
				int off = index * 16384;
				int len = Math.Min(16384, sz - off);
				byte[] b = new byte[len];
				Buffer.BlockCopy(rawInfo, off, b, 0, len);
				return b;
			}
		}

		void OfferMetaPiece(int index, byte[] data) {
			byte[] assembled = null;
			lock (metaLock) {
				if (infoReady || mdHave == null || index < 0 || index >= mdHave.Length) return;
				if (mdHave[index]) return;
				int expect = (index == mdHave.Length - 1) ? (mdSize - index * 16384) : 16384;
				if (data == null || data.Length != expect) return;
				mdPieces[index] = data;
				mdHave[index] = true;
				mdGot++;
				if (mdGot < mdHave.Length) {
					Log(2, "metadata piece " + index.ToString(CultureInfo.InvariantCulture) + " (" + mdGot.ToString(CultureInfo.InvariantCulture) + "/" + mdHave.Length.ToString(CultureInfo.InvariantCulture) + ")");
					return;
				}
				assembled = new byte[mdSize];
				int o = 0;
				for (int i = 0; i < mdPieces.Length; i++) {
					Buffer.BlockCopy(mdPieces[i], 0, assembled, o, mdPieces[i].Length);
					o += mdPieces[i].Length;
				}
			}
			if (assembled == null) return;
			byte[] hash;
			using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
				hash = sha.ComputeHash(assembled);
			}
			bool hashOk = true;
			if (v2Only && v2Hash != null && v2Hash.Length == 32) {
				byte[] h256 = Crypto.Sha256All(assembled);
				for (int k = 0; k < 32; k++) if (h256[k] != v2Hash[k]) hashOk = false;
			} else {
				for (int k = 0; k < 20; k++) if (hash[k] != infoHash[k]) hashOk = false;
			}
			if (!hashOk) {
					Log(0, "metadata hash mismatch, retrying");
					lock (metaLock) {
						mdSize = -1;
						mdPieces = null;
						mdHave = null;
						mdGot = 0;
					}
					return;
			}
			fetchedInfo = assembled;
			infoReady = true;
			Log(1, "metadata received (" + assembled.Length.ToString(CultureInfo.InvariantCulture) + " bytes)");
		}

		void ApplyFetchedInfo() {
			if (fetchedInfo == null) throw new Exception("no metadata");
			Meta loaded = Meta.FromInfoBytes(fetchedInfo, settings.SavePath);
			HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
			for (int i = 0; i < loaded.Trackers.Count; i++) seenT.Add(loaded.Trackers[i]);
			for (int i = 0; i < magnetTrackers.Count; i++) MetaAddTracker(loaded, seenT, magnetTrackers[i]);
			for (int i = 0; i < magnetWebseeds.Count; i++) {
				if (!string.IsNullOrEmpty(magnetWebseeds[i]) && !loaded.Webseeds.Contains(magnetWebseeds[i]))
					loaded.Webseeds.Add(magnetWebseeds[i]);
			}
			meta = loaded;
			rawInfo = fetchedInfo;
			pieces = new PieceMgr(this, meta);
			status.Name = meta.Name;
			Log(1, "torrent: " + meta.Name + " (" + Fmt(meta.TotalSize) + ", " + meta.PieceCount.ToString(CultureInfo.InvariantCulture) + " pieces)");
			SaveTorrentFile();
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) {
				try { snap[i].OnEngineHasInfo(); } catch { }
			}
		}

		static void MetaAddTracker(Meta m, HashSet<string> seenT, string url) {
			if (string.IsNullOrEmpty(url)) return;
			url = url.Trim();
			if (url.Length == 0) return;
			if (!seenT.Add(url)) return;
			m.Trackers.Add(url);
		}

		void SaveTorrentFile() {
			try {
				if (rawInfo == null || meta == null) return;
				string path = Path.Combine(settings.SavePath, meta.Name + ".torrent");
				MemoryStream ms = new MemoryStream();
				ms.WriteByte((byte)'d');
				if (meta.Trackers.Count > 0) {
					WriteBencBytes(ms, Encoding.UTF8.GetBytes("announce"));
					WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Trackers[0]));
					if (meta.Trackers.Count > 1) {
						WriteBencBytes(ms, Encoding.UTF8.GetBytes("announce-list"));
						ms.WriteByte((byte)'l');
						for (int i = 0; i < meta.Trackers.Count; i++) {
							ms.WriteByte((byte)'l');
							WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Trackers[i]));
							ms.WriteByte((byte)'e');
						}
						ms.WriteByte((byte)'e');
					}
				}
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("created by"));
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("PowerTorrent/1.2"));
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("info"));
				ms.Write(rawInfo, 0, rawInfo.Length);
				if (meta.Webseeds.Count > 0) {
					WriteBencBytes(ms, Encoding.UTF8.GetBytes("url-list"));
					ms.WriteByte((byte)'l');
					for (int i = 0; i < meta.Webseeds.Count; i++)
						WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Webseeds[i]));
					ms.WriteByte((byte)'e');
				}
				ms.WriteByte((byte)'e');
				File.WriteAllBytes(path, ms.ToArray());
				Log(1, "wrote " + path);
			} catch (Exception ex) {
				Log(1, "could not save .torrent: " + ex.Message);
			}
		}

		static void WriteBencBytes(MemoryStream ms, byte[] data) {
			byte[] hdr = Encoding.ASCII.GetBytes(data.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(hdr, 0, hdr.Length);
			ms.Write(data, 0, data.Length);
		}

		void RememberPeer(string ep) {
			if (string.IsNullOrEmpty(ep)) return;
			lock (poolLock) {
				if (seen.Add(ep)) pool.Enqueue(ep);
			}
		}

		string NextPeer() {
			lock (poolLock) {
				if (pool.Count == 0) return null;
				return pool.Dequeue();
			}
		}

		void RecyclePeers() {
			lock (poolLock) {
				if (pool.Count > 0) return;
				if (seen.Count == 0) return;
				if ((DateTime.UtcNow - lastRecycle).TotalSeconds < 90) return;
				lastRecycle = DateTime.UtcNow;
				foreach (string s in seen) pool.Enqueue(s);
				Log(2, "re-queued " + seen.Count.ToString(CultureInfo.InvariantCulture) + " peers");
			}
		}

		void UpdateSpeed() {
			DateTime n = DateTime.UtcNow;
			double dt = (n - lastSp).TotalSeconds;
			if (dt < 0.4) return;
			long dl = Interlocked.Read(ref sessionDown);
			long ul = Interlocked.Read(ref sessionUp);
			double nd = (dl - lastDl) / dt;
			double nu = (ul - lastUl) / dt;
			downBps = downBps * 0.65 + nd * 0.35;
			upBps = upBps * 0.65 + nu * 0.35;
			lastDl = dl;
			lastUl = ul;
			lastSp = n;
		}

		void Coordinator() {
			try {
				try {
					ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
				} catch { }
				ServicePointManager.DefaultConnectionLimit = 32;
				ServicePointManager.Expect100Continue = false;

				lock (statusLock) status.State = "Preparing";
				Log(1, "info hash " + meta.InfoHashHex);
				StartListen();
				if (!string.IsNullOrEmpty(settings.ForcedPeer)) RememberPeer(settings.ForcedPeer);

				if (meta.Trackers.Count > 0) {
					lock (statusLock) status.State = infoReady ? "Announcing" : "Metadata";
					Log(1, "announcing to " + meta.Trackers.Count.ToString(CultureInfo.InvariantCulture) + " tracker(s)");
					AnnounceAll("started");
					startedAnnounced = true;
				}

				if (settings.EnableDht) {
					dhtThread = new Thread(DhtRun);
					dhtThread.IsBackground = true;
					dhtThread.Start();
				}

				if (!infoReady) {
					lock (statusLock) status.State = "Metadata";
					if (meta.Trackers.Count == 0 && !settings.EnableDht && string.IsNullOrEmpty(settings.ForcedPeer))
						Log(0, "magnet has no trackers, DHT is off, and no -Peer was given");
					Log(1, "fetching metadata via LTEP/ut_metadata (BEP 9/10)");
					while (running && !infoReady) {
						if (paused) { Thread.Sleep(250); continue; }
						RecyclePeers();
						FillPeers();
						Thread.Sleep(250);
					}
					if (!running) return;
					ApplyFetchedInfo();
				}

				lock (statusLock) status.State = "Preparing";
				pieces.Open();
				lock (statusLock) status.State = "Hashing";
				Log(1, "checking existing pieces...");
				pieces.HashCheck();
				if (!running) return;

				int dc0, tot0; long ver0, totb0;
				pieces.Snapshot(out dc0, out tot0, out ver0, out totb0);
				Log(1, "have " + dc0.ToString(CultureInfo.InvariantCulture) + "/" + tot0.ToString(CultureInfo.InvariantCulture) + " pieces (" + Fmt(ver0) + ")");

				if (meta.Trackers.Count > 0) {
					lock (statusLock) status.State = "Announcing";
					string ev = startedAnnounced ? "" : "started";
					AnnounceAll(ev);
					startedAnnounced = true;
				}

				if (meta.Webseeds.Count > 0) {
					Thread wt = new Thread(WebseedRun);
					wt.IsBackground = true;
					wt.Start();
					Log(1, "webseeds: " + meta.Webseeds.Count.ToString(CultureInfo.InvariantCulture));
				}

				DateTime lastAnn = DateTime.UtcNow;
				lastSp = DateTime.UtcNow;
				while (running) {
					if (paused) {
						ZeroRates();
						lock (statusLock) status.State = "Paused";
						Thread.Sleep(250);
						continue;
					}
					UpdateSpeed();
					RecyclePeers();
					FillPeers();
					if (pieces.IsComplete) {
						if (settings.SeedAfterComplete) {
							lock (statusLock) {
								if (status.State != "Seeding") {
									status.State = "Seeding";
									Log(1, "download complete, seeding");
									ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll("completed"); } catch { } });
								}
							}
						} else {
							lock (statusLock) status.State = "Complete";
							Log(1, "download complete");
							ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll("completed"); } catch { } });
							running = false;
							break;
						}
					} else {
						lock (statusLock) {
							if (status.State != "Hashing") status.State = "Downloading";
						}
					}
					if ((DateTime.UtcNow - lastAnn).TotalSeconds >= announceInterval) {
						lastAnn = DateTime.UtcNow;
						ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll(""); } catch { } });
					}
					Thread.Sleep(100);
				}
			} catch (Exception ex) {
				lock (statusLock) {
					status.State = "Error";
					status.ErrorMessage = ex.Message;
				}
				Log(0, "engine error: " + ex.Message);
			}
		}

		void FillPeers() {
			if (paused) return;
			for (int k = 0; k < 16; k++) {
				if (activePeerThreads >= settings.MaxPeers) return;
				lock (peerLock) {
					if (activePeerThreads - peers.Count >= 24) return;
				}
				string ep = NextPeer();
				if (ep == null) return;
				string[] parts = ep.Split(':');
				if (parts.Length != 2) continue;
				int p;
				if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out p)) continue;
				if (p <= 0 || p > 65535) continue;
				StartOutgoing(parts[0], p);
			}
		}

		void StartOutgoing(string host, int port) {
			Interlocked.Increment(ref activePeerThreads);
			Thread t = new Thread(delegate(object state) {
				try {
					object[] hp = (object[])state;
					PeerWorker w = new PeerWorker(this, (string)hp[0], (int)hp[1]);
					w.Run();
				} finally {
					Interlocked.Decrement(ref activePeerThreads);
				}
			});
			t.IsBackground = true;
			t.Start(new object[] { host, port });
		}

		void StartIncoming(TcpClient client) {
			Interlocked.Increment(ref activePeerThreads);
			Thread t = new Thread(delegate(object state) {
				try {
					PeerWorker w = new PeerWorker(this, (TcpClient)state);
					w.Run();
				} finally {
					Interlocked.Decrement(ref activePeerThreads);
				}
			});
			t.IsBackground = true;
			t.Start(client);
		}

		internal void StartIncomingUtp(UtpConn c) {
			if (!running || paused || activePeerThreads >= settings.MaxPeers) {
				try { c.Close(); } catch { }
				return;
			}
			Interlocked.Increment(ref activePeerThreads);
			Thread t = new Thread(delegate(object state) {
				try {
					PeerWorker w = new PeerWorker(this, (UtpConn)state);
					w.Run();
				} finally {
					Interlocked.Decrement(ref activePeerThreads);
				}
			});
			t.IsBackground = true;
			t.Start(c);
		}

		void StartListen() {
			int p = settings.ListenPort;
			for (int i = 0; i < 10; i++) {
				try {
					listener = new TcpListener(IPAddress.Any, p + i);
					listener.Start();
					boundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
					Log(1, "listening on TCP " + boundPort.ToString(CultureInfo.InvariantCulture));
					acceptThread = new Thread(AcceptLoop);
					acceptThread.IsBackground = true;
					acceptThread.Start();
					if (settings.EnableUtp) {
						utp = new UtpHub(this);
						if (utp.Start(boundPort)) Log(1, "listening on UDP/uTP " + boundPort.ToString(CultureInfo.InvariantCulture));
						else { utp = null; Log(1, "uTP bind failed"); }
					}
					return;
				} catch {
					listener = null;
				}
			}
			boundPort = settings.ListenPort;
			Log(1, "could not bind a listen port; outgoing connections only");
		}

		void AcceptLoop() {
			while (running && listener != null) {
				try {
					if (!listener.Server.Poll(500000, SelectMode.SelectRead)) continue;
					TcpClient c = listener.AcceptTcpClient();
					if (paused || activePeerThreads >= settings.MaxPeers) {
						try { c.Close(); } catch { }
						continue;
					}
					StartIncoming(c);
				} catch {
					if (!running) break;
				}
			}
		}

		void AnnounceAll(string ev) {
			List<string> urls = meta.Trackers;
			if (urls.Count == 0) {
				Log(1, "no trackers in torrent");
				return;
			}
			List<string> collected = new List<string>();
			int remaining = urls.Count;
			ManualResetEvent done = new ManualResetEvent(false);
			for (int i = 0; i < urls.Count; i++) {
				ThreadPool.QueueUserWorkItem(delegate(object state) {
					string u = (string)state;
					try {
						List<string> local = new List<string>();
						string scheme = "";
						try { scheme = new Uri(u).Scheme.ToLowerInvariant(); } catch { }
						if (scheme == "udp") QueryUdp(u, ev, local);
						else if (scheme == "http" || scheme == "https") QueryHttp(u, ev, local);
						else Log(2, "skip tracker " + u);
						lock (collected) {
							for (int k = 0; k < local.Count; k++) collected.Add(local[k]);
						}
						if (local.Count > 0)
							Log(1, local.Count.ToString(CultureInfo.InvariantCulture) + " peers from " + u);
					} catch (Exception ex) {
						Log(2, "tracker " + u + " " + ex.Message);
					} finally {
						if (Interlocked.Decrement(ref remaining) == 0) done.Set();
					}
				}, urls[i]);
			}
			done.WaitOne(ev == "stopped" ? 2000 : 18000);
			lock (collected) {
				for (int i = 0; i < collected.Count; i++) RememberPeer(collected[i]);
			}
		}

		void QueryUdp(string url, string ev, List<string> peersOut) {
			Uri uri;
			try { uri = new Uri(url); } catch { return; }
			if (uri.Port <= 0) { Log(2, "UDP tracker missing port: " + url); return; }
			IPAddress ip = Bt.ResolveV4(uri.Host);
			if (ip == null) { Log(2, "UDP DNS failed: " + uri.Host); return; }
			UdpClient udp = new UdpClient();
			try {
				udp.Client.ReceiveTimeout = 8000;
				udp.Connect(ip, uri.Port);
				Random rng = new Random(Guid.NewGuid().GetHashCode());
				byte[] req = new byte[16];
				Bt.W64(req, 0, 0x41727101980L);
				Bt.W32(req, 8, 0);
				int tx = rng.Next();
				Bt.W32(req, 12, tx);
				udp.Send(req, req.Length);
				IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
				byte[] resp = udp.Receive(ref ep);
				if (resp == null || resp.Length < 16) return;
				if (Bt.R32(resp, 0) != 0) return;
				if (Bt.R32(resp, 4) != tx) return;
				byte[] conn = new byte[8];
				Buffer.BlockCopy(resp, 8, conn, 0, 8);

				byte[] a = new byte[98];
				Buffer.BlockCopy(conn, 0, a, 0, 8);
				Bt.W32(a, 8, 1);
				tx = rng.Next();
				Bt.W32(a, 12, tx);
				Buffer.BlockCopy(infoHash, 0, a, 16, 20);
				Buffer.BlockCopy(peerId, 0, a, 36, 20);
				int dc = 0, totp = 0; long ver = 0, totb = 0;
				if (pieces != null) pieces.Snapshot(out dc, out totp, out ver, out totb);
				else totb = 1;
				Bt.W64(a, 56, Interlocked.Read(ref sessionDown));
				Bt.W64(a, 64, Math.Max(0, totb - ver));
				Bt.W64(a, 72, Interlocked.Read(ref sessionUp));
				int evn = 0;
				if (ev == "completed") evn = 1;
				else if (ev == "started") evn = 2;
				else if (ev == "stopped") evn = 3;
				Bt.W32(a, 80, evn);
				Bt.W32(a, 84, 0);
				Bt.W32(a, 88, rng.Next());
				Bt.W32(a, 92, 80);
				a[96] = (byte)((boundPort >> 8) & 0xFF);
				a[97] = (byte)(boundPort & 0xFF);
				udp.Send(a, a.Length);
				resp = udp.Receive(ref ep);
				if (resp == null || resp.Length < 20) return;
				if (Bt.R32(resp, 4) != tx) return;
				int action = Bt.R32(resp, 0);
				if (action == 3) {
					Log(1, "UDP tracker error " + url);
					return;
				}
				if (action != 1) return;
				int iv = Bt.R32(resp, 8);
				if (iv >= 60) {
					lock (statusLock) {
						if (iv < announceInterval) announceInterval = iv;
					}
				}
				if (resp.Length > 20) {
					byte[] compact = new byte[resp.Length - 20];
					Buffer.BlockCopy(resp, 20, compact, 0, compact.Length);
					Bt.AddCompactPeers(compact, peersOut);
				}
			} catch (Exception ex) {
				Log(2, "UDP " + url + " " + ex.Message);
			} finally {
				try { udp.Close(); } catch { }
			}
		}

		void QueryHttp(string url, string ev, List<string> peersOut) {
			try {
				string sep = url.IndexOf('?') >= 0 ? "&" : "?";
				int dc = 0, totp = 0; long ver = 0, totb = 0;
				if (pieces != null) pieces.Snapshot(out dc, out totp, out ver, out totb);
				else totb = 1;
				StringBuilder sb = new StringBuilder();
				sb.Append(url);
				sb.Append(sep);
				sb.Append("info_hash=");
				sb.Append(Bt.UrlEnc(infoHash));
				sb.Append("&peer_id=");
				sb.Append(Bt.UrlEnc(peerId));
				sb.Append("&port=");
				sb.Append(boundPort.ToString(CultureInfo.InvariantCulture));
				sb.Append("&uploaded=");
				sb.Append(Interlocked.Read(ref sessionUp).ToString(CultureInfo.InvariantCulture));
				sb.Append("&downloaded=");
				sb.Append(Interlocked.Read(ref sessionDown).ToString(CultureInfo.InvariantCulture));
				sb.Append("&left=");
				sb.Append(Math.Max(0, totb - ver).ToString(CultureInfo.InvariantCulture));
				sb.Append("&compact=1&numwant=80&supportcrypto=1");
				if (!string.IsNullOrEmpty(ev)) {
					sb.Append("&event=");
					sb.Append(ev);
				}
				HttpWebRequest req = (HttpWebRequest)WebRequest.Create(sb.ToString());
				req.Method = "GET";
				req.UserAgent = "PowerTorrent/1.2";
				req.Timeout = 15000;
				req.ReadWriteTimeout = 15000;
				req.KeepAlive = false;
				req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
				using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
				using (Stream rs = resp.GetResponseStream()) {
					MemoryStream ms = new MemoryStream();
					byte[] tmp = new byte[4096];
					int n;
					while ((n = rs.Read(tmp, 0, tmp.Length)) > 0) ms.Write(tmp, 0, n);
					byte[] body = ms.ToArray();
					Be dict = Benc.Decode(body);
					if (dict == null || dict.Dict == null) return;
					Be fail = dict.Get("failure reason");
					if (fail != null && fail.Bytes != null) {
						Log(1, "tracker " + url + ": " + Encoding.UTF8.GetString(fail.Bytes));
						return;
					}
					long iv = dict.GetInt("interval", 0);
					if (iv >= 60) {
						lock (statusLock) {
							if ((int)iv < announceInterval) announceInterval = (int)iv;
						}
					}
					Be p = dict.Get("peers");
					if (p != null && p.Bytes != null) Bt.AddCompactPeers(p.Bytes, peersOut);
					else if (p != null && p.List != null) {
						for (int i = 0; i < p.List.Count; i++) {
							Be d2 = p.List[i];
							if (d2.Dict == null) continue;
							string ip = d2.Str("ip");
							long prt = d2.GetInt("port", 0);
							if (!string.IsNullOrEmpty(ip) && prt > 0)
								peersOut.Add(ip + ":" + prt.ToString(CultureInfo.InvariantCulture));
						}
					}
				}
			} catch (Exception ex) {
				Log(2, "HTTP " + url + " " + ex.Message);
			}
		}

		static byte[] BuildGetPeers(byte[] nodeId, byte[] ih, byte[] tid) {
			MemoryStream ms = new MemoryStream();
			byte[] p1 = Encoding.ASCII.GetBytes("d1:ad2:id20:");
			ms.Write(p1, 0, p1.Length);
			ms.Write(nodeId, 0, 20);
			byte[] p2 = Encoding.ASCII.GetBytes("9:info_hash20:");
			ms.Write(p2, 0, p2.Length);
			ms.Write(ih, 0, 20);
			byte[] p3 = Encoding.ASCII.GetBytes("e1:q9:get_peers1:t");
			ms.Write(p3, 0, p3.Length);
			byte[] p4 = Encoding.ASCII.GetBytes(tid.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p4, 0, p4.Length);
			ms.Write(tid, 0, tid.Length);
			byte[] p5 = Encoding.ASCII.GetBytes("1:y1:qe");
			ms.Write(p5, 0, p5.Length);
			return ms.ToArray();
		}

		static byte[] BuildAnnouncePeer(byte[] nodeId, byte[] ih, byte[] token, int port, byte[] tid) {
			MemoryStream ms = new MemoryStream();
			byte[] p1 = Encoding.ASCII.GetBytes("d1:ad2:id20:");
			ms.Write(p1, 0, p1.Length);
			ms.Write(nodeId, 0, 20);
			byte[] p2 = Encoding.ASCII.GetBytes("9:info_hash20:");
			ms.Write(p2, 0, p2.Length);
			ms.Write(ih, 0, 20);
			byte[] p3 = Encoding.ASCII.GetBytes("4:porti" + port.ToString(CultureInfo.InvariantCulture) + "e5:token" + token.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p3, 0, p3.Length);
			ms.Write(token, 0, token.Length);
			byte[] p4 = Encoding.ASCII.GetBytes("e1:q13:announce_peer1:t" + tid.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p4, 0, p4.Length);
			ms.Write(tid, 0, tid.Length);
			byte[] p5 = Encoding.ASCII.GetBytes("1:y1:qe");
			ms.Write(p5, 0, p5.Length);
			return ms.ToArray();
		}

		void DhtRun() {
			string[] boots = new string[] {
				"router.bittorrent.com:6881",
				"dht.transmissionbt.com:6881",
				"router.utorrent.com:6881",
				"dht.libtorrent.org:25401"
			};
			byte[] nid = new byte[20];
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			rng.GetBytes(nid);
			rng.Dispose();
			Queue<string> nodes = new Queue<string>();
			HashSet<string> tried = new HashSet<string>();
			for (int i = 0; i < boots.Length; i++) nodes.Enqueue(boots[i]);
			int queries = 0;
			int maxQueries = infoReady ? 32 : 120;
			while (running && queries < maxQueries) {
				if (!settings.EnableDht) { Thread.Sleep(400); continue; }
				if (pieces != null && pieces.IsComplete) break;
				if (nodes.Count == 0) break;
				string n = nodes.Dequeue();
				if (!tried.Add(n)) continue;
				queries++;
				try {
					int colon = n.LastIndexOf(':');
					if (colon <= 0) continue;
					int p = int.Parse(n.Substring(colon + 1), CultureInfo.InvariantCulture);
					string h = n.Substring(0, colon);
					IPAddress ip = Bt.ResolveV4(h);
					if (ip == null) continue;
					byte[] tid = new byte[2];
					tid[0] = (byte)queries;
					tid[1] = 7;
					byte[] msg = BuildGetPeers(nid, infoHash, tid);
					UdpClient udp = new UdpClient();
					try {
						udp.Client.ReceiveTimeout = 2500;
						udp.Connect(ip, p);
						udp.Send(msg, msg.Length);
						IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
						byte[] resp = udp.Receive(ref ep);
						Be dict = Benc.Decode(resp);
						if (dict == null) continue;
						Be r = dict.Get("r");
						if (r == null) continue;
						Be values = r.Get("values");
						if (values != null && values.List != null) {
							int added = 0;
							for (int i = 0; i < values.List.Count; i++) {
								byte[] v = values.List[i].Bytes;
								if (v == null || v.Length < 6) continue;
								List<string> tmp = new List<string>();
								Bt.AddCompactPeers(v, tmp);
								for (int k = 0; k < tmp.Count; k++) {
									RememberPeer(tmp[k]);
									added++;
								}
							}
							if (added > 0) Log(1, "DHT +" + added.ToString(CultureInfo.InvariantCulture) + " peers from " + n);
						}
						Be tok = r.Get("token");
						if (tok != null && tok.Bytes != null && tok.Bytes.Length > 0 && tok.Bytes.Length <= 64 && boundPort > 0) {
							byte[] tid2 = new byte[2];
							tid2[0] = (byte)(queries + 3);
							tid2[1] = 9;
							byte[] amsg = BuildAnnouncePeer(nid, infoHash, tok.Bytes, boundPort, tid2);
							try { udp.Send(amsg, amsg.Length); } catch { }
						}
						Be nd = r.Get("nodes");
						if (nd != null && nd.Bytes != null) {
							byte[] nb = nd.Bytes;
							int cnt = nb.Length / 26;
							for (int i = 0; i < cnt; i++) {
								int o = i * 26 + 20;
								int np = (nb[o + 4] << 8) | nb[o + 5];
								if (np <= 0) continue;
								if (nb[o] == 0 || nb[o] == 127) continue;
								string ns = string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}:{4}", nb[o], nb[o + 1], nb[o + 2], nb[o + 3], np);
								if (!tried.Contains(ns)) nodes.Enqueue(ns);
							}
						}
					} finally {
						try { udp.Close(); } catch { }
					}
				} catch { }
			}
		}

		void WebseedRun() {
			while (running && pieces != null && !pieces.IsComplete) {
				if (paused) { Thread.Sleep(250); continue; }
				try {
					BitArray all = new BitArray(Math.Max(meta.PieceCount, 0));
					all.SetAll(true);
					int piece, begin, len;
					bool endgame = pieces.RemainingBlocks() <= 32;
					if (!pieces.TryClaim(all, settings.Sequential, endgame, out piece, out begin, out len)) {
						Thread.Sleep(1000);
						continue;
					}
					bool ok = false;
					for (int w = 0; w < meta.Webseeds.Count && !ok && running; w++) {
						ok = FetchWebseedBlock(meta.Webseeds[w], piece, begin, len);
					}
					if (!ok) {
						pieces.Unclaim(piece, begin);
						Thread.Sleep(800);
					}
				} catch {
					Thread.Sleep(1000);
				}
			}
		}

		bool FetchWebseedBlock(string baseUrl, int piece, int begin, int length) {
			long off = (long)piece * (long)meta.PieceLength + begin;
			byte[] data = new byte[length];
			long cursor = off;
			int remain = length;
			int bufOff = 0;
			for (int fi = 0; fi < meta.Files.Count && remain > 0; fi++) {
				FileEnt f = meta.Files[fi];
				long fe = f.Offset + f.Length;
				if (cursor >= fe || cursor < f.Offset) continue;
				long local = cursor - f.Offset;
				int n = (int)Math.Min((long)remain, f.Length - local);
				string url = CombineUrl(baseUrl, f.RelPath, meta.IsMulti);
				if (!HttpRange(url, local, n, data, bufOff)) return false;
				cursor += n;
				remain -= n;
				bufOff += n;
			}
			if (remain != 0) return false;
			int stored = pieces.Submit(piece, begin, data, 0, length);
			if (stored == 0) return false;
			if (stored == 2) BroadcastHave(piece);
			return true;
		}

		static string CombineUrl(string baseUrl, string rel, bool multi) {
			if (!multi) {
				if (baseUrl.EndsWith("/")) return baseUrl + rel.Replace('\\', '/');
				return baseUrl;
			}
			string r = rel.Replace('\\', '/');
			if (!baseUrl.EndsWith("/")) baseUrl += "/";
			return baseUrl + r;
		}

		bool HttpRange(string url, long start, int n, byte[] dest, int destOff) {
			HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
			req.Method = "GET";
			req.UserAgent = "PowerTorrent/1.2";
			req.Timeout = 20000;
			req.ReadWriteTimeout = 20000;
			req.AddRange(start, start + n - 1);
			req.KeepAlive = false;
			using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
				if (resp.StatusCode == HttpStatusCode.OK && start != 0) return false;
				if (resp.StatusCode != HttpStatusCode.PartialContent && resp.StatusCode != HttpStatusCode.OK) return false;
				using (Stream s = resp.GetResponseStream()) {
					int got = 0;
					while (got < n) {
						int r = s.Read(dest, destOff + got, n - got);
						if (r <= 0) return false;
						got += r;
					}
				}
				return true;
			}
		}
	}
}
'@

function Initialize-PowerTorrentEngine {
	if ('PowerTorrent.Engine' -as [type]) { return }
	Write-Host 'Compiling PowerTorrent engine (C# / .NET 4.5)...' -ForegroundColor DarkCyan
	try {
		Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue | Out-Null
	} catch { }
	$refs = @()
	try { $refs += [System.Numerics.BigInteger].Assembly.Location } catch { }
	try {
		if ($refs.Count -gt 0) {
			Add-Type -TypeDefinition $script:PowerTorrentCSharp -Language CSharp -ReferencedAssemblies $refs -ErrorAction Stop
		} else {
			Add-Type -TypeDefinition $script:PowerTorrentCSharp -Language CSharp -ErrorAction Stop
		}
	} catch {
		Write-Host 'C# compile failed:' -ForegroundColor Red
		if ($_.Exception.InnerException -and $_.Exception.InnerException.LoaderExceptions) {
			$_.Exception.InnerException.LoaderExceptions | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }
		}
		Write-Host $_ -ForegroundColor Red
		throw
	}
}

function Select-TorrentFile {
	if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
		throw 'File picker requires STA. Pass -Torrent <path> instead.'
	}
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	$dlg = New-Object System.Windows.Forms.OpenFileDialog
	$dlg.Filter = 'Torrent files (*.torrent)|*.torrent|All files (*.*)|*.*'
	$dlg.Title = 'Select a Torrent File'
	$dlg.InitialDirectory = (Get-Location).Path
	$dlg.Multiselect = $false
	if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		return $dlg.FileName
	}
	return $null
}

function Write-Padded([string]$text, [ConsoleColor]$color = [ConsoleColor]::Gray) {
	$w = 80
	try { $w = [Math]::Max(40, [Console]::WindowWidth - 1) } catch { }
	if ($null -eq $text) { $text = '' }
	if ($text.Length -ge $w) { $text = $text.Substring(0, $w) }
	Write-Host ($text.PadRight($w)) -ForegroundColor $color
}

function Show-TorrentDashboard {
	param($s)
	$stateColor = switch ($s.State) {
		'Downloading' { [ConsoleColor]::Cyan }
		'Seeding'	  { [ConsoleColor]::Green }
		'Complete'	  { [ConsoleColor]::Green }
		'Error'		  { [ConsoleColor]::Red }
		'Hashing'	  { [ConsoleColor]::Yellow }
		'Announcing'  { [ConsoleColor]::Yellow }
		'Metadata'	  { [ConsoleColor]::Yellow }
		default		  { [ConsoleColor]::Gray }
	}
	Write-Padded '------------------------------------------------' ([ConsoleColor]::DarkGray)
	Write-Padded ("State	: {0}" -f $s.State) $stateColor
	Write-Padded ("Progress : {0,6:0.00}%	{1} / {2}" -f $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.Downloaded), [PowerTorrent.Engine]::Fmt([long]$s.TotalSize)) ([ConsoleColor]::White)
	Write-Padded ("Pieces	: {0} / {1}" -f $s.PiecesDone, $s.PiecesTotal)
	Write-Padded ("Peers	: {0} connected / {1} known	   listen :{2}" -f $s.PeersConnected, $s.PeersKnown, $s.ListenPort)
	Write-Padded ("Down		: {0}/s		Up : {1}/s	   ETA {2}" -f [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), [PowerTorrent.Engine]::Fmt([long]$s.UpBytesPerSec), $s.Eta)
	if ($s.ErrorMessage) {
		Write-Padded ("Error	: {0}" -f $s.ErrorMessage) ([ConsoleColor]::Red)
	}
	Write-Padded ''
	Write-Padded 'Recent:' ([ConsoleColor]::DarkGray)
	$lines = @($s.LogLines)
	foreach ($line in $lines) {
		Write-Padded $line ([ConsoleColor]::DarkCyan)
	}
	for ($i = $lines.Count; $i -lt 8; $i++) { Write-Padded '' }
}

function Show-TorrentInfo {
	param($info)
	Write-Host ''
	Write-Host ("  Name		  : {0}" -f $info.Name) -ForegroundColor White
	Write-Host ("  Info hash  : {0}" -f $info.InfoHashHex) -ForegroundColor DarkGray
	Write-Host ("  Size		  : {0}	 ({1} piece(s) x {2})" -f [PowerTorrent.Engine]::Fmt([long]$info.TotalSize), $info.PieceCount, [PowerTorrent.Engine]::Fmt([long]$info.PieceLength))
	Write-Host ("  Files	  : {0}" -f $info.FileCount)
	if ($info.PieceCount -eq 0 -and $info.TotalSize -eq 0) {
		Write-Host '  (magnet: file list and size arrive after metadata is fetched)' -ForegroundColor Yellow
	}
	if ($info.Comment) { Write-Host ("	Comment	   : {0}" -f $info.Comment) }
	if ($info.CreatedBy) { Write-Host ("  Created by : {0}" -f $info.CreatedBy) }
	$trackers = @($info.Trackers)
	$webseeds = @($info.Webseeds)
	$files = @($info.Files)
	Write-Host ("  Trackers	  : {0}" -f $trackers.Count)
	$shown = [Math]::Min(8, $trackers.Count)
	for ($i = 0; $i -lt $shown; $i++) {
		Write-Host ("				{0}" -f $trackers[$i]) -ForegroundColor DarkGray
	}
	if ($trackers.Count -gt $shown) {
		Write-Host ("				... {0} more" -f ($trackers.Count - $shown)) -ForegroundColor DarkGray
	}
	if ($webseeds.Count -gt 0) {
		Write-Host ("  Webseeds	  : {0}" -f $webseeds.Count)
	}
	$fileShow = [Math]::Min(12, $files.Count)
	if ($fileShow -gt 0) {
		Write-Host '  Content	 :' -ForegroundColor DarkGray
		for ($i = 0; $i -lt $fileShow; $i++) {
			Write-Host ("				{0}" -f $files[$i]) -ForegroundColor DarkGray
		}
		if ($files.Count -gt $fileShow) {
			Write-Host ("				... {0} more files" -f ($files.Count - $fileShow)) -ForegroundColor DarkGray
		}
	}
	Write-Host ''
}

function Get-PowerTorrentScriptPath {
	$p = $PSCommandPath
	if ([string]::IsNullOrWhiteSpace($p)) { $p = $MyInvocation.MyCommand.Path }
	if ([string]::IsNullOrWhiteSpace($p)) { $p = Join-Path (Get-Location).Path 'PowerTorrent.ps1' }
	return [System.IO.Path]::GetFullPath($p)
}

function Get-PowerTorrentLaunchCommand {
	$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	$script = Get-PowerTorrentScriptPath
	return '"{0}" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $exe, $script
}

function Register-PowerTorrentAssociations {
	param([switch]$IncludeTorrentFiles)
	$cmd = Get-PowerTorrentLaunchCommand
	$hkcu = [Microsoft.Win32.Registry]::CurrentUser
	$magnet = $hkcu.CreateSubKey('Software\Classes\magnet')
	[void]$magnet.SetValue('', 'URL:BitTorrent Magnet')
	[void]$magnet.SetValue('URL Protocol', '')
	$icon = $magnet.CreateSubKey('DefaultIcon')
	[void]$icon.SetValue('', (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + ',0')
	$open = $magnet.CreateSubKey('shell\open\command')
	[void]$open.SetValue('', $cmd)
	$magnet.Close()

	if ($IncludeTorrentFiles) {
		$prog = $hkcu.CreateSubKey('Software\Classes\PowerTorrent.torrent')
		[void]$prog.SetValue('', 'BitTorrent File')
		$popen = $prog.CreateSubKey('shell\open\command')
		[void]$popen.SetValue('', $cmd)
		$prog.Close()
		$ext = $hkcu.CreateSubKey('Software\Classes\.torrent')
		[void]$ext.SetValue('', 'PowerTorrent.torrent')
		$ext.Close()
	}
}

function Unregister-PowerTorrentAssociations {
	$hkcu = [Microsoft.Win32.Registry]::CurrentUser
	try { $hkcu.DeleteSubKeyTree('Software\Classes\magnet', $false) } catch { }
	try { $hkcu.DeleteSubKeyTree('Software\Classes\PowerTorrent.torrent', $false) } catch { }
	try {
		$ext = $hkcu.OpenSubKey('Software\Classes\.torrent', $true)
		if ($ext) {
			$cur = [string]$ext.GetValue('')
			if ($cur -eq 'PowerTorrent.torrent') {
				$hkcu.DeleteSubKeyTree('Software\Classes\.torrent', $false)
			}
			$ext.Close()
		}
	} catch { }
}

function Test-PowerTorrentMagnetAssociation {
	try {
		$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\magnet\shell\open\command')
		if (-not $k) { return $false }
		$v = [string]$k.GetValue('')
		$k.Close()
		$script = Get-PowerTorrentScriptPath
		return ($v -like ('*{0}*' -f [System.IO.Path]::GetFileName($script)))
	} catch { return $false }
}

function Get-DefaultSavePath {
	$dl = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
	if (Test-Path -LiteralPath $dl) { return $dl }
	return (Get-Location).Path
}

function Get-PtIniPath {
	$dir = Split-Path -Parent (Get-PowerTorrentScriptPath)
	Join-Path $dir 'PowerTorrent.ini'
}

function Get-PtLegacyIniPath {
	Join-Path $env:APPDATA 'PowerTorrent\PowerTorrent.ini'
}

function Get-PtDefaultOptions {
	[ordered]@{
		Theme		   = 'Ice'
		Dht			   = '1'
		Encrypt		   = '1'
		Utp			   = '1'
		Sequential	   = '0'
		Seed		   = '1'
		Port		   = '6881'
		MaxPeers	   = '40'
		SavePath	   = (Get-DefaultSavePath)
		CloseToTray	   = '0'
		NoticeAccepted = '0'
	}
}

function Read-PtIni {
	$map = @{}
	$p = Get-PtIniPath
	if (-not (Test-Path -LiteralPath $p)) {
		$legacy = Get-PtLegacyIniPath
		if (Test-Path -LiteralPath $legacy) { $p = $legacy }
		else { return $map }
	}
	try {
		foreach ($line in @(Get-Content -LiteralPath $p -ErrorAction Stop)) {
			$t = [string]$line
			if ($t.Trim().Length -eq 0) { continue }
			if ($t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('[')) { continue }
			$eq = $t.IndexOf('=')
			if ($eq -lt 1) { continue }
			$k = $t.Substring(0, $eq).Trim()
			$v = $t.Substring($eq + 1).Trim()
			if ($k) { $map[$k] = $v }
		}
	} catch { }
	return $map
}

function Write-PtIni {
	param([hashtable]$Map)
	$p = Get-PtIniPath
	$dir = Split-Path -Parent $p
	if (-not (Test-Path -LiteralPath $dir)) {
		New-Item -ItemType Directory -Path $dir -Force | Out-Null
	}
	$keys = @('NoticeAccepted','Theme','Dht','Encrypt','Utp','Sequential','Seed','Port','MaxPeers','SavePath','CloseToTray')
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add('[PowerTorrent]')
	$seen = @{}
	foreach ($k in $keys) {
		if ($Map.ContainsKey($k)) {
			[void]$lines.Add(('{0}={1}' -f $k, [string]$Map[$k]))
			$seen[$k] = $true
		}
	}
	foreach ($k in @($Map.Keys)) {
		if (-not $seen.ContainsKey($k)) {
			[void]$lines.Add(('{0}={1}' -f $k, [string]$Map[$k]))
		}
	}
	Set-Content -LiteralPath $p -Value $lines.ToArray() -Encoding ASCII
}

function Merge-PtIni {
	param([hashtable]$Updates)
	$map = Read-PtIni
	foreach ($k in @($Updates.Keys)) { $map[$k] = [string]$Updates[$k] }
	Write-PtIni $map
}

function Test-PtIniFlag([string]$v) {
	if ([string]::IsNullOrWhiteSpace($v)) { return $false }
	switch ($v.Trim().ToLowerInvariant()) {
		'1' { return $true }
		'true' { return $true }
		'yes' { return $true }
		'on' { return $true }
		default { return $false }
	}
}

function Get-PtThemeNames {
	@('Ice','Ember','Forest','Violet','Steel','Light')
}

function Get-PtTheme {
	param([string]$Name)
	$n = [string]$Name
	if ([string]::IsNullOrWhiteSpace($n)) { $n = 'Ice' }
	switch ($n) {
		'Ember' {
			return @{
				WindowBg='#1C1410'; Text='#F8EDE4'; Muted='#C4B0A0'; Accent='#E09A5A'; AccentHi='#F0C090'; AccentDeep='#8A5A32'
				Hdr0='#2A1C14'; Hdr1='#18100C'; Tool0='#322218'; Tool1='#1C140E'; Bar0='#2A1E16'; Bar1='#18120E'
				Btn0='#5A3C28'; Btn1='#3A2418'; Hover0='#6A4A32'; Hover1='#4A3020'; Press0='#3A2418'; Press1='#24180E'
				Select0='#6A4028'; Select1='#4A2C1C'; Head0='#322218'; Head1='#1C140E'; Pop0='#322218'; Pop1='#1A120C'
				Fill='#2A1C14'; FillDeep='#140E0A'; Border='#8A5A32'; BorderHi='#F0C090'; ListBg='#201610'
				CaptionHover='#4A3020'; CaptionPress='#3A2418'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#F0C090'; CheckOn='#6A4028'; CheckMark='#F8EDE4'; Prog0='#F0C090'; Prog1='#C07838'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#7A6A5A'
			}
		}
		'Forest' {
			return @{
				WindowBg='#121A14'; Text='#E6F4EA'; Muted='#A8C4B0'; Accent='#5AA87A'; AccentHi='#8FD4A8'; AccentDeep='#2A5A3C'
				Hdr0='#14241A'; Hdr1='#0C1810'; Tool0='#1A2E22'; Tool1='#101C14'; Bar0='#16241A'; Bar1='#0E1812'
				Btn0='#2A4A38'; Btn1='#1A3024'; Hover0='#3A6A50'; Hover1='#2A4A38'; Press0='#1A3024'; Press1='#102018'
				Select0='#1E5A3C'; Select1='#164830'; Head0='#1A2E22'; Head1='#101C14'; Pop0='#1A2E22'; Pop1='#101A14'
				Fill='#14241A'; FillDeep='#0A140E'; Border='#3D6A50'; BorderHi='#8FD4A8'; ListBg='#101C14'
				CaptionHover='#2A4A38'; CaptionPress='#1A3024'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#8FD4A8'; CheckOn='#1E5A3C'; CheckMark='#E6F4EA'; Prog0='#8FD4A8'; Prog1='#2EA043'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7A70'
			}
		}
		'Violet' {
			return @{
				WindowBg='#16141C'; Text='#F0E8F8'; Muted='#B8A8C8'; Accent='#A78BDA'; AccentHi='#C4B0F0'; AccentDeep='#5A3A88'
				Hdr0='#201828'; Hdr1='#140E1C'; Tool0='#2A2038'; Tool1='#181422'; Bar0='#221A2C'; Bar1='#16101E'
				Btn0='#3A2A50'; Btn1='#241832'; Hover0='#4A3A68'; Hover1='#342448'; Press0='#241832'; Press1='#181022'
				Select0='#4A2A68'; Select1='#3A1E50'; Head0='#2A2038'; Head1='#181422'; Pop0='#2A2038'; Pop1='#16101E'
				Fill='#201828'; FillDeep='#0E0A14'; Border='#6A4A98'; BorderHi='#C4B0F0'; ListBg='#14101C'
				CaptionHover='#342448'; CaptionPress='#241832'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#C4B0F0'; CheckOn='#4A2A68'; CheckMark='#F0E8F8'; Prog0='#C4B0F0'; Prog1='#7A5AB8'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A6078'
			}
		}
		'Steel' {
			return @{
				WindowBg='#1A1C1E'; Text='#E8EAEC'; Muted='#A8B0B4'; Accent='#7A8A98'; AccentHi='#B0B8C0'; AccentDeep='#3A4A58'
				Hdr0='#22262A'; Hdr1='#141618'; Tool0='#2A2E32'; Tool1='#1A1C1E'; Bar0='#24282C'; Bar1='#16181A'
				Btn0='#3A4248'; Btn1='#24282C'; Hover0='#4A545C'; Hover1='#343A40'; Press0='#24282C'; Press1='#181A1C'
				Select0='#3A4A58'; Select1='#2A3844'; Head0='#2A2E32'; Head1='#1A1C1E'; Pop0='#2A2E32'; Pop1='#181A1C'
				Fill='#22262A'; FillDeep='#101214'; Border='#5A646C'; BorderHi='#B0B8C0'; ListBg='#181A1C'
				CaptionHover='#343A40'; CaptionPress='#24282C'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#B0B8C0'; CheckOn='#3A4A58'; CheckMark='#F4F6F8'; Prog0='#8FA0B0'; Prog1='#4A6A80'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7078'
			}
		}
		'Light' {
			return @{
				WindowBg='#F2F4F6'; Text='#0B1014'; Muted='#1C2A32'; Accent='#18616F'; AccentHi='#0E4852'; AccentDeep='#3E7A88'
				Hdr0='#FCFDFE'; Hdr1='#E4EAEE'; Tool0='#F4F6F8'; Tool1='#E2E8EC'; Bar0='#F2F4F6'; Bar1='#DCE3E8'
				Btn0='#E6ECF0'; Btn1='#CDD6DC'; Hover0='#D2DEE4'; Hover1='#B7C9D2'; Press0='#B7C9D2'; Press1='#9CB4BE'
				Select0='#C3D8E0'; Select1='#A7C8D2'; Head0='#ECF0F3'; Head1='#DCE3E8'; Pop0='#FCFDFE'; Pop1='#E8EEF2'
				Fill='#FFFFFF'; FillDeep='#DCE3E8'; Border='#5A727C'; BorderHi='#18616F'; ListBg='#E4EAEE'
				CaptionHover='#D5DEE4'; CaptionPress='#B7C6CE'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#102830'; CheckOn='#18616F'; CheckMark='#FFFFFF'; Prog0='#178A42'; Prog1='#116C34'; ProgHash0='#B88600'; ProgHash1='#946C00'
				Disabled='#4A5C64'
			}
		}
		default {
			return @{
				WindowBg='#141A1E'; Text='#E8F4F8'; Muted='#A8C4CC'; Accent='#6BB3C4'; AccentHi='#8FD4E3'; AccentDeep='#1E4A5C'
				Hdr0='#1A242C'; Hdr1='#10161A'; Tool0='#243038'; Tool1='#172026'; Bar0='#1E2A32'; Bar1='#141C22'
				Btn0='#334650'; Btn1='#1E2C34'; Hover0='#3E5C68'; Hover1='#2A4450'; Press0='#1A3A48'; Press1='#122830'
				Select0='#245A6C'; Select1='#1A3E4C'; Head0='#243038'; Head1='#182228'; Pop0='#243038'; Pop1='#161E24'
				Fill='#1A2228'; FillDeep='#10161A'; Border='#3D5A66'; BorderHi='#8FD4E3'; ListBg='#151C22'
				CaptionHover='#2A4450'; CaptionPress='#1A3A48'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#C5E8F0'; CheckOn='#1E4A5C'; CheckMark='#E8F4F8'; Prog0='#6EE08A'; Prog1='#2EA043'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7A80'
			}
		}
	}
}

function Initialize-PowerTorrentThemeUtil {
	if ('PowerTorrent.ThemeUtil' -as [type]) { return }
	Add-Type -AssemblyName PresentationCore | Out-Null
	Add-Type -AssemblyName PresentationFramework | Out-Null
	Add-Type -AssemblyName WindowsBase | Out-Null
	$cs = @'
using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;

namespace PowerTorrent {
	public static class ThemeUtil {
		public static void PutSolid(ResourceDictionary rd, string key, byte r, byte g, byte b) {
			PutSolidObj(rd, key, r, g, b);
		}

		public static void PutSys(ResourceDictionary rd, ResourceKey key, byte r, byte g, byte b) {
			PutSolidObj(rd, key, r, g, b);
		}

		static void PutSolidObj(ResourceDictionary rd, object key, byte r, byte g, byte b) {
			if (rd == null || key == null) return;
			Color c = Color.FromRgb(r, g, b);
			object existing = null;
			if (rd.Contains(key)) existing = rd[key];
			SolidColorBrush sb = existing as SolidColorBrush;
			if (sb != null && !sb.IsFrozen) {
				sb.Color = c;
				return;
			}
			SolidColorBrush brush = new SolidColorBrush(c);
			if (rd.Contains(key)) rd.Remove(key);
			rd.Add(key, brush);
		}

		public static void PutGrad(ResourceDictionary rd, string key, byte r1, byte g1, byte b1, byte r2, byte g2, byte b2, bool horizontal) {
			if (rd == null || key == null) return;
			object existing = null;
			if (rd.Contains(key)) existing = rd[key];
			LinearGradientBrush old = existing as LinearGradientBrush;
			if (old != null && !old.IsFrozen && old.GradientStops != null && old.GradientStops.Count >= 2) {
				old.GradientStops[0].Color = Color.FromRgb(r1, g1, b1);
				old.GradientStops[1].Color = Color.FromRgb(r2, g2, b2);
				return;
			}
			LinearGradientBrush brush = new LinearGradientBrush();
			brush.StartPoint = new Point(0, 0);
			brush.EndPoint = horizontal ? new Point(1, 0) : new Point(0, 1);
			brush.GradientStops.Add(new GradientStop(Color.FromRgb(r1, g1, b1), 0));
			brush.GradientStops.Add(new GradientStop(Color.FromRgb(r2, g2, b2), 1));
			if (rd.Contains(key)) rd.Remove(key);
			rd.Add(key, brush);
		}

		public static void SetPathStrokeRgb(Path path, byte r, byte g, byte b) {
			if (path == null) return;
			path.Stroke = new SolidColorBrush(Color.FromRgb(r, g, b));
		}

		public static void SetPathStrokeKey(Path path, ResourceDictionary rd, string key) {
			if (path == null || rd == null || key == null) return;
			Brush b = rd[key] as Brush;
			if (b != null) path.Stroke = b;
		}
	}
}
'@
	$refs = @(
		[System.Windows.Media.SolidColorBrush].Assembly.Location,
		[System.Windows.Window].Assembly.Location,
		[System.Windows.Point].Assembly.Location,
		[System.Windows.Shapes.Path].Assembly.Location,
		([System.Reflection.Assembly]::Load('System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')).Location
	) | Select-Object -Unique
	Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
}

function Convert-PtColor([string]$Hex) {
	$h = ([string]$Hex).Trim().TrimStart('#')
	if ($h.Length -eq 8) { $h = $h.Substring(2) }
	if ($h.Length -ne 6) { return [System.Windows.Media.Colors]::Black }
	$rv = [Convert]::ToByte($h.Substring(0, 2), 16)
	$gv = [Convert]::ToByte($h.Substring(2, 2), 16)
	$bv = [Convert]::ToByte($h.Substring(4, 2), 16)
	return [System.Windows.Media.Color]::FromRgb($rv, $gv, $bv)
}

function Set-PtSolid {
	param($Window, $Key, [string]$Hex)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$c = Convert-PtColor $Hex
	$rd = $Window.Resources
	if ($Key -is [System.Windows.ResourceKey]) {
		[PowerTorrent.ThemeUtil]::PutSys($rd, $Key, $c.R, $c.G, $c.B)
	} else {
		[PowerTorrent.ThemeUtil]::PutSolid($rd, [string]$Key, $c.R, $c.G, $c.B)
	}
}

function Set-PtGrad {
	param($Window, [string]$Key, [string]$A, [string]$B)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$ca = Convert-PtColor $A
	$cb = Convert-PtColor $B
	$horiz = ($Key -eq 'SelectFace' -or $Key -eq 'HoverFace')
	[PowerTorrent.ThemeUtil]::PutGrad($Window.Resources, $Key, $ca.R, $ca.G, $ca.B, $cb.R, $cb.G, $cb.B, $horiz)
}

function Apply-PtTheme {
	param($Window, [string]$Name)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$t = Get-PtTheme $Name
	Set-PtSolid $Window 'Theme.WindowBg' $t.WindowBg
	Set-PtSolid $Window 'Theme.Text' $t.Text
	Set-PtSolid $Window 'Theme.Muted' $t.Muted
	Set-PtSolid $Window 'Theme.Accent' $t.Accent
	Set-PtSolid $Window 'Theme.AccentHi' $t.AccentHi
	Set-PtSolid $Window 'Theme.AccentDeep' $t.AccentDeep
	Set-PtSolid $Window 'Theme.Fill' $t.Fill
	Set-PtSolid $Window 'Theme.FillDeep' $t.FillDeep
	Set-PtSolid $Window 'Theme.Border' $t.Border
	Set-PtSolid $Window 'Theme.BorderHi' $t.BorderHi
	Set-PtSolid $Window 'Theme.ListBg' $t.ListBg
	Set-PtSolid $Window 'Theme.CaptionHover' $t.CaptionHover
	Set-PtSolid $Window 'Theme.CaptionPress' $t.CaptionPress
	Set-PtSolid $Window 'Theme.CloseHover' $t.CloseHover
	Set-PtSolid $Window 'Theme.ClosePress' $t.ClosePress
	Set-PtSolid $Window 'Theme.Ico' $t.Ico
	Set-PtSolid $Window 'Theme.CheckOn' $t.CheckOn
	Set-PtSolid $Window 'Theme.CheckMark' $t.CheckMark
	Set-PtSolid $Window 'Theme.Disabled' $t.Disabled
	Set-PtGrad $Window 'HdrFace' $t.Hdr0 $t.Hdr1
	Set-PtGrad $Window 'ToolFace' $t.Tool0 $t.Tool1
	Set-PtGrad $Window 'BarFace' $t.Bar0 $t.Bar1
	Set-PtGrad $Window 'BtnFace' $t.Btn0 $t.Btn1
	Set-PtGrad $Window 'BtnHover' $t.Hover0 $t.Hover1
	Set-PtGrad $Window 'BtnPress' $t.Press0 $t.Press1
	Set-PtGrad $Window 'SelectFace' $t.Select0 $t.Select1
	Set-PtGrad $Window 'HoverFace' $t.Hover0 $t.Hover1
	Set-PtGrad $Window 'HeadFace' $t.Head0 $t.Head1
	Set-PtGrad $Window 'PopFace' $t.Pop0 $t.Pop1
	Set-PtGrad $Window 'ProgGreen' $t.Prog0 $t.Prog1
	Set-PtGrad $Window 'ProgYellow' $t.ProgHash0 $t.ProgHash1
	try {
		Set-PtSolid $Window ([System.Windows.SystemColors]::HighlightBrushKey) $t.AccentDeep
		Set-PtSolid $Window ([System.Windows.SystemColors]::HighlightTextBrushKey) $t.Text
		Set-PtSolid $Window ([System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey) $t.Fill
		Set-PtSolid $Window ([System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey) $t.Muted
		Set-PtSolid $Window ([System.Windows.SystemColors]::WindowBrushKey) $t.WindowBg
		Set-PtSolid $Window ([System.Windows.SystemColors]::WindowTextBrushKey) $t.Text
	} catch { }
}

function Show-PtNoticeGui {
	Add-Type -AssemblyName PresentationFramework | Out-Null
	$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="PowerTorrent" SizeToContent="WidthAndHeight"
		WindowStartupLocation="CenterScreen" WindowStyle="None"
		ResizeMode="NoResize" Background="{DynamicResource Theme.WindowBg}"
		Foreground="{DynamicResource Theme.Text}"
		FontFamily="Segoe UI" FontSize="13"
		BorderBrush="{DynamicResource Theme.Accent}" BorderThickness="1">
  <Window.Resources>
	<SolidColorBrush x:Key="Theme.WindowBg" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.Text" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Muted" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="Theme.Accent" Color="#6BB3C4"/>
	<SolidColorBrush x:Key="Theme.AccentHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.AccentDeep" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.Fill" Color="#1A2228"/>
	<SolidColorBrush x:Key="Theme.FillDeep" Color="#10161A"/>
	<SolidColorBrush x:Key="Theme.Border" Color="#3D5A66"/>
	<SolidColorBrush x:Key="Theme.BorderHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.ListBg" Color="#151C22"/>
	<SolidColorBrush x:Key="Theme.CaptionHover" Color="#2A4450"/>
	<SolidColorBrush x:Key="Theme.CaptionPress" Color="#1A3A48"/>
	<SolidColorBrush x:Key="Theme.CloseHover" Color="#C42B1C"/>
	<SolidColorBrush x:Key="Theme.ClosePress" Color="#9B2115"/>
	<SolidColorBrush x:Key="Theme.Ico" Color="#C5E8F0"/>
	<SolidColorBrush x:Key="Theme.CheckOn" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.CheckMark" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Disabled" Color="#6A7A80"/>
	<LinearGradientBrush x:Key="BtnFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#334650" Offset="0"/>
	  <GradientStop Color="#1E2C34" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnHover" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#3E5C68" Offset="0"/>
	  <GradientStop Color="#2A4450" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnPress" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A3A48" Offset="0"/>
	  <GradientStop Color="#122830" Offset="1"/>
	</LinearGradientBrush>
	<StreamGeometry x:Key="GeoCheck">M21,7L9,19L3.5,13.5L4.91,12.09L9,16.17L19.59,5.59L21,7Z</StreamGeometry>
	<Style TargetType="TextBlock">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	</Style>
	<Style TargetType="Button">
	  <Setter Property="Background" Value="{DynamicResource BtnFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="10,4"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					Padding="{TemplateBinding Padding}" CornerRadius="3">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="CheckBox">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="CheckBox">
			<StackPanel Orientation="Horizontal">
			  <Border x:Name="box" Width="16" Height="16" Background="{DynamicResource Theme.Fill}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2"
					  Margin="0,0,8,0" VerticalAlignment="Center">
				<Path x:Name="check" Data="{StaticResource GeoCheck}" Fill="{DynamicResource Theme.CheckMark}"
					  Stretch="Uniform" Margin="2" Visibility="Collapsed"/>
			  </Border>
			  <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
			</StackPanel>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsChecked" Value="True">
				<Setter TargetName="check" Property="Visibility" Value="Visible"/>
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CheckOn}"/>
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
  </Window.Resources>
  <Border Padding="22,18" Background="{DynamicResource Theme.WindowBg}">
	<StackPanel Width="380">
	  <TextBlock Text="PowerTorrent" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,10"
				 Foreground="{DynamicResource Theme.Text}"/>
	  <TextBlock TextWrapping="Wrap" Margin="0,0,0,16" Foreground="{DynamicResource Theme.Text}"
				 Text="Please follow copyright and local laws when using this BitTorrent client."/>
	  <CheckBox x:Name="chkRemember" Content="Remember this" Margin="0,0,0,16"/>
	  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
		<Button x:Name="btnOk" Content="OK" Width="84" Height="28" Margin="0,0,8,0" IsDefault="True"/>
		<Button x:Name="btnCancel" Content="Cancel" Width="84" Height="28" IsCancel="True"/>
	  </StackPanel>
	</StackPanel>
  </Border>
</Window>
'@
	$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
	$chk = $w.FindName('chkRemember')
	$ok = $w.FindName('btnOk')
	$cancel = $w.FindName('btnCancel')
	$script:PtNoticeOk = $false
	$script:PtNoticeRemember = $false
	try {
		$th = $script:PtTheme
		if ([string]::IsNullOrWhiteSpace($th)) { $th = 'Ice' }
		Apply-PtTheme $w $th
	} catch { }
	$ok.add_Click({
		$script:PtNoticeOk = $true
		$script:PtNoticeRemember = ($chk.IsChecked -eq $true)
		try { $w.DialogResult = $true } catch { }
	})
	$cancel.add_Click({
		try { $w.DialogResult = $false } catch { }
	})
	[void]$w.ShowDialog()
	return @{ Ok = [bool]$script:PtNoticeOk; Remember = [bool]$script:PtNoticeRemember }
}

function Show-PtNoticeCli {
	Write-Host ''
	Write-Host 'Please follow copyright and local laws when using this BitTorrent client.'
	Write-Host ''
	Write-Host '  Enter / Y	 continue once'
	Write-Host '  R			 remember this (writes a small settings file)'
	Write-Host '  N / Q		 cancel'
	Write-Host ''
	$ans = Read-Host 'Choice'
	$a = $ans.Trim().ToLowerInvariant()
	switch ($a) {
		'' { return @{ Ok = $true; Remember = $false } }
		'y' { return @{ Ok = $true; Remember = $false } }
		'yes' { return @{ Ok = $true; Remember = $false } }
		'r' { return @{ Ok = $true; Remember = $true } }
		'remember' { return @{ Ok = $true; Remember = $true } }
		default { return @{ Ok = $false; Remember = $false } }
	}
}

function Confirm-PowerTorrentNotice {
	param([switch]$Gui)
	$ini = Read-PtIni
	if (Test-PtIniFlag $ini['NoticeAccepted']) { return $true }
	if ($RememberAccept) {
		Merge-PtIni @{ NoticeAccepted = '1' }
		return $true
	}
	if ($Accept) { return $true }
	$r = $null
	if ($Gui) { $r = Show-PtNoticeGui } else { $r = Show-PtNoticeCli }
	if (-not $r.Ok) { return $false }
	if ($r.Remember) { Merge-PtIni @{ NoticeAccepted = '1' } }
	return $true
}

function Import-PtIniToSession {
	$ini = Read-PtIni
	if ($ini.Count -eq 0) { return }
	if (-not $PSBoundParameters.ContainsKey('Port') -and $ini.ContainsKey('Port')) {
		$v = 0
		if ([int]::TryParse($ini['Port'], [ref]$v) -and $v -gt 0) { $script:Port = $v }
	}
	if (-not $PSBoundParameters.ContainsKey('MaxPeers') -and $ini.ContainsKey('MaxPeers')) {
		$v = 0
		if ([int]::TryParse($ini['MaxPeers'], [ref]$v) -and $v -gt 0) { $script:MaxPeers = $v }
	}
	if (-not $PSBoundParameters.ContainsKey('SavePath') -and $ini.ContainsKey('SavePath') -and $ini['SavePath']) {
		$script:SavePath = $ini['SavePath']
	}
	if (-not $PSBoundParameters.ContainsKey('Sequential') -and $ini.ContainsKey('Sequential')) {
		$script:Sequential = [switch](Test-PtIniFlag $ini['Sequential'])
	}
	if (-not $PSBoundParameters.ContainsKey('NoDht') -and $ini.ContainsKey('Dht')) {
		$script:NoDht = [switch](-not (Test-PtIniFlag $ini['Dht']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoEncrypt') -and $ini.ContainsKey('Encrypt')) {
		$script:NoEncrypt = [switch](-not (Test-PtIniFlag $ini['Encrypt']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoUtp') -and $ini.ContainsKey('Utp')) {
		$script:NoUtp = [switch](-not (Test-PtIniFlag $ini['Utp']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoSeed') -and $ini.ContainsKey('Seed')) {
		$script:NoSeed = [switch](-not (Test-PtIniFlag $ini['Seed']))
	}
	if ($ini.ContainsKey('Theme') -and $ini['Theme']) { $script:PtTheme = $ini['Theme'] }
	if ($ini.ContainsKey('CloseToTray')) { $script:PtCloseToTray = Test-PtIniFlag $ini['CloseToTray'] }
}

function Get-PtBoolText([bool]$v) {
	if ($v) { '1' } else { '0' }
}

function Get-PtInt {
	param(
		[string]$Text,
		[int]$Fallback
	)
	$n = 0
	$s = [string]$Text
	if ([int]::TryParse($s, [ref]$n) -and $n -gt 0) { return $n }
	return $Fallback
}

function Get-PtInboxPath {
	Join-Path $env:TEMP 'PowerTorrent.inbox'
}

function Send-PtInbox([string]$source) {
	if ([string]::IsNullOrWhiteSpace($source)) { return }
	Add-Content -LiteralPath (Get-PtInboxPath) -Value $source.Trim() -Encoding UTF8
}

function Read-PtInbox {
	$p = Get-PtInboxPath
	if (-not (Test-Path -LiteralPath $p)) { return @() }
	try {
		$lines = @(Get-Content -LiteralPath $p -ErrorAction Stop)
		Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
		return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
	} catch { return @() }
}

function New-PowerTorrentSettings {
	param(
		[string]$Source,
		[string]$OutDir,
		[int]$ListenPort = 6881,
		[int]$Peers = 40,
		[bool]$Dht = $true,
		[bool]$Encrypt = $true,
		[bool]$Utp = $true,
		[bool]$Seq = $false,
		[bool]$Seed = $true,
		[string]$Forced = '',
		[int]$Level = 1
	)
	if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Get-DefaultSavePath }
	$OutDir = [System.IO.Path]::GetFullPath($OutDir)
	if (-not (Test-Path -LiteralPath $OutDir)) {
		New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
	}
	$cfg = [PowerTorrent.EngineSettings]::new()
	$src = $Source.Trim()
	if ($src.ToLowerInvariant().StartsWith('magnet:')) {
		$cfg.MagnetUri = $src
	} else {
		$cfg.TorrentPath = [System.IO.Path]::GetFullPath($src)
	}
	$cfg.SavePath = $OutDir
	$cfg.ListenPort = $ListenPort
	$cfg.MaxPeers = $Peers
	$cfg.LogLevel = $Level
	$cfg.Sequential = $Seq
	$cfg.EnableDht = $Dht
	$cfg.SeedAfterComplete = $Seed
	$cfg.ForcedPeer = $Forced
	$cfg.EnableEncrypt = $Encrypt
	$cfg.EnableUtp = $Utp
	return $cfg
}

function Start-PowerTorrentConsole {
	param($engine)
	Write-Host '  Press Q or Escape to stop.' -ForegroundColor DarkGray
	Write-Host ''
	$isConsole = $Host.Name -eq 'ConsoleHost'
	$dashRow = 0
	if ($isConsole) {
		try { $dashRow = [Console]::CursorTop } catch { $isConsole = $false }
	}
	$engine.Start()
	$printedLogs = @{}
	try {
		while ($engine.IsRunning) {
			$s = $engine.GetStatus()
			if ($isConsole) {
				try {
					[Console]::SetCursorPosition(0, $dashRow)
					Show-TorrentDashboard $s
				} catch {
					Show-TorrentDashboard $s
				}
			} else {
				Write-Host ("[{0}] {1:0.00}%  {2}/s	 peers {3}/{4}	{5}" -f $s.State, $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), $s.PeersConnected, $s.PeersKnown, $s.Eta)
				foreach ($line in @($s.LogLines)) {
					if ($line -and -not $printedLogs.ContainsKey($line)) {
						$printedLogs[$line] = $true
						Write-Host $line -ForegroundColor DarkCyan
					}
				}
			}
			$pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Floor($s.ProgressPercent)))
			Write-Progress -Activity $s.Name -Status ("{0}	{1:0.00}%  {2}" -f $s.State, $s.ProgressPercent, $s.Eta) -PercentComplete $pct
			if ($isConsole) {
				try {
					while ([Console]::KeyAvailable) {
						$k = [Console]::ReadKey($true)
						if ($k.Key -eq 'Q' -or $k.Key -eq 'Escape') {
							Write-Host ''
							Write-Host 'Stopping...' -ForegroundColor Yellow
							$engine.Stop()
							break
						}
					}
				} catch { }
			}
			Start-Sleep -Milliseconds 500
		}
	} finally {
		Write-Progress -Activity 'PowerTorrent' -Completed
		try { $engine.Stop() } catch { }
	}
	$final = $engine.GetStatus()
	Write-Host ''
	Write-Host ("Finished: {0}	{1:0.00}%  down {2}	 up {3}" -f $final.State, $final.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$final.Downloaded), [PowerTorrent.Engine]::Fmt([long]$final.Uploaded)) -ForegroundColor $(if ($final.State -eq 'Complete' -or $final.State -eq 'Seeding' -or $final.State -eq 'Stopped') { 'Green' } else { 'Yellow' })
	if ($final.ErrorMessage) {
		Write-Host ("Error: {0}" -f $final.ErrorMessage) -ForegroundColor Red
		exit 1
	}
}

function Initialize-PowerTorrentNativeIcons {
	if ('PowerTorrent.IconExtractor' -as [type]) { return }
	$cs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace PowerTorrent {
	public static class WindowMaximizeFix {
		const int WM_GETMINMAXINFO = 0x0024;
		const uint MONITOR_DEFAULTTONEAREST = 2;

		[StructLayout(LayoutKind.Sequential)]
		struct POINT { public int X; public int Y; }

		[StructLayout(LayoutKind.Sequential)]
		struct MINMAXINFO {
			public POINT ptReserved;
			public POINT ptMaxSize;
			public POINT ptMaxPosition;
			public POINT ptMinTrackSize;
			public POINT ptMaxTrackSize;
		}

		[StructLayout(LayoutKind.Sequential)]
		struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

		[StructLayout(LayoutKind.Sequential)]
		struct MONITORINFO {
			public int cbSize;
			public RECT rcMonitor;
			public RECT rcWork;
			public int dwFlags;
		}

		[DllImport("user32.dll")]
		static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

		[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
		static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

		public static void Attach(Window window) {
			if (window == null) return;
			window.SourceInitialized += delegate {
				IntPtr hwnd = new WindowInteropHelper(window).Handle;
				HwndSource src = HwndSource.FromHwnd(hwnd);
				if (src != null) src.AddHook(Hook);
			};
		}

		static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
			if (msg != WM_GETMINMAXINFO || lParam == IntPtr.Zero) return IntPtr.Zero;
			IntPtr mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
			if (mon == IntPtr.Zero) return IntPtr.Zero;
			MONITORINFO mi = new MONITORINFO();
			mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
			if (!GetMonitorInfo(mon, ref mi)) return IntPtr.Zero;
			MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
			RECT wa = mi.rcWork;
			RECT ma = mi.rcMonitor;
			mmi.ptMaxPosition.X = wa.Left - ma.Left;
			mmi.ptMaxPosition.Y = wa.Top - ma.Top;
			mmi.ptMaxSize.X = wa.Right - wa.Left;
			mmi.ptMaxSize.Y = wa.Bottom - wa.Top;
			mmi.ptMaxTrackSize.X = mmi.ptMaxSize.X;
			mmi.ptMaxTrackSize.Y = mmi.ptMaxSize.Y;
			Marshal.StructureToPtr(mmi, lParam, true);
			return IntPtr.Zero;
		}
	}

	public static class IconExtractor {
		[DllImport("Shell32.dll", EntryPoint = "ExtractIconExW", CharSet = CharSet.Unicode, ExactSpelling = true)]
		static extern int ExtractIconEx(string sFile, int iIndex, out IntPtr piLargeVersion, out IntPtr piSmallVersion, int amountIcons);

		[DllImport("user32.dll", SetLastError = true)]
		static extern bool DestroyIcon(IntPtr hIcon);

		public static BitmapSource Extract(string file, int number, bool largeIcon) {
			IntPtr large;
			IntPtr small;
			ExtractIconEx(file, number, out large, out small, 1);
			IntPtr use = largeIcon ? large : small;
			IntPtr other = largeIcon ? small : large;
			if (use == IntPtr.Zero) {
				if (other != IntPtr.Zero) DestroyIcon(other);
				return null;
			}
			try {
				BitmapSource bs = Imaging.CreateBitmapSourceFromHIcon(
					use,
					Int32Rect.Empty,
					BitmapSizeOptions.FromEmptyOptions());
				bs.Freeze();
				return bs;
			} catch {
				return null;
			} finally {
				DestroyIcon(use);
				if (other != IntPtr.Zero) DestroyIcon(other);
			}
		}

		public static Icon ExtractWinIcon(string file, int number, bool largeIcon) {
			IntPtr large;
			IntPtr small;
			ExtractIconEx(file, number, out large, out small, 1);
			IntPtr use = largeIcon ? large : small;
			IntPtr other = largeIcon ? small : large;
			if (use == IntPtr.Zero) {
				if (other != IntPtr.Zero) DestroyIcon(other);
				return null;
			}
			try {
				Icon tmp = Icon.FromHandle(use);
				return (Icon)tmp.Clone();
			} catch {
				return null;
			} finally {
				DestroyIcon(use);
				if (other != IntPtr.Zero) DestroyIcon(other);
			}
		}
	}
}
'@
	Add-Type -AssemblyName System.Drawing | Out-Null
	$refs = @(
		[System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
		[System.Windows.Window].Assembly.Location,
		[System.Windows.Int32Rect].Assembly.Location,
		[System.Drawing.Icon].Assembly.Location,
		([System.Reflection.Assembly]::Load('System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')).Location
	) | Select-Object -Unique
	Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
}

function Get-NativeWinIcon {
	param(
		[string]$File,
		[int]$Index,
		[switch]$Large
	)
	$path = [Environment]::ExpandEnvironmentVariables($File)
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	try {
		return [PowerTorrent.IconExtractor]::ExtractWinIcon($path, $Index, [bool]$Large)
	} catch {
		return $null
	}
}

function Get-NativeIconBitmap {
	param(
		[string]$File,
		[int]$Index,
		[switch]$Large
	)
	$path = [Environment]::ExpandEnvironmentVariables($File)
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	try {
		return [PowerTorrent.IconExtractor]::Extract($path, $Index, [bool]$Large)
	} catch {
		return $null
	}
}

function Show-PowerTorrentGui {
	param(
		[string]$InitialSource = '',
		[string]$InitialSave = '',
		[switch]$AutoStart
	)

	Add-Type -AssemblyName PresentationFramework | Out-Null
	Add-Type -AssemblyName PresentationCore | Out-Null
	Add-Type -AssemblyName WindowsBase | Out-Null
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	Add-Type -AssemblyName System.Drawing | Out-Null
	Initialize-PowerTorrentNativeIcons

	$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="PowerTorrent"
		Width="760" Height="700"
		MinWidth="640" MinHeight="560"
		WindowStartupLocation="CenterScreen"
		WindowStyle="None"
		ResizeMode="CanResize"
		Background="{DynamicResource Theme.WindowBg}"
		FontFamily="Segoe UI" FontSize="13"
		BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1"
		Foreground="{DynamicResource Theme.Text}">
  <Window.Resources>
	<SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#1A2228"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#141A1E"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E8F4F8"/>
	<StreamGeometry x:Key="GeoPlus">M19,13H13V19H11V13H5V11H11V5H13V11H19V13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoMinus">M19,13H5V11H19V13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoPause">M14,19H18V5H14M6,19H10V5H6V19Z</StreamGeometry>
	<StreamGeometry x:Key="GeoPlay">M8,5.14V19.14L19,12.14L8,5.14Z</StreamGeometry>
	<StreamGeometry x:Key="GeoStop">M18,18H6V6H18V18Z</StreamGeometry>
	<StreamGeometry x:Key="GeoMagnet">M3,7V13A9,9 0 0,0 12,22A9,9 0 0,0 21,13V7H17V13A5,5 0 0,1 12,18A5,5 0 0,1 7,13V7M17,5H21V2H17M3,5H7V2H3</StreamGeometry>
	<StreamGeometry x:Key="GeoCheck">M21,7L9,19L3.5,13.5L4.91,12.09L9,16.17L19.59,5.59L21,7Z</StreamGeometry>
	<StreamGeometry x:Key="GeoCheckMulti">M0.41,13.41L6,19L7.41,17.58L1.83,12M22.24,5.58L11.66,16.17L7.5,12L6.07,13.41L11.66,19L23.66,7M18,7L16.59,5.58L10.24,11.93L11.66,13.34L18,7Z</StreamGeometry>
	<StreamGeometry x:Key="GeoDownload">M13,2.03C17.73,2.5 21.5,6.25 21.95,11C22.5,16.5 18.5,21.38 13,21.93V19.93C16.64,19.5 19.5,16.61 19.96,12.97C20.5,8.58 17.39,4.59 13,4.05V2.05L13,2.03M11,2.06V4.06C9.57,4.26 8.22,4.84 7.1,5.74L5.67,4.26C7.19,3 9.05,2.25 11,2.06M4.26,5.67L5.69,7.1C4.8,8.23 4.24,9.58 4.05,11H2.05C2.25,9.04 3,7.19 4.26,5.67M2.06,13H4.06C4.24,14.42 4.81,15.77 5.69,16.9L4.27,18.33C3.03,16.81 2.26,14.96 2.06,13M7.1,18.37C8.23,19.25 9.58,19.82 11,20V22C9.04,21.79 7.18,21 5.67,19.74L7.1,18.37M12,16.5L7.5,12H11V8H13V12H16.5L12,16.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoUpload">M13,2.03C17.73,2.5 21.5,6.25 21.95,11C22.5,16.5 18.5,21.38 13,21.93V19.93C16.64,19.5 19.5,16.61 19.96,12.97C20.5,8.58 17.39,4.59 13,4.05V2.05L13,2.03M11,2.06V4.06C9.57,4.26 8.22,4.84 7.1,5.74L5.67,4.26C7.19,3 9.05,2.25 11,2.06M4.26,5.67L5.69,7.1C4.8,8.23 4.24,9.58 4.05,11H2.05C2.25,9.04 3,7.19 4.26,5.67M2.06,13H4.06C4.24,14.42 4.81,15.77 5.69,16.9L4.27,18.33C3.03,16.81 2.26,14.96 2.06,13M7.1,18.37C8.23,19.25 9.58,19.82 11,20V22C9.04,21.79 7.18,21 5.67,19.74L7.1,18.37M12,7.5L7.5,12H11V16H13V12H16.5L12,7.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoClock">M13,2.03V2.05L13,4.05C17.39,4.59 20.5,8.58 19.96,12.97C19.5,16.61 16.64,19.5 13,19.93V21.93C18.5,21.38 22.5,16.5 21.95,11C21.5,6.25 17.73,2.5 13,2.03M11,2.06C9.05,2.25 7.19,3 5.67,4.26L7.1,5.74C8.22,4.84 9.57,4.26 11,4.06V2.06M4.26,5.67C3,7.19 2.25,9.04 2.05,11H4.05C4.24,9.58 4.8,8.23 5.69,7.1L4.26,5.67M2.06,13C2.26,14.96 3.03,16.81 4.27,18.33L5.69,16.9C4.81,15.77 4.24,14.42 4.06,13H2.06M7.1,18.37L5.67,19.74C7.18,21 9.04,21.79 11,22V20C9.58,19.82 8.23,19.25 7.1,18.37M12.5,7V12.25L17,14.92L16.25,16.15L11,13V7H12.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoQuestion">M13 18H11V16H13V18M13 15H11C11 11.75 14 12 14 10C14 8.9 13.1 8 12 8C10.9 8 10 8.9 10 10H8C8 7.79 9.79 6 12 6C14.21 6 16 7.79 16 10C16 12.5 13 12.75 13 15M22 12C22 17.18 18.05 21.45 13 21.95V19.94C16.95 19.45 20 16.08 20 12C20 7.92 16.95 4.55 13 4.06V2.05C18.05 2.55 22 6.82 22 12M11 2.05V4.06C9.54 4.24 8.2 4.82 7.09 5.68L5.67 4.26C7.15 3.05 9 2.25 11 2.05M4.06 11H2.05C2.25 9 3.05 7.15 4.26 5.67L5.68 7.1C4.82 8.2 4.24 9.54 4.06 11M11 19.94V21.95C9 21.75 7.15 20.96 5.67 19.74L7.09 18.32C8.2 19.18 9.54 19.76 11 19.94M2.05 13H4.06C4.24 14.46 4.82 15.8 5.68 16.91L4.26 18.33C3.05 16.85 2.25 15 2.05 13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoChevronLeft">M15.41,16.58L10.83,12L15.41,7.41L14,6L8,12L14,18L15.41,16.58Z</StreamGeometry>
	<StreamGeometry x:Key="GeoChevronRight">M8.59,16.58L13.17,12L8.59,7.41L10,6L16,12L10,18L8.59,16.58Z</StreamGeometry>
	<SolidColorBrush x:Key="Theme.WindowBg" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.Text" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Muted" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="Theme.Accent" Color="#6BB3C4"/>
	<SolidColorBrush x:Key="Theme.AccentHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.AccentDeep" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.Fill" Color="#1A2228"/>
	<SolidColorBrush x:Key="Theme.FillDeep" Color="#10161A"/>
	<SolidColorBrush x:Key="Theme.Border" Color="#3D5A66"/>
	<SolidColorBrush x:Key="Theme.BorderHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.ListBg" Color="#151C22"/>
	<SolidColorBrush x:Key="Theme.CaptionHover" Color="#2A4450"/>
	<SolidColorBrush x:Key="Theme.CaptionPress" Color="#1A3A48"/>
	<SolidColorBrush x:Key="Theme.CloseHover" Color="#C42B1C"/>
	<SolidColorBrush x:Key="Theme.ClosePress" Color="#9B2115"/>
	<SolidColorBrush x:Key="Theme.Ico" Color="#C5E8F0"/>
	<SolidColorBrush x:Key="Theme.CheckOn" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.CheckMark" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Disabled" Color="#6A7A80"/>
	<LinearGradientBrush x:Key="HdrFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A242C" Offset="0"/>
	  <GradientStop Color="#10161A" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ToolFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#172026" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BarFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1E2A32" Offset="0"/>
	  <GradientStop Color="#141C22" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#334650" Offset="0"/>
	  <GradientStop Color="#1E2C34" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnHover" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#3E5C68" Offset="0"/>
	  <GradientStop Color="#2A4450" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnPress" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A3A48" Offset="0"/>
	  <GradientStop Color="#122830" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="SelectFace" StartPoint="0,0" EndPoint="1,0">
	  <GradientStop Color="#245A6C" Offset="0"/>
	  <GradientStop Color="#1A3E4C" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="HoverFace" StartPoint="0,0" EndPoint="1,0">
	  <GradientStop Color="#2C4450" Offset="0"/>
	  <GradientStop Color="#1E3038" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="HeadFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#182228" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ProgGreen" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#6EE08A" Offset="0"/>
	  <GradientStop Color="#2EA043" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ProgYellow" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#FFE066" Offset="0"/>
	  <GradientStop Color="#E0A800" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="PopFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#161E24" Offset="1"/>
	</LinearGradientBrush>
	<Style x:Key="Ico" TargetType="Path">
	  <Setter Property="Stretch" Value="Uniform"/>
	  <Setter Property="Width" Value="14"/>
	  <Setter Property="Height" Value="14"/>
	  <Setter Property="Fill" Value="{DynamicResource Theme.Ico}"/>
	  <Setter Property="Stroke" Value="#000000"/>
	  <Setter Property="StrokeThickness" Value="0.7"/>
	  <Setter Property="StrokeLineJoin" Value="Round"/>
	  <Setter Property="StrokeStartLineCap" Value="Round"/>
	  <Setter Property="StrokeEndLineCap" Value="Round"/>
	  <Setter Property="VerticalAlignment" Value="Center"/>
	  <Setter Property="SnapsToDevicePixels" Value="True"/>
	  <Setter Property="Effect">
		<Setter.Value>
		  <DropShadowEffect Color="#000000" BlurRadius="1.2" ShadowDepth="0.4" Opacity="0.55" Direction="270"/>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="IcoOnBtn" TargetType="Path" BasedOn="{StaticResource Ico}">
	  <Setter Property="Fill" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Margin" Value="0,0,6,0"/>
	</Style>
	<Style x:Key="IcoFilter" TargetType="Path" BasedOn="{StaticResource Ico}">
	  <Setter Property="Stroke" Value="Transparent"/>
	  <Setter Property="StrokeThickness" Value="0"/>
	</Style>
	<Style x:Key="CaptionBtn" TargetType="Button">
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CaptionHover}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CaptionPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="CaptionCloseBtn" TargetType="Button" BasedOn="{StaticResource CaptionBtn}">
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CloseHover}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.ClosePress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="DlgBtn" TargetType="Button">
	  <Setter Property="Background" Value="{DynamicResource BtnFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="10,4"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					Padding="{TemplateBinding Padding}" CornerRadius="3" SnapsToDevicePixels="True">
			  <Border.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="4" ShadowDepth="1" Opacity="0.32" Direction="270"/>
			  </Border.Effect>
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="Button" BasedOn="{StaticResource DlgBtn}"/>
	<Style TargetType="TextBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="CaretBrush" Value="{DynamicResource Theme.AccentHi}"/>
	  <Setter Property="SelectionBrush" Value="{DynamicResource Theme.AccentDeep}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="6,2"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TextBox">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					CornerRadius="2" SnapsToDevicePixels="True">
			  <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsFocused" Value="True">
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="CheckBox">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="CheckBox">
			<StackPanel Orientation="Horizontal">
			  <Border x:Name="box" Width="16" Height="16" Background="{DynamicResource Theme.Fill}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2"
					  Margin="0,0,8,0" VerticalAlignment="Center" SnapsToDevicePixels="True">
				<Border.Effect>
				  <DropShadowEffect Color="#000000" BlurRadius="2" ShadowDepth="0.6" Opacity="0.4" Direction="270"/>
				</Border.Effect>
				<Path x:Name="check" Data="{StaticResource GeoCheck}" Fill="{DynamicResource Theme.CheckMark}"
					  Stroke="#000000" StrokeThickness="0.7" StrokeLineJoin="Round"
					  Stretch="Uniform" Margin="2" Visibility="Collapsed"/>
			  </Border>
			  <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
			</StackPanel>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsChecked" Value="True">
				<Setter TargetName="check" Property="Visibility" Value="Visible"/>
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CheckOn}"/>
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CaptionPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TextBlock">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	</Style>
	<Style TargetType="ListBoxItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="Padding" Value="10,7"/>
	  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListBoxItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}" SnapsToDevicePixels="True">
			  <DockPanel>
				<Border x:Name="accent" Width="3" Background="Transparent" DockPanel.Dock="Left"/>
				<ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
			  </DockPanel>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
				<Setter TargetName="accent" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <MultiTrigger>
				<MultiTrigger.Conditions>
				  <Condition Property="IsSelected" Value="True"/>
				  <Condition Property="IsMouseOver" Value="True"/>
				</MultiTrigger.Conditions>
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="accent" Property="Background" Value="{DynamicResource Theme.Ico}"/>
			  </MultiTrigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ListViewItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
	  <Setter Property="SnapsToDevicePixels" Value="True"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListViewItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}" Padding="0,2" SnapsToDevicePixels="True">
			  <GridViewRowPresenter Content="{TemplateBinding Content}"
									Columns="{TemplateBinding GridView.ColumnCollection}"
									VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <MultiTrigger>
				<MultiTrigger.Conditions>
				  <Condition Property="IsSelected" Value="True"/>
				  <Condition Property="IsMouseOver" Value="True"/>
				</MultiTrigger.Conditions>
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
			  </MultiTrigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ListBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.ListBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListBox">
			<Border Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					SnapsToDevicePixels="True">
			  <ScrollViewer Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
							Focusable="False" HorizontalScrollBarVisibility="Disabled"
							VerticalScrollBarVisibility="Auto">
				<ItemsPresenter/>
			  </ScrollViewer>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="PtListView" TargetType="ListView">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListView">
			<Border Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					SnapsToDevicePixels="True">
			  <ScrollViewer Style="{DynamicResource {x:Static GridView.GridViewScrollViewerStyleKey}}"
							Background="{TemplateBinding Background}"
							Padding="{TemplateBinding Padding}">
				<ItemsPresenter SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
			  </ScrollViewer>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ListView" BasedOn="{StaticResource PtListView}"/>
	<Style x:Key="{x:Static GridView.GridViewStyleKey}" TargetType="ListView" BasedOn="{StaticResource PtListView}"/>
	<Style x:Key="{x:Static GridView.GridViewItemContainerStyleKey}" TargetType="ListViewItem" BasedOn="{StaticResource {x:Type ListViewItem}}"/>
	<Style TargetType="GridViewColumnHeader">
	  <Setter Property="Background" Value="{DynamicResource HeadFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Muted}"/>
	  <Setter Property="Padding" Value="6,5"/>
	  <Setter Property="HorizontalContentAlignment" Value="Left"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="GridViewColumnHeader">
			<Grid>
			  <Border x:Name="bd" Background="{TemplateBinding Background}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="0,0,1,1"
					  Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
				<ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
								  VerticalAlignment="Center"/>
			  </Border>
			  <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="8">
				<Thumb.Template>
				  <ControlTemplate TargetType="Thumb">
					<Border Background="Transparent" Width="8"/>
				  </ControlTemplate>
				</Thumb.Template>
			  </Thumb>
			</Grid>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
			  </Trigger>
			  <Trigger Property="Role" Value="Padding">
				<Setter TargetName="PART_HeaderGripper" Property="Visibility" Value="Collapsed"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TabItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Muted}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="Padding" Value="12,6"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TabItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					Padding="{TemplateBinding Padding}" BorderThickness="0,0,0,2"
					BorderBrush="Transparent" SnapsToDevicePixels="True">
			  <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BarFace}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TabControl">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TabControl">
			<Grid>
			  <Grid.RowDefinitions>
				<RowDefinition Height="Auto"/>
				<RowDefinition Height="*"/>
			  </Grid.RowDefinitions>
			  <TabPanel Grid.Row="0" IsItemsHost="True" Background="{DynamicResource Theme.FillDeep}"/>
			  <Border Grid.Row="1" Background="{TemplateBinding Background}">
				<ContentPresenter ContentSource="SelectedContent"/>
			  </Border>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="GridSplitter">
	  <Setter Property="Background" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="GridSplitter">
			<Border x:Name="bd" Background="{TemplateBinding Background}"/>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsDragging" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="ThemeScrollThumb" TargetType="Thumb">
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Thumb">
			<Border x:Name="bd" Background="{DynamicResource Theme.Border}" CornerRadius="3" Margin="1"/>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsDragging" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="ThemeScrollPage" TargetType="RepeatButton">
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="RepeatButton">
			<Border Background="Transparent"/>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ScrollBar">
	  <Setter Property="Background" Value="{DynamicResource Theme.FillDeep}"/>
	  <Setter Property="Width" Value="10"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ScrollBar">
			<Grid Background="{TemplateBinding Background}">
			  <Track x:Name="PART_Track" IsDirectionReversed="True">
				<Track.DecreaseRepeatButton>
				  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ThemeScrollPage}"/>
				</Track.DecreaseRepeatButton>
				<Track.Thumb>
				  <Thumb Style="{StaticResource ThemeScrollThumb}"/>
				</Track.Thumb>
				<Track.IncreaseRepeatButton>
				  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ThemeScrollPage}"/>
				</Track.IncreaseRepeatButton>
			  </Track>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	  <Style.Triggers>
		<Trigger Property="Orientation" Value="Horizontal">
		  <Setter Property="Width" Value="Auto"/>
		  <Setter Property="Height" Value="10"/>
		  <Setter Property="Template">
			<Setter.Value>
			  <ControlTemplate TargetType="ScrollBar">
				<Grid Background="{TemplateBinding Background}">
				  <Track x:Name="PART_Track" IsDirectionReversed="False">
					<Track.DecreaseRepeatButton>
					  <RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource ThemeScrollPage}"/>
					</Track.DecreaseRepeatButton>
					<Track.Thumb>
					  <Thumb Style="{StaticResource ThemeScrollThumb}"/>
					</Track.Thumb>
					<Track.IncreaseRepeatButton>
					  <RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource ThemeScrollPage}"/>
					</Track.IncreaseRepeatButton>
				  </Track>
				</Grid>
			  </ControlTemplate>
			</Setter.Value>
		  </Setter>
		</Trigger>
	  </Style.Triggers>
	</Style>
	<Style TargetType="ToolTip">
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="8,5"/>
	</Style>
	<Style TargetType="ContextMenu">
	  <Setter Property="Background" Value="{DynamicResource PopFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ContextMenu">
			<Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="1" Padding="4,6" CornerRadius="2">
			  <Border.Effect>
				<DropShadowEffect Color="#041018" BlurRadius="12" ShadowDepth="2" Opacity="0.4" Direction="270"/>
			  </Border.Effect>
			  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="MenuItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Padding" Value="8,6"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="MenuItem">
			<Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}">
			  <DockPanel>
				<ContentPresenter DockPanel.Dock="Left" ContentSource="Icon" Width="18" Margin="0,0,8,0"
								  VerticalAlignment="Center"/>
				<ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
			  </DockPanel>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsHighlighted" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="Separator">
	  <Setter Property="Margin" Value="8,4"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Separator">
			<Border Height="1" Background="{DynamicResource Theme.Border}"/>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ComboBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="Height" Value="26"/>
	  <Setter Property="Padding" Value="6,2"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ComboBox">
			<Grid>
			  <ToggleButton x:Name="toggle" Focusable="False" ClickMode="Press"
							IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
				<ToggleButton.Template>
				  <ControlTemplate TargetType="ToggleButton">
					<Border x:Name="cbd" Background="{DynamicResource Theme.Fill}"
							BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2">
					  <Path HorizontalAlignment="Right" Margin="0,0,8,0" VerticalAlignment="Center"
							Data="{StaticResource GeoChevronRight}" Fill="{DynamicResource Theme.Ico}"
							Width="10" Height="10" Stretch="Uniform" RenderTransformOrigin="0.5,0.5">
						<Path.RenderTransform>
						  <RotateTransform Angle="90"/>
						</Path.RenderTransform>
					  </Path>
					</Border>
					<ControlTemplate.Triggers>
					  <Trigger Property="IsMouseOver" Value="True">
						<Setter TargetName="cbd" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
					  </Trigger>
					  <Trigger Property="IsChecked" Value="True">
						<Setter TargetName="cbd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
					  </Trigger>
					</ControlTemplate.Triggers>
				  </ControlTemplate>
				</ToggleButton.Template>
			  </ToggleButton>
			  <ContentPresenter Margin="8,0,22,0" VerticalAlignment="Center" HorizontalAlignment="Left"
								Content="{TemplateBinding SelectionBoxItem}"
								ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
								IsHitTestVisible="False"
								TextElement.Foreground="{DynamicResource Theme.Text}"/>
			  <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
					 PopupAnimation="Fade">
				<Border Background="{DynamicResource PopFace}" BorderBrush="{DynamicResource Theme.Accent}"
						BorderThickness="1" MinWidth="{TemplateBinding ActualWidth}">
				  <ScrollViewer MaxHeight="220">
					<ItemsPresenter/>
				  </ScrollViewer>
				</Border>
			  </Popup>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ComboBoxItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Padding" Value="8,5"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ComboBoxItem">
			<Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}">
			  <ContentPresenter/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsHighlighted" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ProgressBar">
	  <Setter Property="Background" Value="{DynamicResource Theme.FillDeep}"/>
	  <Setter Property="Foreground" Value="{DynamicResource ProgGreen}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ProgressBar">
			<Border Background="{TemplateBinding Background}" CornerRadius="3" ClipToBounds="True" BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1">
			  <Border.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="2" ShadowDepth="0.5" Opacity="0.35" Direction="270"/>
			  </Border.Effect>
			  <Grid>
				<Rectangle x:Name="PART_Track" Fill="Transparent"/>
				<Decorator x:Name="PART_Indicator" HorizontalAlignment="Left">
				  <Border Background="{TemplateBinding Foreground}" CornerRadius="2"/>
				</Decorator>
			  </Grid>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	  <Style.Triggers>
		<DataTrigger Binding="{Binding Status}" Value="Hashing">
		  <Setter Property="Foreground" Value="{DynamicResource ProgYellow}"/>
		</DataTrigger>
		<DataTrigger Binding="{Binding Status}" Value="Paused">
		  <Setter Property="Foreground" Value="{DynamicResource ProgYellow}"/>
		</DataTrigger>
	  </Style.Triggers>
	</Style>
  </Window.Resources>
  <DockPanel Background="{DynamicResource Theme.WindowBg}">
	<Border x:Name="hdrBar" DockPanel.Dock="Top" Background="{DynamicResource HdrFace}" Height="32">
	  <Grid>
		<Grid.ColumnDefinitions>
		  <ColumnDefinition Width="Auto"/>
		  <ColumnDefinition Width="*"/>
		  <ColumnDefinition Width="Auto"/>
		</Grid.ColumnDefinitions>
		<Image x:Name="imgPlanet" Width="20" Height="20" Margin="10,0,8,0"
			   VerticalAlignment="Center" RenderOptions.BitmapScalingMode="NearestNeighbor"
			   SnapsToDevicePixels="True"/>
		<StackPanel Grid.Column="1" VerticalAlignment="Center">
		  <TextBlock Text="PowerTorrent" Foreground="{DynamicResource Theme.Text}" FontSize="13" FontWeight="SemiBold"/>
		</StackPanel>
		<StackPanel Grid.Column="2" Orientation="Horizontal">
		  <Button x:Name="btnOptions" Style="{StaticResource CaptionBtn}" Width="46" Height="32" Padding="0" ToolTip="Options">
			<Canvas Width="16" Height="16">
			  <Path Fill="{DynamicResource Theme.Text}" Stroke="#000000" StrokeThickness="0.7" StrokeLineJoin="Round"
					Stretch="Uniform" Width="16" Height="16"
					Data="M12,15.5A3.5,3.5 0 0,1 8.5,12A3.5,3.5 0 0,1 12,8.5A3.5,3.5 0 0,1 15.5,12A3.5,3.5 0 0,1 12,15.5M19.43,12.97C19.47,12.65 19.5,12.33 19.5,12C19.5,11.67 19.47,11.34 19.43,11L21.54,9.37C21.73,9.22 21.78,8.95 21.66,8.73L19.66,5.27C19.54,5.05 19.27,4.96 19.05,5.05L16.56,6.05C16.04,5.66 15.5,5.32 14.87,5.07L14.5,2.42C14.46,2.18 14.25,2 14,2H10C9.75,2 9.54,2.18 9.5,2.42L9.13,5.07C8.5,5.32 7.96,5.66 7.44,6.05L4.95,5.05C4.73,4.96 4.46,5.05 4.34,5.27L2.34,8.73C2.21,8.95 2.27,9.22 2.46,9.37L4.57,11C4.53,11.34 4.5,11.67 4.5,12C4.5,12.33 4.53,12.65 4.57,12.97L2.46,14.63C2.27,14.78 2.21,15.05 2.34,15.27L4.34,18.73C4.46,18.95 4.73,19.03 4.95,18.95L7.44,17.94C7.96,18.34 8.5,18.68 9.13,18.93L9.5,21.58C9.54,21.82 9.75,22 10,22H14C14.25,22 14.46,21.82 14.5,21.58L14.87,18.93C15.5,18.67 16.04,18.34 16.56,17.94L19.05,18.95C19.27,19.03 19.54,18.95 19.66,18.73L21.66,15.27C21.78,15.05 21.73,14.78 21.54,14.63L19.43,12.97Z">
				<Path.Effect>
				  <DropShadowEffect Color="#000000" BlurRadius="1.2" ShadowDepth="0.4" Opacity="0.55" Direction="270"/>
				</Path.Effect>
			  </Path>
			</Canvas>
		  </Button>
		  <Button x:Name="btnWinMin" Style="{StaticResource CaptionBtn}" Width="46" Height="32" Padding="0" ToolTip="Minimize">
			<Path Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10" Stretch="None"
				  Data="M0,5 L10,5">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		  <Button x:Name="btnWinMax" Style="{StaticResource CaptionBtn}" Width="46" Height="32" Padding="0" ToolTip="Maximize">
			<Path x:Name="pathWinMax" Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10"
				  Stretch="Uniform" Data="M1,1 H9 V9 H1 Z">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		  <Button x:Name="btnWinClose" Style="{StaticResource CaptionCloseBtn}" Width="46" Height="32" Padding="0" ToolTip="Close">
			<Path x:Name="pathWinClose" Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10"
				  Stretch="None" Data="M0,0 L10,10 M10,0 L0,10">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		</StackPanel>
		<Popup x:Name="popOptions" Placement="Bottom" StaysOpen="True" AllowsTransparency="True" PopupAnimation="Fade">
		  <Border Background="{DynamicResource PopFace}" BorderBrush="{DynamicResource Theme.Accent}" BorderThickness="1" Padding="16,14" CornerRadius="3">
			<Border.Effect>
			  <DropShadowEffect Color="#041018" BlurRadius="16" ShadowDepth="3" Opacity="0.45" Direction="270"/>
			</Border.Effect>
			<StackPanel Width="250">
			  <TextBlock Text="Options" FontWeight="SemiBold" Margin="0,0,0,10"/>
			  <DockPanel Margin="0,0,0,10">
				<TextBlock Text="Theme" Width="80" VerticalAlignment="Center"/>
				<ComboBox x:Name="cmbTheme"/>
			  </DockPanel>
			  <CheckBox x:Name="chkDht" Content="DHT" IsChecked="True" Margin="0,0,0,8"/>
			  <CheckBox x:Name="chkEncrypt" Content="MSE encryption" IsChecked="True" Margin="0,0,0,8"/>
			  <CheckBox x:Name="chkUtp" Content="uTP" IsChecked="True" Margin="0,0,0,8"/>
			  <CheckBox x:Name="chkSeq" Content="Sequential download" Margin="0,0,0,8"/>
			  <CheckBox x:Name="chkSeed" Content="Seed when done" IsChecked="True" Margin="0,0,0,8"/>
			  <CheckBox x:Name="chkCloseToTray" Content="Close to tray" IsChecked="False" Margin="0,0,0,12"/>
			  <DockPanel Margin="0,0,0,8">
				<TextBlock Text="Port" Width="80" VerticalAlignment="Center"/>
				<TextBox x:Name="txtPort" Height="24" Text="6881" VerticalContentAlignment="Center" Padding="4,1"/>
			  </DockPanel>
			  <DockPanel Margin="0,0,0,10">
				<TextBlock Text="Max peers" Width="80" VerticalAlignment="Center"/>
				<TextBox x:Name="txtPeers" Height="24" Text="40" VerticalContentAlignment="Center" Padding="4,1"/>
			  </DockPanel>
			  <Button x:Name="btnSaveOptions" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch"
					  Margin="0,0,0,12">
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheck}"/>
				  <TextBlock Text="Save options" VerticalAlignment="Center"/>
				</StackPanel>
			  </Button>
			  <Border Height="1" Background="{DynamicResource Theme.Border}" Margin="0,2,0,12"/>
			  <TextBlock Text="File associations" FontWeight="SemiBold" Margin="0,0,0,8"/>
			  <TextBlock x:Name="lblAssoc" Foreground="{DynamicResource Theme.Muted}" FontSize="11" Margin="0,0,0,8"
						 TextWrapping="Wrap" Text="magnet: not registered"/>
			  <Button x:Name="btnRegister" Style="{StaticResource DlgBtn}"
					  HorizontalAlignment="Stretch" Margin="0,0,0,6">
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMagnet}"/>
				  <TextBlock Text="Register magnet" VerticalAlignment="Center"/>
				</StackPanel>
			  </Button>
			  <Button x:Name="btnRegisterTorrent" Style="{StaticResource DlgBtn}"
					  HorizontalAlignment="Stretch" Margin="0,0,0,6">
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheckMulti}"/>
				  <TextBlock Text="Register .torrent" VerticalAlignment="Center"/>
				</StackPanel>
			  </Button>
			  <Button x:Name="btnUnregister" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch">
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
				  <TextBlock Text="Remove associations" VerticalAlignment="Center"/>
				</StackPanel>
			  </Button>
			</StackPanel>
		  </Border>
		</Popup>
	  </Grid>
	</Border>
	<Border DockPanel.Dock="Top" Background="{DynamicResource ToolFace}" Padding="8,6">
	  <Border.Effect>
		<DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="1" Opacity="0.28" Direction="270"/>
	  </Border.Effect>
	  <DockPanel>
		<Button x:Name="btnAddFile" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Add torrent">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoPlus}"/>
			<TextBlock Text="Add torrent" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnAddMagnet" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Add magnet">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMagnet}"/>
			<TextBlock Text="Add magnet" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnPlayPause" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Pause" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path x:Name="icoPlayPause" Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoPause}"/>
			<TextBlock x:Name="txtPlayPause" Text="Pause" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnStop" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Stop" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoStop}"/>
			<TextBlock Text="Stop" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnRemove" Style="{StaticResource DlgBtn}" Margin="0,0,16,0" ToolTip="Remove" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
			<TextBlock Text="Remove" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<TextBlock Text="Save to" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}" Margin="0,0,6,0"/>
		<Button x:Name="btnBrowseDir" Style="{StaticResource DlgBtn}" DockPanel.Dock="Right" Content="Browse..." Width="80" Margin="6,0,0,0"/>
		<TextBox x:Name="txtSave" Height="26" VerticalContentAlignment="Center"/>
	  </DockPanel>
	</Border>
	<Border DockPanel.Dock="Bottom" Background="{DynamicResource BarFace}" Padding="10,6">
	  <Border.Effect>
		<DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="1" Opacity="0.22" Direction="90"/>
	  </Border.Effect>
	  <DockPanel>
		<TextBlock x:Name="lblFooter" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}" FontSize="11"/>
		<StackPanel Orientation="Horizontal" VerticalAlignment="Center">
		  <Path Style="{StaticResource Ico}" Data="{StaticResource GeoDownload}" Margin="0,0,5,0"/>
		  <TextBlock x:Name="lblDownTotal" Text="0 B/s" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Margin="0,0,14,0"/>
		  <Path Style="{StaticResource Ico}" Data="{StaticResource GeoUpload}" Margin="0,0,5,0"/>
		  <TextBlock x:Name="lblUpTotal" Text="0 B/s" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Margin="0,0,14,0"/>
		  <TextBlock x:Name="lblTotals" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Text="Torrents: 0"/>
		</StackPanel>
	  </DockPanel>
	</Border>
	<Grid x:Name="grdBody" Background="{DynamicResource Theme.WindowBg}">
	  <Grid.ColumnDefinitions>
		<ColumnDefinition x:Name="colFilter" Width="150"/>
		<ColumnDefinition Width="18"/>
		<ColumnDefinition Width="*"/>
	  </Grid.ColumnDefinitions>
	  <ListBox x:Name="lstFilter" Background="{DynamicResource Theme.ListBg}" Foreground="{DynamicResource Theme.Text}" BorderThickness="0" BorderBrush="{DynamicResource Theme.Border}">
		<ListBoxItem Tag="All" IsSelected="True">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoCheckMulti}" Margin="0,0,8,0"/>
			<TextBlock Text="All" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Downloading">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoDownload}" Margin="0,0,8,0"/>
			<TextBlock Text="Downloading" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Seeding">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoUpload}" Margin="0,0,8,0"/>
			<TextBlock Text="Seeding" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Completed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoCheck}" Margin="0,0,8,0"/>
			<TextBlock Text="Completed" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Paused">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoPause}" Margin="0,0,8,0"/>
			<TextBlock Text="Paused" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Checking">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoQuestion}" Margin="0,0,8,0"/>
			<TextBlock Text="Checking" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
	  </ListBox>
	  <Button x:Name="btnFilterFold" Grid.Column="1" Style="{StaticResource CaptionBtn}" Width="18"
			  ToolTip="Hide filters" Background="{DynamicResource Theme.ListBg}">
		<Path x:Name="icoFilterFold" Style="{StaticResource IcoFilter}" Width="12" Height="12"
			  Data="{StaticResource GeoChevronLeft}"/>
	  </Button>
	  <Grid Grid.Column="2" Background="{DynamicResource Theme.WindowBg}">
		<Grid.RowDefinitions>
		  <RowDefinition Height="*"/>
		  <RowDefinition Height="3"/>
		  <RowDefinition Height="180"/>
		</Grid.RowDefinitions>
		<ListView x:Name="lvTorrents" Style="{StaticResource PtListView}" Background="{DynamicResource Theme.WindowBg}" Foreground="{DynamicResource Theme.Text}" BorderThickness="0"
				  SelectionMode="Single">
		  <ListView.ContextMenu>
			<ContextMenu x:Name="ctxTorrents">
			  <MenuItem x:Name="miCtxPlayPause" Header="Pause">
				<MenuItem.Icon>
				  <Path x:Name="icoCtxPlayPause" Style="{StaticResource IcoFilter}" Width="14" Height="14"
						Data="{StaticResource GeoPause}"/>
				</MenuItem.Icon>
			  </MenuItem>
			  <MenuItem x:Name="miCtxStop" Header="Stop">
				<MenuItem.Icon>
				  <Path Style="{StaticResource IcoFilter}" Width="14" Height="14" Data="{StaticResource GeoStop}"/>
				</MenuItem.Icon>
			  </MenuItem>
			  <Separator x:Name="miCtxSep"/>
			  <MenuItem x:Name="miCtxRemove" Header="Remove">
				<MenuItem.Icon>
				  <Path Style="{StaticResource IcoFilter}" Width="14" Height="14" Data="{StaticResource GeoMinus}"/>
				</MenuItem.Icon>
			  </MenuItem>
			</ContextMenu>
		  </ListView.ContextMenu>
		  <ListView.View>
			<GridView>
			  <GridViewColumn Header="Name" Width="220" DisplayMemberBinding="{Binding Name}"/>
			  <GridViewColumn Header="Size" Width="80" DisplayMemberBinding="{Binding SizeText}"/>
			  <GridViewColumn Header="Progress" Width="140">
				<GridViewColumn.CellTemplate>
				  <DataTemplate>
					<Grid Width="120" Height="18">
					  <ProgressBar Minimum="0" Maximum="100" Value="{Binding Progress}" Height="16"/>
					  <TextBlock Text="{Binding ProgressText}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="11"
								 Foreground="{DynamicResource Theme.Text}" FontWeight="SemiBold"/>
					</Grid>
				  </DataTemplate>
				</GridViewColumn.CellTemplate>
			  </GridViewColumn>
			  <GridViewColumn Header="Status" Width="90" DisplayMemberBinding="{Binding Status}"/>
			  <GridViewColumn Header="Peers" Width="70" DisplayMemberBinding="{Binding PeersText}"/>
			  <GridViewColumn Width="80" DisplayMemberBinding="{Binding DownText}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoDownload}"/>
					<TextBlock Text="Down" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			  <GridViewColumn Width="80" DisplayMemberBinding="{Binding UpText}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoUpload}"/>
					<TextBlock Text="Up" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			  <GridViewColumn Width="80" DisplayMemberBinding="{Binding Eta}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoClock}"/>
					<TextBlock Text="ETA" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			</GridView>
		  </ListView.View>
		</ListView>
		<GridSplitter Grid.Row="1" Height="3" HorizontalAlignment="Stretch"/>
		<TabControl x:Name="tabDetails" Grid.Row="2" Background="{DynamicResource Theme.WindowBg}" BorderThickness="0">
		  <TabItem Header="General">
			<StackPanel x:Name="pnlGeneral" Margin="10" Background="{DynamicResource Theme.WindowBg}">
			  <TextBlock x:Name="lblName" Text="Name: -" Margin="0,0,0,4"/>
			  <TextBlock x:Name="lblHash" Text="Hash: -" FontFamily="Consolas" FontSize="12" Foreground="{DynamicResource Theme.Muted}" Margin="0,0,0,4" TextWrapping="Wrap"/>
			  <TextBlock x:Name="lblState" Text="State: Idle" Margin="0,0,0,4"/>
			  <TextBlock x:Name="lblProgress" Text="Progress: 0%" Margin="0,0,0,4"/>
			  <TextBlock x:Name="lblPeers" Text="Peers: 0 / 0" Margin="0,0,0,4"/>
			  <TextBlock x:Name="lblSpeed" Text="Down 0 B/s	  Up 0 B/s	 ETA --"/>
			</StackPanel>
		  </TabItem>
		  <TabItem Header="Log">
			<TextBox x:Name="txtLog" IsReadOnly="True" TextWrapping="Wrap"
					 VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
					 Background="{DynamicResource Theme.FillDeep}" Foreground="{DynamicResource Theme.Ico}" BorderThickness="0" Padding="8"/>
		  </TabItem>
		</TabControl>
		<Popup x:Name="popMagnet" Placement="Center" StaysOpen="False" AllowsTransparency="True">
		  <Border Background="{DynamicResource PopFace}" BorderBrush="{DynamicResource Theme.Accent}" BorderThickness="1" Padding="16" Width="480" CornerRadius="3">
			<Border.Effect>
			  <DropShadowEffect Color="#041018" BlurRadius="16" ShadowDepth="3" Opacity="0.45" Direction="270"/>
			</Border.Effect>
			<StackPanel>
			  <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
				<Path Style="{StaticResource Ico}" Width="16" Height="16" Margin="0,0,8,0" Data="{StaticResource GeoMagnet}"/>
				<TextBlock Text="Add magnet link" FontWeight="SemiBold" VerticalAlignment="Center"/>
			  </StackPanel>
			  <TextBox x:Name="txtMagnet" Height="52" TextWrapping="Wrap" AcceptsReturn="False"/>
			  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
				<Button x:Name="btnMagnetOk" Style="{StaticResource DlgBtn}" Margin="0,0,8,0" MinWidth="80">
				  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheck}"/>
					<TextBlock Text="OK" VerticalAlignment="Center"/>
				  </StackPanel>
				</Button>
				<Button x:Name="btnMagnetCancel" Style="{StaticResource DlgBtn}" MinWidth="80">
				  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
					<TextBlock Text="Cancel" VerticalAlignment="Center"/>
				  </StackPanel>
				</Button>
			  </StackPanel>
			</StackPanel>
		  </Border>
		</Popup>
	  </Grid>
	</Grid>
  </DockPanel>
</Window>
'@

	$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
	$window = [Windows.Markup.XamlReader]::Load($reader)

	$ui = @{}
	foreach ($n in @(
			'hdrBar','imgPlanet','txtSave','btnBrowseDir','chkDht','chkEncrypt','chkUtp','chkSeq','chkSeed','chkCloseToTray',
			'txtPort','txtPeers','cmbTheme','btnSaveOptions','btnAddFile','btnAddMagnet','btnPlayPause','icoPlayPause','txtPlayPause','btnStop','btnRemove',
			'lblName','lblHash','lblState','lblProgress','lblPeers','lblSpeed','txtLog','btnRegister','btnRegisterTorrent',
			'btnUnregister','lblAssoc','lblFooter','lblTotals','lblDownTotal','lblUpTotal',
			'btnWinMin','btnWinMax','btnWinClose','pathWinMax','pathWinClose','btnOptions','popOptions',
			'lvTorrents','lstFilter','colFilter','btnFilterFold','icoFilterFold','popMagnet','txtMagnet','btnMagnetOk','btnMagnetCancel',
			'ctxTorrents','miCtxPlayPause','icoCtxPlayPause','miCtxStop','miCtxRemove','miCtxSep'
		)) {
		$ui[$n] = $window.FindName($n)
	}
	$script:PtGeoPause = $window.TryFindResource('GeoPause')
	$script:PtGeoPlay = $window.TryFindResource('GeoPlay')
	$script:PtGeoChevronLeft = $window.TryFindResource('GeoChevronLeft')
	$script:PtGeoChevronRight = $window.TryFindResource('GeoChevronRight')
	$script:PtFilterCollapsed = $false

	$chrome = New-Object System.Windows.Shell.WindowChrome
	$chrome.CaptionHeight = 0
	$chrome.ResizeBorderThickness = New-Object System.Windows.Thickness 6
	$chrome.GlassFrameThickness = New-Object System.Windows.Thickness 0
	$chrome.CornerRadius = New-Object System.Windows.CornerRadius 0
	$chrome.UseAeroCaptionButtons = $false
	[System.Windows.Shell.WindowChrome]::SetWindowChrome($window, $chrome)
	foreach ($b in @($ui.btnWinMin, $ui.btnWinMax, $ui.btnWinClose, $ui.btnOptions)) {
		[System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($b, $true)
	}
	$ui.popOptions.PlacementTarget = $ui.btnOptions
	$ui.popOptions.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
	try { [PowerTorrent.WindowMaximizeFix]::Attach($window) } catch { }

	$wmploc = '%SystemRoot%\System32\wmploc.dll'
	$script:PtPlanetIdle = Get-NativeIconBitmap -File $wmploc -Index 139 -Large
	$script:PtPlanetFrames = @()
	foreach ($idx in 137..151) {
		$fr = Get-NativeIconBitmap -File $wmploc -Index $idx -Large
		if ($fr) { $script:PtPlanetFrames += ,$fr }
	}
	if (-not $script:PtPlanetIdle -and $script:PtPlanetFrames.Count -ge 3) {
		$script:PtPlanetIdle = $script:PtPlanetFrames[2]
	}
	if ($script:PtPlanetIdle) {
		$ui.imgPlanet.Source = $script:PtPlanetIdle
		$window.Icon = $script:PtPlanetIdle
	}
	$script:PtPlanetIndex = 0
	$script:PtPlanetConnected = $false
	$script:PtTrayIdle = $null
	try { $script:PtTrayIdle = Get-NativeWinIcon -File $wmploc -Index 139 } catch { }
	if (-not $script:PtTrayIdle) {
		try { $script:PtTrayIdle = [System.Drawing.SystemIcons]::Application } catch { }
	}

	$script:PtGeomMax = [System.Windows.Media.Geometry]::Parse('M0.5,0.5 H9.5 V9.5 H0.5 Z')
	$script:PtGeomRestore = [System.Windows.Media.Geometry]::Parse('M2.5,0.5 H9.5 V7.5 H8.5 V1.5 H2.5 Z M0.5,2.5 H7.5 V9.5 H0.5 Z')

	$script:PtJobs = New-Object System.Collections.Generic.List[object]
	$script:PtRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[PowerTorrent.TorrentRow]'
	$ui.lvTorrents.ItemsSource = $script:PtRows
	try {
		$script:PtView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:PtRows)
		if ($script:PtView) { $script:PtView.Filter = [PowerTorrent.TorrentRowFilter]::GetPredicate() }
	} catch { }
	$script:PtLogSeen = @{}
	$script:PtWindow = $window
	$script:PtNextPort = [int]$Port
	if ($script:PtNextPort -le 0) { $script:PtNextPort = 6881 }

	if ($InitialSave) { $ui.txtSave.Text = $InitialSave }
	else { $ui.txtSave.Text = Get-DefaultSavePath }
	$ui.txtPort.Text = [string]$Port
	$ui.txtPeers.Text = [string]$MaxPeers
	$ui.chkDht.IsChecked = -not [bool]$NoDht
	$ui.chkEncrypt.IsChecked = -not [bool]$NoEncrypt
	$ui.chkUtp.IsChecked = -not [bool]$NoUtp
	$ui.chkSeq.IsChecked = [bool]$Sequential
	$ui.chkSeed.IsChecked = -not [bool]$NoSeed
	if ($null -eq $script:PtCloseToTray) { $script:PtCloseToTray = $false }
	$ui.chkCloseToTray.IsChecked = [bool]$script:PtCloseToTray
	if (-not $script:PtTheme) { $script:PtTheme = 'Ice' }
	foreach ($tn in @(Get-PtThemeNames)) { [void]$ui.cmbTheme.Items.Add($tn) }
	$themePick = 'Ice'
	foreach ($it in $ui.cmbTheme.Items) {
		if ([string]$it -eq $script:PtTheme) { $themePick = [string]$it; break }
	}
	$script:PtTheme = $themePick
	$ui.cmbTheme.SelectedItem = $themePick
	try { Apply-PtTheme $window $themePick } catch { }

	function Get-PtUiOptionMap {
		$portVal = Get-PtInt -Text $ui.txtPort.Text -Fallback 6881
		$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 40
		$th = [string]$ui.cmbTheme.SelectedItem
		if ([string]::IsNullOrWhiteSpace($th)) { $th = 'Ice' }
		@{
			Theme	   = $th
			Dht		   = Get-PtBoolText ([bool]$ui.chkDht.IsChecked)
			Encrypt	   = Get-PtBoolText ([bool]$ui.chkEncrypt.IsChecked)
			Utp		   = Get-PtBoolText ([bool]$ui.chkUtp.IsChecked)
			Sequential = Get-PtBoolText ([bool]$ui.chkSeq.IsChecked)
			Seed	   = Get-PtBoolText ([bool]$ui.chkSeed.IsChecked)
			CloseToTray = Get-PtBoolText ([bool]$ui.chkCloseToTray.IsChecked)
			Port	   = [string]$portVal
			MaxPeers   = [string]$peerVal
			SavePath   = [string]$ui.txtSave.Text
		}
	}
	function Get-PtCompareOptionMap {
		$d = Get-PtDefaultOptions
		$ini = Read-PtIni
		foreach ($k in @('Theme','Dht','Encrypt','Utp','Sequential','Seed','Port','MaxPeers','SavePath','CloseToTray')) {
			if ($ini.ContainsKey($k) -and $null -ne $ini[$k] -and [string]$ini[$k] -ne '') { $d[$k] = [string]$ini[$k] }
		}
		return $d
	}
	function Update-SaveOptionsButton {
		if ($ui.btnSaveOptions) {
			$ui.btnSaveOptions.Visibility = [System.Windows.Visibility]::Visible
		}
	}

	function Sync-LiveOptions {
		try {
			$portVal = Get-PtInt -Text $ui.txtPort.Text -Fallback 6881
			$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 40
			$n = 0
			if ($script:PtJobs) { $n = $script:PtJobs.Count }
			for ($i = 0; $i -lt $n; $i++) {
				$job = $script:PtJobs[$i]
				$cfg = $job.Engine.Settings
				$cfg.EnableDht = [bool]$ui.chkDht.IsChecked
				$cfg.EnableEncrypt = [bool]$ui.chkEncrypt.IsChecked
				$cfg.EnableUtp = [bool]$ui.chkUtp.IsChecked
				$cfg.Sequential = [bool]$ui.chkSeq.IsChecked
				$cfg.SeedAfterComplete = [bool]$ui.chkSeed.IsChecked
				$cfg.MaxPeers = $peerVal
				$script:PtCloseToTray = [bool]$ui.chkCloseToTray.IsChecked
				try { $job.Engine.ApplyLiveSettings() } catch { }
			}
			try { Update-SaveOptionsButton } catch { }
		} catch { }
	}
	$optSync = { try { Sync-LiveOptions } catch { } }
	foreach ($c in @($ui.chkDht, $ui.chkEncrypt, $ui.chkUtp, $ui.chkSeq, $ui.chkSeed, $ui.chkCloseToTray)) {
		$c.add_Click($optSync)
	}
	$ui.txtPort.add_LostFocus($optSync)
	$ui.txtPeers.add_LostFocus($optSync)
	$ui.txtSave.add_LostFocus({ Update-SaveOptionsButton })
	$ui.cmbTheme.add_SelectionChanged({
		$th = [string]$ui.cmbTheme.SelectedItem
		if ($th) {
			$script:PtTheme = $th
			try { Apply-PtTheme $window $th } catch { }
		}
		try { Update-SaveOptionsButton } catch { }
	})
	$ui.btnSaveOptions.add_Click({
		try {
			Merge-PtIni (Get-PtUiOptionMap)
			Update-SaveOptionsButton
			Add-UiLog 'Options saved'
		} catch {
			[System.Windows.MessageBox]::Show([string]$_, 'PowerTorrent') | Out-Null
		}
	})
	foreach ($c in @($ui.chkDht, $ui.chkEncrypt, $ui.chkUtp, $ui.chkSeq, $ui.chkSeed, $ui.chkCloseToTray)) {
		$c.add_Click({ try { Update-SaveOptionsButton } catch { } })
	}
	$ui.txtPort.add_LostFocus({ try { Update-SaveOptionsButton } catch { } })
	$ui.txtPeers.add_LostFocus({ try { Update-SaveOptionsButton } catch { } })
	try { Update-SaveOptionsButton } catch { }

	function Update-AssocLabel {
		if (Test-PowerTorrentMagnetAssociation) {
			$ui.lblAssoc.Text = 'magnet: registered for this user'
		} else {
			$ui.lblAssoc.Text = 'magnet: not registered'
		}
	}
	Update-AssocLabel

	function Add-UiLog([string]$line) {
		if ([string]::IsNullOrWhiteSpace($line)) { return }
		$ui.txtLog.AppendText($line + [Environment]::NewLine)
		$ui.txtLog.ScrollToEnd()
	}

	function Get-SelectedJob {
		$row = $ui.lvTorrents.SelectedItem
		if (-not $row) { return $null }
		$n = 0
		if ($script:PtJobs) { $n = $script:PtJobs.Count }
		for ($i = 0; $i -lt $n; $i++) {
			$j = $script:PtJobs[$i]
			if ($j.Id -eq $row.Id) { return $j }
		}
		return $null
	}

	function Add-PtTorrent {
		param([string]$Source)
		$src = $Source.Trim()
		$isMag = $src.ToLowerInvariant().StartsWith('magnet:')
		if (-not $isMag) {
			if (-not (Test-Path -LiteralPath $src)) {
				[System.Windows.MessageBox]::Show("Torrent file not found:`n$src", 'PowerTorrent') | Out-Null
				return
			}
			$src = [System.IO.Path]::GetFullPath($src)
		}
		$jc = 0
		if ($script:PtJobs) { $jc = $script:PtJobs.Count }
		for ($ji = 0; $ji -lt $jc; $ji++) {
			if ($script:PtJobs[$ji].Source -eq $src) { return }
		}
		$script:PtNextPort = Get-PtInt -Text $ui.txtPort.Text -Fallback $script:PtNextPort
		$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 40
		$portVal = $script:PtNextPort
		if ($script:PtJobs.Count -gt 0) { $portVal = $script:PtNextPort + $script:PtJobs.Count }
		try {
			$cfg = New-PowerTorrentSettings -Source $src -OutDir $ui.txtSave.Text -ListenPort $portVal -Peers $peerVal `
				-Dht ([bool]$ui.chkDht.IsChecked) -Encrypt ([bool]$ui.chkEncrypt.IsChecked) -Utp ([bool]$ui.chkUtp.IsChecked) `
				-Seq ([bool]$ui.chkSeq.IsChecked) -Seed ([bool]$ui.chkSeed.IsChecked) -Forced $Peer -Level $LogLevel
			$eng = [PowerTorrent.Engine]::new($cfg)
			$info = $eng.GetInfo()
			$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
			$row = New-Object PowerTorrent.TorrentRow
			$row.Id = $id
			$row.Name = $(if ($info.Name) { $info.Name } else { $src })
			$row.Hash = $info.InfoHashHex
			$row.Apply($eng.GetStatus())
			$job = New-Object psobject -Property @{
				Id = $id
				Engine = $eng
				Row = $row
				Source = $src
				LogSeen = @{}
			}
			$script:PtJobs.Add($job)
			$script:PtRows.Add($row)
			$eng.Start()
			$script:PtPlanetConnected = $true
			$ui.lvTorrents.SelectedItem = $row
			Add-UiLog ('Added {0}' -f $row.Name)
		} catch {
			[System.Windows.MessageBox]::Show([string]$_, 'PowerTorrent') | Out-Null
		}
	}

	function Stop-AllTorrents {
		foreach ($job in @($script:PtJobs)) {
			try { $job.Engine.Stop() } catch { }
		}
		$script:PtJobs.Clear()
		$script:PtRows.Clear()
		$script:PtPlanetConnected = $false
		if ($script:PtPlanetIdle -and $ui.imgPlanet) { $ui.imgPlanet.Source = $script:PtPlanetIdle }
	}

	function Get-PtFilterName {
		$item = $ui.lstFilter.SelectedItem
		if ($item -is [System.Windows.Controls.ListBoxItem]) {
			if ($null -ne $item.Tag -and [string]$item.Tag -ne '') { return [string]$item.Tag }
			return [string]$item.Content
		}
		return [string]$item
	}

	function Test-PtRowVisible([string]$st) {
		switch (Get-PtFilterName) {
			'Downloading' { return ($st -eq 'Downloading' -or $st -eq 'Metadata' -or $st -eq 'Announcing') }
			'Seeding' { return ($st -eq 'Seeding') }
			'Completed' { return ($st -eq 'Complete' -or $st -eq 'Seeding') }
			'Paused' { return ($st -eq 'Paused') }
			'Checking' { return ($st -eq 'Hashing') }
			default { return $true }
		}
	}

	function Update-FilterView {
		[PowerTorrent.TorrentRowFilter]::Name = Get-PtFilterName
		if ($script:PtView) { try { $script:PtView.Refresh() } catch { } }
	}

	function Update-UiStatus {
		try {
			$incoming = Read-PtInbox
			if ($incoming) {
				foreach ($line in $incoming) { Add-PtTorrent -Source $line }
			}
			$anyPeers = $false
			$sumDown = [double]0
			$sumUp = [double]0
			$count = $script:PtJobs.Count
			for ($i = 0; $i -lt $count; $i++) {
				$job = $script:PtJobs[$i]
				try { $s = $job.Engine.GetStatus() } catch { continue }
				$job.Row.Apply($s)
				$sumDown += [double]$s.DownBytesPerSec
				$sumUp += [double]$s.UpBytesPerSec
				if ($job.Engine.IsRunning -and -not $job.Engine.IsPaused) { $anyPeers = $true }
			}
			$script:PtPlanetConnected = $anyPeers
			$ui.lblDownTotal.Text = ('{0}/s' -f [PowerTorrent.Engine]::Fmt([long]$sumDown))
			$ui.lblUpTotal.Text = ('{0}/s' -f [PowerTorrent.Engine]::Fmt([long]$sumUp))
			$ui.lblTotals.Text = ('Torrents: {0}' -f $count)
			Update-TransportButtons
			$job = Get-SelectedJob
			if ($job) {
				$s = $job.Engine.GetStatus()
				$ui.lblName.Text = ('Name: {0}' -f $(if ($s.Name) { $s.Name } else { '-' }))
				$ui.lblHash.Text = ('Hash: {0}' -f $(if ($s.InfoHashHex) { $s.InfoHashHex } else { '-' }))
				$ui.lblState.Text = ('State: {0}' -f $s.State)
				$ui.lblProgress.Text = ('Progress: {0:0.00}%   {1} / {2}   pieces {3}/{4}' -f $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.Downloaded), [PowerTorrent.Engine]::Fmt([long]$s.TotalSize), $s.PiecesDone, $s.PiecesTotal)
				$ui.lblPeers.Text = ('Peers: {0} connected / {1} known	  listen {2}' -f $s.PeersConnected, $s.PeersKnown, $s.ListenPort)
				$ui.lblSpeed.Text = ('Down {0}/s   Up {1}/s	  ETA {2}' -f [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), [PowerTorrent.Engine]::Fmt([long]$s.UpBytesPerSec), $s.Eta)
				$logs = $s.LogLines
				if ($logs) {
					for ($li = 0; $li -lt $logs.Length; $li++) {
						$line = $logs[$li]
						$key = $job.Id + '|' + $line
						if ($line -and -not $script:PtLogSeen.ContainsKey($key)) {
							$script:PtLogSeen[$key] = $true
							Add-UiLog (('[{0}] {1}' -f $job.Row.Name, $line))
						}
					}
				}
			}
		} catch { }
	}

	$ui.btnBrowseDir.add_Click({
		$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
		$dlg.Description = 'Choose download folder'
		if ($ui.txtSave.Text) { $dlg.SelectedPath = $ui.txtSave.Text }
		if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			$ui.txtSave.Text = $dlg.SelectedPath
		}
	})
	$ui.btnAddFile.add_Click({
		$dlg = New-Object System.Windows.Forms.OpenFileDialog
		$dlg.Filter = 'Torrent files (*.torrent)|*.torrent|All files (*.*)|*.*'
		$dlg.Title = 'Add torrent'
		$dlg.Multiselect = $true
		if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			foreach ($f in @($dlg.FileNames)) { Add-PtTorrent -Source $f }
		}
	})
	$ui.btnAddMagnet.add_Click({
		$ui.txtMagnet.Text = ''
		$ui.popMagnet.PlacementTarget = $ui.btnAddMagnet
		$ui.popMagnet.IsOpen = $true
		$ui.txtMagnet.Focus()
	})
	$ui.btnMagnetOk.add_Click({
		$m = [string]$ui.txtMagnet.Text
		$ui.popMagnet.IsOpen = $false
		if ($m) { Add-PtTorrent -Source $m }
	})
	$ui.btnMagnetCancel.add_Click({ $ui.popMagnet.IsOpen = $false })
	function Update-TransportButtons {
		$vis = [System.Windows.Visibility]::Visible
		$hid = [System.Windows.Visibility]::Collapsed
		$job = Get-SelectedJob
		if (-not $job) {
			$ui.btnPlayPause.Visibility = $hid
			$ui.btnStop.Visibility = $hid
			$ui.btnRemove.Visibility = $hid
			if ($ui.miCtxPlayPause) { $ui.miCtxPlayPause.Visibility = $hid }
			if ($ui.miCtxStop) { $ui.miCtxStop.Visibility = $hid }
			if ($ui.miCtxRemove) { $ui.miCtxRemove.Visibility = $hid }
			if ($ui.miCtxSep) { $ui.miCtxSep.Visibility = $hid }
			return
		}
		$ui.btnRemove.Visibility = $vis
		if ($ui.miCtxRemove) { $ui.miCtxRemove.Visibility = $vis }
		if ($ui.miCtxSep) { $ui.miCtxSep.Visibility = $vis }
		$st = [string]$job.Row.Status
		$isPaused = [bool]$job.Engine.IsPaused
		$isRunning = [bool]$job.Engine.IsRunning
		$playLabel = 'Start'
		$playGeo = $script:PtGeoPlay
		$showStop = $false
		if ($isRunning -and $isPaused) {
			$playLabel = 'Resume'
			$playGeo = $script:PtGeoPlay
			$showStop = $true
		} elseif ($isRunning) {
			$playLabel = 'Pause'
			$playGeo = $script:PtGeoPause
			$showStop = $true
		} elseif ($st -eq 'Paused') {
			$playLabel = 'Resume'
			$playGeo = $script:PtGeoPlay
			$showStop = $false
		}
		$ui.icoPlayPause.Data = $playGeo
		$ui.txtPlayPause.Text = $playLabel
		$ui.btnPlayPause.ToolTip = $playLabel
		$ui.btnPlayPause.Visibility = $vis
		$ui.btnStop.Visibility = $(if ($showStop) { $vis } else { $hid })
		if ($ui.miCtxPlayPause) {
			$ui.miCtxPlayPause.Header = $playLabel
			$ui.miCtxPlayPause.Visibility = $vis
		}
		if ($ui.icoCtxPlayPause) { $ui.icoCtxPlayPause.Data = $playGeo }
		if ($ui.miCtxStop) { $ui.miCtxStop.Visibility = $(if ($showStop) { $vis } else { $hid }) }
	}

	function Invoke-PtPlayPause {
		$job = Get-SelectedJob
		if (-not $job) { return }
		if ($job.Engine.IsRunning -and -not $job.Engine.IsPaused) {
			$job.Engine.Pause()
		} else {
			if ([string]$job.Row.Status -eq 'Error') {
				try { $job.Engine.Stop() } catch { }
			}
			$job.Engine.Resume()
		}
		try { $job.Row.Apply($job.Engine.GetStatus()) } catch { }
		try { Update-FilterView } catch { }
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	}
	function Invoke-PtStop {
		$job = Get-SelectedJob
		if (-not $job) { return }
		try { $job.Engine.Stop() } catch { }
		try { $job.Row.Apply($job.Engine.GetStatus()) } catch { }
		try { Update-FilterView } catch { }
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	}
	function Invoke-PtRemove {
		$job = Get-SelectedJob
		if (-not $job) { return }
		$r = [System.Windows.MessageBox]::Show(
			('Remove "{0}" from the list?' -f $job.Row.Name),
			'PowerTorrent',
			[System.Windows.MessageBoxButton]::YesNo)
		if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
		try { $job.Engine.Stop() } catch { }
		[void]$script:PtJobs.Remove($job)
		[void]$script:PtRows.Remove($job.Row)
		try { Update-TransportButtons } catch { }
	}

	$ui.btnPlayPause.add_Click({ Invoke-PtPlayPause })
	$ui.btnStop.add_Click({ Invoke-PtStop })
	$ui.btnRemove.add_Click({ Invoke-PtRemove })
	if ($ui.miCtxPlayPause) { $ui.miCtxPlayPause.add_Click({ Invoke-PtPlayPause }) }
	if ($ui.miCtxStop) { $ui.miCtxStop.add_Click({ Invoke-PtStop }) }
	if ($ui.miCtxRemove) { $ui.miCtxRemove.add_Click({ Invoke-PtRemove }) }
	$ui.lvTorrents.add_ContextMenuOpening({
		param($sender, $e)
		$row = $null
		try {
			$pos = [System.Windows.Input.Mouse]::GetPosition($ui.lvTorrents)
			$hit = [System.Windows.Media.VisualTreeHelper]::HitTest($ui.lvTorrents, $pos)
			$cur = $null
			if ($hit) { $cur = $hit.VisualHit }
			while ($null -ne $cur) {
				if ($cur -is [System.Windows.Controls.ListViewItem]) {
					$row = $cur.DataContext
					break
				}
				try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { break }
			}
		} catch { }
		if ($row) { $ui.lvTorrents.SelectedItem = $row }
		$job = Get-SelectedJob
		if (-not $job) {
			$e.Handled = $true
			return
		}
		try { Update-TransportButtons } catch { }
	})
	$ui.lstFilter.add_SelectionChanged({ try { Update-FilterView } catch { } })
	function Set-PtFilterCollapsed([bool]$collapsed) {
		$script:PtFilterCollapsed = [bool]$collapsed
		$hid = [System.Windows.Visibility]::Collapsed
		$vis = [System.Windows.Visibility]::Visible
		foreach ($item in $ui.lstFilter.Items) {
			$sp = $null
			try { $sp = $item.Content } catch { }
			if ($sp -isnot [System.Windows.Controls.StackPanel]) { continue }
			if ($sp.Children.Count -gt 1) {
				$sp.Children[1].Visibility = $(if ($collapsed) { $hid } else { $vis })
			}
			if ($sp.Children.Count -gt 0 -and $sp.Children[0] -is [System.Windows.Shapes.Path]) {
				if ($collapsed) {
					$sp.Children[0].Margin = New-Object System.Windows.Thickness 0
				} else {
					$sp.Children[0].Margin = New-Object System.Windows.Thickness 0,0,8,0
				}
			}
		}
		switch ($collapsed) {
			$true {
				$ui.colFilter.Width = New-Object System.Windows.GridLength 40
				$ui.icoFilterFold.Data = $script:PtGeoChevronRight
				$ui.btnFilterFold.ToolTip = 'Show filters'
			}
			$false {
				$ui.colFilter.Width = New-Object System.Windows.GridLength 150
				$ui.icoFilterFold.Data = $script:PtGeoChevronLeft
				$ui.btnFilterFold.ToolTip = 'Hide filters'
			}
		}
	}
	$ui.btnFilterFold.add_Click({
		switch ([bool]$script:PtFilterCollapsed) {
			$true  { Set-PtFilterCollapsed $false }
			$false { Set-PtFilterCollapsed $true }
		}
	})
	$ui.lvTorrents.add_SelectionChanged({ try { Update-TransportButtons } catch { } })
	$ui.btnRegister.add_Click({
		try {
			Register-PowerTorrentAssociations
			Update-AssocLabel
			[System.Windows.MessageBox]::Show('magnet: links for this Windows user now open PowerTorrent.`nYou can test from a browser or by clicking a magnet URI.', 'PowerTorrent') | Out-Null
		} catch {
			[System.Windows.MessageBox]::Show([string]$_, 'PowerTorrent') | Out-Null
		}
	})
	$ui.btnRegisterTorrent.add_Click({
		try {
			Register-PowerTorrentAssociations -IncludeTorrentFiles
			Update-AssocLabel
			[System.Windows.MessageBox]::Show(".torrent files for this Windows user now open PowerTorrent.`nWindows 10/11 may still need Open with if another app is the default.", 'PowerTorrent') | Out-Null
		} catch {
			[System.Windows.MessageBox]::Show([string]$_, 'PowerTorrent') | Out-Null
		}
	})
	$ui.btnUnregister.add_Click({
		Unregister-PowerTorrentAssociations
		Update-AssocLabel
		[System.Windows.MessageBox]::Show('Removed this user''s magnet: / PowerTorrent .torrent associations.', 'PowerTorrent') | Out-Null
	})

	function Update-MaxCaptionIcon {
		if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
			$ui.pathWinMax.Data = $script:PtGeomRestore
			$ui.btnWinMax.ToolTip = 'Restore'
		} else {
			$ui.pathWinMax.Data = $script:PtGeomMax
			$ui.btnWinMax.ToolTip = 'Maximize'
		}
	}

	$ui.btnOptions.add_Click({
		switch ([bool]$ui.popOptions.IsOpen) {
			$true  { $ui.popOptions.IsOpen = $false }
			$false { $ui.popOptions.IsOpen = $true }
		}
	})
	$window.add_PreviewMouseLeftButtonDown({
		param($sender, $e)
		if (-not [bool]$ui.popOptions.IsOpen) { return }
		if ([bool]$ui.btnOptions.IsMouseOver) { return }
		$child = $ui.popOptions.Child
		if ($null -ne $child -and [bool]$child.IsMouseOver) { return }
		if ($ui.cmbTheme -and [bool]$ui.cmbTheme.IsDropDownOpen) { return }
		$ui.popOptions.IsOpen = $false
	})
	function Hide-PtToTray {
		if ($script:PtInTray -or $script:PtHidingToTray) { return }
		$script:PtHidingToTray = $true
		try {
			$window.ShowInTaskbar = $false
			if ($window.WindowState -ne [System.Windows.WindowState]::Minimized) {
				$window.WindowState = [System.Windows.WindowState]::Minimized
			}
			$script:PtInTray = $true
			if ($script:PtNotify) {
				$script:PtNotify.Visible = $true
				try {
					$script:PtNotify.ShowBalloonTip(2500, 'PowerTorrent', 'PowerTorrent is minimized to the notification area.', [System.Windows.Forms.ToolTipIcon]::Info)
				} catch { }
			}
		} finally {
			$script:PtHidingToTray = $false
		}
	}
	function Show-PtFromTray {
		if ($script:PtHidingToTray) { return }
		$script:PtInTray = $false
		if ($script:PtNotify) { try { $script:PtNotify.Visible = $false } catch { } }
		$window.ShowInTaskbar = $true
		$window.WindowState = [System.Windows.WindowState]::Normal
		try { [void]$window.Activate() } catch { }
		try { Update-MaxCaptionIcon } catch { }
	}
	function Exit-PtFromTray {
		$script:PtReallyExit = $true
		try { $window.DialogResult = $true } catch {
			try { $window.Close() } catch { }
		}
	}

	Add-Type -AssemblyName System.Drawing | Out-Null
	$script:PtReallyExit = $false
	$script:PtInTray = $false
	$script:PtHidingToTray = $false
	try {
		$ni = New-Object System.Windows.Forms.NotifyIcon
		$ni.Text = 'PowerTorrent'
		$ni.Visible = $false
		if ($script:PtTrayIdle) { $ni.Icon = $script:PtTrayIdle }
		else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
		$cm = New-Object System.Windows.Forms.ContextMenu
		$miShow = New-Object System.Windows.Forms.MenuItem 'Show PowerTorrent'
		$miExit = New-Object System.Windows.Forms.MenuItem 'Exit'
		[void]$cm.MenuItems.Add($miShow)
		[void]$cm.MenuItems.Add($miExit)
		$ni.ContextMenu = $cm
		$miShow.add_Click({ Show-PtFromTray })
		$miExit.add_Click({ Exit-PtFromTray })
		$ni.add_DoubleClick({ Show-PtFromTray })
		$script:PtNotify = $ni
	} catch {
		$script:PtNotify = $null
	}

	$ui.btnWinMin.add_Click({ Hide-PtToTray })
	$ui.btnWinMax.add_Click({
		if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
			$window.WindowState = [System.Windows.WindowState]::Normal
		} else {
			$window.WindowState = [System.Windows.WindowState]::Maximized
		}
		Update-MaxCaptionIcon
	})
	$ui.btnWinClose.add_Click({
		if ($ui.chkCloseToTray -and [bool]$ui.chkCloseToTray.IsChecked) {
			Hide-PtToTray
			return
		}
		Exit-PtFromTray
	})
	$ui.btnWinClose.add_MouseEnter({
		try { [PowerTorrent.ThemeUtil]::SetPathStrokeRgb($ui.pathWinClose, 255, 255, 255) } catch { }
	})
	$ui.btnWinClose.add_MouseLeave({
		try { [PowerTorrent.ThemeUtil]::SetPathStrokeKey($ui.pathWinClose, $window.Resources, 'Theme.Text') } catch { }
	})

	$ui.hdrBar.add_MouseLeftButtonDown({
		param($sender, $e)
		if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
		if ($e.ClickCount -ge 2) {
			if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
				$window.WindowState = [System.Windows.WindowState]::Normal
			} else {
				$window.WindowState = [System.Windows.WindowState]::Maximized
			}
			Update-MaxCaptionIcon
			return
		}
		try { $window.DragMove() } catch { }
	})
	$window.add_StateChanged({
		Update-MaxCaptionIcon
		if ($script:PtHidingToTray) { return }
		if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
			Hide-PtToTray
		}
	})

	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(400)
	$timer.add_Tick({ Update-UiStatus })
	$timer.Start()

	$planetTimer = New-Object System.Windows.Threading.DispatcherTimer
	$planetTimer.Interval = [TimeSpan]::FromMilliseconds(140)
	$planetTimer.add_Tick({
		if (-not $script:PtPlanetFrames -or $script:PtPlanetFrames.Count -eq 0) { return }
		if (-not $script:PtPlanetConnected) {
			if ($script:PtPlanetIdle) { $ui.imgPlanet.Source = $script:PtPlanetIdle }
			$script:PtPlanetIndex = 2
			return
		}
		$script:PtPlanetIndex = ($script:PtPlanetIndex + 1) % $script:PtPlanetFrames.Count
		$ui.imgPlanet.Source = $script:PtPlanetFrames[$script:PtPlanetIndex]
	})
	$planetTimer.Start()

	$window.add_Closing({
		param($sender, $e)
		if (-not $script:PtReallyExit -and $ui.chkCloseToTray -and [bool]$ui.chkCloseToTray.IsChecked) {
			$e.Cancel = $true
			Hide-PtToTray
			return
		}
		try { $timer.Stop() } catch { }
		try { $planetTimer.Stop() } catch { }
		try { Stop-AllTorrents } catch { }
		if ($script:PtNotify) {
			try { $script:PtNotify.Visible = $false } catch { }
			try { $script:PtNotify.Dispose() } catch { }
			$script:PtNotify = $null
		}
		if ($script:PtMutex) {
			try { [void]$script:PtMutex.ReleaseMutex() } catch { }
			try { $script:PtMutex.Dispose() } catch { }
		}
	})

	try { Update-TransportButtons } catch { }

	if ($AutoStart -and $InitialSource) {
		$window.add_ContentRendered({
			Add-PtTorrent -Source $InitialSource
		})
	}

	try {
		[void]$window.ShowDialog()
	} catch {
		$dump = Join-Path $env:TEMP 'pt-gui-fail.txt'
		[System.IO.File]::WriteAllText($dump, $_.Exception.ToString())
		throw
	}
}

# --- main ---
Initialize-PowerTorrentEngine
$script:PtTheme = 'Ice'
$script:PtCloseToTray = $false
Import-PtIniToSession
if (-not $script:PtTheme) { $script:PtTheme = 'Ice' }

if ($SelfTest) {
	$fail = [PowerTorrent.Engine]::SelfTest()
	if ($fail) {
		Write-Host "SELFTEST FAILED: $fail" -ForegroundColor Red
		exit 1
	}
	Write-Host 'SELFTEST OK' -ForegroundColor Green
	exit 0
}

if ($Unregister) {
	Unregister-PowerTorrentAssociations
	Write-Host 'Removed current-user magnet: / PowerTorrent .torrent associations.' -ForegroundColor Green
	exit 0
}

if ($Register) {
	if (-not (Confirm-PowerTorrentNotice)) { exit 1 }
	if ($MagnetOnly) { Register-PowerTorrentAssociations }
	else { Register-PowerTorrentAssociations -IncludeTorrentFiles }
	Write-Host 'Registered PowerTorrent as the magnet: handler for this Windows user.' -ForegroundColor Green
	if (-not $MagnetOnly) {
		Write-Host 'Also registered .torrent files (Windows may still ask you to confirm the default app).' -ForegroundColor Green
	}
	Write-Host ('Command: {0}' -f (Get-PowerTorrentLaunchCommand)) -ForegroundColor DarkGray
	exit 0
}

try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if ($Torrent -and $Torrent.Trim().ToLowerInvariant().StartsWith('magnet:')) {
	$Magnet = $Torrent
	$Torrent = ''
}

$isMagnet = -not [string]::IsNullOrWhiteSpace($Magnet)
$source = ''
if ($isMagnet) { $source = $Magnet.Trim() }
elseif ($Torrent) { $source = $Torrent }

$useGui = -not [bool]$NoGui -and -not [bool]$ListOnly

if ($useGui) {
	if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
		$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
		$argList = New-Object System.Collections.Generic.List[string]
		[void]$argList.Add('-STA')
		[void]$argList.Add('-NoProfile')
		[void]$argList.Add('-ExecutionPolicy')
		[void]$argList.Add('Bypass')
		[void]$argList.Add('-File')
		[void]$argList.Add((Get-PowerTorrentScriptPath))
		foreach ($k in $PSBoundParameters.Keys) {
			$v = $PSBoundParameters[$k]
			if ($v -is [Management.Automation.SwitchParameter]) {
				if ($v) { [void]$argList.Add("-$k") }
			} else {
				[void]$argList.Add("-$k")
				[void]$argList.Add([string]$v)
			}
		}
		$p = Start-Process -FilePath $exe -ArgumentList $argList.ToArray() -Wait -PassThru
		exit $p.ExitCode
	}
	$save = $SavePath
	if ([string]::IsNullOrWhiteSpace($save)) { $save = Get-DefaultSavePath }
	$auto = -not [string]::IsNullOrWhiteSpace($source)
	$createdNew = $false
	$script:PtMutex = New-Object System.Threading.Mutex($false, 'Local\PowerTorrent.Gui', [ref]$createdNew)
	if (-not $createdNew) {
		if ($source) { Send-PtInbox $source }
		try { $script:PtMutex.Dispose() } catch { }
		exit 0
	}
	try { [void]$script:PtMutex.WaitOne(0) } catch { }
	if (-not (Confirm-PowerTorrentNotice -Gui)) {
		try { [void]$script:PtMutex.ReleaseMutex() } catch { }
		try { $script:PtMutex.Dispose() } catch { }
		exit 1
	}
	Show-PowerTorrentGui -InitialSource $source -InitialSave $save -AutoStart:$auto
	exit 0
}

if (-not $isMagnet -and -not $Torrent) {
	$Torrent = Select-TorrentFile
	if (-not $Torrent) {
		Write-Host 'No torrent file selected. Exiting.' -ForegroundColor Yellow
		exit 0
	}
	$source = $Torrent
}

if (-not $isMagnet) {
	$source = [System.IO.Path]::GetFullPath($source)
	if (-not (Test-Path -LiteralPath $source)) {
		throw "Torrent file not found: $source"
	}
}

if ([string]::IsNullOrWhiteSpace($SavePath)) {
	if ($isMagnet) { $SavePath = Get-DefaultSavePath }
	else { $SavePath = [System.IO.Path]::GetDirectoryName($source) }
}

if (-not (Confirm-PowerTorrentNotice)) { exit 1 }

Write-Host ''
Write-Host '  PowerTorrent 1.3	|  Windows PowerShell 5.1  |  no dependencies' -ForegroundColor Cyan
Write-Host '  =================================================================' -ForegroundColor Cyan

$cfg = New-PowerTorrentSettings -Source $source -OutDir $SavePath -ListenPort $Port -Peers $MaxPeers `
	-Dht (-not [bool]$NoDht) -Encrypt (-not [bool]$NoEncrypt) -Utp (-not [bool]$NoUtp) `
	-Seq ([bool]$Sequential) -Seed (-not [bool]$NoSeed) -Forced $Peer -Level $LogLevel
$engine = [PowerTorrent.Engine]::new($cfg)
$info = $engine.GetInfo()
Show-TorrentInfo $info
Write-Host ("  Save path  : {0}" -f $cfg.SavePath) -ForegroundColor DarkGray
Write-Host ''

if ($ListOnly) {
	if ($isMagnet) {
		Write-Host 'ListOnly: magnet metadata is not fetched. Run without -ListOnly to download.' -ForegroundColor Yellow
	} else {
		Write-Host 'ListOnly: not starting download.' -ForegroundColor Yellow
	}
	exit 0
}

Start-PowerTorrentConsole -engine $engine
if ($Host.Name -eq 'Windows PowerShell ISE Host') {
	Start-Sleep -Seconds 3
}
